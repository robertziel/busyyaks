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
                                                  argv: [], prompt_template: nil, vars: {})
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

  # the worker's PR subagents (QA + Reviewer) run on haiku, never on the worker's own model
  def test_the_worker_prompt_runs_its_qa_and_reviewer_subagents_on_haiku
    prompt = S.template["agent_types"].find { |t| t["key"] == "worker" }.fetch("prompt")
    qa = prompt.lines.find { |l| l.include?("independent QA agent") }
    reviewer = prompt.lines.find { |l| l.include?("dispatch a REVIEWER AGENT") }
    [qa, reviewer].each { |line| assert_includes line, 'Agent tool `model: "haiku"`' }
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
end
