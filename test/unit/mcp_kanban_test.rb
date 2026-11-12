# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "busyyaks/mcp_server"

class McpKanbanTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods

  TOKEN = "t" * 40
  REPORT_TOKEN = "r" * 40
  # live tmux sessions as the launcher's `sessions` op would list them; :down = launcher unreachable
  def live_sessions = (@live_sessions ||= %w[tl_g_r lead_1])

  def app
    Busyyaks::McpServer.new(token: TOKEN, report_token: REPORT_TOKEN, scan_interval: 60, store: store, config: nil,
                            sessions: lambda {
      raise Busyyaks::LauncherClient::Unavailable, "launcher not reachable at /x.sock: Errno::ENOENT" if live_sessions == :down

      live_sessions
    })
  end

  def setup
    super
    store.upsert_project(slug: "g/r", path: "/nonexistent/g/r", remote: nil, branch: "main", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
  end

  def rpc(method, params = {})
    header "Authorization", "Bearer #{TOKEN}"
    post "/mcp", JSON.generate(jsonrpc: "2.0", id: 1, method: method, params: params), "CONTENT_TYPE" => "application/json"
    JSON.parse(last_response.body)
  end

  def tool(name, args = {}) = rpc("tools/call", { name: name, arguments: args })["result"]
  def ok(name, args = {})
    r = tool(name, args)
    assert_equal false, r["isError"], r["content"][0]["text"]
    JSON.parse(r["content"][0]["text"])
  end

  def err(name, args = {})
    r = tool(name, args)
    assert_equal true, r["isError"]
    r["content"][0]["text"]
  end

  def test_tools_are_listed_and_worded_for_busyyaks_board
    tools = rpc("tools/list").dig("result", "tools")
    names = tools.map { |t| t["name"] }
    assert_empty(%w[kanban_board kanban_card kanban_create kanban_move kanban_update kanban_comment kanban_claim
                    kanban_handoff kanban_ask kanban_attach] - names)
    assert_match(%r{Agents enter a gate \(Human Check / Ready to merge\) only through kanban_handoff},
                 tools.find { |t| t["name"] == "kanban_move" }["description"])
    assert_empty(%w[kanban_block kanban_unblock] - names)
    # the template's; no enum: a project's board may differ
    move_column = tools.find { |t| t["name"] == "kanban_move" }["inputSchema"]["properties"]["column"]
    assert_match(/backlog=Backlog, todo=To do/, move_column["description"])
  end

  # the attach path through busyyaks's MCP server (the engine's own suite covers every refusal)
  def test_attach_base64_with_comment_pings_the_owner
    Dir.mktmpdir("mcp-att") do |root|
      env = ENV.to_h.slice("ATTACHMENTS_DIR", "ATTACHMENT_MAX_BYTES", "ATTACHMENT_TYPES")
      ENV["ATTACHMENTS_DIR"] = root
      ENV["ATTACHMENT_MAX_BYTES"] = "1000"
      ENV["ATTACHMENT_TYPES"] = "image/png,text/plain"
      Busyyaks::Kanban.instance_variable_set(:@policy, nil)
      kb = Busyyaks::Kanban.default
      card = kb.create(slug: "g/r", title: "T", by: "op")
      kb.set_owner(card, session: "tl_g_r", by: "op")
      png = "\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR".b + ("\x00".b * 40)
      r = ok("kanban_attach", id: card, author: "agent-a", filename: "shot.png", content_base64: [png].pack("m0"),
                              comment: "the bug:")
      a = r["attachment"]
      assert_equal ["shot.png", "image/png", "agent-a", r["comment_id"]],
                   a.values_at("filename", "content_type", "uploaded_by", "comment_id")
      assert_equal "the bug:\n\n![shot.png](/api/attachments/#{a['id']})", kb.comment!(r["comment_id"])[:body]
      assert_includes kb.pending_pings.find { |p| p[:card_id] == card }[:text], "/api/attachments/#{a['id']}"
      assert_equal [a["id"]], ok("kanban_attachments", id: card).map { |x| x["id"] }
      assert_match "the name says image/png",
                   err("kanban_attach", id: card, author: "a", filename: "a.png", content_base64: ["hello"].pack("m0"))
    ensure
      env.each { |k, v| ENV[k] = v }
      Busyyaks::Kanban.instance_variable_set(:@policy, nil)
    end
  end

  def test_agent_works_a_card_end_to_end
    ok("kanban_label_save", project: "g/r", name: "auth", color: "red", author: "agent-a")
    c = ok("kanban_create", project: "g/r", title: "Fix login", author: "agent-a", tmux_session: "tl_g_r", labels: ["auth"],
                            priority: "high", description: "**why**")
    assert_equal ["backlog", 0, ["auth"]], [c["column"], c["position"], c["labels"]]
    ok("kanban_create", project: "g/r", title: "Other", author: "agent-a", tmux_session: "tl_g_r", column: "todo")
    assert_equal "tl_g_r", ok("kanban_claim", id: c["id"], assignee: "tl_g_r", tmux_session: "tl_g_r")["assignee"]
    moved = ok("kanban_move", id: c["id"], column: "todo", position: 0, author: "tl_g_r")
    assert_equal ["todo", 0], [moved["column"], moved["position"]]
    ok("kanban_update", id: c["id"], author: "tl_g_r", title: "Fix login flow", priority: "")
    assert_equal "none: tl_g_r is the card's owner",
                 ok("kanban_comment", id: c["id"], body: "PR ready", author: "tl_g_r")["delivered"]
    ok("kanban_move", id: c["id"], transition: "Start work", author: "tl_g_r")
    e = err("kanban_move", id: c["id"], column: "human_check", author: "tl_g_r")
    assert_includes e, "kanban_handoff"
    hand = { id: c["id"], qa: "Open /x at 375 px and 1280 px; 4 buttons in one row", pr_url: "https://github.com/o/r/pull/7",
             ci_url: "https://ci.example.com/job/r/7/", ui_change: false, author: "tl_g_r", }
    assert_match(/has no PR whose checks could be read/, err("kanban_handoff", **hand), "no PR assigned yet")
    ok("kanban_pr_assign", id: c["id"], pr_url: "https://github.com/o/r/pull/7", role: "pr", author: "tl_g_r")
    assert_match(/CI not read yet .*; hand off once CI is green\z/, err("kanban_handoff", **hand)) # card #247
    now = Time.now.to_i # the github service answers the request the refusal registered: green
    Hanami.app["db.gateway"].connection[:gh_pr_checks].where(repo: "o/r", ref: "pr:7")
                                                    .update(checked_at: now, number: 7, state: "success", finished_at: now)
    ok("kanban_handoff", **hand)

    board = ok("kanban_board", project: "g/r")
    assert_equal %w[backlog todo doing qa human_check ready merged], board["columns"].map { |col| col["column"] }
    assert_equal ["Fix login flow"], board["columns"][4]["cards"].map { |x| x["title"] }
    assert_nil board["backlog_md"]
    assert_equal ["Other"], ok("kanban_board", project: "g/r", column: "todo")["columns"][0]["cards"].map { |x| x["title"] }

    card = ok("kanban_card", id: c["id"])
    assert_equal "**why**", card["card"]["description"]
    # each card's absolute board URL (Links rule): the test env's PUBLIC_HOST + the SPA path
    url = "https://example.org/projects/g/r?tab=board&card=#{c['id']}"
    assert_equal url, card["card"]["url"]
    assert_equal [url], board["columns"][4]["cards"].map { |x| x["url"] }
    kinds = card["activity"].map { |a| [a["kind"], a["author"]] }
    assert_includes kinds, %w[comment tl_g_r]
    assert_includes card["activity"].map { |a| a["body"] }, "In progress → Human Check"
  end

  def test_agents_cannot_merge_or_leave_human_check
    assert_match(/agents cannot create cards in Human Check: create it, do the work, then kanban_handoff/,
                 err("kanban_create", project: "g/r", title: "x", author: "a", tmux_session: "tl_g_r", column: "human_check"))
    assert_match(/agents cannot create cards in Ready to merge/,
                 err("kanban_create", project: "g/r", title: "x", author: "a", tmux_session: "tl_g_r", column: "ready"))
    c = ok("kanban_create", project: "g/r", title: "x", author: "a", tmux_session: "tl_g_r")
    Busyyaks::Kanban.default.move(c["id"], column: "human_check", by: "op")
    assert_match(/only the operator moves a card out of Human Check/,
                 err("kanban_move", id: c["id"], column: "merged", author: "a"))
    assert_match(/only the operator/, err("kanban_move", id: c["id"], column: "qa", author: "a"))
    assert_match(/agents cannot create cards in Merged/,
                 err("kanban_create", project: "g/r", title: "y", author: "a", tmux_session: "tl_g_r", column: "merged"))
    d = ok("kanban_create", project: "g/r", title: "z", author: "a", tmux_session: "tl_g_r")
    assert_match(/Merged/, err("kanban_move", id: d["id"], column: "merged", author: "a"))
  end

  def test_new_tools_are_listed
    names = rpc("tools/list").dig("result", "tools").map { |t| t["name"] }
    want = %w[kanban_comment_edit kanban_comment_delete kanban_labels kanban_label_save kanban_label_delete
              kanban_labels_set kanban_due_set kanban_checklist_add kanban_checklist_rename kanban_checklist_delete
              kanban_checklist_item_add kanban_checklist_item_edit kanban_checklist_toggle kanban_checklist_item_delete
              kanban_checklist_item_convert]
    assert_empty(want - names)
  end

  def test_agent_comments_markdown_edits_and_deletes_own
    c = ok("kanban_create", project: "g/r", title: "T", author: "agent-a", tmux_session: "tl_g_r")
    cid = ok("kanban_comment", id: c["id"], body: "**done**\n\n- a\n- b\n\n```\nx\n```", author: "agent-a")["id"]
    entry = Busyyaks::Kanban.default.activity_json(Busyyaks::Kanban.default.comment!(cid))
    assert_includes entry[:body_html], "<strong>done</strong>"
    assert_includes entry[:body_html], "<pre"
    e = ok("kanban_comment_edit", comment_id: cid, body: "edited @op", author: "agent-a")
    assert_equal "edited @op", e["body"]
    refute_nil e["edited"]
    refute e.key?("body_html")
    assert_match(/only agent-a edits or deletes/, err("kanban_comment_edit", comment_id: cid, body: "x", author: "agent-b"))
    assert_match(/only agent-a/, err("kanban_comment_delete", comment_id: cid, author: "agent-b"))
    assert_equal({ "deleted" => cid, "card" => c["id"] }, ok("kanban_comment_delete", comment_id: cid, author: "agent-a"))
    assert_match(/no comment/, err("kanban_comment_edit", comment_id: cid, body: "x", author: "agent-a"))
  end

  def test_agent_labels_due_checklists_and_reads_markdown
    assert_equal [], ok("kanban_labels", project: "g/r")
    assert_match(/color is required/, err("kanban_label_save", project: "g/r", name: "bug", author: "a"))
    ok("kanban_label_save", project: "g/r", name: "bug", color: "red", author: "a")
    l = ok("kanban_label_save", project: "g/r", name: "bug", color: "orange", new_name: "defect", author: "a")
    assert_equal [%w[defect orange]], l.map { |x| [x["name"], x["color"]] }
    ok("kanban_label_save", project: "g/r", name: "ui", color: "blue", author: "a")
    c = ok("kanban_create", project: "g/r", title: "T", author: "a", tmux_session: "tl_g_r", labels: ["defect"],
                            due: "2026-11-09T12:00Z")
    refute_nil c["due"]
    assert_match(/unknown label nope/, err("kanban_labels_set", id: c["id"], labels: ["nope"], author: "a"))
    assert_equal %w[defect ui], ok("kanban_labels_set", id: c["id"], labels: %w[defect ui], author: "a")["labels"]
    d = ok("kanban_due_set", id: c["id"], due: "2026-11-10T08:00+02:00", done: true, author: "a")
    assert_equal [true, "2026-11-10T06:00:00+00:00"], [d["due_done"], d["due"]]
    assert_nil ok("kanban_due_set", id: c["id"], due: "", author: "a")["due"]
    assert_equal "teal", ok("kanban_update", id: c["id"], cover: "teal", author: "a")["cover"]
    assert_equal %w[ui], ok("kanban_label_delete", project: "g/r", name: "defect", author: "a").map { |x| x["name"] }

    cl = ok("kanban_checklist_add", id: c["id"], title: "Steps", items: ["one", "two `x`"], author: "a")
    assert_equal [0, 2], [cl["checklist_done"], cl["checklist_total"]]
    list = cl["checklists"][0]
    refute list["items"][0].key?("body_html")
    ok("kanban_checklist_item_add", checklist_id: list["id"], body: "three", author: "a")
    t = ok("kanban_checklist_toggle", item_id: list["items"][0]["id"], done: true, author: "a")
    assert_equal [1, 3, "a"], [t["checklist_done"], t["checklist_total"], t["checklists"][0]["items"][0]["done_by"]]
    assert_match(/done must be true or false/,
                 err("kanban_checklist_toggle", item_id: list["items"][0]["id"], done: "yes", author: "a"))
    ok("kanban_checklist_item_edit", item_id: list["items"][1]["id"], body: "two **bold**", author: "a")
    ok("kanban_checklist_rename", checklist_id: list["id"], title: "Steps 2", author: "a")
    n = ok("kanban_checklist_item_convert", item_id: list["items"][1]["id"], author: "a")
    assert_equal ["two **bold**", "backlog"], [n["title"], n["column"]]
    r = ok("kanban_checklist_item_delete", item_id: list["items"][0]["id"], author: "a")
    assert_equal 1, r["checklist_total"]

    card = ok("kanban_card", id: c["id"])
    assert_equal "Steps 2", card["card"]["checklists"][0]["title"]
    refute card["card"].key?("description_html")
    assert(card["activity"].none? { |e| e.key?("body_html") })
    assert_equal %w[ui], card["card"]["labels"]
    assert_equal [], ok("kanban_checklist_delete", checklist_id: list["id"], author: "a")["checklists"]
  end

  def test_agent_cannot_convert_in_merged_and_human_check_rule_holds
    k = Busyyaks::Kanban.default
    id = k.create(slug: "g/r", title: "m", by: "op", column: "merged")
    item = k.item_add(k.checklist_add(id, title: "T", by: "op"), body: "x", by: "op")
    assert_match(/agents cannot create cards in Merged/, err("kanban_checklist_item_convert", item_id: item, author: "a"))
  end

  def test_bad_input_is_a_tool_error
    assert_match(/no project/, err("kanban_board", project: "nope"))
    assert_match(/no card/, err("kanban_card", id: 999_999))
    assert_match(/column must be one of/,
                 err("kanban_create", project: "g/r", title: "t", author: "a", tmux_session: "tl_g_r", column: "done"))
    assert_match(/author is required/, err("kanban_move", id: 1, column: "todo"))
  end

  # ── listening must hold: an agent is a card's assignee only together with a live tmux session ──────
  def test_update_and_create_refuse_an_agent_assignee
    c = ok("kanban_create", project: "g/r", title: "T", author: "claude-shop-lead", tmux_session: "tl_g_r")
    e = err("kanban_update", id: c["id"], author: "claude-shop-lead", assignee: "claude-shop-lead")
    assert_match(/use kanban_claim\(id, assignee, tmux_session\)/, e)
    assert_match(/use kanban_claim\(id, assignee, tmux_session\)/, err("kanban_update", id: c["id"], author: "a", assignee: ""))
    assert_match(/use kanban_claim/,
                 err("kanban_create", project: "g/r", title: "U", author: "a", tmux_session: "tl_g_r", assignee: "a"))
    assert_equal "claude-shop-lead", Busyyaks::Kanban.default.card(c["id"])[:assignee],
                 "created = owned by the author and its session"
    update = rpc("tools/list").dig("result", "tools").find { |t| t["name"] == "kanban_update" }
    refute(update["inputSchema"]["properties"].key?("assignee"))
  end

  def test_claim_requires_a_live_tmux_session
    c = ok("kanban_create", project: "g/r", title: "T", author: "a", tmux_session: "tl_g_r")
    # an ownerless, unassigned card (the operator cleared it)
    Busyyaks::Kanban.default.set_owner(c["id"], session: "", by: "test")
    Busyyaks::Kanban.default.update(c["id"], { "assignee" => "" }, by: "test")
    claim = rpc("tools/list").dig("result", "tools").find { |t| t["name"] == "kanban_claim" }
    assert_includes claim["inputSchema"]["required"], "tmux_session"
    assert_match(/subagent/, claim["description"])
    assert_match(/tmux_session is required/, err("kanban_claim", id: c["id"], assignee: "lead"))
    assert_match(/no tmux session "ghost" is running.*live: tl_g_r, lead_1/,
                 err("kanban_claim", id: c["id"], assignee: "lead", tmux_session: "ghost"))
    @live_sessions = :down
    assert_match(/cannot verify tmux sessions: launcher not reachable/,
                 err("kanban_claim", id: c["id"], assignee: "lead", tmux_session: "lead_1"))
    card = Busyyaks::Kanban.default.card(c["id"])
    assert_equal [nil, nil], card.values_at(:assignee, :owner_session), "a refused claim changes nothing"
    @live_sessions = nil
    got = ok("kanban_claim", id: c["id"], assignee: "claude-shop-lead", tmux_session: "lead_1")
    assert_equal %w[claude-shop-lead lead_1], got.values_at("assignee", "owner_session")
  end

  # ── needs_operator: kanban_ask FLAGS a card with a question (it keeps its column); the operator's answer clears it ──
  def test_ask_flags_the_card_with_a_question_and_options
    c = ok("kanban_create", project: "g/r", title: "Security triage", author: "lead", tmux_session: "tl_g_r", column: "doing")
    Busyyaks::Kanban.default.set_owner(c["id"], session: "", by: "test")
    assert_match(/no owner session.*kanban_claim/, err("kanban_ask", id: c["id"], question: "Which first?", author: "lead"))
    ok("kanban_claim", id: c["id"], assignee: "lead", tmux_session: "lead_1")
    assert_match(/question is required/, err("kanban_ask", id: c["id"], question: " ", author: "lead"))
    assert_match(/duplicate choices/, err("kanban_ask", id: c["id"], question: "Q", options: %w[A A], author: "lead"))
    assert_match(/array of strings/, err("kanban_ask", id: c["id"], question: "Q", options: "A,B", author: "lead"))

    asked = ok("kanban_ask", id: c["id"], question: "Fix **auth** or **imgproc** first?",
                             options: ["Auth first", "Imgproc first"], author: "shop-sec-imgproc")
    assert_equal ["doing", true, "Fix **auth** or **imgproc** first?", ["Auth first", "Imgproc first"], "shop-sec-imgproc"],
                 asked.values_at("column", "needs_operator", "question", "question_options", "asked_by")
    refute_nil asked["asked"]
    board = ok("kanban_board", project: "g/r")
    doing = board["columns"].find { |col| col["column"] == "doing" }
    assert_equal [[c["id"], true]], doing["cards"].map { |x| [x["id"], x["needs_operator"]] }, "the card kept its column"
    q = ok("kanban_card", id: c["id"])["activity"].reverse.find { |a| a["kind"] == "comment" }
    assert_equal "**Question for the operator:**\n\nFix **auth** or **imgproc** first?\n\n" \
                 "**Options:** `Auth first` · `Imgproc first`",
                 q["body"], "the question is a normal comment"
    refute q.key?("body_html")
    # a flagged card is not moved by agents until the operator answers
    assert_match(/waits for the operator's answer \(needs_operator\)/,
err("kanban_move", id: c["id"], column: "qa", author: "lead"))
    Busyyaks::Kanban.default.comment(c["id"], body: "Auth first", author: "op", operator: true)
    assert_equal false, ok("kanban_card", id: c["id"])["card"]["needs_operator"]
    assert_equal "qa", ok("kanban_move", id: c["id"], column: "qa", author: "lead")["column"]
  end

  def test_block_and_unblock_flag_a_card_blocked_external
    c = ok("kanban_create", project: "g/r", title: "ci", author: "lead", tmux_session: "tl_g_r", column: "doing")
    assert_match(/url is required/, err("kanban_block", id: c["id"], reason: "CI down", author: "lead"))
    assert_match(/http\(s\) URL/, err("kanban_block", id: c["id"], reason: "CI down", url: "jenkins", author: "lead"))
    b = ok("kanban_block", id: c["id"], reason: "CI runner down", url: "https://ci.example.com/job/x/3/", author: "lead")
    assert_equal ["doing", "CI runner down", "https://ci.example.com/job/x/3/", "lead"],
                 [b["column"], b["blocked"]["reason"], b["blocked"]["url"], b["blocked"]["by"]]
    assert_match(/blocked \(external\).*kanban_unblock/, err("kanban_move", id: c["id"], column: "qa", author: "lead"))
    assert_nil ok("kanban_unblock", id: c["id"], note: "runner back", author: "lead")["blocked"]
    assert_equal "qa", ok("kanban_move", id: c["id"], column: "qa", author: "lead")["column"]
  end

  def test_ask_refused_once_the_card_is_finished
    k = Busyyaks::Kanban.default
    id = k.create(slug: "g/r", title: "done", by: "op", column: "merged")
    k.set_owner(id, session: "lead_1", by: "op")
    assert_match(/its work is over/, err("kanban_ask", id: id, question: "Q?", author: "lead"))
  end

  # ── the session rules through busyyaks's server: owned creation, kanban_register, the instructions ───────
  def test_create_without_a_session_is_refused_and_register_adopts
    assert_match(/owned by its session: pass tmux_session/,
                 err("kanban_create", project: "g/r", title: "orphan", author: "someone"))
    k = Busyyaks::Kanban.default
    a = k.create(slug: "g/r", title: "A", by: "op", column: "human_check")
    # the lead runs two launchers and has no spawn_launcher: a hand-started session names the one it runs
    assert_match(/agent type lead runs fullclaude, localclaude — name the launcher this session was started with/,
                 err("kanban_register", project: "g/r", type: "lead", tmux_session: "tl_g_r", author: "x"))
    reg = ok("kanban_register", project: "g/r", type: "lead", launcher: "fullclaude", tmux_session: "tl_g_r", author: "x")
    assert_equal "fullclaude", reg["launcher"]
    assert_equal ["claude-tl_g_r", [a], nil, 1],
                 [reg["agent"], reg["adopted"].map { |c| c["id"] }, reg["concurrency"]["max_sessions"],
                  reg["concurrency"]["running"],]
    assert_equal %w[claude-tl_g_r tl_g_r], k.card(a).values_at(:assignee, :owner_session)
    c = ok("kanban_create", project: "g/r", title: "D", author: "claude-tl_g_r")
    assert_equal "tl_g_r", c["owner_session"]
    assert_match(%r{1/1 lead session already runs for g/r},
                 err("kanban_register", project: "g/r", type: "lead", tmux_session: "lead_1", author: "x"))

    init = rpc("initialize", { "protocolVersion" => "2025-06-18" })["result"]["instructions"]
    assert_match(/Start with whats_new\. Kanban: a board per project/, init)
    assert_match(/kanban_ask\(id, question, author, options\) on that card.*needs_operator/, init)
    # the Links rule reaches every agent through busyyaks's server (text pinned by the engine's tools_test)
    assert init.end_with?(AgentsKanban::Tools::LINKS)
  end
end
