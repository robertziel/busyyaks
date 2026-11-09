# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "socket"
require "json"

# The launcher-backed API: projects tree + sessions, launch (with the Remote Control verdict), create, agents sidebar.
class LaunchTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods
  include SignIn

  SOCK = ENV.fetch("LAUNCHER_SOCKET")
  def app = Hanami.app

  def setup
    super
    store.upsert_project(slug: "group/repo", path: "/projects/group/repo", remote: nil, branch: "main", own: true,
                         last_commit_at: Time.now.to_i, commits_window: 1, mine_window: 1, dirty: 0, unpushed: nil,
                         scanned_at: 1)
    assert_equal 200, sign_in
    get "/"
    @csrf = last_response.body[/name="csrf-token" content="([^"]+)"/, 1]
    @remote_control = { remote_control: "on", remote_control_name: "group_repo_teamlead", trust: "accepted" }
  end

  def teardown
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
      { ok: true, session: req["session"], type: req["type"], launcher: req["launcher"],
        prompt: !req["prompt_template"].nil?, **@remote_control, }
    when "sessions"
      { ok: true, sessions: [{ name: "group_repo", project_path: "/projects/group/repo", created: 1, attached: false }] }
    when "jobs"
      { ok: true, jobs: [{ url: "https://github.com/o/r.git", path: "/projects/r", status: "failed", exit: 128,
                           tail: ["fatal: nope"], }], }
    when "agents" then agents_snapshot
    when "agent_tasks"
      { ok: true,
        agents: [{ id: "a1", description: "Sweep exhibitor pages", type: "subagent", state: "running", mtime: Time.now.to_f }],
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
        { ok: false, error: "asker: the dialog on its screen changed — nothing typed", status: 409 }
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
    busy = { name: "group_repo", socket: "default", attached: 1, created: 1, activity: Time.now.to_i,
             claude_url: "https://claude.ai/code/session_x",
             panes: [{ target: "0.0", cwd: "/mnt/x/group/repo/sub", project_path: "/projects/group/repo/sub",
                       engine: "claudeapi", engine_label: "Claude", model: "opus", status: "busy", title: "kanban work",
                       subagents_running: 3, }], }
    unconfigured = { name: "elsewhere", socket: "default", attached: 0, created: 1, activity: 1,
                     panes: [{ target: "0.0", cwd: "/tmp", project_path: nil, engine: "codex", status: "idle", status_at: 100.0,
                               screen: { error: "engine \"codex\" is not configured (config/busyyaks.yml engines; known: " \
                                                "claude, claudeapi, localclaude, hermes)" }, }], }
    dialog = { question: "Do you want to proceed?", command: "rm -rf build", escape: true, free_text: true, hash: "h1",
               answerable: true,
               options: [{ key: "1", label: "Yes", free: false }, { key: "3", label: "No, and tell Claude", free: true }], }
    asker = { name: "asker", socket: "default", attached: 0, created: 1, activity: 2,
              panes: [{ target: "0.0", cwd: "/mnt/x/group/repo", project_path: "/projects/group/repo", engine: "claudeapi",
                        status: "idle", screen: { state: "blocked", rule: "bash_permission_prompt", dialog: dialog }, }], }
    { ok: true, generated_at: Time.now.to_f, age_s: 1.0, interval_s: 5, collector_error: nil,
      sessions: [busy, unconfigured, asker], }
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
    # the board config's agent types (config/kanban.yml) with their launchers, and the cap state from the engine
    assert_equal [["lead", "Launch", %w[fullclaude localclaude], true],
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

  def agent(j, name) = j["groups"].flat_map { |g| g["sessions"] }.find { |x| x["name"] == name }

  # unread (formerly "done"): a turn that ended after the operator last saw the session;
  # opening its row marks it seen.
  def test_unread_until_the_operator_opens_it
    fake_launcher
    refute agent(api(:get, "/api/agents"), "elsewhere")["unread"], "first sighting = seen"
    store.agent_seen!("default/elsewhere", now: 50.0) # last seen before its turn ended (status_at 100)
    j = api(:get, "/api/agents")
    assert_equal ["idle", true, 1, 2],
                 [agent(j, "elsewhere")["state"], agent(j, "elsewhere")["unread"], j["totals"]["unread"], j["totals"]["you"]],
                 "you = the blocked asker + the unread one"
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
    assert_equal [[id, "Auth or imgproc first?", "/projects/group/repo?tab=board&card=#{id}"]],
                 s["asks"].map { |a| a.values_at("id", "question", "path") }
  end

  # a session's handed-over card (the handoff column) waits for the operator's review: state review, the card + its PR linked
  def test_a_handed_over_card_puts_its_owner_session_in_review
    fake_launcher
    kb = Busyyaks::Kanban.default
    id = kb.create(slug: "group/repo", title: "ship it", by: "op", column: "doing")
    kb.set_owner(id, session: "elsewhere", by: "op")
    now = Time.now.to_i # the github service read the PR's checks green: a gate is handed off on green CI only
    Hanami.app["db.gateway"].connection[:gh_pr_checks].insert(repo: "o/r", ref: "pr:5", requested_at: now, checked_at: now,
                                                             number: 5, state: "success", finished_at: now)
    kb.handoff(id, qa: "Open the board, check the card ships what it says, then the PR diff and its CI build.",
                   pr_url: "https://github.com/o/r/pull/5", ci_url: "https://ci/1", ui_change: false, by: "elsewhere")
    j = api(:get, "/api/agents")
    s = agent(j, "elsewhere")
    assert_equal ["review", "card ##{id} in review"], s.values_at("state", "state_by")
    assert_equal [[id, "https://github.com/o/r/pull/5"]], s["reviews"].map { |r| r.values_at("id", "pr_url") }
    assert_equal 1, j["totals"]["review"]
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
    kb.register_session(session: "elsewhere", project: "group/repo", type: "plain", launcher: "fullclaude", by: "op")
    id = kb.create(slug: "group/repo", title: "ship it", by: "op", column: "doing")
    kb.set_owner(id, session: "elsewhere", by: "op")
    s = agent(api(:get, "/api/agents"), "elsewhere")
    assert_equal ["idle", true, 0], s.values_at("state", "cards_known", "cards_finished")
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
                 api(:post, "/api/agents/answer", { session: "asker", socket: "default", hash: "h1", key: "1" }))
    assert_equal({ "op" => "answer", "session" => "asker", "socket" => "default", "hash" => "h1", "key" => "1" },
                 @requests.find { |r| r["op"] == "answer" })
    r = api(:post, "/api/agents/answer", { session: "asker", socket: "default", hash: "old", key: "1" })
    assert_equal [422, "asker: the dialog on its screen changed — nothing typed"], [last_response.status, r["error"]]
    api(:post, "/api/agents/answer", { session: "asker", socket: "default", hash: "h1" })
    assert_equal 400, last_response.status
    api(:post, "/api/agents/answer", { session: "asker", socket: "default", hash: "h1", key: "1" }, csrf: nil)
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
    assert_equal ["asker", "blocked", "screen: bash_permission_prompt"], blocked.values_at("name", "state", "state_by")
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

  def test_reap_preview_and_stop_go_through_the_launcher
    fake_launcher
    api(:get, "/api/agents/reap")
    body = JSON.parse(last_response.body)
    assert_equal "group/repo", body["candidates"].first["project"]
    api(:post, "/api/agents/reap",
        { sessions: [{ name: "group_repo", socket: "default" }, { name: "busy_one", socket: "default" }] })
    res = JSON.parse(last_response.body)["results"]
    assert_equal [true, false], res.map { |r| r["stopped"] }
    assert_equal [{ "name" => "group_repo", "socket" => "default" }, { "name" => "busy_one", "socket" => "default" }],
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
    assert k.open_session("group_repo_teamlead")
    j = api(:post, "/api/projects/group/repo/stop", { sessions: %w[group_repo_teamlead group_repo other_project group_repo] })
    assert_equal 200, last_response.status
    assert_equal [["group_repo_teamlead", true, "ended"], ["group_repo", true, nil], ["other_project", false, nil]],
                 j["results"].map { |r| r.values_at("name", "stopped", "registration") }
    assert_equal "not in this project (/projects/x)", j["results"][2]["reason"]
    req = @requests.find { |r| r["op"] == "stop" }
    assert_equal ["/projects/group/repo", %w[group_repo_teamlead group_repo other_project]], req.values_at("path", "sessions")
    assert_nil k.open_session("group_repo_teamlead"), "the stopped lead no longer holds a cap slot"
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
    assert_equal ["group_repo_teamlead", "lead", "localclaude", "claude-group_repo_teamlead", [orphan]],
                 j.values_at("session", "type", "launcher", "agent").push(j["adopted"].map { |c| c["id"] })
    assert_equal({ "ok" => true, "session" => "group_repo_teamlead", "type" => "lead", "launcher" => "localclaude",
                   "prompt" => true, "remote_control" => "on", "remote_control_name" => "group_repo_teamlead",
                   "trust" => "accepted", },
                 j["result"])
    assert_equal 1, j["concurrency"]["running"]
    req = @requests.find { |r| r["op"] == "launch" }
    assert_equal ["/projects/group/repo", "group_repo_teamlead", "lead", "localclaude"],
                 req.values_at("path", "session", "type", "launcher")
    assert_equal ["bash", "-ic", "localclaude --remote-control group_repo_teamlead"], req["argv"]
    assert_equal({ "slug" => "group/repo", "session" => "group_repo_teamlead", "agent" => "claude-group_repo_teamlead",
                   "type" => "lead", "cards" => "##{orphan}", },
                 req["vars"])
    assert_match(/\{dir\}/, req["prompt_template"])
    assert_equal %w[claude-group_repo_teamlead group_repo_teamlead], k.card(orphan).values_at(:assignee, :owner_session),
                 "the lead owns the orphan by rule"
    j = api(:get, "/api/projects/group/repo")
    assert_equal ["group_repo"], j["project"]["sessions"].map { |s| s["name"] }
    assert_equal 1, j["launches"]["types"][0]["running"]
    # a second lead for the same board: refused (one lead per board), nothing started
    j = api(:post, "/api/launch", { slug: "group/repo", type: "lead" })
    assert_equal 422, last_response.status
    assert_match(%r{1/1 lead session already runs for group/repo .*group_repo_teamlead \(lead, group/repo\)}, j["error"])
    assert_equal 1, @requests.count { |r| r["op"] == "launch" }
    # the lead runs localclaude → a sub team and a worker for this board run it too, with no --model (it
    # would override the gateway's); the Launch bar locks the menu to it; another launcher asked for is refused
    l = api(:get, "/api/projects/group/repo")["launches"]
    assert_equal "lead", l["types"].find { |t| t["key"] == "team" }["launcher_follows"]
    assert_equal [%w[group_repo_teamlead lead localclaude group/repo]],
                 l["concurrency"]["sessions"].map { |s| s.values_at("session", "type", "launcher", "project") },
                 "the page's sessions name the lead's launcher: the Launch bar locks the follower's menu to it (launchesFor)"
    j = api(:post, "/api/launch", { slug: "group/repo", type: "team", launcher: "fullclaude" })
    assert_equal 422, last_response.status
    assert_match(/team sessions of group\/repo run localclaude while the lead session group_repo_teamlead does/, j["error"])
    j = api(:post, "/api/launch", { slug: "group/repo", type: "team", launcher: "localclaude" })
    assert_equal [201, "localclaude"], [last_response.status, j["launcher"]]
    assert_equal ["bash", "-ic", "localclaude --remote-control #{j['session']}"],
                 @requests.reverse.find { |r| r["op"] == "launch" }["argv"]
    todo = k.create(slug: "group/repo", title: "new work", by: "op", column: "todo")
    api_spawn = Busyyaks::Kanban.api
    assert_equal [todo], api_spawn.spawn_pass
    req = @requests.reverse.find { |r| r["op"] == "launch" }
    assert_equal %w[worker localclaude], req.values_at("type", "launcher")
    assert_equal ["bash", "-ic", "localclaude --remote-control #{req['session']}"], req["argv"]
    # a failed Remote Control is passed through, never presented as fine
    @remote_control = { remote_control: "failed", reason: "no claude --remote-control group_repo process after 12s" }
    j = api(:post, "/api/launch", { slug: "group/repo", type: "plain" })
    refused = "agent type plain runs fullclaude, localclaude and none was named — name the launcher, or set " \
              "agent_types[plain].spawn_launcher"
    assert_equal [422, refused], [last_response.status, j["error"]], "never the first one"
    j = api(:post, "/api/launch", { slug: "group/repo", type: "plain", launcher: "fullclaude" })
    assert_equal 201, last_response.status
    assert_equal ["group_repo", "failed", "no claude --remote-control group_repo process after 12s"],
                 [j["session"], *j["result"].values_at("remote_control", "reason")]

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
    j = api(:post, "/api/launch", { slug: "group/repo", type: "team", launcher: "nope" })
    assert_equal 422, last_response.status
    assert_match(/agent type team does not run launcher "nope"/, j["error"])
    assert_nil @requests.find { |r| r["op"] == "launch" }
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
