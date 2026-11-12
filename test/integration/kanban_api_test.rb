# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "tmpdir"
require "fileutils"
require "busyyaks/kanban"
require "socket"

class KanbanApiTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods
  include SignIn

  def app = Hanami.app
  def kb = Busyyaks::Kanban.default

  def setup
    super
    @dir = Dir.mktmpdir
    store.upsert_project(slug: "g/r", path: @dir, remote: nil, branch: "main", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    assert_equal 200, sign_in
    get "/" # the SPA shell carries the CSRF token every mutation sends back as X-CSRF-Token
    @csrf = last_response.body[/name="csrf-token" content="([^"]+)"/, 1]
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  def api(verb, path, body = nil)
    send(verb, path, body && JSON.generate(body),
         "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json", "HTTP_X_CSRF_TOKEN" => @csrf)
    assert_equal "application/json", last_response.content_type.split(";").first,
                 "#{verb} #{path}: #{last_response.body[0, 200]}"
    JSON.parse(last_response.body)
  end

  def test_unauthenticated_is_json_401
    post "/logout"
    j = api(:get, "/api/projects/g/r/board")
    assert_equal [401, "not signed in"], [last_response.status, j["error"]]
  end

  def test_board_lifecycle
    j = api(:get, "/api/projects/g/r/board")
    assert_equal 200, last_response.status
    assert_equal %w[backlog todo doing qa human_check ready merged], j["columns"].map { |c| c["column"] }
    assert_equal [false, false, false, false, true, true, true], j["columns"].map { |c| c["operator_only"] }
    assert_includes j["assignees"], "owner@example.com"
    assert_nil j["backlog_md"]

    api(:post, "/api/projects/g/r/labels", name: "ui", color: "teal")
    assert_equal 201, last_response.status
    a = api(:post, "/api/projects/g/r/board", title: "A", column: "todo", labels: ["ui"], priority: "high",
                                              description: "**d**")
    assert_equal 201, last_response.status
    id = a["card"]["id"]
    assert_equal ["todo", ["ui"], "high", "**d**", "owner@example.com"],
                 a["card"].values_at("column", "labels", "priority", "description", "created_by")
    b = api(:post, "/api/projects/g/r/board", title: "B", column: "todo")["card"]["id"]

    m = api(:post, "/api/cards/#{b}/move", column: "todo", position: 0)
    assert_equal [0, 2], [m["card"]["position"], m["counts"]["todo"]]
    m = api(:post, "/api/cards/#{id}/move", column: "human_check")
    m = api(:post, "/api/cards/#{id}/move", column: "merged") # the operator may merge
    assert_equal "merged", m["card"]["column"]

    u = api(:patch, "/api/cards/#{id}", title: "A2", labels: [], priority: nil)
    assert_equal ["A2", [], nil], u["card"].values_at("title", "labels", "priority")
    assert_equal "tl_g_r", api(:post, "/api/cards/#{id}/assign", assignee: "tl_g_r")["card"]["assignee"]
    c = api(:post, "/api/cards/#{id}/comment", body: "done")
    assert_equal 201, last_response.status
    assert_equal 1, c["card"]["comments"]
    kinds = c["activity"].map { |e| e["kind"] }
    assert_equal %w[create move move update update comment], kinds
    assert_equal "owner@example.com", c["activity"].last["author"]

    ar = api(:post, "/api/cards/#{id}/archive", archived: true)
    refute_nil ar["card"]["archived"]
    j = api(:get, "/api/projects/g/r/board?archived=1")
    assert_equal [id], j["archived"].map { |x| x["id"] }
    assert_equal 1, api(:get, "/api/boards")["boards"].first["total"]
    assert_equal "A2", api(:get, "/api/cards/#{id}")["card"]["title"]
  end

  def test_refusals_are_json_errors
    id = kb.create(slug: "g/r", title: "x", by: "op")
    assert_match(/column must be one of/, api(:post, "/api/cards/#{id}/move", column: "done")["error"])
    assert_equal 422, last_response.status
    assert_match(/column is required/, api(:post, "/api/projects/g/r/board", title: "t")["error"])
    assert_match(/title is required/, api(:post, "/api/projects/g/r/board", title: "", column: "todo")["error"])
    assert_match(/unknown fields: column/, api(:patch, "/api/cards/#{id}", column: "todo")["error"])
    assert_match(/archived must be/, api(:post, "/api/cards/#{id}/archive", archived: "maybe")["error"])
    assert_match(/assignee is required/, api(:post, "/api/cards/#{id}/assign", {})["error"])
    assert_equal "no card 999999", api(:get, "/api/cards/999999")["error"]
    assert_equal 404, last_response.status
    assert_equal "no project nope", api(:get, "/api/projects/nope/board")["error"]
  end

  # the "waiting for you" widget's two routes — the list and the rev it polls
  # the card's Links list its assigned PRs — local / public from the enrolment, state from gh_pr_states
  def test_card_links_flag_the_local_and_public_pr
    store.upsert_project(slug: "g/r", remote: "https://github.com/o/r_local.git", pr_remote: "https://github.com/o/r_local.git",
                         local_mode: "own", local_repo: "https://github.com/o/r_local.git",
                         public_repo: "https://github.com/o/r.git", public_head: "https://github.com/o/r.git")
    id = kb.create(slug: "g/r", title: "T", by: "op")
    Hanami.app["db.gateway"].connection[:cards].where(id: id).update(pr_url: "https://github.com/o/r_local/pull/5")
    shown = lambda do
      api(:get, "/api/cards/#{id}")["links"].select { |l| l["kind"] == "pr" }
                                            .map { |l| [l["label"], l["tags"].map { |t| t["text"] }] }
    end
    assert_equal [], shown.call, "the handoff pr_url is not a row: nothing assigned, no PR row"
    kb.assign_pr(id, url: "https://github.com/o/r_local/pull/5", role: "local", by: "agent")
    assert_equal [["#5", %w[local checking]]], shown.call, "no public PR assigned to the card: no row"
    kb.assign_pr(id, url: "https://github.com/o/r/pull/7", role: "public", by: "agent")
    assert_equal [["#5", %w[local checking]], ["#7", %w[public checking]]], shown.call, "the assigned public PR"
    assert_equal [%w[o/r pr:7], ["o/r_local", "pr:5"]],
                 Hanami.app["db.gateway"].connection[:gh_pr_states].order(:repo).select_map(%i[repo ref])
  end

  # the checkout's links come from the scanner's last read (no git in the web process): branches it stored link; a repo
  # it never read, or a file question the GitRead child cannot answer, is a row that says why — never a guessed link
  def test_card_links_read_the_scanned_checkout_and_say_why_when_they_cannot
    store.upsert_project(slug: "g/r", remote: "https://github.com/o/r.git", pr_remote: "https://github.com/o/r.git")
    id = kb.create(slug: "g/r", title: "on main: see the notes", by: "op")
    links = api(:get, "/api/cards/#{id}")["links"]
    assert_equal [], links.select { |l| l["kind"] == "branch" }
    warn_row = links.find { |l| l["label"] == "checkout" }
    assert_equal %w[git unknown], warn_row["tags"].map { |t| t["text"] }
    assert_equal "g/r has not been read by the scanner yet", warn_row["detail"].first["value"]
    assert(links.any? { |l| l["kind"] == "repo" && l["url"] == "https://github.com/o/r" }, "what needs no checkout stays")

    store.upsert_project(slug: "g/r", branches: JSON.generate(%w[main feature]), default_ref: "main", git_error: nil)
    links = api(:get, "/api/cards/#{id}")["links"]
    assert_equal [["main", "https://github.com/o/r/tree/main"]],
                 links.select { |l| l["kind"] == "branch" }.map { |l| [l["label"], l["url"]] }
    assert_nil(links.find { |l| l["label"] == "checkout" })

    # a file the text names: the GitRead child is asked, and its refusal (this checkout is outside PROJECTS_MOUNT) shows
    kb.comment(id, body: "edit docs/x.md", author: "op", operator: true)
    links = api(:get, "/api/cards/#{id}")["links"]
    assert_match(/root cannot be resolved|resolves outside/, links.find { |l|
 l["label"] == "checkout" }["detail"].first["value"])

    # a repo whose last scan failed keeps its branches, beside the reason
    store.project_git_failed("g/r", "#{@dir}: Refused: sparse checkout is not supported")
    db = Hanami.app["db.gateway"].connection
    db[:card_activity].where(card_id: id, kind: "comment").delete
    links = api(:get, "/api/cards/#{id}")["links"]
    assert_equal ["main"], links.select { |l| l["kind"] == "branch" }.map { |l| l["label"] }
    assert_match(/\Alast scan: .*sparse checkout/, links.find { |l| l["label"] == "checkout" }["detail"].first["value"])
  end

  def test_waiting_lists_the_operators_cards_and_its_rev_changes_with_them
    r0 = api(:get, "/api/waiting/rev")["rev"]
    assert_equal "no-store", last_response.headers["Cache-Control"]
    assert_equal({ "waiting_columns" => %w[human_check ready], "total" => 0, "projects" => [], "held" => [], "external" => [],
                   "launch_failures" => [], }, api(:get, "/api/waiting"))
    # card #273: a session whose start failed (claude never came up) is in the list the layout's alert modal reads
    kb.register_session(session: "g_r_teamlead", project: "g/r", type: "lead", launcher: "fullclaude", by: "op")
    kb.end_session("g_r_teamlead", reason: "start failed: Temp directory is owned by uid 0", by: "op")
    f = api(:get, "/api/waiting")["launch_failures"]
    assert_equal [["g_r_teamlead", "g/r", "lead", "Temp directory is owned by uid 0"]],
                 f.map { |x| x.values_at("session", "project", "type", "reason") }
    r0 = api(:get, "/api/waiting/rev")["rev"]
    id = kb.create(slug: "g/r", title: "check me", by: "op", column: "human_check")
    kb.create(slug: "g/r", title: "busy", by: "op", column: "doing")
    w = api(:get, "/api/waiting")
    assert_equal [0, [[id, "no PR whose checks could be read"]]], [w["total"], w["held"][0]["cards"].map { |c|
 c.values_at("id", "gate_hold") },],
                 "card #248: a gate card that cannot be approved now waits for CI, not for you"
    t = Time.now.to_i # its PR, read green by the github service
    Hanami.app["db.gateway"].connection[:gh_pr_checks].insert(repo: "o/r", ref: "pr:3", requested_at: t, checked_at: t,
                                                             number: 3, state: "success", finished_at: t)
    kb.assign_pr(id, url: "https://github.com/o/r/pull/3", role: "pr", by: "agent")
    w = api(:get, "/api/waiting")
    assert_equal [1, "g/r", 1], [w["total"], w["projects"][0]["slug"], w["projects"][0]["count"]]
    assert_equal [id, "check me", "human_check", "Human Check", nil],
                 w["projects"][0]["cards"][0].values_at("id", "title", "column", "column_label", "question_first_line")
    refute_equal r0, api(:get, "/api/waiting/rev")["rev"]
    # each card's kind (ask = flagged needs_operator, review = in a gate) and the project's icon key; a card only
    # blocked_external waits for the world: in `external`, not in the list, a gate card too
    assert_equal "review", w["projects"][0]["cards"][0]["kind"]
    assert w["projects"][0].key?("icon")
    ask = kb.create(slug: "g/r", title: "which?", by: "op", column: "doing")
    kb.set_owner(ask, session: "lead_1", by: "lead")
    kb.ask(ask, question: "A or B?", by: "lead")
    blocked = kb.create(slug: "g/r", title: "ci down", by: "op", column: "qa")
    kb.block(blocked, reason: "runner offline", url: "https://ci.example.com/x", by: "agent")
    gate_blocked = kb.create(slug: "g/r", title: "deploy box down", by: "op", column: "ready")
    kb.block(gate_blocked, reason: "deploy host offline", url: "https://status.example.com", by: "agent")
    w = api(:get, "/api/waiting")
    kinds = w["projects"][0]["cards"].to_h { |c| [c["id"], c.values_at("kind", "owner_session")] }
    assert_equal({ ask => %w[ask lead_1], id => ["review", nil] }, kinds, "a blocked card is no review, no ask")
    assert_equal 2, w["total"]
    ext = w["external"][0]["cards"]
    assert_equal [[blocked, false, true, "runner offline"], [gate_blocked, false, true, "deploy host offline"]],
                 ext.map { |c| c.values_at("id", "needs_operator", "blocked", "blocked_first_line") }
    clear_cookies
    get "/api/waiting", nil, "HTTP_ACCEPT" => "application/json"
    assert_equal 401, last_response.status
  end

  def test_comment_with_no_owner_session_says_nobody_is_listening
    id = kb.create(slug: "g/r", title: "x", by: "op", column: "doing")
    kb.update(id, { "assignee" => "claude-shop-lead" }, by: "claude-shop-lead")
    c = api(:post, "/api/cards/#{id}/comment", body: "Ok, so what's the decision now?")
    assert_equal [201, "none: no owner session"], [last_response.status, c["delivered"]]
    m = api(:post, "/api/cards/#{id}/move", column: "qa")
    assert_match(/\Aspawn deferred to the notifier pass: launcher not reachable/, m["delivered"],
                 "an ownerless QA card gets its own worker")
    kb.set_owner(id, session: "acme_shop", by: "op")
    assert_equal "queued: acme_shop", api(:post, "/api/cards/#{id}/comment", body: "now?")["delivered"]
    assert_nil api(:post, "/api/cards/#{id}/move", column: "qa", position: 0)["delivered"], "a reorder in place moves nothing"
  end

  def test_operator_answer_clears_the_flag_in_place_and_pings_once
    id = kb.create(slug: "g/r", title: "triage", by: "op", column: "qa")
    kb.update(id, { "assignee" => "lead" }, by: "lead")
    kb.set_owner(id, session: "lead_1", by: "lead")
    kb.ask(id, question: "Auth or imgproc first?", options: ["Auth first", "Imgproc first"], by: "lead")
    j = api(:get, "/api/cards/#{id}")
    assert_equal ["qa", true, ["Auth first", "Imgproc first"]],
