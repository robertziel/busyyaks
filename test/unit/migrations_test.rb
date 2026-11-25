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
  V9 = 20_261_124_000_000 # the last migration before v10 (gate head / state)
  BEFORE_LOCAL = 20_261_125_000_000 # the last migration before the local naming
  LOCAL = 20_261_130_000_000
  BEFORE_PRS = 20_261_202_000_000 # the last migration before the assigned PRs
  BEFORE_SESSION_BOARDS = 20_261_205_000_000 # the last migration before v11 (session boards: boards.archived_at)
  BEFORE_LEAD_FIRST = 20_261_206_000_000 # the last migration before v12 (lead-first boards)
  BEFORE_PR_LISTS = 20_261_209_492_000 # the last migration before v14 (a card's PRs are a list)
  BEFORE_PR_FLAGS = 20_261_208_467_999 # just before the PR base / merge flags: whatever lands before it stays
  BEFORE_DETACHED = 20_261_224_280_999 # just before projects.detached_sha
  BEFORE_PROGRESS = 20_261_209_491_999 # just before the progress watch (Schema v13 + projects.branch_tips)
  RUNTIME = 20_261_217_523_000 # the runtime settings (before writer_sync_seconds joined them)
  BEFORE_HOLD = 20_261_217_523_000 # the last migration before v15 (On hold)
  BEFORE_GREEN_CI = 20_261_221_574_000 # the last migration before v16 (green CI per gate)
  BEFORE_BY_PREFIX = 20_261_221_584_000 # the last migration before the by_ session names
  BEFORE_TEAM_LEAD = 20_261_224_600_000 # the last migration before the lead's label became its name
  BEFORE_LAUNCH_BAR = 20_261_225_000_000 # the last migration before the Launch bar's keys (launchable, launch_label)
  BEFORE_LEAD_UNASSIGNABLE = 20_261_225_100_000 # the last migration before v17 (card 612: a lead is never an assignee)
  BEFORE_COMMENT_ACTIONS = 20_261_225_612_000 # the last migration before v18 (comment actions)
  BEFORE_PARKED = 20_261_225_613_000 # the last migration before v19 (parked exits are the operator's)

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
                                 boards: ->(s) { @db[:projects].where(slug: s).any? },
                                 ci: Busyyaks::Kanban.ci_port(@db, interval: 60), # runtime_settings may not exist yet
                                 prs: Busyyaks::Kanban.pr_roles(@db))
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

  # v11 adds boards.archived_at; its rollback is refused while session boards exist (below v11 a
  # `session:*` row would read as a project's board) and goes once they are removed
  def test_v11_session_boards_roll_back_only_without_session_boards
    migrate
    assert_includes @db.schema(:boards).map(&:first), :archived_at
    st = store
    st.session_board!("s_one", by: "s_one")
    e = assert_raises(StandardError) { migrate(BEFORE_SESSION_BOARDS) }
    assert_match(/rollback refused: 1 session board\(s\) exist \(session:s_one\)/, e.message)
    assert_includes @db.schema(:boards).map(&:first), :archived_at
    %i[board_transitions board_columns boards].each { |t| @db[t].where(project_slug: "session:s_one").delete }
    migrate(BEFORE_SESSION_BOARDS)
    refute_includes @db.schema(:boards).map(&:first), :archived_at
    migrate
    assert_includes @db.schema(:boards).map(&:first), :archived_at
  end

  # the up adds detached_sha and turns a stored "" branch (a detached HEAD read before it) into null; the
  # down drops the column
  def test_detached_sha_clears_blank_branches_and_rolls_back
    migrate(BEFORE_DETACHED)
    project("det")
    project("on")
    @db[:projects].where(slug: "det").update(branch: "")
    migrate
    assert_equal({ "det" => [nil, nil], "on" => ["main", nil] },
                 @db[:projects].select_hash(:slug, %i[branch detached_sha]).transform_values(&:to_a))
    migrate(BEFORE_DETACHED)
    refute_includes @db.schema(:projects).map(&:first), :detached_sha
    migrate
  end

  # v13 = the progress watch's stretch on the card, + the scanner's branch tips; both roll back
  def test_v13_progress_watch_columns_roll_back
    pw = %i[progress_at progress_marks progress_pinged_at progress_commented_at progress_stale_at progress_error]
    migrate
    assert_equal pw, @db.schema(:cards).map(&:first) & pw
    assert_includes @db.schema(:projects).map(&:first), :branch_tips
    migrate(BEFORE_PROGRESS)
    assert_empty @db.schema(:cards).map(&:first) & pw
    refute_includes @db.schema(:projects).map(&:first), :branch_tips
    migrate
    assert_equal pw, @db.schema(:cards).map(&:first) & pw
  end

  # review round 1: v12 adds lead_id / needs_lead / lead_key_digest and the CHECK, rewrites the newest agent
  # settings revision as a new one (lead-first), and rolls back only with no open session under a lead and no revision
  # saved after its own — then the pre-463 revision is the newest again
  def test_v12_lead_first_checks_rewrites_the_revision_and_rolls_back
    migrate(BEFORE_LEAD_FIRST)
    fixture = YAML.safe_load_file(File.expand_path("../fixtures/agents.yml", __dir__))
    old = fixture.merge("agent_types" => fixture["agent_types"].map do |t|
      case t["key"]
      when "lead" then t.merge("takes" => ["gate"])
      when "worker" then t.except("under").merge("launcher_follows" => "lead", "spawn_launcher" => "fullclaude",
                                                 "spawns_for" => %w[queued working review gate])
      when "team" then t.except("under").merge("launcher_follows" => "lead")
      else t.except("standalone")
      end
    end)
    @db[:agent_settings].insert(doc: JSON.generate(old), author: "op", created_at: 1)
    migrate
    v12 = %i[lead_id needs_lead lead_key_digest]
    assert_equal v12, @db.schema(:agent_sessions).map(&:first) & v12
    row = { session: "w", socket: "default", project_slug: "p", type_key: "worker", launcher_key: "fullclaude",
            agent_name: "worker-w", launched_by: "op", launched_at: 1, }
    assert_raises(Sequel::CheckConstraintViolation, Sequel::ConstraintViolation) do
      @db[:agent_sessions].insert(row.merge(needs_lead: 1, lead_id: nil))
    end
    newest = @db[:agent_settings].reverse(:id).first
    assert_equal "migration 20261207463000", newest[:author]
    doc = JSON.parse(newest[:doc])
    assert_equal [nil, "lead", "lead", nil], doc["agent_types"].map { |t| t["under"] }
    assert_equal [nil, nil, nil, true], doc["agent_types"].map { |t| t["standalone"] }
    # refused while a session runs under a lead
    lead = @db[:agent_sessions].insert(row.merge(session: "l", type_key: "lead", agent_name: "claude-l"))
    w = @db[:agent_sessions].insert(row.merge(needs_lead: 1, lead_id: lead))
    e = assert_raises(StandardError) { migrate(BEFORE_LEAD_FIRST) }
    assert_match(/rollback refused: 1 open agent session\(s\) run under a lead/, e.message)
    @db[:agent_sessions].where(id: [lead, w]).update(ended_at: 2)
    # refused while a lead-first revision was saved after the migration's
    later = @db[:agent_settings].insert(doc: newest[:doc], author: "op", created_at: 3)
    e = assert_raises(StandardError) { migrate(BEFORE_LEAD_FIRST) }
    assert_match(/rollback refused: agent settings revision\(s\) #{later} saved after migration 20261207463000/, e.message)
    @db[:agent_settings].where(id: later).delete
    migrate(BEFORE_LEAD_FIRST)
    assert_empty @db.schema(:agent_sessions).map(&:first) & v12
    back = @db[:agent_settings].reverse(:id).first
    assert_equal ["migration 20261207463000 rollback", old], [back[:author], JSON.parse(back[:doc])]
    migrate
    assert_equal "lead", JSON.parse(@db[:agent_settings].reverse(:id).first[:doc])["agent_types"][1]["under"]
  end

  # 2026-11-24, the operator: "add naming to the busyyaks sessions … start them with BY so we can easily identify and
  # isolate them" — an existing install's newest agent settings revision gets `by_` on every session_name as a NEW
  # revision (no hand import), a prefixed one is left alone, and the rollback brings the old one back
  def test_existing_agent_settings_get_the_by_prefix_as_a_new_revision
    migrate(BEFORE_BY_PREFIX)
    fixture = YAML.safe_load_file(File.expand_path("../fixtures/agents.yml", __dir__))
    old = fixture.merge("agent_types" => fixture["agent_types"].map do |t|
      t.merge("session_name" => t["session_name"].delete_prefix("by_"))
    end)
    @db[:agent_settings].insert(doc: JSON.generate(old), author: "op", created_at: 1)
    migrate
    newest = @db[:agent_settings].reverse(:id).first
    assert_equal "migration 20261224600000 (by_ session names)", newest[:author]
    assert_equal %w[by_{slug}_teamlead by_{slug}_worker by_{slug}_team by_{slug}],
                 JSON.parse(newest[:doc])["agent_types"].map { |t| t["session_name"] }
    later = @db[:agent_settings].insert(doc: newest[:doc], author: "op", created_at: 3)
    e = assert_raises(StandardError) { migrate(BEFORE_BY_PREFIX) }
    assert_match(/rollback refused: 1 agent settings revision\(s\) saved after migration 20261224600000/, e.message)
    @db[:agent_settings].where(id: later).delete
    migrate(BEFORE_BY_PREFIX)
    back = @db[:agent_settings].reverse(:id).first
    assert_equal ["migration 20261224600000 (by_ session names) rollback", old], [back[:author], JSON.parse(back[:doc])]
    # a newest revision that has the prefix already: up writes nothing
    @db[:agent_settings].insert(doc: newest[:doc], author: "op", created_at: 4)
    n = @db[:agent_settings].count
    migrate
    assert_equal n, @db[:agent_settings].count, "a prefixed revision is left alone: no new row"
    assert_equal "op", @db[:agent_settings].reverse(:id).first[:author]
  end

  # 2026-11-25, the operator: "what's sub team? where is lead?" — the lead's rules were titled "Launch" (its label was
  # the button text): an existing install's newest revision gets "Team lead" on every lead type still labelled
  # "Launch", as a NEW revision (no hand import); a named one is left alone; the rollback brings the old one back
  def test_the_lead_labelled_launch_is_renamed_team_lead_as_a_new_revision
    migrate(BEFORE_TEAM_LEAD)
    fixture = YAML.safe_load_file(File.expand_path("../fixtures/agents.yml", __dir__))
    old = fixture.merge("agent_types" => fixture["agent_types"].map do |t|
      t["key"] == "lead" ? t.merge("label" => "Launch") : t
    end)
    @db[:agent_settings].insert(doc: JSON.generate(old), author: "op", created_at: 1)
    migrate
    newest = @db[:agent_settings].reverse(:id).first
    assert_equal "migration 20261225000000 (the lead's label: Team lead)", newest[:author]
    assert_equal ["Team lead", "Worker", "Sub team", "Plain"], JSON.parse(newest[:doc])["agent_types"].map { _1["label"] }
    assert_equal old.merge("agent_types" => fixture["agent_types"]), JSON.parse(newest[:doc]), "only the label changed"
    migrate(BEFORE_TEAM_LEAD)
    back = @db[:agent_settings].reverse(:id).first
    assert_equal old, JSON.parse(back[:doc])
    # a revision whose lead is named already: nothing written
    @db[:agent_settings].insert(doc: JSON.generate(fixture), author: "op", created_at: 4)
    n = @db[:agent_settings].count
    migrate
    assert_equal n, @db[:agent_settings].count
  end

  # only a LEAD (a type another runs under) labelled "Launch" is renamed: a worker or a plain session the operator
  # chose to call "Launch" keeps its label — it is a name, not the old button text on the lead
  def test_only_the_lead_labelled_launch_is_renamed
    fixture = YAML.safe_load_file(File.expand_path("../fixtures/agents.yml", __dir__))
    labelled = fixture.merge("agent_types" => fixture["agent_types"].map { |t| t.merge("label" => "Launch") })
    named = Busyyaks::AgentSettings.lead_named(labelled)
    assert_equal({ "lead" => "Team lead", "worker" => "Launch", "team" => "Launch", "plain" => "Launch" },
                 named["agent_types"].to_h { [_1["key"], _1["label"]] })
    assert_nil Busyyaks::AgentSettings.lead_named(fixture), "nothing to rename: no new revision"
  end

  # The Launch bar never offers Worker: an existing install's newest revision gets `launchable: false` on the worker
  # and "Launch team lead" as the lead's button text, as a NEW revision; one that says either already is left alone;
  # the rollback brings the old one back
  def test_the_launch_bar_never_offers_worker_after_the_migration
    migrate(BEFORE_LAUNCH_BAR)
    fixture = YAML.safe_load_file(File.expand_path("../fixtures/agents.yml", __dir__))
    old = fixture.merge("agent_types" => fixture["agent_types"].map { |t| t.except("launchable", "launch_label") })
    @db[:agent_settings].insert(doc: JSON.generate(old), author: "op", created_at: 1)
    migrate
    newest = @db[:agent_settings].reverse(:id).first
    assert_equal "migration 20261225100000 (Launch bar: worker spawn-only, Launch team lead)", newest[:author]
    assert_equal fixture, JSON.parse(newest[:doc]), "only the two keys changed"
    file = Busyyaks::AgentSettings.file_hash(File.expand_path("../fixtures/kanban.yml", __dir__))
    cfg = Busyyaks::AgentSettings.host(file, fixture)
    assert_equal [false, nil], [cfg.agent_type("worker").launchable, cfg.agent_type("worker").launch_label]
    assert_equal "Launch team lead", cfg.agent_type("lead").launch_label
    migrate(BEFORE_LAUNCH_BAR)
    assert_equal old, JSON.parse(@db[:agent_settings].reverse(:id).first[:doc])
    @db[:agent_settings].insert(doc: JSON.generate(fixture), author: "op", created_at: 4)
    n = @db[:agent_settings].count
    migrate
    assert_equal n, @db[:agent_settings].count, "a revision that says the keys already: nothing written"
    chosen = old.merge("agent_types" => old["agent_types"].map { |t| t["key"] == "worker" ? t.merge("launchable" => true) : t })
    out = Busyyaks::AgentSettings.launch_bar(chosen)
    assert(out["agent_types"].find { |t| t["key"] == "worker" }["launchable"], "the operator's own choice is kept")
  end

  # The migrator loads a migration file more than once (on boot: "already initialized constant LEAD_LABEL_AUTHOR"):
  # no migration assigns a top-level constant — its values are local variables of the file
  def test_no_migration_defines_a_top_level_constant
    offenders = Dir[File.expand_path("../../config/db/migrate/*.rb", __dir__)].flat_map do |f|
      File.readlines(f).each_with_index.filter_map do |l, i|
        "#{File.basename(f)}:#{i + 1}: #{l.strip}" if l.match?(/\A[A-Z][A-Za-z0-9_]*\s*(\|\|)?=[^=~]/)
      end
    end
    assert_empty offenders
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
    # the catch-all "Move" split v19-safe: agents everywhere but Backlog, the operator from Backlog
    assert_equal %w[Approve Merge Move Move],
                 @db[:board_transitions].where(project_slug: "plain").order(:position).select_map(:name)
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

  # ── local naming (20261130000000): the enrolment columns + the v3 private board's keys and labels ─────────

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
    out, = migrate(BEFORE_PR_LISTS)
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

  # v15 adds cards.on_hold_at / on_hold_by; the rollback drops both (a held card is a live card again)
  def test_v15_adds_the_hold_and_the_rollback_drops_it
    hold = %i[on_hold_at on_hold_by]
    migrate(BEFORE_HOLD)
    assert_empty @db.schema(:cards, reload: true).map(&:first) & hold
    migrate
    assert_equal hold, @db.schema(:cards, reload: true).map(&:first) & hold
    project("p")
    id = card("p", "doing", "held", on_hold_at: 50, on_hold_by: "op")
    migrate(BEFORE_HOLD)
    assert_empty @db.schema(:cards, reload: true).map(&:first) & hold
    assert_equal "doing", @db[:cards].where(id: id).get(:column), "the card itself is kept"
  end

  # v16 adds board_columns.requires_green_ci (null = no gate asks CI); the rollback drops it, the columns kept
  def test_v16_adds_requires_green_ci_and_the_rollback_drops_it
    migrate(BEFORE_GREEN_CI)
    refute_includes @db.schema(:board_columns, reload: true).map(&:first), :requires_green_ci
    migrate
    assert_includes @db.schema(:board_columns, reload: true).map(&:first), :requires_green_ci
    n = @db[:board_columns].count
    assert_operator n, :>, 0, "the template's columns"
    assert_equal [nil], @db[:board_columns].distinct.select_map(:requires_green_ci), "no gate asks CI after the step"
    @db[:board_columns].where(type: "gate").update(requires_green_ci: 1)
    migrate(BEFORE_GREEN_CI)
    refute_includes @db.schema(:board_columns, reload: true).map(&:first), :requires_green_ci
    assert_equal n, @db[:board_columns].count, "the columns themselves are kept"
  end

  # card 612: v17 clears every open card's lead assignee (the agent settings' lead types; owner kept, a line by
  # "migration"), adds the worker watch's columns; the rollback is refused once it cleared one, else drops the columns
  def test_v17_clears_lead_assignees_and_refuses_a_rollback_that_would_restore_one
    migrate(BEFORE_LEAD_UNASSIGNABLE)
    project("p")
    reg = ->(s, type, agent) do
      @db[:agent_sessions].insert(session: s, socket: "default", project_slug: "p", type_key: type, launcher_key: "x",
                                  agent_name: agent, launched_by: "op", launched_at: 1, needs_lead: 0)
    end
    reg.("p_lead", "lead", "claude-p_lead")
    reg.("p_plain", "plain", "claude-p_plain")
    lead = card("p", "doing", "lead's", assignee: "claude-p_lead", owner_session: "p_lead")
    plain = card("p", "doing", "plain's", assignee: "claude-p_plain", owner_session: "p_plain")
    migrate
    assert_includes @db.schema(:cards, reload: true).map(&:first), :worker_wait_at
    assert_equal [nil, "p_lead"], @db[:cards].where(id: lead).get(%i[assignee owner_session])
    assert_equal "claude-p_plain", @db[:cards].where(id: plain).get(:assignee), "not a lead: kept"
    line = @db[:card_activity].where(card_id: lead).get(%i[author body])
    assert_equal "migration", line[0]
    assert_match(/assignee cleared by the v17 migration: claude-p_lead is a lead/, line[1])
    e = assert_raises(StandardError) { migrate(BEFORE_LEAD_UNASSIGNABLE) }
    assert_match(/step 17 cleared a lead assignee on cards #{lead}: rolling back would restore a lead/, e.message)
    assert_includes @db.schema(:cards, reload: true).map(&:first), :worker_wait_at, "a refused rollback drops nothing"
    @db[:card_activity].where(card_id: lead).delete
    migrate(BEFORE_LEAD_UNASSIGNABLE)
    refute_includes @db.schema(:cards, reload: true).map(&:first), :worker_wait_at
  end

  # v18 adds board_transitions.comment (null = no comment action); the rollback drops it, the transitions kept
  def test_v18_adds_comment_actions_and_the_rollback_drops_it
    migrate(BEFORE_COMMENT_ACTIONS)
    refute_includes @db.schema(:board_transitions, reload: true).map(&:first), :comment
    migrate
    assert_includes @db.schema(:board_transitions, reload: true).map(&:first), :comment
    n = @db[:board_transitions].count
    assert_operator n, :>, 0, "the template's transitions"
    assert_equal [nil], @db[:board_transitions].distinct.select_map(:comment), "no comment action after the step"
    @db[:board_transitions].update(comment: 1)
    migrate(BEFORE_COMMENT_ACTIONS)
    refute_includes @db.schema(:board_transitions, reload: true).map(&:first), :comment
    assert_equal n, @db[:board_transitions].count, "the transitions themselves are kept"
  end

  # v17 then v18 in one upgrade on a live DB, open cards assigned to a worker and to a lead — v18
  # re-runs v17's lead-assignee step with the agent settings' lead types (never an ArgumentError), the worker's card
  # keeps its assignee, the lead's is cleared once (v18 adds no second line)
  def test_v17_then_v18_with_worker_assigned_open_cards
    migrate(BEFORE_LEAD_UNASSIGNABLE)
    project("p")
    %w[lead worker].each do |type|
      @db[:agent_sessions].insert(session: "p_#{type}", socket: "default", project_slug: "p", type_key: type,
                                  launcher_key: "x", agent_name: "#{type}-p", launched_by: "op", launched_at: 1,
                                  needs_lead: 0)
    end
    worker = card("p", "doing", "worker's", assignee: "worker-p", owner_session: "p_worker")
    lead = card("p", "doing", "lead's", assignee: "lead-p", owner_session: "p_lead")
    migrate
    assert_includes @db.schema(:board_transitions, reload: true).map(&:first), :comment
    assert_equal "worker-p", @db[:cards].where(id: worker).get(:assignee), "a worker stays the assignee"
    assert_nil @db[:cards].where(id: lead).get(:assignee)
    assert_equal 1, @db[:card_activity].where(card_id: lead, author: "migration").count, "cleared once"
  end

  # v19 makes every stored way out of a parked column the operator's (the template and each project's board),
  # splits a "*" catch-all, writes nothing on a board that has none, and its rollback leaves the boards as they are
  def test_v19_makes_the_ways_out_of_backlog_the_operators
    migrate(BEFORE_PARKED)
    project("p")
    store.board_of("p") # the project's own rows, from the template
    @db[:board_transitions].where(name: "Prioritise").update(by: "any")
    @db[:board_transitions].where(name: "Move", by: "operator").delete
    @db[:board_transitions].where(name: "Move").update(by: "any", from_keys: JSON.generate("*"))
    @db[:boards].where(project_slug: "").update(updated_by: "op", updated_at: 7)
    migrate
    ["p", ""].each do |slug|
      t = transitions_of(slug)
      assert_equal %w[Prioritise backlog todo operator], t.find { |x| x[0] == "Prioritise" }
      moves = t.select { |x| x[0] == "Move" }
      assert_equal [["Move", %w[todo doing qa human_check ready merged], "*", "any"], ["Move", "backlog", "*", "operator"]],
                   moves
    end
    assert_equal "migration", @db[:boards].where(project_slug: "").get(:updated_by)
    assert_empty store.board_of("p").workflow.from("backlog", actor: :agent), "the stored board loads, no agent way out"
    before = transitions_of("p")
    migrate(BEFORE_PARKED)
    assert_equal before, transitions_of("p"), "the rollback changes nothing"
  end

  # v14 turns each card's prs {role => url} into a list (by / at from its own "PR <role>: <url>" line);
  # the rollback goes back while every card fits {role => url}, and is refused naming the cards that do not
  def test_v14_prs_become_lists_and_roll_back_while_they_fit
    migrate(BEFORE_PR_LISTS)
    project("m/p")
    project("eng")
    @db[:projects].where(slug: "m/p").update(local_mode: "own", local_repo: "https://github.com/o/p_local.git",
                                             public_repo: "https://github.com/o/p.git")
    @db[:projects].where(slug: "eng").update(local_mode: "own", local_repo: "https://github.com/o/eng_local.git",
                                             public_repo: "https://github.com/o/eng.git")
    lpr = "https://github.com/o/p_local/pull/5"
    one = card("m/p", "doing", "one", metadata: JSON.generate("x" => 1, "prs" => { "local" => lpr }))
    @db[:card_activity].insert(card_id: one, kind: "update", body: "PR local: #{lpr}", author: "agent-1", created_at: 70)
    # real-world values: text naming two PRs, and a legacy role key mapped by the PR's repo
    old = card("m/p", "merged", "old", metadata: JSON.generate("prs" => {
      "mirror" => "https://github.com/o/p_local/pull/7 (merged → a476b54) + /pull/10 (merged → dcefc04)",
      "engine" => "https://github.com/o/eng/pull/2",
    }))
    # a `local` PR on a project that is not enrolled, in no role of the card →
    # removed by the migration (logged), never active
    project("plain")
    @db[:projects].where(slug: "plain").update(remote: "https://github.com/o/fleet.git")
    gone_card = card("plain", "todo", "gone",
                     metadata: JSON.generate("prs" => {
                                               "local" => "https://github.com/o/fleet_local/pull/4",
                                             }))
    migrate
    meta = ->(id) { JSON.parse(@db[:cards].where(id: id).get(:metadata)) }
    assert_equal({ "x" => 1, "prs" => [{ "url" => lpr, "repo" => "o/p_local", "number" => 5, "role" => "local",
                                          "by" => "agent-1", "at" => 70, }], }, meta.(one))
    assert_equal [["local", "https://github.com/o/p_local/pull/7"], ["local", "https://github.com/o/p_local/pull/10"],
                  ["public", "https://github.com/o/eng/pull/2"],], meta.(old)["prs"].map { |e| e.values_at("role", "url") }
    @db[:cards].where(id: old).delete
    gone = meta.(gone_card)
    why = "v14: o/fleet_local is in no role this project reads (project not enrolled)"
    assert_equal [[], "migration", why],
                 [gone["prs"], gone["prs_removed"][0]["removed_by"], gone["prs_removed"][0]["reason"]]
    assert_equal "PR local removed by the v14 migration: https://github.com/o/fleet_local/pull/4 — " \
                 "v14: o/fleet_local is in no role this project reads (project not enrolled)",
                 @db[:card_activity].where(card_id: gone_card, author: "migration").get(:body)
    @db[:cards].where(id: gone_card).delete
    two = card("m/p", "doing", "two", metadata: JSON.generate("prs" => [
      { "url" => "https://github.com/o/p_local/pull/6", "role" => "local" },
      { "url" => "https://github.com/o/eng_local/pull/7", "role" => "local" },
    ]))
    e = assert_raises(StandardError) { migrate(BEFORE_PR_LISTS) }
    assert_match(/cards #{two} hold several PRs of one role or unassigned PRs/, e.message)
    assert_equal "local", meta.(one)["prs"].first["role"], "a refused rollback writes nothing"
    @db[:cards].where(id: two).delete
    migrate(BEFORE_PR_LISTS)
    assert_equal({ "x" => 1, "prs" => { "local" => lpr } }, meta.(one))
    migrate
    assert_equal "agent-1", meta.(one)["prs"].first["by"]
  end

  # the PR base / draft / mergeable columns, and the CI poller's cached pages (read before it kept those
  # fields) dropped so the next read is a full one; down restores the shape
  def test_pr_flags_add_the_merge_columns_and_drop_the_old_ci_pages
    migrate(BEFORE_PR_FLAGS)
    @db[:gh_pages].insert(url: "ci:/repos/o/r/pulls/1", etag: "e", items: "{}", at: 1)
    @db[:gh_pages].insert(url: "follows:me", etag: "e", items: "[]", at: 1)
    migrate
    assert_equal ["follows:me"], @db[:gh_pages].select_map(:url), "only the CI poller's pages"
    cols = ->(t) { @db.schema(t, reload: true).map(&:first) }
    assert_empty(%i[local_base public_base] - cols.(:projects))
    assert_empty(%i[base merge_state auto_merge] - cols.(:gh_pr_states))
    assert_empty(%i[base draft merge_state auto_merge] - cols.(:gh_pr_checks))
    migrate(BEFORE_PR_FLAGS)
    refute_includes cols.(:projects), :local_base
    refute_includes cols.(:gh_pr_checks), :draft
    refute_includes cols.(:gh_pr_states), :auto_merge
  end

  # a database migrated before writer_sync_seconds: its newest revision gets it at the template's value, other keys
  # kept; down writes a revision without it; a revision that has it (a fresh database) is left alone
  def test_writer_sync_joins_the_runtime_settings_of_a_database_that_lacks_it
    migrate(RUNTIME)
    seeded = JSON.parse(@db[:runtime_settings].reverse(:id).get(:doc))
    assert_equal 30, seeded["writer_sync_seconds"], "a fresh database: the template seeds it"
    migrate
    assert_equal 1, @db[:runtime_settings].count, "nothing written over a revision that has it"
    migrate(RUNTIME)
    assert_equal 2, @db[:runtime_settings].count, "down: a revision without it"
    assert_equal seeded.except("writer_sync_seconds"), JSON.parse(@db[:runtime_settings].reverse(:id).get(:doc))
    old = seeded.except("writer_sync_seconds").merge("scan_interval_seconds" => 90)
    @db[:runtime_settings].insert(doc: JSON.generate(old), author: "op", created_at: 1)
    migrate
    row = @db[:runtime_settings].reverse(:id).first
    assert_equal "migration 20261219429000", row[:author]
    assert_equal old.merge("writer_sync_seconds" => 30), JSON.parse(row[:doc])
    assert_equal Busyyaks::RuntimeSettings::KEYS.keys, JSON.parse(row[:doc]).keys, "keys in order"
    migrate(RUNTIME)
    assert_equal old, JSON.parse(@db[:runtime_settings].reverse(:id).get(:doc)), "down: the key goes again"
  end

  # config/db/structure.sql (the schema dump, edited by hand since the services migrate with --no-dump
  # — a table pasted twice once went unnoticed): every table once, the same tables the migrations create, every
  # migration listed once
  def test_the_structure_dump_matches_the_migrations
    sql = File.read(File.expand_path("../../config/db/structure.sql", __dir__))
    tables = sql.scan(/^CREATE TABLE `([a-z_]+)`/).flatten
    assert_equal tables.uniq, tables, "a table created twice"
    files = Dir.children(DIR).grep(/\A\d+_.*\.rb\z/).sort
    listed = sql.scan(/\('(\d+_[a-z0-9_]+\.rb)'\)/).flatten
    assert_equal files, listed.sort, "schema_migrations rows = the migration files"
    db = Hanami.app["db.gateway"].connection
    assert_equal (db.tables.map(&:to_s) - ["schema_migrations"]).sort, (tables - ["schema_migrations"]).sort
  end
end
