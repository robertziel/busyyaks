# frozen_string_literal: true

require "test_helper"
require "open3"
require "busyyaks/daily_report_settings_api"

# how the daily report runs is a revision in the database, edited on Settings → Daily report; the runner's
# host keys must equal an entry of the host allowlist (config/busyyaks.yml daily_report_runners).
class DailyReportSettingsTest < Minitest::Test
  include DBReset

  S = Busyyaks::DailyReportSettings
  API = Busyyaks::DailyReportSettingsAPI
  ALLOW = YAML.safe_load_file(File.expand_path("../fixtures/busyyaks.yml", __dir__))["daily_report_runners"].freeze
  ROOT = File.expand_path("../..", __dir__)
  DOC = { "schedule" => "*-*-* *:00/10:00", "cutoff" => "23:30", "probe_timeout" => 60, "run_timeout" => "90m",
          "gateway" => "http://127.0.0.1:8000/v1", "model" => "served", "agent_model" => "served",
          "context_length" => 131_072,
          "runner" => { "type" => "hermes", "command" => "hermes", "home" => "/h/.hermes-busyyaks",
                        "max_children" => 16, }, }.freeze

  def db = Hanami.app["db.gateway"].connection
  def doc = JSON.parse(JSON.generate(DOC))
  def save(d, base: S.current_id(db), runners: ALLOW)
    API.save({ "base" => base, "doc" => d }, by: "op", db: db, runners: runners)
  end

  def test_nothing_saved_is_not_configured_and_says_where
    status, body = API.show(db: db, runners: ALLOW)
    assert_equal 200, status
    assert_nil body[:revision]
    assert_nil body[:doc]
    assert_equal "no daily report settings saved: Settings → Daily report", body[:error]
    assert_equal ALLOW, body[:runners]
    assert_equal({ "hermes" => %w[command home] }, body[:host_keys])
    assert_equal [:not_configured, body[:error]], S.resolve(db, ALLOW)
  end

  def test_a_first_save_on_base_null_then_one_on_the_newest_write_revisions
    status, body = save(doc, base: nil)
    assert_equal 200, status, body.inspect
    assert_equal "op", body[:revision][:author]
    assert_nil body[:error]
    first = body[:revision][:id]
    d = doc.merge("cutoff" => "22:00")
    status, body = save(d, base: first)
    assert_equal 200, status, body.inspect
    assert_equal 2, body[:history].size, "the earlier revision stays as history"
    assert_equal 2, body[:revisions]
    state, cfg = S.resolve(db, ALLOW)
    assert_equal :ok, state
    assert_equal "22:00", cfg.to_h[:cutoff]
    assert_equal "http://127.0.0.1:8000/v1", cfg.to_h[:gateway]
  end

  def test_a_save_on_a_stale_base_is_a_conflict_and_writes_nothing
    assert_equal 200, save(doc, base: nil).first
    status, body = save(doc, base: nil)
    assert_equal 409, status
    assert_match(/revision nil is not the newest/, body[:error])
    assert_equal 1, db[S::TABLE].count
  end

  def test_a_runner_off_the_allowlist_or_a_bad_value_is_422_and_writes_nothing
    [["command", "bash"], ["home", "/home/me/.ssh"]].each do |k, v|
      d = doc
      d["runner"][k] = v
      status, body = save(d)
      assert_equal 422, status
      off = /runner \{.*"#{k}" ?=> ?"#{Regexp.escape(v)}".*\} is not on this host's allowlist/
      assert_match off, body[:error]
      assert_includes body[:error], "config/busyyaks.yml daily_report_runners"
    end
    status, body = save(doc, runners: [])
    assert_equal 422, status
    assert_includes body[:error], "none: config/busyyaks.yml has no daily_report_runners"
    {
      "cutoff must be HH:MM" => doc.merge("cutoff" => "25:00"),
      "unknown keys: extra" => doc.merge("extra" => 1),
      "missing keys: gateway" => doc.except("gateway"),
      "runner.max_children must be a positive integer" => doc.merge("runner" => doc["runner"].merge("max_children" => 0)),
      "gateway must be an http" => doc.merge("gateway" => "file:///etc"),
      "must be an object" => [1],
    }.each do |msg, d|
      status, body = save(d)
      assert_equal 422, status, msg
      assert_includes body[:error], msg
    end
    assert_equal 422, API.save({ "doc" => doc }, by: "op", db: db, runners: ALLOW).first, "base is required"
    assert_equal 422, API.save({ "base" => "1", "doc" => doc }, by: "op", db: db, runners: ALLOW).first
    assert_equal 0, db[S::TABLE].count
  end

  # the host allowlist dropped the saved runner: the page and the tool say why it does not run, nothing is repaired
  def test_a_current_revision_the_allowlist_no_longer_runs_is_not_configured
    assert_equal 200, save(doc, base: nil).first
    _, body = API.show(db: db, runners: [])
    assert_match(/\Arevision \d+ does not run: runner .* has no daily_report_runners/, body[:error])
    assert_equal "hermes", body[:doc]["runner"]["command"], "the saved revision is still shown"
  end

  # DailyReportConfig, the one validator of a revision: every key, no defaults; no zero run_timeout (no
  # limit inside the tick while systemd kills it), no schedule that reads as an option, no " or \ in the values the
  # runner writes into its YAML
  def test_the_validator_refuses_bad_values
    dr = ->(over) { Busyyaks::DailyReportConfig.new(doc.merge(over)) }
    runner = doc["runner"]
    bad = {
      "missing keys: cutoff" => -> { Busyyaks::DailyReportConfig.new(doc.except("cutoff")) },
      "unknown keys: extra" => -> { dr.("extra" => 1) },
      "cutoff must be HH:MM" => -> { dr.("cutoff" => "25:00") },
      "run_timeout must be a non-zero timeout(1)" => -> { dr.("run_timeout" => "1.5 hours") },
      "run_timeout must be a non-zero" => -> { dr.("run_timeout" => 90) },
      "must be a non-zero timeout(1) duration like 90m, got \"0\"" => -> { dr.("run_timeout" => "0") },
      "got \"00m\"" => -> { dr.("run_timeout" => "00m") },
      "schedule must be a systemd OnCalendar expression" => -> { dr.("schedule" => "--help") },
      "schedule must be a systemd OnCalendar" => -> { dr.("schedule" => "daily; rm") },
      "runner.home must not contain control characters" => -> { dr.("runner" => runner.merge("home" => "/h\nX=1")) },
      "probe_timeout must be a positive integer" => -> { dr.("probe_timeout" => 0) },
      "gateway must be an http" => -> { dr.("gateway" => "127.0.0.1:8000") },
      "gateway must not contain \" or \\" => -> { dr.("gateway" => "http://g/v1\"x") },
      "model must not contain \" or \\" => -> { dr.("model" => "a\\b") },
      "agent_model must not contain" => -> { dr.("agent_model" => "a\"b") },
      "model must be a non-empty string" => -> { dr.("model" => "") },
      "not a runner (known: hermes)" => -> { dr.("runner" => { "type" => "codex" }) },
      "runner: missing keys: home" => -> { dr.("runner" => runner.except("home")) },
      "runner: unknown keys: model" => -> { dr.("runner" => runner.merge("model" => "x")) },
      "runner.max_children must be a positive integer" => -> { dr.("runner" => runner.merge("max_children" => "16")) },
    }
    bad.each { |msg, f| assert_includes assert_raises(Busyyaks::DailyReportConfig::Invalid, msg, &f).message, msg }
    ["daily", "*-*-* *:00/10:00", "Mon..Fri 08:00", "hourly"].each { |v| assert_equal v, dr.("schedule" => v).to_h[:schedule] }
    assert_equal "90m", dr.("run_timeout" => "90m").to_h[:run_timeout]
    assert_equal "10", dr.("run_timeout" => "10").to_h[:run_timeout]
  end

  def test_the_migration_seeds_nothing
    assert_equal %i[id doc author created_at], db.schema(S::TABLE).map(&:first)
  end

  # the move off config/busyyaks.yml: the old block (under daily_report: or bare) becomes a revision
  def test_bin_daily_report_settings_imports_the_old_block_and_shows_it
    bin = File.join(ROOT, "bin/daily-report-settings")
    _, err, st = Open3.capture3(bin, "show", chdir: ROOT)
    refute st.success?
    assert_includes err, "no revision saved"
    out, err, st = Open3.capture3(bin, "import", stdin_data: YAML.dump("daily_report" => doc), chdir: ROOT)
    assert st.success?, err
    assert_match(%r{\Arevision \d+: \*-\*-\* \*:00/10:00 · http://127.0.0.1:8000/v1 · runner hermes\n\z}, out)
    assert_equal "bin/daily-report-settings import", S.current(db)[:author]
    out, err, st = Open3.capture3(bin, "import", stdin_data: YAML.dump(doc.merge("cutoff" => "21:00")), chdir: ROOT)
    assert st.success?, err
    out, err, st = Open3.capture3(bin, "show", chdir: ROOT)
    assert st.success?, err
    assert_equal "21:00", YAML.safe_load(out)["cutoff"]
    bad = doc.merge("runner" => doc["runner"].merge("command" => "sh"))
    _, err, st = Open3.capture3(bin, "import", stdin_data: YAML.dump(bad), chdir: ROOT)
    refute st.success?
    assert_match(/422: runner .*"sh".* is not on this host's allowlist/, err)
  end
end
