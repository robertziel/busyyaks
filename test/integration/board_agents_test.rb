# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "socket"
require "json"
require "tmpdir"
require "fileutils"
require "busyyaks/mcp_server"

# Which agent type works a board's cards. The repo's .busyyaks/agents.yml (read by bin/launcher's
# project_agents op — faked here) says which opt-in types the board uses, its roles and which type or role each column
# takes; the MCP server checks every kanban_spawn / kanban_assign_worker against it before the engine starts anything,
# hands the role to bin/launcher's start and records what it started (session_roles).
class BoardAgentsTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods
  include SignIn

  SOCK = ENV.fetch("LAUNCHER_SOCKET")
  ALLOW = YAML.safe_load_file(File.expand_path("../fixtures/busyyaks.yml", __dir__)).dig("launch", "commands").freeze
  LEAD = "by_group_repo_teamlead"
  def app = Hanami.app
  def db = Hanami.app["db.gateway"].connection
  def k = Busyyaks::Kanban.default

  def setup
    super
    # the repo (mounted read-only in the services): its .busyyaks/agents.yml is there, its content the fake launcher's
    @repo = Dir.mktmpdir("board-agents")
    FileUtils.mkdir_p(File.join(@repo, ".busyyaks"))
    File.write(File.join(@repo, ".busyyaks/agents.yml"), "{}\n")
    store.upsert_project(slug: "group/repo", path: @repo, remote: nil, branch: "main", own: true,
                         last_commit_at: Busyyaks::Clock.epoch, commits_window: 1, mine_window: 1, dirty: 0, unpushed: nil,
                         scanned_at: 1)
    add_copywriter!
    @agents_answer = { ok: true, state: "none", agents: nil, opt_in: ["copywriter"] }
    fake_launcher
    assert_equal 200, sign_in
    get "/"
    csrf = last_response.body[/name="csrf-token" content="([^"]+)"/, 1]
    post "/api/launch", JSON.generate(slug: "group/repo", type: "lead", launcher: "localclaude"),
         "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json", "HTTP_X_CSRF_TOKEN" => csrf
    assert_equal 201, last_response.status, last_response.body
    @lead_keys = { LEAD => @requests.find { |r| r["op"] == "launch" }.fetch("lead_key") }
    @live = [LEAD]
  end

  def teardown
    @server&.close
    @thread&.kill
    File.unlink(SOCK) if File.socket?(SOCK)
    FileUtils.rm_rf(@repo)
    super
  end

  # the copywriter preset added to the agent settings (Settings → Agents & launchers → Add from preset): opt-in, under
  # the lead, on the lead's launchers
  def add_copywriter!
    cur = Busyyaks::AgentSettings.current(db)
    doc = cur[:doc]
    preset = Busyyaks::AgentPresets.load!.find { |p| p["key"] == "copywriter" }
    lead = doc["agent_types"].find { |t| t["key"] == "lead" }
    doc["agent_types"] << Busyyaks::AgentPresets.type(preset, launchers: lead["launchers"])
    Busyyaks::AgentSettings.save!(db, file: Busyyaks::Kanban.file_config, doc: doc, base: cur[:id], author: "op",
                                      commands: ALLOW)
  end

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
      { ok: true, session: n == 1 ? req["base"] : "#{req['base']}_#{n - 1}" }
    when "launch"
      { ok: true, session: req["session"], type: req["type"], launcher: req["launcher"], prompt: true,
        remote_control: "on", remote_control_name: req["session"], trust: "accepted", }
    when "lead_key"
      k = (@lead_keys || {})[req["session"]]
      k ? { ok: true, key: k } : { ok: false, status: 422, error: "#{req['session']}: no lead this launcher started" }
    when "sessions"
      row = { project_path: @repo, created: 1, attached: false, launched: true }
      { ok: true, sessions: (@live || []).map { |n| row.merge(name: n) } }
    when "project_agents" then @agents_answer
    else { ok: false, error: "unknown op #{req['op']}" }
    end
  end

  def mcp
    tok = ->(c) { c * 40 }
    Busyyaks::McpServer.new(token: tok.("a"), report_token: tok.("b"), board_token: tok.("c"), scan_interval: -> { 60 })
  end

  # → [error?, text]
  def tool(name, args)
    r = mcp.dispatch({ "id" => 1, "method" => "tools/call", "params" => { "name" => name, "arguments" => args } },
                     scope: :board)
    [r[:result][:isError], r[:result][:content][0][:text]]
  end

  def spawn(id, type, role: nil)
    a = { "id" => id, "type" => type, "tmux_session" => LEAD, "author" => "claude-#{LEAD}" }
    a["role"] = role if role
    tool("kanban_spawn", a)
  end

  def last_launch = @requests.reverse.find { |r| r["op"] == "launch" }

  def loaded(columns: {}, roles: {}, use: ["copywriter"])
    @agents_answer = { ok: true, state: "loaded", opt_in: ["copywriter"],
                       agents: { use: use, roles: roles, columns: columns }, }
  end

  def card(column) = k.create(slug: "group/repo", title: "work in #{column}", by: "op", column: column)

  def test_an_opt_in_type_runs_only_on_a_board_that_uses_it
    c = card("todo")
    # no file in the repo: "none" without asking the launcher
    FileUtils.rm_f(File.join(@repo, ".busyyaks/agents.yml"))
    err, text = spawn(c, "copywriter")
    assert err
    assert_match(/opt-in and this board does not use it \(\.busyyaks\/agents\.yml: none\)/, text)
    assert_equal 0, @requests.count { |r| r["op"] == "project_agents" }
    File.write(File.join(@repo, ".busyyaks/agents.yml"), "{}\n")
    err, text = spawn(c, "copywriter")
    assert err
    assert_match(%r{agent type copywriter is opt-in and this board does not use it \(\.busyyaks/agents\.yml: none\)}, text)
    refute(@requests.any? { |r| r["op"] == "launch" && r["type"] == "copywriter" }, "nothing started")
    err, text = spawn(c, "worker")
    refute err, text
    assert_equal ["worker", nil], last_launch.values_at("type", "role")
    row = db[:session_roles].first
    assert_equal [JSON.parse(text)["session"], "group/repo", "worker", nil],
