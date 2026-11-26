# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "rack/test"
require "socket"
require "json"
require "yaml"
require_relative "../support/green_ci"

# The launcher-backed API: projects tree + sessions, launch (with the Remote Control verdict), create, agents sidebar.
class LaunchTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods
  include SignIn

  SOCK = ENV.fetch("LAUNCHER_SOCKET")
  def app = Hanami.app

  # the card the fake launcher's busy session's running tool names (its verdict's `card`); a test sets it to its own card
  TOOL_CARD = 7

  def setup
    super
    @tool_card = TOOL_CARD
    store.upsert_project(slug: "group/repo", path: "/projects/group/repo", remote: nil, branch: "main", own: true,
                         last_commit_at: Busyyaks::Clock.epoch, commits_window: 1, mine_window: 1, dirty: 0, unpushed: nil,
                         scanned_at: 1)
    assert_equal 200, sign_in
    get "/"
    @csrf = last_response.body[/name="csrf-token" content="([^"]+)"/, 1]
    @remote_control = { remote_control: "on", remote_control_name: "by_group_repo_teamlead", trust: "accepted" }
  end

  def teardown
    Busyyaks::LauncherClient.forget_agents_snapshot! # the shared ≤ 2 s snapshot must not carry one test's fake into the next
    @server&.close
    @thread&.kill
    File.unlink(SOCK) if File.socket?(SOCK)
    super
  end

  def api(verb, path, body = nil, csrf: @csrf)
    headers = { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json" }
    headers["HTTP_X_CSRF_TOKEN"] = csrf if csrf
    send(verb, path, body && JSON.generate(body), headers)
    assert_equal "application/json", last_response.content_type.split(";").first,
                 "#{verb} #{path}: #{last_response.body[0, 200]}"
    JSON.parse(last_response.body)
  end

  # A fake bin/launcher: records requests, answers like the real one.
  def fake_launcher
    File.unlink(SOCK) if File.socket?(SOCK)
    @requests = []
    @server = UNIXServer.new(SOCK)
    @thread = Thread.new do
      loop do
        c = @server.accept
        req = JSON.parse(c.gets)
        @requests << req
        c.puts JSON.generate(answer(req))
        c.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
  end

  def answer(req)
    case req["op"]
    when "name"
      n = ((@names ||= Hash.new(0))[req["base"]] += 1)
      { ok: true, session: n == 1 ? req["base"] : "#{req["base"]}_#{n - 1}" }
    when "launch"
      return @launch_refused if @launch_refused

      { ok: true, session: req["session"], type: req["type"], launcher: req["launcher"],
        prompt: !req["prompt_template"].nil?, **@remote_control, }
    when "lead_key"
      k = (@lead_keys || {})[req["session"]]
      k ? { ok: true, key: k } : { ok: false, status: 422, error: "#{req['session']}: no lead this launcher started" }
    when "sessions"
      names = ["group_repo", *@live_extra]
      # hand: a claude started in the repo by hand — no skills stage, so the launcher says launched: false
      row = { project_path: "/projects/group/repo", created: 1, attached: false }
      { ok: true,
        sessions: names.map { |n| row.merge(name: n, launched: true) } + [row.merge(name: "hand", launched: false)], }
    when "jobs"
      { ok: true, jobs: [{ url: "https://github.com/o/r.git", path: "/projects/r", status: "failed", exit: 128,
                           tail: ["fatal: nope"], }], }
    when "agents" then @agents_refused || agents_snapshot
    when "agent_tasks"
      { ok: true,
        agents: [{ id: "a1", description: "Sweep exhibitor pages", type: "subagent", state: "running",
mtime: Busyyaks::Clock.now.to_f, }],
        workflows: [{ id: "wf_1", name: "review-changes", status: "running", agents_n: 4 }], }
    when "reap_preview"
      { ok: true, quiet_min: 30, candidates: [{ name: "group_repo", socket: "default", reason: "idle", activity: 1,
                                                project_path: "/projects/group/repo", engines: ["claudeapi"], title: "t", }], }
    when "reap"
      { ok: true, results: req["sessions"].map do |s|
        { name: s["name"], stopped: s["name"] == "group_repo",
          reason: s["name"] == "group_repo" ? "idle" : "no longer eligible", }
      end, }
    when "stop"
      { ok: true, results: req["sessions"].map do |n|
        { name: n, stopped: n != "other_project",
          reason: n == "other_project" ? "not in this project (/projects/x)" : "stopped", }
      end, }
    when "answer"
      if req["hash"] == "h1"
        { ok: true, pressed: req["key"] }
      else
        { ok: false, error: "by_asker: the dialog on its screen changed — nothing typed", status: 409 }
      end
    when "create"
      if req["url"].to_s.empty?
        { ok: false, error: "already exists: /x" }
      else
        { ok: true, path: "/projects/r", cloning: true, trusted: false }
      end
    end
  end

  # the collector's snapshot: a busy session with subagents, one on an unconfigured engine, one blocked on a dialog
  def agents_snapshot
    busy = { name: "group_repo", socket: "default", attached: 1, created: 1, activity: Busyyaks::Clock.epoch,
             claude_url: "https://claude.ai/code/session_x",
             panes: [{ target: "0.0", cwd: "/mnt/x/group/repo/sub", project_path: "/projects/group/repo/sub",
                       engine: "claudeapi", engine_label: "Claude", model: "opus", status: "busy", title: "kanban work",
                       subagents_running: 3,
                       screen: { state: "working", rule: "live_turn_working",
                                 activity: { phase: "tool", elapsed_s: 65, tokens: "↓ 1.6k", tool: "busyyaks · kanban_comment",
                                             card: @tool_card, background: "1 shell", }, }, }], }
    unconfigured = { name: "elsewhere", socket: "default", attached: 0, created: 1, activity: 1,
                     panes: [{ target: "0.0", cwd: "/tmp", project_path: nil, engine: "codex", status: "idle", status_at: 100.0,
                               screen: { error: "engine \"codex\" is not configured (config/busyyaks.yml engines; known: " \
                                                "claude, claudeapi, localclaude, hermes)" }, }], }
    dialog = { question: "Do you want to proceed?", command: "rm -rf build", escape: true, free_text: true, hash: "h1",
               answerable: true,
               options: [{ key: "1", label: "Yes", free: false }, { key: "3", label: "No, and tell Claude", free: true }], }
    by_asker = { name: "by_asker", socket: "default", attached: 0, created: 1, activity: 2,
              panes: [{ target: "0.0", cwd: "/mnt/x/group/repo", project_path: "/projects/group/repo", engine: "claudeapi",
                        status: "idle", screen: { state: "blocked", rule: "bash_permission_prompt", dialog: dialog }, }], }
    { ok: true, generated_at: Busyyaks::Clock.now.to_f, age_s: 1.0, interval_s: 5, collector_error: nil,
      sessions: [busy, unconfigured, by_asker], }
  end

  def test_projects_is_a_folder_tree_with_launchers_sessions_and_jobs
    fake_launcher
    j = api(:get, "/api/projects")
    assert_equal 200, last_response.status
    folder = j["tree"][0]
    assert_equal %w[folder group 1], [folder["type"], folder["path"], folder["repos"].to_s]
    assert_equal 1, folder["live"]
    repo = folder["children"][0]
    assert_equal "group/repo", repo["project"]["slug"]
    assert_equal ["group_repo"], repo["project"]["sessions"].map { |s| s["name"] }
    # the operator, 2026-11-24: a session busyyaks did not launch is never listed (nor stopped by Stop all, nor
    # offered as an assignee) — hand runs in this repo and is left out
    # the board config's agent types (config/kanban.yml) with their launchers, and the cap state from the engine
    assert_equal [["lead", "Team lead", %w[fullclaude localclaude], true],
                  ["worker", "Worker", %w[fullclaude localclaude], true],
                  ["team", "Sub team", %w[fullclaude localclaude], true],
                  ["plain", "Plain", %w[fullclaude localclaude], false],],

                 j["launches"]["types"].map { |t| [t["key"], t["label"], t["launchers"].map { |l| l["key"] }, t["prompt"]] }
    assert_equal({ "max_sessions" => nil, "running" => 0, "free" => nil },
                 j["launches"]["concurrency"].slice("max_sessions", "running", "free"))
    assert_nil j["launches"]["sessions_error"]
    assert_nil j["launcher_error"]
    assert_equal [{ "url" => "https://github.com/o/r.git", "path" => "/projects/r", "status" => "failed", "exit" => 128,
                    "tail" => "fatal: nope", }],
                 j["jobs"]
    assert_equal [{ "path" => "/projects/none", "prefix" => "" }], j["roots"]
    assert_equal 1, j["total"]
  end

  # card 275: the project page polls GET /api/projects/*slug/sessions (card 614) — a session started later is listed,
  # one that ended is gone, and the launcher down answers 200 with launcher_error and NO sessions (it could not ask):
  # this test proves the answers the page reads; the held list itself is the frontend's (sessionLanes.test.ts heldSessions)
  def test_project_sessions_poll_follows_the_launcher
    fake_launcher
    names = -> { api(:get, "/api/projects/group/repo/sessions")["sessions"].map { |s| s["name"] } }
    assert_equal ["group_repo"], names.call
    assert_equal 200, last_response.status
    @live_extra = ["group_repo_worker"]
    assert_equal %w[group_repo group_repo_worker], names.call, "a session started after the page loaded is listed"
    @live_extra = nil
    assert_equal ["group_repo"], names.call, "an ended session is gone"

    @server.close
    @thread.kill
    File.unlink(SOCK)
    j = api(:get, "/api/projects/group/repo/sessions")
    assert_equal 200, last_response.status
    assert_equal [], j["sessions"]
    assert_includes j["launcher_error"], "launcher not reachable"
    api(:get, "/api/projects/nope/sessions")
    assert_equal 404, last_response.status
  end

  def agent(j, name) = j["groups"].flat_map { |g| g["sessions"] }.find { |x| x["name"] == name }

  # unread (formerly "done"): a turn that ended after the operator last saw the session;
  # opening its row marks it seen.
  def test_unread_until_the_operator_opens_it
    fake_launcher
    refute agent(api(:get, "/api/agents"), "elsewhere")["unread"], "first sighting = seen"
    store.agent_seen!("default/elsewhere", now: 50.0) # last seen before its turn ended (status_at 100)
    j = api(:get, "/api/agents")
    assert_equal ["idle", true, 1, 1],
                 [agent(j, "elsewhere")["state"], agent(j, "elsewhere")["unread"], j["totals"]["unread"], j["totals"]["you"]],
                 "you = the blocked by_asker only: unread does not need the operator"
    assert_equal({ "key" => "default/elsewhere", "seen" => true }, api(:post, "/api/agents/seen", { key: "default/elsewhere" }))
    refute agent(api(:get, "/api/agents"), "elsewhere")["unread"]
    api(:post, "/api/agents/seen", { key: "" })
    assert_equal 400, last_response.status
  end

  # a session's question on the board (its card in the ask column) makes it blocked, with a link to the card
  def test_a_card_question_blocks_its_owner_session
    fake_launcher
    kb = Busyyaks::Kanban.default
    id = kb.create(slug: "group/repo", title: "pick one", by: "op", column: "doing")
    kb.set_owner(id, session: "elsewhere", by: "op")
    kb.ask(id, question: "Auth or imgproc first?", options: nil, by: "elsewhere")
    s = agent(api(:get, "/api/agents"), "elsewhere")
    assert_equal ["blocked", "card ##{id}"], s.values_at("state", "state_by")
    assert_equal [[id, "Auth or imgproc first?", "/projects/group/repo?tab=board&card=#{id}", []]],
                 s["asks"].map { |a| a.values_at("id", "question", "path", "options") }
    # the question's choices come with it (the project page's Needs-you lane answers with one)
    other = kb.create(slug: "group/repo", title: "pick two", by: "op", column: "doing")
    kb.set_owner(other, session: "elsewhere", by: "op")
    kb.ask(other, question: "Rebase or split?", options: ["Rebase", "Split PR"], by: "elsewhere")
    s = agent(api(:get, "/api/agents"), "elsewhere")
    assert_equal ["Rebase", "Split PR"], s["asks"].find { |a| a["id"] == other }["options"]
  end

  # the Working lane's evidence — the running tool, the turn's elapsed seconds and tokens, the card a kanban
  # tool acts on — from the screen's verdict only; a session whose screen says nothing has nil there (shown "working")
  def test_agents_carry_what_each_working_screen_shows
    fake_launcher
    j = api(:get, "/api/agents")
    # the background work its footer counts rides along ("1 shell": a live turn keeps its own phase)
    assert_equal({ "tool" => "busyyaks · kanban_comment", "elapsed_s" => 65, "tokens" => "↓ 1.6k", "card" => TOOL_CARD,
                   "background" => "1 shell", }, agent(j, "group_repo")["live"])
    assert_equal({ "tool" => nil, "elapsed_s" => nil, "tokens" => nil, "card" => nil, "background" => nil },
                 agent(j, "by_asker")["live"])
  end

  # a card blocked on the world (another card, CI, a third party) is not the operator's to answer — its owner
  # session is not "needs input", the totals do not count it, its card row says it is blocked externally
  def test_a_blocked_external_card_does_not_block_its_owner_session
    fake_launcher
    kb = Busyyaks::Kanban.default
    id = kb.create(slug: "group/repo", title: "held back", by: "op", column: "doing")
    kb.register_session(session: "elsewhere", project: "group/repo", type: "plain", launcher: "fullclaude", by: "op")
    kb.set_owner(id, session: "elsewhere", by: "op")
    before = api(:get, "/api/agents")["totals"].values_at("blocked", "you")
    kb.block(id, reason: "waits for card #9 to merge", url: "https://github.com/o/r/pulls", by: "elsewhere")
    j = api(:get, "/api/agents")
    s = agent(j, "elsewhere")
    refute_equal "blocked", s["state"]
    assert_equal [[], before], [s["asks"], j["totals"].values_at("blocked", "you")]
    assert_equal [[id, "waits for card #9 to merge"]], s["cards"].map { |c| c.values_at("id", "blocked_external") }
    # the same card with a question waits for the operator again
    kb.ask(id, question: "Unblock it?", by: "elsewhere")
    s = agent(api(:get, "/api/agents"), "elsewhere")
    assert_equal ["blocked", [id], nil], [s["state"], s["asks"].map { |a| a["id"] }, s["cards"][0]["blocked_external"]]
  end

  # a gate card the operator approved, its agent carrying it on (Ready to merge → Merged), is no review —
  # its owner session is not in review, its card row says approved
  def test_an_approved_gate_card_does_not_put_its_owner_session_in_review
    fake_launcher
    kb = Busyyaks::Kanban.default
    id = kb.create(slug: "group/repo", title: "merging", by: "op", column: "ready")
    kb.register_session(session: "elsewhere", project: "group/repo", type: "plain", launcher: "fullclaude", by: "op")
    kb.set_owner(id, session: "elsewhere", by: "op")
    s = agent(api(:get, "/api/agents"), "elsewhere")
    assert_equal ["review", [id], false], [s["state"], s["reviews"].map { |r| r["id"] }, s["cards"][0]["approved_carried_on"]],
                 "unapproved in the gate: the operator's to approve"
    Hanami.app["db.gateway"].connection[:cards].where(id: id).update(approved_at: 1_700_000_000, approved_by: "op")
    s = agent(api(:get, "/api/agents"), "elsewhere")
    refute_equal "review", s["state"]
    assert_equal [[], [[id, true]]], [s["reviews"], s["cards"].map { |c| c.values_at("id", "approved_carried_on") }]
  end

  # a session's handed-over card (the handoff column) waits for the operator's review: state review, the card + its PR linked
  def test_a_handed_over_card_puts_its_owner_session_in_review
    fake_launcher
    kb = Busyyaks::Kanban.default
    GreenCi.on!(kb, "group/repo") # its gates ask CI
    id = kb.create(slug: "group/repo", title: "ship it", by: "op", column: "doing")
    kb.set_owner(id, session: "elsewhere", by: "op")
    now = Busyyaks::Clock.epoch # the github service read the PR's checks green: a gate is handed off on green CI only
    Hanami.app["db.gateway"].connection[:gh_pr_checks].insert(repo: "o/r", ref: "pr:5", requested_at: now, checked_at: now,
                                                             number: 5, state: "success", finished_at: now,
                                                             base: "main", draft: false, merge_state: "clean",
                                                             builds: '["https://ci/1"]') # the build handed off (card #470)
    # the PR its agent opened, on the project's repo
    Hanami.app["db.gateway"].connection[:projects].where(slug: "group/repo").update(remote: "https://github.com/o/r.git")
    kb.assign_pr(id, url: "https://github.com/o/r/pull/5", role: "pr", by: "elsewhere")
    kb.handoff(id, qa: "Open the board, check the card ships what it says, then the PR diff and its CI build.",
                   pr_url: "https://github.com/o/r/pull/5", ci_url: "https://ci/1", ui_change: false, by: "elsewhere")
    j = api(:get, "/api/agents")
    s = agent(j, "elsewhere")
    assert_equal ["review", "card ##{id} in review"], s.values_at("state", "state_by")
    assert_equal [[id, "https://github.com/o/r/pull/5"]], s["reviews"].map { |r| r.values_at("id", "pr_url") }
    assert_equal 1, j["totals"]["review"]
    # blocked on the world while in the gate: no review for the operator, not counted, not blocked on the operator
    kb.block(id, reason: "waits for card #9 to merge", url: "https://github.com/o/r/pulls", by: "elsewhere")
    j = api(:get, "/api/agents")
    s = agent(j, "elsewhere")
    assert_equal [[], [], 0], [s["reviews"], s["asks"], j["totals"]["review"]]
    refute_includes %w[review blocked], s["state"]
    kb.unblock(id, by: "elsewhere")
    assert_equal "review", agent(api(:get, "/api/agents"), "elsewhere")["state"]
    # card #248: its CI re-runs (pending): not approvable now — no review, its row says it waits for CI
    Hanami.app["db.gateway"].connection[:gh_pr_checks].where(repo: "o/r", ref: "pr:5").update(state: "pending",
                                                                                            finished_at: nil)
    kb.approval_prefetch_pass # the notifier's watch pass sees it (reads take its view)
    j = api(:get, "/api/agents")
    s = agent(j, "elsewhere")
    refute_equal "review", s["state"]
    assert_equal [], s["reviews"]
    assert_equal 0, j["totals"]["review"]
    kb.register_session(session: "elsewhere", project: "group/repo", type: "plain", launcher: "fullclaude", by: "op")
    kb.set_owner(id, session: "elsewhere", by: "op") # owned since the registration: its card list is known
    s = agent(api(:get, "/api/agents"), "elsewhere")
    assert_equal [[id, "PR #5: CI is still running"]], s["cards"].map { |c| c.values_at("id", "gate_hold") }
  end

  # a session's cards say whether it is finished — every card it owns in the board's done column
  def test_a_session_is_finished_only_when_every_card_it_owns_is_done
    fake_launcher
    kb = Busyyaks::Kanban.default
    s = agent(api(:get, "/api/agents"), "elsewhere")
    assert_equal ["idle", false, []], s.values_at("state", "cards_known", "cards"),
                 "no open registration: its cards are unknown"
    assert_equal [nil, nil], s.values_at("agent", "agent_type"), "no registration: no agent name, no type"
    kb.register_session(session: "elsewhere", project: "group/repo", type: "plain", launcher: "fullclaude", by: "op")
    id = kb.create(slug: "group/repo", title: "ship it", by: "op", column: "doing")
    kb.set_owner(id, session: "elsewhere", by: "op")
    s = agent(api(:get, "/api/agents"), "elsewhere")
    assert_equal ["idle", true, 0], s.values_at("state", "cards_known", "cards_finished")
    assert_equal ["claude-elsewhere", "plain", nil], s.values_at("agent", "agent_type", "phase"), "its face"
    assert_equal [[id, "In progress", "working", "/projects/group/repo?tab=board&card=#{id}"]],
                 s["cards"].map { |c| c.values_at("id", "column_label", "column_type", "path") }
    kb.move(id, column: "merged", by: "op")
    j = api(:get, "/api/agents")
    s = agent(j, "elsewhere")
    assert_equal ["finished", "cards: 1 in Merged", [], 1, 1],
                 [*s.values_at("state", "state_by", "cards", "cards_finished"), j["totals"]["finished"]]
  end

  def test_a_dialog_is_answered_from_the_sidebar_only_while_it_is_on_the_screen
    fake_launcher
    assert_equal({ "pressed" => "1" },
                 api(:post, "/api/agents/answer", { session: "by_asker", socket: "default", hash: "h1", key: "1" }))
    assert_equal({ "op" => "answer", "session" => "by_asker", "socket" => "default", "hash" => "h1", "key" => "1" },
                 @requests.find { |r| r["op"] == "answer" })
    r = api(:post, "/api/agents/answer", { session: "by_asker", socket: "default", hash: "old", key: "1" })
    assert_equal [422, "by_asker: the dialog on its screen changed — nothing typed"], [last_response.status, r["error"]]
    api(:post, "/api/agents/answer", { session: "by_asker", socket: "default", hash: "h1" })
    assert_equal 400, last_response.status
    api(:post, "/api/agents/answer", { session: "by_asker", socket: "default", hash: "h1", key: "1" }, csrf: nil)
    assert_equal 403, last_response.status
  end

  def test_clone_and_refused_create_are_reported
    fake_launcher
    j = api(:post, "/api/create", { root: "/projects", name: "", url: "https://github.com/o/r.git" })
    assert_equal 202, last_response.status
    assert_equal({ "cloning" => true, "path" => "r", "trusted" => false }, j, "trusted passed through: a clone never")
    assert_equal({ "op" => "create", "root" => "/projects", "name" => "", "url" => "https://github.com/o/r.git" },
                 @requests.find { |r| r["op"] == "create" })
    j = api(:post, "/api/create", { root: "/projects", name: "x", url: "" })
    assert_equal 422, last_response.status
    assert_equal "already exists: /x", j["error"]
  end

  def test_agents_groups_by_project_and_shows_teams
    fake_launcher
    j = api(:get, "/api/agents")
    assert_equal 200, last_response.status
    assert_equal ["group/repo", nil], j["groups"].map { |g| g["slug"] }
    assert_equal %w[blocked idle], j["groups"].map { |g| g["state"] }, "a group shows its worst session"
    assert_equal "outside tracked repos", j["groups"][1]["label"]
    blocked, s = j["groups"][0]["sessions"]
    assert_equal ["by_asker", "blocked", "screen: bash_permission_prompt"], blocked.values_at("name", "state", "state_by")
    assert_equal [["h1", %w[1 3], true]],
                 blocked["dialogs"].map { |d| [d["hash"], d["options"].map { |o| o["key"] }, d["answerable"]] }
    assert_equal %w[working 3 default/group_repo], [s["state"], s["subagents"].to_s, s["key"]]
    assert_equal ["Claude"], s["engines"]
    assert_equal ["codex (not configured)"], j["groups"][1]["sessions"][0]["engines"],
                 "an engine missing from config is said, never guessed"
    assert_equal "https://claude.ai/code/session_x", s["claude_url"]
    assert_equal "ssh -t box tmux attach -t group_repo", s["ssh_attach"]
    assert_equal({ "sessions" => 3, "busy" => 1, "subagents" => 3, "blocked" => 1, "review" => 0, "finished" => 0,
                   "unread" => 0, "you" => 1, },
                 j["totals"])
    refute j["stale"]
    j = api(:get, "/api/agents/team?session=group_repo&socket=default")
    assert_equal ["Sweep exhibitor pages"], j["agents"].map { |a| a["label"] }
    assert_equal ["review-changes"], j["workflows"].map { |w| w["label"] }
    assert_equal({ "op" => "agent_tasks", "session" => "group_repo", "socket" => "default" },
                 @requests.find { |r| r["op"] == "agent_tasks" })
    api(:get, "/api/agents/team")
    assert_equal 400, last_response.status
  end

  def test_session_links_carry_the_model_the_pane_runs
    fake_launcher
    j = api(:get, "/api/projects/group/repo/board")
    assert_equal 200, last_response.status
    assert_equal "opus", j["session_links"]["group_repo"]["model"]
    assert_nil j["session_links"]["elsewhere"]["model"]
  end

  # the card dialog's live line — what the card's project's sessions and its owner do now, never the screen
  def test_card_live_reads_what_the_sessions_do_now
    fake_launcher
    k = Busyyaks::Kanban.default
    id = k.create(slug: "group/repo", title: "t", by: "op", column: "doing")
    j = api(:get, "/api/cards/#{id}/live")
    assert_equal 200, last_response.status
    assert_equal %w[by_asker group_repo], j["sessions"].keys.sort # "elsewhere" runs outside this project
    assert_equal({ "state" => "working", "state_by" => "screen: live_turn_working", "phase" => "tool", "elapsed_s" => 65,
                   "tokens" => "↓ 1.6k", "tool" => "busyyaks · kanban_comment", "card" => TOOL_CARD,
                   "background" => "1 shell", "subagents" => 3, },
                 j["sessions"]["group_repo"])
    # only the verdict's fields, for every session: no screen text, no dialog (its question / command is the sidebar's)
    fields = %w[state state_by phase elapsed_s tokens tool card background subagents]
    j["sessions"].each_value { |v| assert_equal fields, v.keys }
    assert_equal({ "state" => "blocked", "state_by" => "screen: bash_permission_prompt", "phase" => nil, "elapsed_s" => nil,
                   "tokens" => nil, "tool" => nil, "card" => nil, "background" => nil, "subagents" => nil, },
                 j["sessions"]["by_asker"])

    # the owner session counts wherever it runs
    other = k.create(slug: "group/repo", title: "t", by: "op", column: "doing")
    Hanami.app["db.gateway"].connection[:cards].where(id: other).update(owner_session: "elsewhere")
    assert_equal %w[by_asker elsewhere group_repo], api(:get, "/api/cards/#{other}/live")["sessions"].keys.sort
    assert_equal "idle", api(:get, "/api/cards/#{other}/live")["sessions"]["elsewhere"]["state"] # its collector says so
    api(:get, "/api/cards/999999/live")
    assert_equal 404, last_response.status
  end

  # who works on a card RIGHT NOW — the dialog's `present` and the board's presence poll: a registered session
  # at work whose agent wrote on the card this turn (or whose running tool names it); ownership alone is not presence
  def test_presence_is_the_registered_sessions_at_work_on_the_card_now
    # the clock stands still: the comment and the reads share one instant, so "this turn" (elapsed_s 65) is no
    # wall-clock window the test could race
    Busyyaks::Clock.stub(:now, Time.at(1_800_000_000)) do
      fake_launcher
      k = Busyyaks::Kanban.default
      k.register_session(session: "group_repo", project: "group/repo", type: "lead", launcher: "fullclaude", by: "op")
      agent = k.agent_types("group/repo").key("lead")
      here = k.create(slug: "group/repo", title: "checked now", by: "op", column: "doing")
      owned = k.create(slug: "group/repo", title: "owned, untouched", by: "op", column: "doing")
      reading = k.create(slug: "group/repo", title: "its tool reads it", by: "op", column: "doing")
      @tool_card = reading # the running kanban tool names this card (set before the first snapshot read)
      k.set_owner(owned, session: "group_repo", by: "op")
      k.comment(here, body: "looked", author: agent) # the turn runs 65 s; the clock stands still, so this is in it
      j = api(:get, "/api/cards/#{here}/live")
      assert_equal 200, last_response.status
      assert_equal [["group_repo", agent, "lead", "activity", "working"]],
                   j["present"].map { |w| [*w.values_at("session", "agent", "type", "why"), w["live"]["state"]] }
      assert_equal [], api(:get, "/api/cards/#{owned}/live")["present"], "ownership alone is not presence"
      tool = api(:get, "/api/cards/#{reading}/live")["present"]
      assert_equal [%w[group_repo tool]], tool.map { |w| w.values_at("session", "why") }
      b = api(:get, "/api/projects/group/repo/board/presence")
      assert_equal 200, last_response.status
      assert_equal [here.to_s, reading.to_s].sort, b["cards"].keys.sort
      assert_equal "no-store", last_response.headers["Cache-Control"]
      api(:get, "/api/projects/nope/board/presence")
      assert_equal 404, last_response.status
      File.unlink(SOCK)
      Busyyaks::LauncherClient.forget_agents_snapshot! # the 2 s shared read would still answer
      assert_match(/\Aagent sessions: /, api(:get, "/api/projects/group/repo/board/presence")["error"])
      assert_equal 503, last_response.status
    end
  end

  def test_card_live_says_the_launcher_is_down_or_refuses
    id = Busyyaks::Kanban.default.create(slug: "group/repo", title: "t", by: "op", column: "doing")
    File.unlink(SOCK) if File.socket?(SOCK)
    j = api(:get, "/api/cards/#{id}/live") # no launcher at all
    assert_equal 503, last_response.status
    assert_match(/\Aagent sessions: launcher not reachable/, j["error"])
    fake_launcher
    @agents_refused = { ok: false, error: "agents snapshot unreadable (/x): Errno::ENOENT" }
    j = api(:get, "/api/cards/#{id}/live") # the launcher answers, the collector's snapshot is not there
    assert_equal 503, last_response.status
    assert_equal "agent sessions: agents snapshot unreadable (/x): Errno::ENOENT", j["error"]
    refute_includes j.keys, "sessions"
  end

  # the sidebar and every open card dialog share one launcher `agents` call per 2 s; a refusal is never kept,
  # and an older good answer never stands in for it
  def test_the_agents_snapshot_is_shared_and_never_replaces_a_refusal
    fake_launcher
    id = Busyyaks::Kanban.default.create(slug: "group/repo", title: "t", by: "op", column: "doing")
    asks = -> { @requests.count { |r| r["op"] == "agents" } }
    # the snapshot's clock stands still: four reads inside one window, however slow the machine (in the past, so the
    # real clock's reads below are all past that window)
    t0 = -1_000_000.0
    Busyyaks::Clock.stub(:monotonic, t0) do
      3.times { api(:get, "/api/cards/#{id}/live") }
      api(:get, "/api/agents")
    end
    assert_equal 1, asks.()
    Busyyaks::Clock.stub(:monotonic, t0 + Busyyaks::LauncherClient::SNAPSHOT_SECONDS) do
      api(:get, "/api/agents")
    end
    assert_equal 2, asks.() # the window ended: asked again
    @agents_refused = { ok: false, error: "collector down" }
    api(:get, "/api/cards/#{id}/live")
    assert_equal 503, last_response.status
    api(:get, "/api/cards/#{id}/live")
    assert_equal [503, 4], [last_response.status, asks.()] # the refusal was asked again, not served from memory
    @agents_refused = nil
    api(:get, "/api/cards/#{id}/live")
    assert_equal [200, 5], [last_response.status, asks.()]
  end

  # the board's working glow — ONE answer for the whole board (the project's sessions + every live card's owner
  # session, wherever it runs), read from the shared agents snapshot: no launcher call per card or per poll
  def test_board_live_is_one_answer_from_the_shared_snapshot
    fake_launcher
    k = Busyyaks::Kanban.default
    3.times { k.create(slug: "group/repo", title: "t", by: "op", column: "doing") }
    owned = k.create(slug: "group/repo", title: "t", by: "op", column: "doing")
    Hanami.app["db.gateway"].connection[:cards].where(id: owned).update(owner_session: "elsewhere")
    asks = -> { @requests.count { |r| r["op"] == "agents" } }
    # the snapshot's clock stands still: every read inside one window, however slow the machine
    j = Busyyaks::Clock.stub(:monotonic, -1_000_000.0) do
      api(:get, "/api/agents")
      Array.new(2) { api(:get, "/api/projects/group/repo/board/live") }.last
    end
    assert_equal 200, last_response.status
    assert_equal 1, asks.() # the sidebar and two board polls of a 4-card board: one launcher call
    assert_equal %w[by_asker elsewhere group_repo], j["sessions"].keys.sort # "elsewhere" owns a card on this board
    assert_equal({ "state" => "working", "state_by" => "screen: live_turn_working", "phase" => "tool", "elapsed_s" => 65,
                   "tokens" => "↓ 1.6k", "tool" => "busyyaks · kanban_comment", "card" => 7, "background" => "1 shell",
                   "subagents" => 3, },
                 j["sessions"]["group_repo"])
    assert_equal "idle", j["sessions"]["elsewhere"]["state"]
    Hanami.app["db.gateway"].connection[:cards].where(id: owned).update(owner_session: nil)
    Busyyaks::LauncherClient.forget_agents_snapshot!
    assert_equal %w[by_asker group_repo], api(:get, "/api/projects/group/repo/board/live")["sessions"].keys.sort
    api(:get, "/api/projects/no/such/board/live")
    assert_equal 404, last_response.status
  end

  def test_board_live_says_the_launcher_is_down_never_nobody_works
    File.unlink(SOCK) if File.socket?(SOCK)
    j = api(:get, "/api/projects/group/repo/board/live")
    assert_equal 503, last_response.status
    assert_match(/\Aagent sessions: launcher not reachable/, j["error"])
    fake_launcher
    @agents_refused = { ok: false, error: "collector down" }
    j = api(:get, "/api/projects/group/repo/board/live")
    assert_equal [503, "agent sessions: collector down"], [last_response.status, j["error"]]
    refute_includes j.keys, "sessions"
  end

  def test_a_session_busyyaks_did_not_launch_is_never_an_assignee
    fake_launcher
    a = api(:get, "/api/projects/group/repo/board")["assignees"]
    assert_includes a, "group_repo"
    refute_includes a, "hand"
  end

  def test_reap_preview_and_stop_go_through_the_launcher
    fake_launcher
    api(:get, "/api/agents/reap")
    body = JSON.parse(last_response.body)
    assert_equal "group/repo", body["candidates"].first["project"]
    api(:post, "/api/agents/reap",
        { sessions: [{ name: "group_repo", socket: "default" }, { name: "by_busy_one", socket: "default" }] })
    res = JSON.parse(last_response.body)["results"]
    assert_equal [true, false], res.map { |r| r["stopped"] }
    assert_equal [{ "name" => "group_repo", "socket" => "default" }, { "name" => "by_busy_one", "socket" => "default" }],
                 @requests.find { |r| r["op"] == "reap" }["sessions"]
  end

  def test_reap_requires_a_selection_and_csrf
    fake_launcher
    api(:post, "/api/agents/reap", { sessions: [] })
    assert_equal 400, last_response.status
    api(:post, "/api/agents/reap", { sessions: [{ name: "x" }] }, csrf: nil)
    assert_equal 403, last_response.status
  end

  # Stop / Stop all — the host kills exactly the named sessions of this project; a stopped registered session
  # ends its registration at once (its cap slot frees now); a refusal comes back per session with the host's reason.
  def test_stop_kills_the_named_sessions_of_the_project_and_ends_their_registration
    fake_launcher
    k = Busyyaks::Kanban.default
    api(:post, "/api/launch", { slug: "group/repo", type: "lead", launcher: "fullclaude" })
    assert_equal 201, last_response.status
    assert k.open_session("by_group_repo_teamlead")
    j = api(:post, "/api/projects/group/repo/stop",
{ sessions: %w[by_group_repo_teamlead group_repo other_project group_repo] })
    assert_equal 200, last_response.status
    assert_equal [["by_group_repo_teamlead", true, "ended"], ["group_repo", true, nil], ["other_project", false, nil]],
                 j["results"].map { |r| r.values_at("name", "stopped", "registration") }
    assert_equal "not in this project (/projects/x)", j["results"][2]["reason"]
    req = @requests.find { |r| r["op"] == "stop" }
    assert_equal ["/projects/group/repo", %w[by_group_repo_teamlead group_repo other_project]],
req.values_at("path", "sessions")
    assert_nil k.open_session("by_group_repo_teamlead"), "the stopped lead no longer holds a cap slot"
  end

  def test_stop_needs_a_project_names_and_csrf
    fake_launcher
    api(:post, "/api/projects/group/repo/stop", { sessions: [] })
    assert_equal 400, last_response.status
    api(:post, "/api/projects/no/such/stop", { sessions: ["x"] })
    assert_equal 404, last_response.status
    api(:post, "/api/projects/group/repo/stop", { sessions: ["x"] }, csrf: nil)
    assert_equal 403, last_response.status
    refute(@requests.any? { |r| r["op"] == "stop" })
  end

  def test_stop_is_503_when_launcher_is_down
    j = api(:post, "/api/projects/group/repo/stop", { sessions: ["group_repo"] })
    assert_equal 503, last_response.status
    assert_includes j["error"], "launcher not reachable"
  end

  def test_agents_is_503_when_launcher_is_down
    j = api(:get, "/api/agents")
    assert_equal 503, last_response.status
    assert_includes j["error"], "launcher not reachable"
  end

  def test_launch_registers_adopts_then_starts_and_reports_remote_control
    fake_launcher
    k = Busyyaks::Kanban.default
    orphan = k.create(slug: "group/repo", title: "left over after the reboot", by: "op", column: "human_check")
    j = api(:post, "/api/launch", { slug: "group/repo", type: "lead", launcher: "localclaude" })
    assert_equal 201, last_response.status
    lead_body = last_response.body
    assert_equal ["by_group_repo_teamlead", "lead", "localclaude", "claude-by_group_repo_teamlead", [orphan]],
                 j.values_at("session", "type", "launcher", "agent").push(j["adopted"].map { |c| c["id"] })
    assert_equal({ "ok" => true, "session" => "by_group_repo_teamlead", "type" => "lead", "launcher" => "localclaude",
                   "prompt" => true, "remote_control" => "on", "remote_control_name" => "by_group_repo_teamlead",
                   "trust" => "accepted", },
                 j["result"])
    assert_equal 1, j["concurrency"]["running"]
    req = @requests.find { |r| r["op"] == "launch" }
    assert_equal ["/projects/group/repo", "by_group_repo_teamlead", "lead", "localclaude"],
                 req.values_at("path", "session", "type", "launcher")
    assert_equal ["bash", "-ic", "localclaude --remote-control by_group_repo_teamlead"], req["argv"]
    assert_equal({ "slug" => "group/repo", "session" => "by_group_repo_teamlead", "agent" => "claude-by_group_repo_teamlead",
                   "type" => "lead", "cards" => "##{orphan}", },
                 req["vars"])
    assert_match(/\{dir\}/, req["prompt_template"])
    assert_equal [nil, "by_group_repo_teamlead"], k.card(orphan).values_at(:assignee, :owner_session),
                 "the lead owns the orphan by rule, and is never its assignee (card 612)"
    j = api(:get, "/api/projects/group/repo/sessions")
    assert_equal ["group_repo"], j["sessions"].map { |s| s["name"] }
    assert_equal 1, j["launches"]["types"][0]["running"]
    # a second lead for the same board: refused (one lead per board), nothing started
    j = api(:post, "/api/launch", { slug: "group/repo", type: "lead" })
    assert_equal 422, last_response.status
    assert_match(%r{1/1 lead session already runs for group/repo .*by_group_repo_teamlead \(lead, group/repo\)}, j["error"])
    assert_equal 1, @requests.count { |r| r["op"] == "launch" }
    # the lead runs localclaude → a sub team and a worker for this board run it too, with no --model (it
    # would override the gateway's); the Launch bar locks the menu to it; another launcher asked for is refused
    l = api(:get, "/api/projects/group/repo/sessions")["launches"]
    assert_equal "lead", l["types"].find { |t| t["key"] == "team" }["under"]
    assert_equal [%w[by_group_repo_teamlead lead localclaude group/repo]],
                 l["concurrency"]["sessions"].map { |s| s.values_at("session", "type", "launcher", "project") },
                 "the page's sessions name the lead's launcher: the Launch bar locks the follower's menu to it (launchesFor)"
    j = api(:post, "/api/launch", { slug: "group/repo", type: "team", launcher: "fullclaude" })
    assert_equal 422, last_response.status
    assert_match(/team sessions of group\/repo run localclaude, the launcher of their lead session by_group_repo_teamlead/,
                 j["error"])
    j = api(:post, "/api/launch", { slug: "group/repo", type: "team", launcher: "localclaude" })
    assert_equal [201, "localclaude"], [last_response.status, j["launcher"]]
    team_req = @requests.reverse.find { |r| r["op"] == "launch" }
    assert_equal ["bash", "-ic", "localclaude --remote-control #{j['session']}"], team_req["argv"]
    assert_equal [nil, "by_group_repo_teamlead"], team_req.values_at("lead_key", "lead"), "under the lead, no key"
    # lead-first: the lead's key went to bin/launcher's start only (it keeps it) — never into an answer
    lead_req = @requests.find { |r| r["op"] == "launch" && r["type"] == "lead" }
    key = lead_req.fetch("lead_key")
    assert_match(/\A\h{64}\z/, key)
    assert_nil lead_req["lead"]
    refute_includes lead_body, key
    # an ownerless To do card is the lead's; the lead starts its worker with kanban_spawn (nothing else starts one)
    todo = k.create(slug: "group/repo", title: "new work", by: "op", column: "todo")
    @live_extra = %w[by_group_repo_teamlead]
    assert_equal [todo], Busyyaks::Kanban.default.adopt_ownerless(live: Busyyaks::LauncherClient.session_names, grace: 60)
    assert_equal "by_group_repo_teamlead", k.card(todo)[:owner_session]
    @lead_keys = { "by_group_repo_teamlead" => key } # what bin/launcher's lead_key op answers for the lead it started
    spawn = { "id" => todo, "type" => "worker", "tmux_session" => "by_group_repo_teamlead",
              "author" => "claude-by_group_repo_teamlead", }
    out = JSON.parse(Busyyaks::Kanban.tools.call("kanban_spawn", spawn))
    req = @requests.reverse.find { |r| r["op"] == "launch" }
    assert_equal %w[worker localclaude by_group_repo_teamlead], req.values_at("type", "launcher", "lead")
    assert_equal ["bash", "-ic", "localclaude --remote-control #{req['session']}"], req["argv"]
    assert_equal [out["session"], nil], [k.card(todo)[:owner_session], req["lead_key"]]
    refute_includes JSON.generate(out), key, "the spawn answer carries no key"
    @lead_keys = { "by_group_repo_teamlead" => "0" * 64 } # a key that is not the registration's
    assert_raises(AgentsKanban::Denied) { Busyyaks::Kanban.tools.call("kanban_spawn", spawn.merge("id" => todo)) }
    @lead_keys = {}
    @live_extra = nil
    j = api(:post, "/api/launch", { slug: "group/repo", type: "plain" })
    refused = "agent type plain runs fullclaude, localclaude — name the launcher this session was started with"
    assert_equal [422, refused], [last_response.status, j["error"]], "never the first one"
    # claude never came up (bin/launcher refuses the launch and kills the session): 422 with the launcher's reason,
    # the registration ended — never a 201 with a registered owner nobody runs
    @launch_refused = { ok: false, status: 422,
                        error: "by_group_repo did not start: no claude --remote-control by_group_repo after 12s " \
                               "(Temp directory /tmp/claude-1000 is owned by uid 0)", }
    j = api(:post, "/api/launch", { slug: "group/repo", type: "plain", launcher: "fullclaude" })
    assert_equal [422, @launch_refused[:error]], [last_response.status, j["error"]]
    reg = Busyyaks::Kanban.store.sessions_t.where(session: "by_group_repo").order(:id).last
    refute_nil reg[:ended_at], "the refused start's registration is ended"

  end

  # U3, the operator: "Add naming to the busyyaks sessions … start with BY so we can easily identify and isolate them".
  # The live run's tmux names, from the web's Launch: the lead by_<slug>_teamlead, the Sub team by_<slug>_team, a plain
  # session by_<slug> — each the name the launcher is asked to start, and the board's registration
  def test_every_session_the_web_launches_is_named_by
    fake_launcher
    %w[lead team plain].each do |type|
      j = api(:post, "/api/launch", { slug: "group/repo", type: type, launcher: "fullclaude" })
      assert_equal 201, last_response.status, j.inspect
    end
    starts = @requests.select { |r| r["op"] == "launch" }
    assert_equal [%w[lead by_group_repo_teamlead], %w[team by_group_repo_team], %w[plain by_group_repo]],
                 starts.map { |r| r.values_at("type", "session") }
    starts.each { |r| assert Busyyaks::LauncherRules.busyyaks_session?(r["session"]), r["session"] }
    starts.each { |r| assert Busyyaks::Kanban.default.open_session(r["session"]), "#{r['session']} registered" }
    # the shipped template (a new install's agent settings), not only this test's fixture: every session_name is by_…
    template = YAML.safe_load_file(File.expand_path("../../config/agents.template.yml", __dir__))
    template["agent_types"].each do |t|
      assert Busyyaks::LauncherRules.busyyaks_session?(t["session_name"]), "#{t['key']}: #{t['session_name']}"
    end
  end

  # card 614: the project page polls its sessions — a session started (the lead's spawn, another tab, by hand) or ended
  # anywhere shows on the next read; each read asks the launcher afresh; nothing of the page's commits / notes
  def test_project_sessions_is_the_live_list_read_afresh_each_time
    fake_launcher
    j = api(:get, "/api/projects/group/repo/sessions")
    assert_equal 200, last_response.status
    assert_equal %w[launcher_error launches sessions], j.keys.sort, "only the live part of the page"
    assert_equal ["group_repo"], j["sessions"].map { |s| s["name"] }
    assert_nil j["launcher_error"]
    assert_equal %w[lead worker team plain], j["launches"]["types"].map { |t| t["key"] }
    assert_equal "no-store", last_response.headers["Cache-Control"]

    @live_extra = ["group_repo_worker_9"] # the lead spawned a worker
    j = api(:get, "/api/projects/group/repo/sessions")
    assert_equal %w[group_repo group_repo_worker_9], j["sessions"].map { |s| s["name"] }
    assert_equal %w[name created attached terminal_url claude_url ssh_attach], j["sessions"][1].keys

    @live_extra = nil # it ended
    j = api(:get, "/api/projects/group/repo/sessions")
    assert_equal ["group_repo"], j["sessions"].map { |s| s["name"] }
    assert_operator @requests.count { |r| r["op"] == "sessions" }, :>=, 3, "each read asks the launcher"

    api(:get, "/api/projects/no/such/sessions")
    assert_equal 404, last_response.status

    # the page's one-off read carries no session list or launches (never refreshed) and asks the launcher nothing
    asked = @requests.size
    j = api(:get, "/api/projects/group/repo")
    assert_equal 200, last_response.status
    assert_equal %w[commits notes project year], j.keys.sort
    refute_includes j["project"].keys, "sessions"
    assert_equal asked, @requests.size, "no launcher op for the page's one-off read"
  end

  def test_project_sessions_says_the_launcher_is_down_never_no_sessions_quietly
    j = api(:get, "/api/projects/group/repo/sessions")
    assert_equal 200, last_response.status
    assert_equal [], j["sessions"]
    assert_includes j["launcher_error"], "launcher not reachable"
    assert_includes j["launches"]["sessions_error"], "launcher not reachable"
  end

  def test_launcher_down_is_reported_and_launch_is_503
    j = api(:get, "/api/projects")
    assert_equal 200, last_response.status
    assert_includes j["launcher_error"], "launcher not reachable"
    assert_equal 4, j["launches"]["types"].size
    assert_nil j["launches"]["concurrency"]
    assert_includes j["launches"]["sessions_error"], "launcher not reachable"
    assert_equal [], j["jobs"]
    j = api(:post, "/api/launch", { slug: "group/repo", type: "lead" })
    assert_equal 503, last_response.status
    assert_includes j["error"], "launcher not reachable"
  end

  def test_unknown_project_type_and_launcher_are_refused
    fake_launcher
    api(:post, "/api/launch", { slug: "nope", type: "lead" })
    assert_equal 404, last_response.status
    j = api(:post, "/api/launch", { slug: "group/repo", type: "" })
    assert_equal 400, last_response.status
    assert_equal "type is required (lead, worker, team, plain)", j["error"]
    j = api(:post, "/api/launch", { slug: "group/repo", type: "boss" })
    assert_equal 422, last_response.status
    assert_match(/no agent type "boss" \(lead, worker, team, plain\)/, j["error"])
    j = api(:post, "/api/launch", { slug: "group/repo", type: "plain", launcher: "nope" })
    assert_equal 422, last_response.status
    assert_match(/agent type plain does not run launcher "nope"/, j["error"])
    j = api(:post, "/api/launch", { slug: "group/repo", type: "team", launcher: "fullclaude" })
    assert_equal 422, last_response.status
    assert_match(%r{no lead session runs for group/repo: a team session runs only under the board's lead — launch the lead},
                 j["error"])
    assert_nil @requests.find { |r| r["op"] == "launch" }
  end

  # review round 1 (blocker): a stored revision with a worker under no lead launches nothing — 503 with the reason
  def test_a_stored_revision_with_a_type_under_no_lead_launches_nothing
    fake_launcher
    d = JSON.parse(JSON.generate(AgentSettingsFixture::DOC))
    w = d["agent_types"].find { |t| t["key"] == "worker" }
    %w[under launchable].each { w.delete(_1) }
    Hanami.app["db.gateway"].connection[:agent_settings].insert(doc: JSON.generate(d), author: "by hand", created_at: 1)
    j = api(:post, "/api/launch", { slug: "group/repo", type: "worker", launcher: "fullclaude" })
    assert_equal 503, last_response.status
    assert_match(/does not run: agent_types\[worker\] runs without a lead/, j["error"])
    assert_nil @requests.find { |r| r["op"] == "launch" }, "nothing reached the launcher"
  ensure
    AgentSettingsFixture.install!
  end

  # the operator, 2026-11-25: workers come only from the lead's kanban_spawn — the page's launches say the worker type
  # is not launchable (the bar leaves it out), the lead's button says "Launch team lead", and a POST for a worker is
  # refused before anything reaches the launcher, with a lead running too
  def test_the_launch_bar_never_offers_worker
    fake_launcher
    j = api(:get, "/api/projects")
    bar = j["launches"]["types"].to_h { |t| [t["key"], t.values_at("label", "launchable", "launch_label")] }
    assert_equal({ "lead" => ["Team lead", true, "Launch team lead"], "worker" => ["Worker", false, nil],
                   "team" => ["Sub team", true, nil], "plain" => ["Plain", true, nil], }, bar)
    j = api(:post, "/api/launch", { slug: "group/repo", type: "worker", launcher: "fullclaude" })
    assert_equal 422, last_response.status
    assert_equal "Worker (worker) is not launched from the Launch bar: the board's lead starts one for a card " \
                 "(kanban_spawn)", j["error"]
    assert_nil @requests.find { |r| r["op"] == "launch" }, "nothing reached the launcher"
  end

  def test_launch_without_csrf_token_is_refused_and_signs_out
    fake_launcher
    j = api(:post, "/api/launch", { slug: "group/repo", type: "plain" }, csrf: nil)
    assert_equal 403, last_response.status
    assert_equal "invalid CSRF token", j["error"]
    assert_nil @requests.find { |r| r["op"] == "launch" }
    api(:get, "/api/today")
    assert_equal 401, last_response.status
  end
  # DNS rebinding (card #253): evil.example re-resolved to this app — a signed-in session and a valid CSRF token, but
  # the attacker's Host. 421 on the reads and on every launcher-backed mutation, and the launcher is never asked.
  def test_a_rebinding_host_reaches_no_handler_and_no_launcher
    fake_launcher
    host = { "HTTP_HOST" => "evil.example:2300" }
    %w[/ /login /up /api/projects /api/agents /api/today /static/app.css].each do |path|
      get path, {}, host
      assert_equal 421, last_response.status, path
    end
    id = Busyyaks::Kanban.default.create(slug: "group/repo", title: "t", by: "op", column: "doing")
    { "/api/launch" => { slug: "group/repo", type: "plain" }, "/api/agents/answer" => { key: "1" },
      "/api/cards/#{id}/comment" => { body: "run rm -rf ~" }, "/api/cards/#{id}/dialog-answer" => { key: "1" }, }
      .each do |path, body|
        post path, JSON.generate(body), host.merge("CONTENT_TYPE" => "application/json", "HTTP_X_CSRF_TOKEN" => @csrf,
                                                  "HTTP_ORIGIN" => "http://evil.example:2300")
        assert_equal 421, last_response.status, path
        assert_match(/host not allowed/, last_response.body)
      end
    assert_empty @requests
    assert_equal 0, Hanami.app["db.gateway"].connection[:card_activity].where(kind: "comment").count
    # the same session from its own page still launches; a foreign Origin on the right Host is 403
    j = api(:post, "/api/launch", { slug: "group/repo", type: "plain", launcher: "fullclaude" })
    assert_equal 201, last_response.status, j.inspect
    header "Origin", "https://evil.example"
    j = api(:post, "/api/launch", { slug: "group/repo", type: "plain", launcher: "fullclaude" })
    assert_equal [403, "origin not allowed: a change must come from this app's own page"], [last_response.status, j["error"]]
  end
end
