# frozen_string_literal: true

require "test_helper"
require "open3"
require "busyyaks/runtime_settings_api"

# The services' timing is a revision in the database (Settings → Runtime), seeded by the migration from
# config/runtime.template.yml; every reader asks the current revision at each use.
class RuntimeSettingsTest < Minitest::Test
  include DBReset

  S = Busyyaks::RuntimeSettings
  API = Busyyaks::RuntimeSettingsAPI
  ROOT = File.expand_path("../..", __dir__)
  DOC = { "scan_interval_seconds" => 60, "writer_sync_seconds" => 30, "github_interval_seconds" => 3600,
          "github_ci_interval_seconds" => 60, "notifier_interval_seconds" => 5, "notifier_watch_seconds" => 30,
          "watchdog_grace_seconds" => 60, }.freeze

  def db = Hanami.app["db.gateway"].connection
  def save(d, base: S.current_id(db)) = API.save({ "base" => base, "doc" => d }, by: "op", db: db)

  def test_the_migration_seeded_the_template_which_holds_the_values_env_example_shipped
    cur = S.current(db)
    assert_equal "migration 20261217523000", cur[:author]
    assert_equal DOC, cur[:doc]
    assert_equal DOC, S.template
    assert_equal DOC.transform_keys(&:to_sym), S.get(db)
  end

  def test_show_lists_the_keys_in_order_with_the_env_key_each_replaced
    status, body = API.show(db: db)
    assert_equal 200, status
    assert_equal DOC.keys, body[:keys].keys
    assert_equal "SCAN_INTERVAL_SECONDS", body[:keys]["scan_interval_seconds"][:env]
    assert_equal [1, 86_400], [body[:min], body[:max]]
    assert_equal 1, body[:revisions]
  end

  def test_a_save_on_the_newest_writes_a_revision_and_every_reader_sees_it_at_once
    status, body = save(DOC.merge("scan_interval_seconds" => 90, "watchdog_grace_seconds" => 120,
                                  "github_ci_interval_seconds" => 30))
    assert_equal 200, status, body.inspect
    assert_equal "op", body[:revision][:author]
    assert_equal 2, body[:history].size, "the earlier revision stays as history"
    assert_equal 90, S.get(db)[:scan_interval_seconds]
    assert_equal 120, Busyyaks::Kanban.grace(db)
    assert_equal 30, Busyyaks::Kanban.ci_interval(db)
    assert_equal 300, Busyyaks::Kanban.ci_window(db)
  end

  # what a service loop does each turn (bin/scan, bin/writer, bin/github, bin/notifier): ask get again — the memo is
  # per revision, so a save between two turns is the next turn's value
  def test_get_answers_the_newest_revision_from_one_turn_to_the_next
    assert_equal 60, S.get(db)[:scan_interval_seconds]
    assert_same S.get(db), S.get(db), "one parse per revision"
    assert_equal 200, save(DOC.merge("scan_interval_seconds" => 45)).first
    assert_equal 45, S.get(db)[:scan_interval_seconds]
    %w[bin/scan bin/writer bin/github bin/notifier].each do |f|
      src = File.read(File.join(ROOT, f))
      loop_body = src[/^\s*loop do\n.*\z/m]
      assert_match(/RuntimeSettings\.get\(/, loop_body, "#{f} asks the settings inside its loop")
    end
  end

  # the seven names are read only through RuntimeSettings — no compose env, no reader in the code. Allowed:
  # runtime_settings.rb (KEYS: the import), bin/setup (refuses leftovers), bin/runtime-settings (its usage), old
  # migrations (history), docs and tests.
  def test_the_moved_env_names_are_read_nowhere_else
    names = Regexp.union(S::ENV_KEYS.keys)
    allowed = %w[lib/busyyaks/runtime_settings.rb bin/setup bin/runtime-settings]
    files = Dir.glob(%w[lib/**/* app/**/* bin/* cli/**/* config/*.rb config/*.yml config/providers/* mcp.ru config.ru
                        docker-compose*.yml Jenkinsfile scripts/**/* deploy/**/* frontend/src/**/*.{ts,tsx}], base: ROOT)
               .select { File.file?(File.join(ROOT, _1)) }
               .reject { _1.match?(/\.test\.tsx?\z/) } - allowed # test files may name them (fixtures, never bundled)
    hits = files.flat_map do |f|
      File.foreach(File.join(ROOT, f)).with_index(1).filter_map { |l, i| "#{f}:#{i}" if l.match?(names) }
    end
    assert_empty hits, "a moved .env name is read (or named as the source) outside RuntimeSettings"
  end

  def test_a_save_on_a_stale_base_is_a_conflict_and_writes_nothing
    base = S.current_id(db)
    assert_equal 200, save(DOC.merge("scan_interval_seconds" => 61), base: base).first
    newest = S.current_id(db)
    status, body = save(DOC.merge("scan_interval_seconds" => 62), base: base)
    assert_equal 409, status
    assert_equal "revision #{base} is not the newest (#{newest} is): reload, then save again", body[:error]
    assert_equal 61, S.get(db)[:scan_interval_seconds]
  end

  def test_every_value_is_a_whole_number_of_seconds_in_bounds_and_every_key_is_there
    {
      DOC.merge("scan_interval_seconds" => 0) => "scan_interval_seconds must be a whole number of seconds, 1..86400 (got 0)",
      DOC.merge("notifier_interval_seconds" => 86_401) => "notifier_interval_seconds must be a whole number of seconds, " \
                                                          "1..86400 (got 86401)",
      DOC.merge("github_interval_seconds" => "60") => "github_interval_seconds must be a whole number of seconds, 1..86400 " \
                                                       '(got "60")',
      DOC.merge("watchdog_grace_seconds" => 1.5) => "watchdog_grace_seconds must be a whole number of seconds, 1..86400 " \
                                                    "(got 1.5)",
      DOC.except("notifier_watch_seconds") => "missing notifier_watch_seconds",
      DOC.merge("ATTACHMENT_TYPES" => 1) => "unknown ATTACHMENT_TYPES (known: #{DOC.keys.join(', ')})",
      [] => "runtime settings must be an object {#{DOC.keys.join(', ')}}",
    }.each do |doc, why|
      status, body = save(doc)
      assert_equal [422, why], [status, body[:error]], doc.inspect
    end
    assert_equal 1, S.revisions(db), "nothing written"
  end

  # the notifier's watch pass re-asks every gated card's CI: a pass slower than the CI poll window
  # (10 × github_ci_interval_seconds) lets a request lapse — refused on save, so no stored revision has it
  def test_the_watch_pass_must_fit_the_ci_poll_window
    assert_equal 200, save(DOC.merge("notifier_watch_seconds" => 595)).first
    status, body = save(DOC.merge("notifier_watch_seconds" => 599, "notifier_interval_seconds" => 7))
    assert_equal 422, status, "the watch runs on whole deliver turns: 599 s at 7 s a turn is 86 turns = 602 s"
    assert_match(/\Aa watch pass every 602 s/, body[:error])
    status, body = save(DOC.merge("notifier_watch_seconds" => 600))
    assert_equal 422, status
    assert_match(/\Aa watch pass every 600 s .* must be below 600 s, the CI poll window/, body[:error])
    status, body = save(DOC.merge("notifier_interval_seconds" => 600))
    assert_equal 422, status
    assert_match(/notifier_interval_seconds 600/, body[:error], "the deliver loop's sleep stretches the watch period too")
    status, body = save(DOC.merge("github_ci_interval_seconds" => 3))
    assert_equal 422, status, "a faster CI poll shrinks the window under the watch pass"
    assert_match(/must be below 30 s/, body[:error])
  end

  def test_base_and_body_are_required
    assert_equal [422, { error: "body must be an object {base, doc}" }], API.save([], by: "op", db: db)
    assert_equal [422, { error: "base (the revision id the editor loaded) is required" }],
                 API.save({ "doc" => DOC }, by: "op", db: db)
  end

  def test_an_empty_table_is_missing_never_a_default
    db[:runtime_settings].delete
    e = assert_raises(S::Missing) { S.get(db) }
    assert_match(/no runtime settings revision: the table runtime_settings is empty/, e.message)
  ensure
    db[:runtime_settings].insert(doc: JSON.generate(DOC), author: "migration 20261217523000", created_at: 0) \
      if db[:runtime_settings].empty?
  end

  def test_the_old_env_lines_import_as_a_document
    text = <<~ENV
      # a comment
      TZ=UTC
      SCAN_INTERVAL_SECONDS=90
      WRITER_SYNC_SECONDS="30"
      export GITHUB_INTERVAL_SECONDS=3600
      GITHUB_CI_INTERVAL_SECONDS=60
      NOTIFIER_INTERVAL_SECONDS=5
      NOTIFIER_WATCH_SECONDS=30
      WATCHDOG_GRACE_SECONDS=60
    ENV
    assert_equal DOC.merge("scan_interval_seconds" => 90), S.from_env_lines(text)
    e = assert_raises(S::Refused) { S.from_env_lines("SCAN_INTERVAL_SECONDS=60\n") }
    assert_match(/\Athe \.env lines lack WRITER_SYNC_SECONDS, GITHUB_INTERVAL_SECONDS, /, e.message)
    assert_equal "x", S.from_env_lines(text.sub("=90", "=x"))["scan_interval_seconds"], "the save names it, not the parser"
  end

  def test_bin_runtime_settings_shows_and_imports_like_a_save
    out, err, st = Open3.capture3("bin/runtime-settings", "show", chdir: ROOT)
    assert st.success?, err
    assert_equal DOC, YAML.safe_load(out)
    env = DOC.map { |k, v| "#{S::KEYS[k].first}=#{k == 'scan_interval_seconds' ? 75 : v}" }.join("\n")
    out, err, st = Open3.capture3("bin/runtime-settings", "import-env", stdin_data: env, chdir: ROOT)
    assert st.success?, err
    assert_match(/^revision \d+: scan_interval_seconds=75 /, out)
    bad = YAML.dump(DOC.merge("scan_interval_seconds" => 0))
    _, err, st = Open3.capture3("bin/runtime-settings", "import", stdin_data: bad, chdir: ROOT)
    refute st.success?
    assert_match(/bin\/runtime-settings: 422: scan_interval_seconds must be a whole number/, err)
    assert_equal 75, S.get(db)[:scan_interval_seconds]
  end
end