j["card"].values_at("column", "needs_operator", "question_options")
    assert_includes j["card"]["question_html"], "Auth or imgproc first?"
    assert_includes j["activity"].reverse.find { |a| a["kind"] == "comment" }["body_html"], "<code>Auth first</code>"
    b = api(:get, "/api/boards")
    assert_equal [%w[human_check ready], 1, 1, 1], [b["waiting_columns"], b["waiting"], b["boards"].first["waiting"],
                                                      b["boards"].first["flagged"],]
    assert_equal [1, 1], api(:get, "/api/projects/g/r/board").values_at("waiting", "flagged")

    c = api(:post, "/api/cards/#{id}/comment", body: "Auth first") # an option button posts the option as the answer
    assert_equal ["qa", false, nil, "queued: lead_1"], [c["card"]["column"], c["card"]["needs_operator"], c["card"]["question"],
                                                        c["delivered"],]
    ans = c["activity"].reverse.find { |a| a["kind"] == "answer" }
    assert_equal ["answered the question — the card stays in QA, work resumes", "owner@example.com"],
ans.values_at("body", "author")
    pings = kb.pending_pings
    assert_equal 1, pings.size
    assert_includes pings.first[:text], "ANSWERED your question on card ##{id}"
    assert_includes pings.first[:text], "Auth first"
    assert_includes pings.first[:text], "the card stays in QA"
    assert_equal 0, api(:get, "/api/boards")["waiting"]
  end

  # A fake bin/launcher on LAUNCHER_SOCKET answering `answer` with `reply` (like launch_test's).
  def with_launcher(reply)
    sock = ENV.fetch("LAUNCHER_SOCKET")
    File.unlink(sock) if File.socket?(sock)
    reqs = []
    server = UNIXServer.new(sock)
    t = Thread.new do
      loop do
        c = server.accept
        reqs << JSON.parse(c.gets)
        c.puts JSON.generate(reqs.last["op"] == "answer" ? reply : { ok: false, error: "not faked" })
        c.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    yield reqs
  ensure
    server&.close
    t&.kill
    File.unlink(sock) if sock && File.socket?(sock)
  end

  def dialog_card
    id = kb.create(slug: "g/r", title: "blocked", by: "op", column: "doing")
    kb.set_owner(id, session: "hi-dialog", by: "op")
    d = AgentsKanban::SessionDialog.parse("This shell -c script runs rm and could not be checked\nDo you want to proceed?\n" \
                                          "❯ 1. Yes\n  2. No\nEsc to cancel · Tab to amend\n")
    kb.dialog_question(session: "hi-dialog", dialog: d)
    [id, d[:hash]]
  end

  def test_dialog_answer_is_the_operators_and_refused_when_the_screen_changed
    require "socket"
    id, hash = dialog_card
    j = api(:get, "/api/cards/#{id}")
    assert_equal ["doing", true, %w[1 2 esc], "hi-dialog"],
                 [j["card"]["column"], j["card"]["needs_operator"], j["card"]["dialog"]["keys"], j["card"]["dialog"]["session"]]
    assert_equal 503, (api(:post, "/api/cards/#{id}/dialog-answer", key: "2") && last_response.status), "launcher down → 503"

    with_launcher({ ok: false, error: "hi-dialog: the dialog on its screen changed — nothing typed", status: 409 }) do |reqs|
      r = api(:post, "/api/cards/#{id}/dialog-answer", key: "2")
      assert_equal [422, "hi-dialog: the dialog on its screen changed — nothing typed"], [last_response.status, r["error"]]
      assert_equal [{ "op" => "answer", "session" => "hi-dialog", "socket" => "default", "hash" => hash, "key" => "2" }], reqs
      assert_equal ["doing", true], [kb.card(id)[:column], kb.flagged?(kb.card(id))]
      assert_match(/free-text answers are typed in the session/,
                   api(:post, "/api/cards/#{id}/dialog-answer", key: "type this")["error"])
      assert_equal 1, reqs.size, "an invalid key never reaches the launcher"
    end
    with_launcher({ ok: true, pressed: "2" }) do
      r = api(:post, "/api/cards/#{id}/dialog-answer", key: "2")
      assert_equal [200, "doing", nil, false],
