# frozen_string_literal: true

require "test_helper"
require "open3"
require "busyyaks/agent_settings_api"

# the launchers + agent types are revisions in the database, edited on Settings → Agents & launchers; every
# launcher's command must be on the host allowlist (config/busyyaks.yml launch.commands).
class AgentSettingsTest < Minitest::Test
  include DBReset

  S = Busyyaks::AgentSettings
  API = Busyyaks::AgentSettingsAPI
  ALLOW = YAML.safe_load_file(File.expand_path("../fixtures/busyyaks.yml", __dir__)).dig("launch", "commands").freeze

  def db = Hanami.app["db.gateway"].connection
  def doc = JSON.parse(JSON.generate(AgentSettingsFixture::DOC))
  def base = S.current_id(db)
  def save(d, base: self.base, commands: ALLOW) = API.save({ "base" => base, "doc" => d }, by: "op", db: db, commands: commands)

  def test_the_config_file_may_not_carry_the_agent_keys
    raw = YAML.safe_load_file(Busyyaks::Kanban::CONFIG_PATH)
    assert_empty raw.keys & S::KEYS, "launchers / agent_types are database revisions"
    Dir.mktmpdir do |d|
      f = File.join(d, "k.yml")
      File.write(f, YAML.dump(raw.merge("launchers" => [])))
      e = assert_raises(S::Error) { S.file_hash(f) }
      assert_match(/launchers moved to the database/, e.message)
    end
  end

  def test_show_answers_the_current_revision_the_allowlist_and_each_argv
    status, body = API.show(db: db, commands: ALLOW)
    assert_equal 200, status
    assert_equal %w[fullclaude localclaude], body[:doc]["launchers"].map { |l| l["key"] }
    assert_equal ALLOW, body[:commands]
    assert_nil body[:error]
    lead = body[:preview].find { |p| p[:type] == "lead" && p[:launcher] == "fullclaude" }
    assert_equal %w[claude --permission-mode bypassPermissions --remote-control SESSION], lead[:argv]
    local = body[:preview].find { |p| p[:type] == "worker" && p[:launcher] == "localclaude" }
    assert_equal ["bash", "-ic", "localclaude --remote-control SESSION"], local[:argv]
  end

  def test_a_save_writes_a_new_revision_that_the_engine_config_runs_at_once
    before = Busyyaks::Kanban.config.agent_type("lead").label
    d = doc
    d["agent_types"].find { |t| t["key"] == "lead" }["label"] = "Lead it"
    status, body = save(d)
    assert_equal 200, status, body.inspect
    assert_equal "op", body[:revision][:author]
    assert_equal 2, body[:history].size, "the earlier revision stays as history"
    refute_equal before, "Lead it"
    assert_equal "Lead it", Busyyaks::Kanban.config.agent_type("lead").label, "rebuilt from the newest revision"
    assert_equal body[:revision][:id], Busyyaks::Kanban.config_revision[:id]
  end

  # a launch is planned and registered on the api's config: its start carries THAT revision, even when a newer one was
  # saved in between (the launcher never runs a revision the registration was not made for)
  def test_a_launch_starts_with_the_revision_its_api_was_built_on
    planned = Busyyaks::Kanban.config_revision
    api = Busyyaks::Kanban.api
    d = doc
    d["agent_types"].find { |t| t["key"] == "lead" }["label"] = "Lead it"
    assert_equal 200, save(d).first
    sent = []
    client = Busyyaks::LauncherClient.singleton_class
    client.alias_method(:call_unstubbed, :call)
    client.define_method(:call) { |req| sent << req and { "ok" => true } }
    begin
      api.instance_variable_get(:@launcher).start(session: "s", project: { path: "/p" }, type: "lead", launcher: "fullclaude",
                                                  argv: [], prompt_template: nil, vars: {}, lead_key: nil, lead: nil)
    ensure
      client.alias_method(:call, :call_unstubbed)
      client.remove_method(:call_unstubbed)
    end
    assert_equal planned, sent.first[:settings]
    refute_equal planned[:id], Busyyaks::Kanban.config_revision[:id], "a newer revision is current"
    assert_raises(ArgumentError) { Busyyaks::Kanban.revision_of(Object.new) }
  end

  def test_a_save_on_a_stale_base_is_a_conflict_and_writes_nothing
    old = base
    assert_equal 200, save(doc).first
    status, body = save(doc, base: old)
    assert_equal 409, status
    assert_match(/revision #{old} is not the newest/, body[:error])
    assert_equal 2, db[:agent_settings].count
  end

  # review round 1 (blocker): a revision with a worker / sub team under no lead is refused when saved, and a stored one
  # (written before the check, or by hand) when loaded — every caller of Kanban.config, the MCP tools included
  def test_a_revision_with_a_type_under_no_lead_is_refused_on_save_and_on_load
    d = doc
    d["agent_types"].find { |t| t["key"] == "worker" }.delete("under")
    n = db[:agent_settings].count
    status, body = save(d)
    assert_equal 422, status
    assert_match(/agent_types\[worker\] runs without a lead: give it `under: <lead type>`/, body[:error])
    assert_equal n, db[:agent_settings].count, "nothing written"
    db[:agent_settings].insert(doc: JSON.generate(d), author: "by hand", created_at: 1)
    e = assert_raises(Busyyaks::Kanban::Unrunnable) { Busyyaks::Kanban.config }
    assert_match(/agent settings revision \d+ does not run: agent_types\[worker\] runs without a lead/, e.message)
    assert_raises(Busyyaks::Kanban::Unrunnable) { Busyyaks::Kanban.tools }
  ensure
    AgentSettingsFixture.install!(db)
  end

  def test_a_command_off_the_allowlist_or_a_value_the_engine_refuses_is_422_and_writes_nothing
    d = doc
    d["launchers"][0]["command"] = "bash"
    status, body = save(d)
    assert_equal 422, status
    assert_includes body[:error], "launcher fullclaude (claude_code: bash --permission-mode bypassPermissions): not an " \
                                  "invocation on this host's allowlist"
    # the command allowlisted, an argument the host did not list: refused the same way (a --settings
    # with hooks, an --mcp-config, a permission mode would otherwise reach the host through an allowed command)
    d = doc
    d["launchers"][0]["args"] += ["--settings", "{}"]
    status, body = save(d)
    assert_equal 422, status
    assert_includes body[:error], "launcher fullclaude (claude_code: claude --permission-mode bypassPermissions " \
                                  "--settings {}): not an invocation"
    d = doc
    d["launchers"][1]["via_shell"] = false
    assert_equal 422, save(d).first, "via_shell is part of the invocation"
    d = doc
    d["agent_types"][0]["launchers"] = ["nope"]
    status, body = save(d)
    assert_equal 422, status
    assert_match(/agent_types\[lead\].launchers must be a non-empty list of launcher keys/, body[:error])
    # a prompt is one argv word: one starting with "-" would be an option of the allowlisted command
    d = doc
    d["agent_types"][0]["prompt"] = "--settings={\"hooks\":{}} {slug}"
    status, body = save(d)
    assert_equal 422, status
    assert_match(/agent_types\[lead\].prompt must not start with "-"/, body[:error])
    assert_equal 422, save(doc.merge("extra" => 1)).first
    assert_equal 422, API.save({ "doc" => doc }, by: "op", db: db, commands: ALLOW).first, "base is required"
    assert_equal 1, db[:agent_settings].count
  end

  # the host allowlist shrank after a revision was saved: the page says why it does not run, nothing is repaired
  def test_show_reports_a_current_revision_the_allowlist_no_longer_runs
    _, body = API.show(db: db, commands: ALLOW.first(1))
    assert_match(/launcher localclaude \(claude_code: localclaude \(via shell\)\): not an invocation on this host's allowlist/,
                 body[:error])
    assert_empty body[:preview]
  end

  def test_the_migration_seeds_the_repo_template
    assert_equal %w[claude], S.template["launchers"].map { |l| l["command"] }
    assert_equal %w[lead worker team plain], S.template["agent_types"].map { |t| t["key"] }
  end

  # the worker's PR subagents (QA + Reviewer) run on haiku, never on the worker's own model — said once, in the
  # worker's part of the skills busyyaks hands every worker session (skills/busyyaks/agents/worker.md)
  def test_the_worker_prompt_runs_its_qa_and_reviewer_subagents_on_haiku
    author = File.read(File.expand_path("../../skills/busyyaks/agents/worker.md", __dir__))
    assert_match(/\*\*QA agent\*\*: a fresh subagent \(`model: "haiku"`\)/, author)
    assert_match(/dispatch a REVIEWER — a fresh subagent \(`model: "haiku"`\)/, author)
  end

  # A template prompt says who the session is; the workflow is the skills', never repeated here
  def test_the_template_prompts_carry_no_workflow_text
    S.template["agent_types"].each do |t|
      p = t["prompt"].to_s
      ["kanban_ask", "kanban_handoff", "kanban_block", "severity", "skill", "reviewer agent", "conflict"].each do |w|
        refute_includes p.downcase, w, "#{t['key']}: #{w}"
      end
    end
  end

  # the move off config/kanban.yml: an old file's launchers + agent_types become a revision, the rest is ignored
  def test_bin_agent_settings_imports_an_old_kanban_yml_and_shows_the_current_revision
    root = File.expand_path("../..", __dir__)
    d = doc
    d["launchers"][1]["label"] = "local (imported)"
    old = YAML.safe_load_file(Busyyaks::Kanban::CONFIG_PATH).merge(d)
    out, err, st = Open3.capture3(File.join(root, "bin/agent-settings"), "import", stdin_data: YAML.dump(old), chdir: root)
    assert st.success?, err
    assert_match(/\Arevision \d+: fullclaude, localclaude · lead, worker, team, plain\n\z/, out)
    assert_equal "bin/agent-settings import", S.current(db)[:author]
    out, err, st = Open3.capture3(File.join(root, "bin/agent-settings"), "show", chdir: root)
    assert st.success?, err
    assert_equal "local (imported)", YAML.safe_load(out)["launchers"][1]["label"]
    bad = old.merge("launchers" => old["launchers"].map { |l| l.merge("command" => "sh") })
    _, err, st = Open3.capture3(File.join(root, "bin/agent-settings"), "import", stdin_data: YAML.dump(bad), chdir: root)
    refute st.success?
    assert_includes err, "launcher localclaude (claude_code: sh (via shell)): not an invocation"
    assert_match(/422: launcher fullclaude \(claude_code: sh /, err)
  end

  # a revision written before lead-first boards, in today's shape — what migration 20261207463000 writes
  def test_lead_first_converts_a_pre_463_revision_and_leaves_a_new_one_alone
    old = { "launchers" => [], "agent_types" => [
      { "key" => "lead", "takes" => ["gate"], "spawn_launcher" => "fullclaude" },
      { "key" => "worker", "takes" => [], "launcher_follows" => "lead", "spawn_launcher" => "fullclaude",
        "spawns_for" => %w[queued working review gate], },
      { "key" => "team", "takes" => [], "launcher_follows" => "lead", "spawn_launcher" => "fullclaude" },
      { "key" => "plain", "takes" => [], "spawn_launcher" => "fullclaude" },
    ], }
    out = Busyyaks::AgentSettings.lead_first(old)["agent_types"]
    assert_equal [%w[gate queued working review], [], [], []], out.map { |t| t["takes"] }
    assert_equal [nil, "lead", "lead", nil], out.map { |t| t["under"] }
    assert_equal [nil, nil, nil, true], out.map { |t| t["standalone"] }, "plain runs without a lead: standalone"
    assert(out.none? { |t| t.keys.intersect?(Busyyaks::AgentSettings::PRE_LEAD_FIRST) })
    assert_nil Busyyaks::AgentSettings.lead_first({ "launchers" => [], "agent_types" => out }), "already lead-first"
    assert_nil Busyyaks::AgentSettings.lead_first(AgentSettingsFixture::DOC), "the suite's revision is lead-first"
    leaderless = { "launchers" => [], "agent_types" => [{ "key" => "w", "takes" => [], "spawns_for" => ["queued"] }] }
    e = assert_raises(Busyyaks::AgentSettings::Error) { Busyyaks::AgentSettings.lead_first(leaderless) }
    assert_match(/cannot convert to lead-first boards — 0 followed types/, e.message)
    two = { "launchers" => [], "agent_types" => [{ "key" => "a", "takes" => [], "launcher_follows" => "x" },
                                                 { "key" => "b", "takes" => [], "launcher_follows" => "y" },], }
    assert_raises(Busyyaks::AgentSettings::Error) { Busyyaks::AgentSettings.lead_first(two) }
    only_spawn_launcher = { "launchers" => [], "agent_types" => [{ "key" => "p", "takes" => [], "spawn_launcher" => "c" }] }
    assert_equal [{ "key" => "p", "takes" => [], "standalone" => true }],
                 Busyyaks::AgentSettings.lead_first(only_spawn_launcher)["agent_types"]
    reviewer = { "key" => "r", "takes" => [], "prompt" => "review", "spawn_launcher" => "c" }
    told = { "launchers" => [], "agent_types" => [reviewer] }
    e = assert_raises(Busyyaks::AgentSettings::Error) { Busyyaks::AgentSettings.lead_first(told) }
    assert_match(/agent type r would run under no lead/, e.message)
  end

  # the live deployment's revision (stored before lead-first boards) converts to one the engine accepts with the suite's file
  def test_the_converted_revision_loads_on_the_engine
    raw = YAML.safe_load_file(File.expand_path("../fixtures/agents.yml", __dir__))
    old = raw.merge("agent_types" => raw["agent_types"].map do |t|
      case t["key"]
      when "lead" then t.merge("takes" => ["gate"])
      when "worker" then t.except("under").merge("launcher_follows" => "lead", "spawn_launcher" => "fullclaude",
                                                 "spawns_for" => %w[queued working review gate])
      when "team" then t.except("under").merge("launcher_follows" => "lead")
      else t
      end
    end)
    doc = Busyyaks::AgentSettings.lead_first(old)
    cfg = Busyyaks::AgentSettings.host(Busyyaks::AgentSettings.file_hash(ENV.fetch("KANBAN_CONFIG")), doc)
    assert_equal %w[gate queued working review], cfg.agent_type("lead").takes
    assert_equal %w[lead lead], [cfg.agent_type("worker").under, cfg.agent_type("team").under]
  end
end
