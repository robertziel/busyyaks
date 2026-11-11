# frozen_string_literal: true

require "test_helper"
require "busyyaks/kanban"

# config/kanban.yml and the vendored engine ship together: a value the engine refuses (e.g. max 0 where it wants "integer >= 1")
# kills the notifier, the launcher and the MCP spawn path, so pings and the watchdog stop. Caught here, before deploy.
class KanbanConfigTest < Minitest::Test
  def test_committed_config_loads_with_the_vendored_engine
    cfg = Busyyaks::Kanban.config # the file + the suite's agent settings revision (test/fixtures/agents.yml)
    assert_equal %w[lead worker team plain], cfg.agent_type_keys
    assert_equal %w[gate], cfg.agent_type("lead").takes
    assert_equal %w[queued working review gate], cfg.agent_type("worker").spawns_for
    assert_equal 24, cfg.flags.reminder_hours
    assert_equal [3, "unresolved", "red", %w[local_agent_review public_agent_review]], cfg.review_loop.to_a
  end
end

# the boards live in the DATABASE — the template row (migration 20261116000000, seeded from the
# engine's coding board fixture) and one board per project, instantiated from it on first use and edited on the board.
# config/kanban.yml holds no column, gate or workflow any more.
class KanbanBoardsInTheDatabaseTest < Minitest::Test
  include DBReset

  def coding_board = JSON.parse(File.read(File.join(__dir__, "../../vendor/agents_kanban/fixtures/boards/coding.board.json")))

  def test_the_template_row_is_the_coding_board_and_config_has_no_board_keys
    st = Busyyaks::Kanban.store
    assert_equal coding_board, st.board_template.to_h
    raw = YAML.safe_load_file(Busyyaks::Kanban::CONFIG_PATH)
    assert_empty raw.keys & %w[columns default_column waiting listened operator_only agent_no_create gates workflow],
                 "columns, gates and workflows are rows, not YAML"
    conn = Hanami.app["db.gateway"].connection
    assert_equal %w[boards board_columns board_transitions],
                 %w[boards board_columns board_transitions].select { |t| conn.table_exists?(t.to_sym) }
    refute conn.table_exists?(:workflows), "the first version's table was carried over and dropped"
  end

  def test_a_project_gets_the_templates_copy_and_the_template_keeps_the_board_free_and_names_the_lifecycle
    store.upsert_project(slug: "free", path: "/nonexistent/free", remote: nil, branch: "main", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    st = Busyyaks::Kanban.store
    b = st.board_of("free")
    assert_equal %w[backlog todo doing qa human_check ready merged], b.keys
    assert_equal %w[parked queued working review gate gate done], b.keys.map { |k| b.type_of(k).key }
    # the rules the types derive (workflow v3: Human input is a flag, Human Check / Ready to merge are gates)
    assert_equal [%w[human_check ready], %w[todo doing qa human_check ready], %w[human_check ready merged]],
                 [b.waiting, b.listened, b.operator_only]
    assert_equal [[%w[human_check ready merged Approve] + [true]], %w[doing todo], "doing"],
                 [b.approvals.map { |a| [a.from, a.to, a.then, a.name, a.final] }, [b.watchdog.from, b.watchdog.to],
                  b.idle_column,]
    assert_equal "busyyaks", st.board_json("free")[:updated_by] # the engine's copy of the template
    id = st.create(slug: "free", title: "a", by: "op")
    assert_equal "merged", st.move(id, column: "merged", by: "op")[:column]
    id = st.create(slug: "free", title: "b", by: "op", column: "todo")
    assert_equal "doing", st.move(id, transition: "Start work", by: "op")[:column]
    names = st.card_json(st.card(id))[:transitions].map { |t| t[:name] }
    assert_includes names, "Send for QA"
    assert_includes names, "Move"
  end
end