[last_response.status, r["card"]["column"], r["card"]["dialog"], r["card"]["needs_operator"]]
      assert_equal ["answer", "owner@example.com"],
                   r["activity"].reverse.find { |a| a["kind"] == "answer" }.values_at("kind", "author")
    end

    post "/logout"
    api(:post, "/api/cards/#{id}/dialog-answer", key: "1")
    assert_includes [401, 403], last_response.status, "signed out (and its CSRF token gone) → refused"
    refute(AgentsKanban::Tools::NAMES.any? { |n| n.match?(/dialog|answer|press/) }, "agents have no tool to answer a dialog")
  end

  def test_backlog_md_tasks_in_board_json
    FileUtils.mkdir_p(File.join(@dir, "backlog/tasks"))
    File.write(File.join(@dir, "backlog/tasks/task-7 - Y.md"), "---\nid: TASK-7\ntitle: Y\nstatus: Done\n---\n")
    j = api(:get, "/api/projects/g/r/board")
    assert_equal [%w[TASK-7 merged]], j["backlog_md"]["tasks"].map { |t| t.values_at("id", "column") }
  end

  # a project's BOARD (its typed columns + workflow) is kept in the database (the engine's boards tables), edited
  # through the web API — read (the template's copy until edited), save (validated as a whole: 422 with the reason; a
  # column with cards cannot be dropped), reset; a move off the saved graph is refused 422 with the transitions there
  # are, a move by transition name works; the board JSON renders the DB columns.
  def test_the_board_shape_is_kept_in_the_database_and_governs_moves
    tpl = JSON.parse(File.read(File.join(__dir__, "../../vendor/agents_kanban/fixtures/boards/coding.board.json")))
    j = api(:get, "/api/projects/g/r/workflow")
    assert_equal [200, tpl["columns"], tpl["transitions"], "busyyaks"],
                 [last_response.status, j["columns"], j["transitions"], j["updated_by"]]
    assert_equal %w[human_check ready], j["rules"]["waiting"]
    assert_equal 7, j["types"].size
    db = Hanami.app["db.gateway"].connection
    assert_equal 1, db[:boards].where(project_slug: "g/r").count
    strict = tpl.merge("transitions" => [
                         { "name" => "Start work", "from" => "todo", "to" => "doing", "by" => "any" },
                         { "name" => "Approve", "from" => "human_check", "to" => "ready", "by" => "operator" },
                       ])

    j = api(:post, "/api/projects/g/r/workflow", strict)
    assert_equal [200, "owner@example.com", strict["transitions"]], [last_response.status, j["updated_by"], j["transitions"]]
    assert_equal 2, db[:board_transitions].where(project_slug: "g/r").count
    j = api(:post, "/api/projects/g/r/workflow",
            strict.merge("transitions" => [{ "name" => "X", "from" => "nope", "to" => "doing", "by" => "any" }]))
    assert_equal 422, last_response.status
    assert_match(/transitions\[0\]\.from/, j["error"])
    j = api(:post, "/api/projects/g/r/workflow",
            strict.merge("columns" => strict["columns"].map { |c| c.merge("type" => "done") }))
    assert_equal 422, last_response.status
    assert_match(/at most one done column|are both done/, j["error"])

    id = api(:post, "/api/projects/g/r/board", { title: "a", column: "todo" })["card"]["id"]
    j = api(:post, "/api/cards/#{id}/move", { column: "merged" })
    assert_equal 422, last_response.status
    assert_match(/workflow: no transition To do → Merged for the operator\. Allowed from To do: Start work → In progress/,
                 j["error"])
    j = api(:post, "/api/cards/#{id}/move", { transition: "Start work" })
    assert_equal [200, "doing"], [last_response.status, j["card"]["column"]]
    # a column with a card cannot be dropped: refused with the card id, nothing changed (the shape validates first:
    # a gate on a host whose handoff config is set needs nothing more; two done columns are refused as a shape)
    qa_id = api(:post, "/api/projects/g/r/board", { title: "in review", column: "qa" })["card"]["id"]
    j = api(:post, "/api/projects/g/r/workflow",
            strict.merge("columns" => strict["columns"].reject { |c| c["key"] == "qa" },
                         "transitions" => [
                           { "name" => "Approve", "from" => "human_check", "to" => "ready", "by" => "operator" },
                         ]))
    assert_equal 422, last_response.status
    assert_match(/cannot remove a column with cards: QA \(qa\) holds card ##{qa_id}/, j["error"])
    j = api(:post, "/api/projects/g/r/workflow",
            strict.merge("columns" => strict["columns"].reject { |c| c["key"] == "merged" },
                         "transitions" => [
                           { "name" => "Approve", "from" => "human_check", "to" => "ready", "by" => "operator" },
                         ]))
    assert_equal 422, last_response.status
    assert_match(/the board has no done column/, j["error"])
    assert_equal 7, db[:board_columns].where(project_slug: "g/r").count
    api(:post, "/api/cards/#{qa_id}/archive", { archived: true })
    # a renamed, retyped and reordered board renders on the board JSON
    renamed = strict["columns"].map { |c| c["key"] == "qa" ? c.merge("label" => "Code review") : c }
    shape = strict.merge("columns" => renamed[0..1] + [renamed[3], renamed[2]] + renamed[4..])
    api(:post, "/api/projects/g/r/workflow", shape)
    b = api(:get, "/api/projects/g/r/board")
    assert_equal ["Backlog", "To do", "Code review", "In progress", "Human Check", "Ready to merge", "Merged"],
                 b["columns"].map { |c| c["label"] }

    assert_equal shape["columns"], b["board"]["columns"]

    j = api(:delete, "/api/projects/g/r/workflow")
    assert_equal [200, tpl["transitions"], "owner@example.com"], [last_response.status, j["transitions"], j["updated_by"]]
    assert_equal 404, (api(:get, "/api/projects/nope/workflow") && last_response.status)
  end
  # the github service's answer for a card's PR: checks green, read just now (the approval gate reads it)
  def green_pr!(id)
    db = Hanami.app["db.gateway"].connection
    now = Time.now.to_i
    db[:gh_pr_checks].insert(repo: "o/r", ref: "pr:9", requested_at: now, checked_at: now, number: 9, state: "success",
                             finished_at: now)
    kb.assign_pr(id, url: "https://github.com/o/r/pull/9", role: "pr", by: "agent")
  end

  # the local board (local_v4) asks the operator three times — the approve endpoint works at every step, withdraw too
  def test_approve_at_every_step_of_a_local_board
    v3 = JSON.parse(File.read(File.join(__dir__, "../../vendor/agents_kanban/fixtures/boards/local_v4.board.json")))
    j = api(:post, "/api/projects/g/r/workflow", v3)
    assert_equal 200, last_response.status
    assert_equal [%w[local_human_review local_merged_pr deploy_check], %w[deploy_check public_create_pr public_agent_review],
                  %w[public_human_review awaiting_merge done],],
                 j["rules"]["gates"]["approvals"].map { |a| a.values_at("from", "to", "then") }
    assert_equal [false, false, true], j["rules"]["gates"]["approvals"].map { |a| a["final"] }
    id = api(:post, "/api/projects/g/r/board", { title: "a", column: "local_human_review" })["card"]["id"]
    # no green CI → refused, 422, the card stays
    j = api(:post, "/api/cards/#{id}/approve", { approved: true })
    assert_equal 422, last_response.status
    assert_match(/not approved \(Local: Human review → Local: Merged\): card ##{id} has no PR whose checks/, j["error"])
    green_pr!(id)
    c = api(:post, "/api/cards/#{id}/approve", { approved: true })["card"]
    assert_equal [200, "local_merged_pr", "owner@example.com"], [last_response.status, c["column"], c["approved_by"]]
    c = api(:post, "/api/cards/#{id}/approve", { approved: false })["card"]
    assert_equal ["local_human_review", nil], c.values_at("column", "approved_by")
    api(:post, "/api/cards/#{id}/move", { column: "public_human_review" })
    c = api(:post, "/api/cards/#{id}/approve", {})["card"]
    assert_equal %w[awaiting_merge owner@example.com], c.values_at("column", "approved_by")
    todo = api(:post, "/api/projects/g/r/board", { title: "b", column: "todo" })["card"]["id"]
    j = api(:post, "/api/cards/#{todo}/approve", {})
    assert_equal 422, last_response.status
    assert_match(/only a card in Local: Human review or Local: Deploy check or Public: Human review can be approved/,
j["error"])
  end
end
