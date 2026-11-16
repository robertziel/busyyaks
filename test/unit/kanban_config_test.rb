# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "busyyaks/kanban"

# config/kanban.yml and the vendored engine ship together: a value the engine refuses (e.g. max 0 where it wants "integer >= 1")
# kills the notifier, the launcher and the MCP spawn path, so pings and the watchdog stop. Caught here, before deploy.
class KanbanConfigTest < Minitest::Test
  def test_committed_config_loads_with_the_vendored_engine
    cfg = Busyyaks::Kanban.config # the file + the suite's agent settings revision (test/fixtures/agents.yml)
    assert_equal %w[lead worker team plain], cfg.agent_type_keys
    assert_equal %w[queued working review gate], cfg.agent_type("lead").takes
    assert_equal "lead", cfg.agent_type("worker").under
    assert cfg.agent_type("plain").standalone
    assert_equal 24, cfg.flags.reminder_hours
    assert_equal [3, "unresolved", "red", %w[local_agent_review public_agent_review]], cfg.review_loop.to_a
    # subagent roles' colours, a person's picture, and every agent type + role a colour of its own
    assert_equal({ "reviewer" => ["reviewer-*"], "qa" => ["qa-*"] }, cfg.face_roles)
    colours = (cfg.agent_type_keys + cfg.face_roles.keys).map { |t| cfg.theme.fetch("--ak-face-type-#{t}") }
    assert_equal colours.uniq, colours, "two agent types / roles share a face colour"
  end

  # the CSP's one image host for a person's picture: the origin of avatar_url, nil when it is null
  def test_avatar_origin_is_the_avatar_url_host_or_nil
    assert_equal "https://gravatar.com", Busyyaks::Kanban.avatar_origin
    file = Busyyaks::Kanban.file_config
    Busyyaks::Kanban.stub(:file_config, file.merge("avatar_url" => nil)) { assert_nil Busyyaks::Kanban.avatar_origin }
    Busyyaks::Kanban.stub(:file_config, file.merge("avatar_url" => "https://pics.test:8443/a/{sha256}")) do
      assert_equal "https://pics.test:8443", Busyyaks::Kanban.avatar_origin
    end
  end

  # the theme maps every --ak-* token the vendored engine's CSS declares, read from that CSS — a token left
  # out would show the engine's own colour instead of this deployment's skin, so the boot refuses it
  def test_the_theme_maps_every_engine_token_or_the_boot_is_refused
    k = Busyyaks::Kanban
    tokens = k.engine_tokens
    assert_includes tokens, "--ak-working"
    assert_includes tokens, "--ak-accent"
    %w[config/kanban.example.yml test/fixtures/kanban.yml].each do |f|
      theme = YAML.safe_load_file(File.join(__dir__, "../..", f))["theme"]
      # beyond them only the agent faces' per-type discs (an open family keyed by agent type, each with an
      # engine default outside .ak-root) — any other extra key is a typo or a token the engine no longer has
      rest = theme.keys.grep_v(/\A--ak-face-type-[a-z0-9_-]+\z/)
      assert_equal tokens, rest.sort, "#{f} maps exactly the engine's tokens"
    end
    k.check_file! # the suite's file passes
    full = k.file_config
    e = assert_raises(AgentsKanban::ConfigError) do
      k.check_theme!(full.merge("theme" => full["theme"].except("--ak-working", "--ak-step-overhang")))
    end
    assert_match(/theme maps no value for --ak-step-overhang, --ak-working — every --ak-\* token/, e.message)
    assert_match(/theme must map/, assert_raises(AgentsKanban::ConfigError) { k.check_theme!(full.except("theme")) }.message)
    # the list is the CSS's, not a copy: a token the engine adds is required at once
    css = ".ak-root {\n  --ak-new-one: red;\n  --ak-ink: #000;\n}\n"
    assert_equal %w[--ak-ink --ak-new-one], k.engine_tokens(css)
    assert_raises(AgentsKanban::ConfigError) { k.check_theme!(full, tokens: k.engine_tokens(css)) }
  end

  # every .ak-root rule counts, at any indent (the dark set sits in @media); a descendant rule's custom property is no
  # token; a CSS in which nothing is found is refused, never read as "no token required"
  def test_engine_tokens_read_every_ak_root_rule_and_refuse_finding_none
    k = Busyyaks::Kanban
    css = <<~CSS
      .ak-root {
        --ak-ink: #000;
      }
      .ak-root .kb-card {
        --ak-not-a-token: 1px;
        --kc: red;
      }
      @media (prefers-color-scheme: dark) {
        .ak-root {
          --ak-ink: #fff;
          --ak-dark-only: #111;
        }
      }
    CSS
    assert_equal %w[--ak-dark-only --ak-ink], k.engine_tokens(css)
    ["nothing here", ".ak-root .kb-card { --ak-x: 1px; }", ".ak-root {\n  color: red;\n}\n", ""].each do |bad|
      e = assert_raises(AgentsKanban::ConfigError) { k.engine_tokens(bad) }
      assert_match(/no --ak-\* token declared in a \.ak-root rule/, e.message)
    end
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