row.values_at(:session, :project_slug, :type_key, :role)
  end

  def test_a_mapped_column_starts_only_its_type_or_role
    loaded(columns: { "todo" => "copywriter", "qa" => "changelog" },
           roles: { "changelog" => { label: "Changelog writer", like: "worker" } })
    todo = card("todo")
    err, text = spawn(todo, "worker")
    assert err
    assert_match(%r{column To do takes copywriter \(\.busyyaks/agents\.yml\): kanban_spawn\(type: copywriter\)}, text)
    err, text = spawn(todo, "copywriter")
    refute err, text
    assert_equal ["copywriter", nil, LEAD], last_launch.values_at("type", "role", "lead")
    assert_equal "copywriter", db[:session_roles].where(session: JSON.parse(text)["session"]).get(:type_key)

    qa = card("qa")
    err, text = spawn(qa, "worker")
    assert_match(/column QA takes changelog .*kanban_spawn\(type: worker, role: changelog\)/, text)
    assert err
    err, text = spawn(qa, "copywriter", role: "changelog")
    assert err
    assert_match(/role changelog runs as agent type worker: kanban_spawn\(type: worker, role: changelog\)/, text)
    err, text = spawn(qa, "worker", role: "changelog")
    refute err, text
    assert_equal %w[worker changelog], last_launch.values_at("type", "role"), "the role reaches bin/launcher's start"
    assert_equal "changelog", db[:session_roles].where(session: JSON.parse(text)["session"]).get(:role)

    # an unmapped column: any type the board runs, a role too (the card asks for it)
    doing = card("doing")
    err, text = spawn(doing, "worker", role: "nope")
    assert err
    assert_match(/no role nope in .busyyaks\/agents.yml \(roles: changelog\)/, text)
  end

  # a file the launcher leaves unread (untrusted repo) starts nothing for the board's cards
  def test_an_untrusted_boards_file_starts_no_session_at_all
    @agents_answer = { ok: true, state: "left: the repo is not trusted", agents: nil, opt_in: ["copywriter"] }
    err, text = spawn(card("todo"), "worker")
    assert err
    assert_match(/is not read \(the repo is not trusted\): no session is started .* never a plain worker/, text)
    refute(@requests.any? { |r| r["op"] == "launch" && r["type"] == "worker" })
  end

  # a held card answers "no card N" as every engine tool does — before the launcher is
  # asked; a session board's card is no project's
  def test_a_held_card_is_no_card_and_nothing_is_read_for_it
    loaded(columns: { "todo" => "copywriter" })
    c = card("todo")
    db[:cards].where(id: c).update(on_hold_at: 1, on_hold_by: "op")
    asked = @requests.count { |r| r["op"] == "project_agents" }
    err, text = spawn(c, "worker")
    assert err
    assert_equal "error: no card #{c}", text
    err, text = tool("kanban_assign_worker", { "id" => c, "worker_session" => "w", "tmux_session" => LEAD, "author" => "x" })
    assert [err, text] == [true, "error: no card #{c}"], text
    assert_equal asked, @requests.count { |r| r["op"] == "project_agents" }, "the launcher was not asked"
  end

  # a mapped column the board no longer has (a hand-edited file, a renamed column) refuses every spawn
  # and the lead's view, naming the key — never skipped
  def test_a_stale_column_key_refuses_naming_it
    loaded(columns: { "gone" => "copywriter" })
    err, text = spawn(card("doing"), "worker")
    assert err
    assert_match(/columns: the board has no column gone/, text)
    err, text = tool("board_agents", { "project" => "group/repo" })
    assert err
    assert_match(/no column gone/, text)
    loaded(columns: { "backlog" => "copywriter" })
    assert_match(/backlog is a parked column/, spawn(card("doing"), "worker")[1])
  end

  def test_an_invalid_file_refuses_every_spawn_naming_why
    @agents_answer = { ok: false, status: 422, error: "agent types: .busyyaks/agents.yml: unknown keys colums" }
    err, text = spawn(card("todo"), "worker")
    assert err
    assert_match(/unknown keys colums/, text)
    refute(@requests.any? { |r| r["op"] == "launch" && r["type"] == "worker" })
  end

  def test_a_worker_handed_a_card_matches_its_column
    loaded(columns: { "todo" => "copywriter" })
    doing = card("doing")
    _, text = spawn(doing, "worker")
    worker = JSON.parse(text)["session"]
    @live = [LEAD, worker]
    todo = card("todo")
    assign = { "id" => todo, "worker_session" => worker, "tmux_session" => LEAD, "author" => "claude-#{LEAD}" }
    err, text = tool("kanban_assign_worker", assign)
    assert err
    assert_match(/column To do takes copywriter .*#{worker} is a worker — give it a card of its kind/, text)
    err, text = tool("kanban_assign_worker", assign.merge("worker_session" => "by_group_repo_old"))
    assert err
    assert_match(/by_group_repo_old's type is not recorded — start one with kanban_spawn\(type: copywriter\)/, text)
  end

  # a session's own kanban_claim on a card in a mapped column is checked the same way; the rule is
  # where a session TAKES a card — a move or handoff into a mapped column is not asked (the card keeps its session)
  def test_a_claim_is_checked_and_a_move_is_not
    loaded(columns: { "todo" => "copywriter" })
    _, text = spawn(card("doing"), "worker")
    worker = JSON.parse(text)["session"]
    @live = [LEAD, worker]
    todo = card("todo")
    err, text = tool("kanban_claim", { "id" => todo, "assignee" => "worker-#{worker}", "tmux_session" => worker })
    assert err
    assert_match(/column To do takes copywriter .*#{worker} is a worker/, text)
    assert_nil k.card(todo)[:assignee], "nothing claimed"
    asked = @requests.count { |r| r["op"] == "project_agents" }
    tool("kanban_move", { "id" => card("doing"), "column" => "todo", "author" => "worker-#{worker}" })
    assert_equal asked, @requests.count { |r| r["op"] == "project_agents" }, "a move never asks the rule"
  end

  def test_the_lead_reads_the_boards_mapping
    loaded(columns: { "todo" => "copywriter", "qa" => "changelog" },
           roles: { "changelog" => { label: "Changelog writer", like: "worker" } })
    err, text = tool("board_agents", { "project" => "group/repo" })
    refute err, text
    v = JSON.parse(text)
    assert_equal ["loaded", ["copywriter"], ["copywriter"]], v.values_at("state", "use", "opt_in")
    assert_equal({ "label" => "Changelog writer", "like" => "worker", "brief" => ".busyyaks/skills/agents/changelog.md" },
                 v["roles"]["changelog"])
    cols = v["columns"].to_h { |c| [c["column"], c.values_at("takes", "spawn")] }
    assert_equal ["copywriter", "type: copywriter"], cols["todo"]
    assert_equal ["changelog", "type: worker, role: changelog"], cols["qa"]
    assert_equal [nil, nil], cols["doing"]
    # the operator's token never sees it: a board tool
    r = mcp.dispatch({ "id" => 1, "method" => "tools/list" }, scope: :operator)
    refute_includes r[:result][:tools].map { |t| t[:name] }, "board_agents"
    spawn_def = mcp.dispatch({ "id" => 1, "method" => "tools/list" }, scope: :board)[:result][:tools]
                   .find { |t| t[:name] == "kanban_spawn" }
    assert spawn_def[:inputSchema][:properties].key?(:role)
  end
end
