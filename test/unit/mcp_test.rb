# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "busyyaks/mcp_server"

class McpTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods

  TOKEN = "t" * 40
  REPORT_TOKEN = "r" * 40
  def app = Busyyaks::McpServer.new(token: TOKEN, report_token: REPORT_TOKEN, scan_interval: 60, store: store, config: nil,
                                    sessions: -> { %w[proj_2] })

  def rpc(method, params = {}, id: 1, auth: TOKEN)
    header "Authorization", "Bearer #{auth}"
    post "/mcp", JSON.generate(jsonrpc: "2.0", id: id, method: method, params: params), "CONTENT_TYPE" => "application/json"
    last_response.content_type == "application/json" ? JSON.parse(last_response.body) : nil
  end

  def tool(name, args = {}) = rpc("tools/call", { name: name, arguments: args })["result"]

  def test_requires_bearer
    rpc("ping", auth: "wrong")
    assert_equal 401, last_response.status
  end

  # a refused request is logged (rack.errors → the container log) with why, never with the header's value
  def test_a_refused_request_is_logged_without_the_token
    near = "#{TOKEN[0..-2]}X"
    [["Bearer #{near}", "wrong bearer token"], ["Basic #{TOKEN}", "not a Bearer Authorization header"],
     [nil, "no Authorization header"],].each do |value, why|
      errors = StringIO.new
      header "Authorization", value
      post "/mcp", "{}", "CONTENT_TYPE" => "application/json", "rack.errors" => errors, "REMOTE_ADDR" => "10.0.0.9"
      assert_equal 401, last_response.status
      line = errors.string
      assert_match(/\A\d{4}-\d\d-\d\dT\S+Z mcp 401 #{why} from 10\.0\.0\.9 POST \/mcp\n\z/, line)
      refute_includes line, TOKEN
      refute_includes line, near
    end
  end

  def test_refuses_browser_origin
    header "Origin", "https://evil.example"
    rpc("ping")
    assert_equal 403, last_response.status
  end

  def test_short_token_refused_at_boot
    assert_raises(KeyError) { Busyyaks::McpServer.new(token: "short", report_token: REPORT_TOKEN, scan_interval: 60) }
    assert_raises(KeyError) { Busyyaks::McpServer.new(token: TOKEN, report_token: "short", scan_interval: 60) }
    assert_raises(KeyError) { Busyyaks::McpServer.new(token: TOKEN, report_token: TOKEN, scan_interval: 60) }
  end

  # The daily report's token (MCP_REPORT_TOKEN) lists and calls only REPORT_TOOLS: a model that read a prompt-injected
  # commit subject cannot comment on a card (typed into a session), claim one or write a note.
  def test_the_report_token_reaches_only_the_report_tools
    names = rpc("tools/list", auth: REPORT_TOKEN).dig("result", "tools").map { |t| t["name"] }
    assert_equal Busyyaks::McpServer::REPORT_TOOLS.sort, names.sort
    %w[kanban_comment kanban_claim kanban_move kanban_create add_note scan_now].each do |t|
      refute_includes names, t
      r = rpc("tools/call", { name: t, arguments: { id: 1, body: "x", author: "a" } }, auth: REPORT_TOKEN)["result"]
      assert r["isError"], t
      assert_match(/not open to the daily report's token/, r.dig("content", 0, "text"))
    end
    r = rpc("tools/call", { name: "list_reports", arguments: {} }, auth: REPORT_TOKEN)["result"]
    refute r["isError"], r.dig("content", 0, "text")
    init = ->(auth) { rpc("initialize", { protocolVersion: "2025-06-18" }, auth: auth).dig("result", "instructions") }
    refute_includes init.(REPORT_TOKEN), "kanban_handoff", "the report token is told only what it may call"
    assert_includes init.(TOKEN), "kanban_handoff"
    full = rpc("tools/list").dig("result", "tools").map { |t| t["name"] }
    assert_includes full, "kanban_comment", "the full token keeps every tool"
  end

  def test_initialize_and_list
    r = rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "1" } })
    assert_equal "2025-06-18", r.dig("result", "protocolVersion")
    names = rpc("tools/list").dig("result", "tools").map { |t| t["name"] }
    assert_includes names, "whats_new"
    assert_includes names, "post_report"
  end

  def test_daily_report_config_tool
    assert_includes rpc("tools/list").dig("result", "tools").map { |t| t["name"] }, "daily_report_config"
    dr = { "schedule" => "daily", "cutoff" => "23:30", "probe_timeout" => 5, "run_timeout" => "90m", "gateway" => "http://g/v1",
           "model" => "served", "agent_model" => "served", "context_length" => 1000,
           "runner" => { "type" => "hermes", "command" => "hermes", "home" => "/h", "max_children" => 2 }, }
    base = { "roots" => [{ "path" => "/p", "prefix" => "" }], "search_depth" => 1, "owner_remotes" => ["example.com/x/"],
             "author_emails" => ["a@x"], "window_days" => 1, "reap_protect" => [], "auth" => { "provider" => "none" },
             "agents" => { "collector" => "none" }, "launch" => LAUNCH_CLAUDE, }
    with = Busyyaks::McpServer.new(token: TOKEN, report_token: REPORT_TOKEN, scan_interval: 60, store: store,
                                   config: Busyyaks::Config.new(base.merge("daily_report" => dr)))
    out = with.send(:call_tool, "daily_report_config", {})
    assert_equal({ "type" => "hermes", "command" => "hermes", "home" => "/h", "max_children" => 2 }, JSON.parse(out)["runner"])
    without = Busyyaks::McpServer.new(token: TOKEN, report_token: REPORT_TOKEN, scan_interval: 60, store: store,
                                      config: Busyyaks::Config.new(base))
    e = assert_raises(Busyyaks::McpServer::ToolError) { without.send(:call_tool, "daily_report_config", {}) }
    assert_match(/no daily_report key/, e.message)
  end

  def test_notification_is_202
    header "Authorization", "Bearer #{TOKEN}"
    post "/mcp", JSON.generate(jsonrpc: "2.0", method: "notifications/initialized")
    assert_equal 202, last_response.status
  end

  def test_post_report_then_whats_new
    res = tool("post_report", title: "Daily", body_markdown: "**hi**", author: "claude")
    assert_equal false, res["isError"]
    today = JSON.parse(tool("whats_new")["content"][0]["text"])
    assert_equal ["Daily"], today["reports"].map { |r| r["title"] }
  end

  def test_missing_argument_is_tool_error
    res = tool("post_report", title: "x", author: "a")
    assert_equal true, res["isError"]
    assert_match(/body_markdown is required/, res["content"][0]["text"])
  end

  def test_report_components_lists_every_component
    text = tool("report_components")["content"][0]["text"]
    Busyyaks::ReportBlocks::CATALOG.each { |c| assert_includes text, "```tl:#{c[:name]}" }
    # a blocked_external card waits for the world — the layout puts it under At risk, never Needs you
    assert_match(/"## At risk" — .*daily_facts\.blocked_external.*never under Needs you/, text)
  end

  def test_claim_with_tmux_session_sets_the_owner
    store.upsert_project(slug: "p", path: "/p", remote: nil, branch: "main", own: true, last_commit_at: 1, commits_window: 0,
                         mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    id = Busyyaks::Kanban.default.create(slug: "p", title: "t", by: "me")
    res = tool("kanban_claim", id: id, assignee: "agent-x", tmux_session: "proj_2")
    assert_equal false, res["isError"], res["content"][0]["text"]
    c = Busyyaks::Kanban.default.card(id)
    assert_equal %w[agent-x proj_2], [c[:assignee], c[:owner_session]]
  end

  def test_daily_facts_counts_both_windows_human_check_and_previous_figures
    t = Time.now.to_i
    store.upsert_project(slug: "a", path: "/a", remote: nil, branch: "main", own: true, last_commit_at: t, commits_window: 3,
                         mine_window: 3, dirty: 4, unpushed: nil, scanned_at: t,
                         dirty_paths: JSON.generate([" M app/a.rb", "?? db/migrate/1_x.rb"]))
    store.upsert_project(slug: "b", path: "/b", remote: "https://x/b", branch: "main", own: true, last_commit_at: t,
                         commits_window: 1, mine_window: 0, dirty: 0, unpushed: 2, scanned_at: t)
    row = ->(sha, ago, mine) { { sha: sha, author: "r", email: "r@x", committed_at: t - ago, subject: "s #{sha}", mine: mine } }
    store.replace_commits("a", [row.("a1", 3600, true), row.("a2", 7200, true), row.("a3", 30 * 3600, true)], t - (90 * 86_400))
    store.replace_commits("b", [row.("b1", 40 * 3600, false), row.("b2", 50 * 3600, false)], t - (90 * 86_400))
    k = Busyyaks::Kanban.default
    id = k.create(slug: "a", title: "check me", by: "agent", column: "qa")
    k.move(id, column: "human_check", by: "op")
    held = k.create(slug: "a", title: "ci first", by: "agent", column: "qa")
    k.move(held, column: "human_check", by: "op")
    db = Hanami.app["db.gateway"].connection
    { id => [7, "success"], held => [8, "pending"] }.each do |card, (n, state)| # the github service's answers
      db[:gh_pr_checks].insert(repo: "o/a", ref: "pr:#{n}", requested_at: t, checked_at: t, number: n, state: state,
                               finished_at: state == "success" ? t : nil)
      k.assign_pr(card, url: "https://github.com/o/a/pull/#{n}", role: "pr", by: "agent")
    end
    store.add_report(date: "2026-11-01", title: "Daily report 2026-11-01", author: "x",
                     body_md: "```tl:stats\n- { label: Uncommitted, value: 9 }\n```\n")
    store.add_report(date: "2026-11-01", title: "Daily report 2026-11-01 FAILED", author: "x", body_md: "log")
    store.add_report(date: "2026-11-01", title: "Daily report 2026-11-01 NOT RUN — local vLLM offline all day", author: "x",
                     body_md: "x")

    res = tool("daily_facts", hours: 24, series: "Daily report")
    assert_equal false, res["isError"], res["content"][0]["text"]
    f = JSON.parse(res["content"][0]["text"])
    assert_equal({ "commits" => 2, "mine" => 2, "repos_active" => 1 }, f["totals"])
    assert_equal({ "commits" => 2, "mine" => 1, "repos_active" => 2 }, f["previous_window"])
    assert_equal [["a", 2, 1, false]], f["repos"].map { |r| [r["repo"], r["commits"], r["prev"], r["upstream"]] }
    assert_equal ["a"], f["pending"]["no_upstream_active_own"]
    assert_equal [" M app/a.rb", "?? db/migrate/1_x.rb"], f["repos"][0]["dirty_paths"], "uncommitted paths come over MCP"
    assert_equal [4, 2], [f["pending"]["dirty_files"], f["pending"]["unpushed_commits"]]
    assert_equal [[id, "check me"]], f["human_check"].map { |c| [c["card"], c["title"]] }
    refute_nil f["human_check"][0]["since"]
    assert_equal [[held, "PR #8: CI is still running"]], f["waiting_for_ci"].map { |c| [c["card"], c["hold"]] },
                 "not approvable now: waiting for CI, not in human_check"
    assert_equal 2, f["kanban_columns"]["Human Check"]
    assert_equal "Daily report 2026-11-01", f["previous_report"]["title"]
    assert_equal [{ "label" => "Uncommitted", "value" => "9", "tone" => "neutral", "delta" => nil, "good" => nil }],
                 f["previous_report"]["figures"]
    assert_equal true, tool("daily_facts", hours: 0, series: "x")["isError"]
  end

  def test_claim_refuses_a_session_that_is_not_running
    store.upsert_project(slug: "p", path: "/p", remote: nil, branch: "main", own: true, last_commit_at: 1, commits_window: 0,
                         mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    id = Busyyaks::Kanban.default.create(slug: "p", title: "t", by: "me")
    res = tool("kanban_claim", id: id, assignee: "agent-x", tmux_session: "proj_9")
    assert_equal true, res["isError"]
    assert_match(/no tmux session "proj_9"/, res["content"][0]["text"])
  end

  def test_daily_facts_lists_human_input_next_to_human_check
    store.upsert_project(slug: "a", path: "/a", remote: nil, branch: "main", own: true, last_commit_at: 1, commits_window: 0,
                         mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    k = Busyyaks::Kanban.default
    id = k.create(slug: "a", title: "triage", by: "agent", column: "doing")
    k.set_owner(id, session: "proj_2", by: "agent")
    k.ask(id, question: "Auth or imgproc first?", options: %w[Auth Imgproc], by: "agent")
    f = JSON.parse(tool("daily_facts", hours: 24, series: "Daily report")["content"][0]["text"])
    hi = f["human_input"]
    assert_equal [[id, "triage", "Auth or imgproc first?", %w[Auth Imgproc], "proj_2"]],
                 hi.map { |c| c.values_at("card", "title", "question", "options", "owner_session") }
    refute_nil hi[0]["since"]
    assert_equal [], f["human_check"]
    assert_equal [true, "In progress", nil], hi[0].values_at("needs_operator", "column", "blocked")
    assert_equal 1, f["kanban_columns"]["In progress"], "the flagged card keeps its column"
    # a card only blocked_external waits for the world, not for the operator: its own list, with its reason
    b = k.create(slug: "a", title: "ci", by: "agent", column: "doing")
    k.block(b, reason: "CI runner down", url: "https://ci.example.com/job/x/3/", by: "agent")
    f = JSON.parse(tool("daily_facts", hours: 24, series: "Daily report")["content"][0]["text"])
    assert_equal [id], f["human_input"].map { |c| c["card"] }
    assert_equal [[b, "In progress", "CI runner down", "https://ci.example.com/job/x/3/", "agent"]],
                 f["blocked_external"].map { |c| c.values_at("card", "column", "reason", "url", "by") }
    refute_nil f["blocked_external"][0]["since"]
  end

  def test_check_report_lists_broken_blocks_and_untracked_repos
    store.upsert_project(slug: "a", path: "/a", remote: nil, branch: "main", own: true, last_commit_at: 1, commits_window: 0,
                         mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    md = "```tl:stats\n- { label: ok, value: 1 }\n```\n\n" \
         "```tl:flags\n- { level: red, kind: x, text: y }\n```\n\n`repo:a` `repo:ghost`"
    f = JSON.parse(tool("check_report", body_markdown: md)["content"][0]["text"])
    assert_equal ["tl:flags (block 2): level \"red\" — use one of bad, warn, info"], f["broken"]
    assert_equal ["ghost"], f["untracked_repos"]
    assert_empty store.reports
  end

  def test_unknown_tool_is_tool_error = assert_equal(true, tool("nope")["isError"])

  # last_scan is stale past 3 × SCAN_INTERVAL_SECONDS (60 here): the scanner stopped, its figures are not today's
  def test_daily_facts_marks_a_stale_scan
    facts = lambda do
      JSON.parse(tool("daily_facts", { hours: 24, series: "Daily report" }).dig("content", 0, "text"))["last_scan"]
    end
    now = Time.now.to_i
    id = store.scan_started(now - 1000)
    store.scan_finished(id, now - 999, 3, nil)
    old = facts.call
    assert_equal [true, 3], [old["stale"], old["repos"]]
    assert_operator old["age_seconds"], :>=, 999
    id = store.scan_started(now - 30)
    store.scan_finished(id, now - 29, 3, nil)
    refute facts.call["stale"]
  end
end
