# frozen_string_literal: true

require "test_helper"
require "sequel"
require "tmpdir"
require "json"

Sequel.extension :migration

# The agents_kanban host migrations replay on a FRESH database step by step (each pinned to the engine schema step it
# introduced), and 20261116000000 (the boards) rolls back to the v5 shape main's code expects: `workflows` with every
# edited board's transitions — unless a board's columns changed, which v5 cannot hold: then the rollback refuses.
class MigrationsTest < Minitest::Test
  DIR = File.expand_path("../../config/db/migrate", __dir__)
  BOARDS = 20_261_116_000_000
  WORKFLOWS = 20_261_115_000_000
  BEFORE_V3 = 20_261_121_000_000 # the last migration before workflow v3 (whose down refuses: the rollback tests stop here)
  V3 = 20_261_122_000_000
  V3_FLAGS = 20_261_123_000_000 # the last migration before the v9 graph-position drop
  V9 = 20_261_124_000_000 # the last migration before v10 (card #248: gate head / state)
  BEFORE_LOCAL = 20_261_125_000_000 # the last migration before the local naming (card #249)
  LOCAL = 20_261_130_000_000
  BEFORE_PRS = 20_261_202_000_000 # the last migration before the assigned PRs

  # The scratch database is of the suite's adapter (DATABASE_ADAPTER): a SQLite file, or a PostgreSQL database
  # <POSTGRES_DB>_mig created on the same server (the CI role has CREATEDB) and dropped after each test.
  def setup
    # ROM::SQL.migration (the migration files' DSL) needs the app's gateway booted; the migrations run on a scratch DB below
    Hanami.app["db.gateway"]
    @dir = Dir.mktmpdir("mig")
    @setup = Busyyaks::Database.from_env
    @db = @setup.adapter == "sqlite" ? Sequel.connect("sqlite://#{File.join(@dir, 'm.sqlite3')}") : scratch_postgres
  end

  def teardown
    @db.disconnect
    FileUtils.rm_rf(@dir)
    admin { |a| a.run("DROP DATABASE IF EXISTS #{a.literal(Sequel.identifier(@scratch))}") } if @scratch
  end

  def admin(&) = Sequel.connect(@setup.url, **@setup.options, &)

  def scratch_postgres
    @scratch = "#{@setup.options.fetch(:database)}_mig"
    admin do |a|
      id = a.literal(Sequel.identifier(@scratch))
      a.run("DROP DATABASE IF EXISTS #{id}")
      a.run("CREATE DATABASE #{id}")
    end
    Sequel.connect(@setup.url, **@setup.options, database: @scratch)
  end

  # Sequel's migrator `load`s every migration file again on each run, and a reloaded file's coverage restarts from
  # zero: the measured lines would be only those of this process's LAST migrate call, which depends on
  # minitest's random test order. Each file is loaded once per process instead; the migration objects are stateless
  # (`apply(db, direction)`), so every run behaves as with a fresh load.
  class OnceMigrator < Sequel::TimestampMigrator
    LOADED = {}
    private_constant :LOADED

    def load_migration_file(file) = LOADED[file] ||= super
  end

  # the migration files use ROM's DSL (ROM::SQL.migration), which needs a current gateway: the app's, while the
  # migrations themselves run on the scratch database
  def migrate(target = nil)
    capture_io { ROM::SQL.with_gateway(Hanami.app["db.gateway"]) { OnceMigrator.new(@db, DIR, target: target).run } }
  end
  def applied = @db[:schema_migrations].select_map(:filename).map { |f| f.to_i }
  def coding = JSON.parse(File.read(File.expand_path("../../vendor/agents_kanban/fixtures/boards/coding.board.json", __dir__)))

  def store
    host = Busyyaks::AgentSettings.migration_host(Busyyaks::Kanban::CONFIG_PATH)
    AgentsKanban::Store.new(@db, config: host, markdown: Busyyaks::Kanban.markdown,
                                 boards: ->(s) { @db[:projects].where(slug: s).any? }, ci: Busyyaks::Kanban.ci_port(@db))
  end

  def project(slug)
    @db[:projects].insert(slug: slug, path: "/nonexistent/#{slug}", branch: "main", own: true, last_commit_at: 1,
                          commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
  end

  # a board's transitions as [name, from, to, by]
  def transitions_of(slug)
    @db[:board_transitions].where(project_slug: slug).select_map(%i[name from_keys to_key by])
                           .map { |n, f, t, b| [n, JSON.parse(f), t, b] }
  end

  def test_a_fresh_database_replays_every_step_and_v5_has_the_workflows_table_before_v6_replaces_it
    migrate(WORKFLOWS)
    assert @db.table_exists?(:workflows), "the v5 step still creates its table on a fresh DB"
    refute @db.table_exists?(:boards)
    assert_equal %i[id project_slug body updated_by updated_at], @db.schema(:workflows).map(&:first)
    project("g/r")
    strict = [{ "name" => "Start work", "from" => "todo", "to" => "doing", "by" => "any" },
              { "name" => "Approve", "from" => "human_check", "to" => "ready", "by" => "operator" },]
    body = JSON.generate("name" => "strict", "transitions" => strict)
    @db[:workflows].insert(project_slug: "g/r", body: body, updated_by: "op", updated_at: 7)
    migrate
    assert_includes applied, BOARDS
    refute @db.table_exists?(:workflows), "carried over and dropped"
    assert_equal ["", "g/r"], @db[:boards].order(:project_slug).select_map(:project_slug)
    assert_equal [["Start work", "todo", "doing", "any"], ["Approve", "human_check", "ready", "operator"]],
                 transitions_of("g/r")
    assert_equal coding["transitions"].size, @db[:board_transitions].where(project_slug: "").count
  end

  def test_rollback_restores_workflows_from_the_edited_boards_and_a_second_migrate_rebuilds_them
    migrate(BEFORE_V3)
    %w[g/r p same].each { |s| project(s) }
    st = store
    shape = coding
    st.board_save("g/r", shape.merge("transitions" => [{ "name" => "Go", "from" => "todo", "to" => "doing", "by" => "agent" },
                                                       { "name" => "Approve", "from" => "human_check", "to" => "ready",
                                                         "by" => "operator", },]),
                  by: "op")
    st.board_of("same") # the template's copy, unchanged: no workflows row on rollback (main's "no row = default")
    migrate(WORKFLOWS)
    refute_includes applied, BOARDS
    refute @db.table_exists?(:boards)
    assert @db.table_exists?(:workflows)
    rows = @db[:workflows].all
    assert_equal ["g/r"], rows.map { |r| r[:project_slug] }
    assert_equal [{ "name" => "Go", "from" => "todo", "to" => "doing", "by" => "agent" },
                  { "name" => "Approve", "from" => "human_check", "to" => "ready", "by" => "operator" },],
                 JSON.parse(rows.first[:body])["transitions"]
    assert_equal "op", rows.first[:updated_by]
    migrate(BEFORE_V3)
    assert_equal [%w[Go todo doing agent], %w[Approve human_check ready operator]], transitions_of("g/r")
    assert_equal coding["transitions"].size, @db[:board_transitions].where(project_slug: "p").count
  end

  def test_rollback_refuses_when_a_boards_columns_changed
    migrate(BEFORE_V3)
    project("g/r")
    shape = coding
    staging = { "key" => "staging", "label" => "Staging", "type" => "review" }
    store.board_save("g/r", shape.merge("columns" => shape["columns"] + [staging]), by: "op")
    e = assert_raises(Sequel::Error) { migrate(WORKFLOWS) }
    assert_match(%r{irreversible: the boards of g/r have columns the template has not.*restore the pre-migration backup},
                 e.message)
    assert @db.table_exists?(:boards), "nothing dropped"
    assert_includes applied, BOARDS
  end
  # v7 adds board_columns.hide_after_hours. A board that sets no value folds each column by its type's
  # default (done 24 h, parked 168 h, the rest 72 h). A board's own value overrides the default and survives a
  # reload; other boards keep the defaults.
  def test_v7_hide_after_hours_defaults_by_type_and_a_board_keeps_its_own_values
    migrate
    assert_includes @db.schema(:board_columns).map(&:first), :hide_after_hours
    %w[g/r p].each { |s| project(s) }
    st = store
    defaults = { "backlog" => 168, "todo" => 72, "doing" => 72, "qa" => 72, "human_check" => 72, "ready" => 72, "merged" => 24 }
    assert_equal defaults, st.board_of("p").hide_after_hours
    shape = coding
    own = { "merged" => 6, "human_check" => 0 }
    columns = shape["columns"].map { |c| own.key?(c["key"]) ? c.merge("hide_after_hours" => own[c["key"]]) : c }
    tuned = shape.merge("columns" => columns)
    st.board_save("g/r", tuned, by: "op")
    assert_equal defaults.merge("merged" => 6, "human_check" => 0), store.board_of("g/r").hide_after_hours
    assert_equal [6, 0], @db[:board_columns].where(project_slug: "g/r", key: %w[merged human_check]).order(:key)
                                            .select_map(:hide_after_hours).reverse
    assert_equal defaults, store.board_of("p").hide_after_hours
  end

  # v9 drops board_columns.x / y (the editor lays the graph out itself); its rollback puts them back, NOT NULL without a
  # default, at the serpentine the v8 code drew from, and up again drops them with the boards intact
  def test_v9_drops_the_graph_positions_and_rolls_back_to_the_v8_shape
    migrate
    project("p")
    before = store.board_of("p")
    assert_empty @db.schema(:board_columns).map(&:first) & %i[x y]
    migrate(V3_FLAGS)
    cols = @db.schema(:board_columns).to_h
    assert_equal [false, false], [cols[:x][:allow_null], cols[:y][:allow_null]]
    assert_equal [nil, nil], [cols[:x][:ruby_default], cols[:y][:ruby_default]]
    assert_equal [[0, 60, 80], [1, 230, 260], [2, 400, 80]],
                 @db[:board_columns].where(project_slug: "p").order(:position).select_map(%i[position x y]).first(3)
    migrate
    assert_empty @db.schema(:board_columns).map(&:first) & %i[x y]
    assert_equal before, store.board_of("p")
  end

  def test_v10_adds_the_gate_head_and_state_and_rolls_back
    migrate
    assert_equal %i[gate_head gate_state], @db.schema(:cards).map(&:first) & %i[gate_head gate_state]
    assert_includes @db.schema(:gh_pr_checks).map(&:first), :head
    migrate(V9)
    assert_empty @db.schema(:cards).map(&:first) & %i[gate_head gate_state]
    refute_includes @db.schema(:gh_pr_checks).map(&:first), :head
    migrate
    assert_includes @db.schema(:gh_pr_checks).map(&:first), :head
  end

  # a board saved before v7 has NULL in the new column: it reads as its column types' defaults
  def test_rows_from_before_v7_read_as_the_type_defaults
    migrate
    project("p")
    store.board_of("p")
    @db[:board_columns].update(hide_after_hours: nil)
    assert_equal({ "backlog" => 168, "merged" => 24, "qa" => 72 },
                 store.board_of("p").hide_after_hours.slice("backlog", "merged", "qa"))
  end

  # ── workflow v3 (20261122000000): Schema v8 + BoardRepo#migrate_v3! over every stored board ────────────────────────

  def board_fixture(name)
    JSON.parse(File.read(File.expand_path("../../vendor/agents_kanban/fixtures/boards/#{name}.board.json", __dir__)))
  end
  def v2 = board_fixture("legacy_v2")
  def v3 = board_fixture("mirror_v3") # the v3 migration's target (frozen); 20261130000000 renames it to local_v3

  # a workflow v2 board written as rows (the engine refuses v2 types as a Board now): what a live DB holds before v3
  def write_v2_board(slug, shape)
    @db[:boards].where(project_slug: slug).delete
    @db[:board_columns].where(project_slug: slug).delete
    @db[:board_transitions].where(project_slug: slug).delete
    @db[:boards].insert(project_slug: slug, updated_by: "op", updated_at: 5, created_at: 5)
    shape["columns"].each_with_index do |c, i|
      # (a v8 table: the graph positions are still there, NOT NULL — the serpentine the v6 – v8 editor seeded)
      @db[:board_columns].insert(project_slug: slug, key: c["key"], label: c["label"], type: c["type"], position: i,
                                 **AgentsKanban::Schema.legacy_xy(i), hide_after_hours: c["hide_after_hours"])
    end
    shape["transitions"].each_with_index do |t, i|
      @db[:board_transitions].insert(project_slug: slug, position: i, name: t["name"], from_keys: JSON.generate(t["from"]),
                                     to_key: t["to"], by: t["by"])
    end
  end

  def v2_coding
    cols = [%w[backlog Backlog parked], ["todo", "To do", "queued"], ["human_input", "Human input", "asks_operator"],
            ["doing", "In progress", "working"], %w[qa QA review], ["human_check", "Human Check", "handoff"],
            ["ready", "Ready to merge", "approved"], %w[merged Merged done],]
    { "columns" => cols.each_with_index.map { |(k, l, t), i| { "key" => k, "label" => l, "type" => t, "x" => i, "y" => 0 } },
      "transitions" => [{ "name" => "Ask the operator", "from" => %w[doing qa], "to" => "human_input", "by" => "agent" },
                        { "name" => "Answer", "from" => "human_input", "to" => "doing", "by" => "any" },
                        { "name" => "Approve", "from" => "human_check", "to" => "ready", "by" => "operator" },
                        { "name" => "Merge", "from" => "ready", "to" => "merged", "by" => "any" },
                        { "name" => "Move", "from" => "*", "to" => "*", "by" => "any" },], }
  end

  def card(slug, column, title, **more)
    now = 100
    @db[:cards].insert({ project_slug: slug, column: column, position: 0, title: title, notes: "", labels: "[]",
                         created_by: "op", created_at: now, updated_at: now, }.merge(more))
  end

  def test_v3_migrates_every_board_mechanically_and_reshapes_the_private_boards_by_their_columns
    migrate(BEFORE_V3)
    %w[g/r m/p plain].each { |s| project(s) }
    write_v2_board("", v2_coding)
    write_v2_board("plain", v2_coding)
    write_v2_board("m/p", v2)
    asked = card("plain", "human_input", "asked", question: "Which?", asked_at: 50, asked_by: "lead")
    @db[:card_activity].insert(card_id: asked, kind: "move", body: "In progress → Human input", author: "lead", created_at: 60)
    stale = card("plain", "qa", "stale", asked_at: 40, asked_by: "lead", question: "old")
    checked = card("plain", "human_check", "checked")
    approved = card("m/p", "approved_mirror", "approved")
    deployed = card("m/p", "deployed", "deployed", archived_at: 90)
    out, = migrate(BEFORE_LOCAL)
    assert_includes applied, V3
    assert_includes out, "1 mirror boards reshaped: m/p"
    cols = ->(slug) { @db[:board_columns].where(project_slug: slug).order(:position).select_map(%i[key type]) }
    assert_equal [%w[backlog parked], %w[todo queued], %w[doing working], %w[qa review], %w[human_check gate],
                  %w[ready gate], %w[merged done],], cols.("")
    assert_equal cols.(""), cols.("plain")
    assert_equal v3["columns"].map { |c| [c["key"], c["type"]] }, cols.("m/p")
    assert_equal %w[Approve Merge Move], @db[:board_transitions].where(project_slug: "plain").order(:position).select_map(:name)
    rows = @db[:cards].to_h { |c| [c[:id], c] }
    assert_equal ["doing", 50, "Which?"], rows[asked].values_at(:column, :asked_at, :question), "returned, flag kept"
    assert_equal ["qa", nil, nil], rows[stale].values_at(:column, :asked_at, :question), "an answered question loses its flag"
    assert_equal "human_check", rows[checked][:column]
    assert_equal %w[mirror_merged deploy_check], [rows[approved][:column], rows[deployed][:column]], "archived cards move too"
    assert_includes @db.schema(:cards).map(&:first), :blocked_at
    assert_includes @db.schema(:cards).map(&:first), :review_rounds
    # the migrated boards read as v3 boards: the approval step is the Approve edge, Human input is gone
    b = store.board_of("plain")
    assert_equal [%w[human_check ready merged Approve]], b.approvals.map { |a| [a.from, a.to, a.then, a.name] }
    assert_equal %w[human_check ready], b.waiting
    assert_equal 3, store.board_of("m/p").approvals.size
  end

  # ── local naming (20261130000000, card #249): the enrolment columns + the v3 private board's keys and labels ─────────

  # the suite's host config with review_loop.columns naming the old (mirror_) keys — what a pre-#249 kanban.yml says
  def with_old_review_loop
    path = File.join(@dir, "kanban-pre249.yml")
    File.write(path, File.read(ENV.fetch("KANBAN_CONFIG")).gsub("local_agent_review", "mirror_agent_review"))
    was = ENV.fetch("KANBAN_CONFIG")
    ENV["KANBAN_CONFIG"] = path
    yield
  ensure
    ENV["KANBAN_CONFIG"] = was
  end

  def test_local_naming_renames_the_private_board_and_the_enrolment_columns_and_down_restores_them
    migrate(BEFORE_LOCAL)
    %w[m/p plain].each { |s| project(s) }
    store.board_of("plain")
    host = Busyyaks::AgentSettings.migration_host(Busyyaks::Kanban::CONFIG_PATH)
    repo = AgentsKanban::BoardRepo.new(@db, tables: AgentsKanban::Schema.tables(""), host: host, known: ->(_) { true })
    repo.save("m/p", v3, by: "op", cards_in: ->(*) { {} })
    @db[:projects].where(slug: "m/p").update(mirror_mode: "own", mirror_repo: "https://github.com/o/p_local.git")
    rounds = JSON.generate("mirror_agent_review" => 2)
    c = card("m/p", "mirror_human_review", "waiting", review_rounds: rounds)
    @db[:card_activity].insert(card_id: c, kind: "move", body: "Mirror: Agent review → Mirror: Human review", author: "a",
                               created_at: 60)
    out, = migrate
    assert_includes applied, LOCAL
    assert_includes out, "local naming: 1 boards renamed"
    keys = ->(slug) { @db[:board_columns].where(project_slug: slug).order(:position).select_map(%i[key label]) }
    assert_equal board_fixture("local_v3")["columns"].map { |x| x.values_at("key", "label") }, keys.("m/p")
    assert_equal keys.(""), keys.("plain"), "a coding board is untouched"
    assert_includes @db[:board_transitions].where(project_slug: "m/p").select_map(:name), "Open local PR"
    assert_equal ["local_human_review", '{"local_agent_review":2}'], @db[:cards].where(id: c).get(%i[column review_rounds])
    assert_equal ["Local: Agent review → Local: Human review"], @db[:card_activity].where(card_id: c).select_map(:body)
    assert_equal ["own", "https://github.com/o/p_local.git"], @db[:projects].where(slug: "m/p").get(%i[local_mode local_repo])
    assert_equal 3, store.board_of("m/p").approvals.size

    e = assert_raises(Sequel::Error) { migrate(BEFORE_LOCAL) }
    assert_match(/review_loop.columns names local_agent_review, which this rollback renames back .*restore the pre-#249/,
                 e.message)
    assert_includes applied, LOCAL, "refused: nothing rolled back"
    with_old_review_loop { migrate(BEFORE_LOCAL) }
    refute_includes applied, LOCAL
    assert_equal v3["columns"].map { |x| x.values_at("key", "label") }, keys.("m/p")
    assert_equal ["mirror_human_review", '{"mirror_agent_review":2}'], @db[:cards].where(id: c).get(%i[column review_rounds])
    assert_equal ["Mirror: Agent review → Mirror: Human review"], @db[:card_activity].where(card_id: c).select_map(:body)
    assert_equal ["own", "https://github.com/o/p_local.git"], @db[:projects].where(slug: "m/p").get(%i[mirror_mode mirror_repo])
  end

  def test_local_naming_refuses_a_config_that_still_names_the_old_review_key
    migrate(BEFORE_LOCAL)
    project("m/p")
    store.board_of("m/p")
    host = Busyyaks::AgentSettings.migration_host(Busyyaks::Kanban::CONFIG_PATH)
    AgentsKanban::BoardRepo.new(@db, tables: AgentsKanban::Schema.tables(""), host: host, known: ->(_) { true })
                           .save("m/p", v3, by: "op", cards_in: ->(*) { {} })
    e = assert_raises(Sequel::Error) { with_old_review_loop { migrate } }
    assert_match(/review_loop.columns names mirror_agent_review, which this migration renames \(local_agent_review\)/,
                 e.message)
    refute_includes applied, LOCAL
    assert_includes @db[:board_columns].where(project_slug: "m/p").select_map(:key), "mirror_agent_review", "nothing renamed"
  end

  def test_local_naming_with_no_private_board_renames_only_the_columns
    migrate(BEFORE_LOCAL)
    project("plain")
    store.board_of("plain")
    out, = migrate
    assert_includes out, "local naming: 0 boards renamed"
    assert_includes @db.schema(:projects).map(&:first), :local_error
    migrate(BEFORE_LOCAL)
    assert_includes @db.schema(:projects).map(&:first), :mirror_error
  end

  def test_v3_refuses_a_human_input_card_whose_origin_the_log_does_not_name
    migrate(BEFORE_V3)
    project("plain")
    write_v2_board("", v2_coding)
    write_v2_board("plain", v2_coding)
    id = card("plain", "human_input", "orphan", asked_at: 50)
    e = assert_raises(Sequel::Error, AgentsKanban::Invalid) { migrate }
    assert_match(/card ##{id} \(plain\) sits in Human input and the activity log does not say/, e.message)
    refute_includes applied, V3
    assert_equal "human_input", @db[:cards].where(id: id).get(:column), "nothing moved"
  end

  def test_v3_down_is_refused_and_names_the_backup
    migrate
    e = assert_raises(Sequel::Error) { migrate(BEFORE_V3) }
    assert_match(/irreversible: workflow v3 .*Restore the pre-deploy backup/m, e.message)
    assert_includes applied, V3
  end

  # the cards in flight get the PRs the old lookup read as assignments (metadata prs.<role>), once
  def test_assigned_prs_carry_the_cards_in_flight_over
    migrate(BEFORE_PRS)
    %w[m/p plain].each { |s| project(s) }
    local_remote = "git@github.com:o/p_local.git"
    @db[:projects].where(slug: "m/p").update(local_mode: "own", local_repo: local_remote, pr_remote: local_remote,
                                             public_repo: "https://github.com/o/p.git")
    lpr = "https://github.com/o/p_local/pull/5"
    ppr = "https://github.com/o/p/pull/9"
    local = card("m/p", "deploy_check", "local in pr_url", pr_url: lpr)
    public = card("m/p", "public_agent_review", "public in pr_url", pr_url: ppr, metadata: JSON.generate("x" => 1))
    @db[:card_activity].insert(card_id: public, kind: "handoff", body: "handed to Local: Deploy check: PR #{lpr}",
                               author: "a", created_at: 50)
    kept = card("m/p", "awaiting_merge", "already assigned", pr_url: ppr,
                                         metadata: JSON.generate("prs" => { "public" => "https://github.com/o/p/pull/8" }))
    plain = card("plain", "human_check", "plain", pr_url: "https://github.com/o/plain/pull/3")
    other = card("plain", "doing", "a PR of another repo", pr_url: "https://github.com/x/y/pull/1")
    junk = card("plain", "doing", "not a PR URL", pr_url: "https://github.com/x/y/pull/1/files")
    none = card("m/p", "doing", "no PR")
    @db[:gh_pr_states].insert(repo: "o/p", ref: "head:o:pub/card-1", requested_at: 1)
    @db[:gh_pr_states].insert(repo: "o/p", ref: "pr:9", requested_at: 1)
    @db[:gh_pr_checks].insert(repo: "o/p", ref: "branch:card/1-x", requested_at: 1)
    out, = migrate
    assert_includes out, "cards_assigned_prs: 4 card(s) carried over"
    meta = ->(id) { (m = @db[:cards].where(id: id).get(:metadata)) && JSON.parse(m) }
    assert_equal({ "prs" => { "local" => lpr } }, meta.(local))
    assert_equal({ "x" => 1, "prs" => { "local" => lpr, "public" => ppr } }, meta.(public), "local from the handoff")
    assert_equal({ "prs" => { "public" => "https://github.com/o/p/pull/8" } }, meta.(kept),
                 "an assigned role is kept")
    assert_equal({ "prs" => { "pr" => "https://github.com/o/plain/pull/3" } }, meta.(plain))
    assert_equal({ "prs" => { "pr" => "https://github.com/x/y/pull/1" } }, meta.(other), "its URL names the repo")
    assert_nil meta.(junk)
    assert_nil meta.(none)
    assert_equal ["pr:9"], @db[:gh_pr_states].select_map(:ref)
    assert_empty @db[:gh_pr_checks].all
    migrate(BEFORE_PRS)
    assert_equal({ "prs" => { "local" => lpr } }, meta.(local), "down keeps the assignments")
  end
end
