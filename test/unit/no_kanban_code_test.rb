# frozen_string_literal: true

require "test_helper"

# busyyaks keeps NO kanban logic of its own: the engine, the operator API handlers, the MCP tool definitions, the
# notifier / watchdog and the React board all come from the vendored agents_kanban (vendor/agents_kanban,
# frontend/src/vendor/agents_kanban) and everything that is busyyaks's own is a value in config/kanban.yml.
# This test fails when engine code grows back outside the vendored copies — the pattern list names what moved out
# when the board became one shared library for every host.
class NoKanbanCodeTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  # [glob of busyyaks's own code, patterns that only the engine may contain]
  RUBY_GLOBS = %w[
    lib/**/*.rb app/**/*.rb bin/* config/*.rb config/db/migrate/2026111[2-9]*.rb config/db/migrate/202612*.rb
  ].freeze
  # any one pattern matching a line is a hit, so an alternation split over two patterns forbids the same lines
  RUBY_FORBIDDEN = [
    /class (Kanban|KanbanTools|Attachments|AttachmentPolicy|Notifier|CardLinks)\b/,
    /module (SessionDialog|BacklogMd|CardLinks|Rev)\b/,
    /COLUMNS\s*=\s*\{/, /OPERATOR_ONLY\s*=/,
    /def (enqueue_ping|watch_owners|dialog_question|handoff|relay_undelivered)\b/,
    /def (agent_move!|register_session|launch_check!|expire_dialogs|sessions_sync)\b/,
    /max_sessions\s*[<>]=?/,
    /def self\.card_json/, /:card_pings\]|:session_dialogs\]|:checklist_items\]|:board_labels\]/, /db\[:cards\]/,
    /"kanban_handoff"|"kanban_ask"|name: "kanban_/, /"human_check"|"human_input"|"ready_merge"/,
  ].freeze
  # lib/busyyaks/kanban.rb is the one adapter allowed to name columns (the Backlog.md status map it hands the engine);
  # bin/daily-report is a prose prompt for the report model, not code
  RUBY_SKIP = %w[/vendor/ lib/busyyaks/kanban.rb bin/daily-report].freeze
  JS_GLOBS = %w[frontend/src/**/*.ts frontend/src/**/*.tsx frontend/src/**/*.css].freeze
  JS_FORBIDDEN = [
    /export function (Board|CardDialog|MarkdownEditor|CardItem|ChecklistView|LabelsPanel|OwnerPanel)\b/,
    /function (dropPosition|applyTool|dueState|splitCard|noListener|pingLine)\b/,
    /className=.kb-(card|col|list|dialog|question|handoff)/, /\.kb-(card|col|list|dialog|question|handoff|lchip|strip)\b/,
    /"human_check"|"human_input"/,
  ].freeze

  def files(globs, skip)
    globs.flat_map { |g| Dir.glob(File.join(ROOT, g)) }
         .reject { |f| Array(skip).any? { |s| f.include?(s) } || File.directory?(f) }
  end

  def offenders(globs, patterns, skip)
    files(globs, skip).flat_map do |f|
      File.read(f, encoding: "UTF-8").each_line.with_index(1).filter_map do |line, n|
        next if line.lstrip.start_with?("#", "//", "*", "/*") # a comment may name the old world

        hit = patterns.find { |re| line.match?(re) }
        hit && "#{f.delete_prefix("#{ROOT}/")}:#{n}: #{line.strip[0, 90]}"
      end
    end
  end

  def test_no_engine_code_outside_the_vendored_ruby_port
    hits = offenders(RUBY_GLOBS, RUBY_FORBIDDEN, RUBY_SKIP)
    assert_empty hits, "kanban logic outside vendor/agents_kanban:\n#{hits.join("\n")}"
  end

  def test_no_board_code_outside_the_vendored_react_port
    hits = offenders(JS_GLOBS, JS_FORBIDDEN, "/vendor/")
    assert_empty hits, "board code outside frontend/src/vendor/agents_kanban:\n#{hits.join("\n")}"
  end

  def test_the_board_config_is_the_coding_fixture_plus_busyyaks_values
    cfg = Busyyaks::Kanban.config.to_h
    fixture = JSON.parse(File.read(File.join(ROOT, "vendor/agents_kanban/fixtures/boards/coding.json")))
    # launchers, agent types, the cap and the dialog timings are busyyaks's own (its prompts, its caps), pinned below,
    # not the fixture's; the system author is the fixture's (both sign as busyyaks)
    own = %w[theme launchers agent_types concurrency session_dialogs]
    assert_equal fixture.except(*own), cfg.except(*own), "config/kanban.yml drifted from the engine's coding host config"
    assert_equal "busyyaks", cfg["system_author"], "the engine's own activity and pings are signed busyyaks"
    assert_equal({ "settle_seconds" => 30, "context_minutes" => 10 }, cfg["session_dialogs"],
                 "a dialog is asked once on screen 30 s and quotes the agent's last 10 min")
    assert_equal %w[fullclaude localclaude], cfg["launchers"].map { |l| l["key"] }, "the commands are the board config's"
    assert_equal %w[lead worker team plain], cfg["agent_types"].map { |t| t["key"] }, "the Launch bar's types"
    assert_equal [true, true, true, false], cfg["agent_types"].map { |t| !t["prompt"].nil? },
                 "Launch / Sub team = a prompt, Plain = none"
    assert_equal [%w[gate], [], [], []], cfg["agent_types"].map { |t| t["takes"] },
                 "a lead adopts only the cards waiting for the operator (the gates, by column type)"
    assert_equal [[], %w[queued working review gate], [], []], cfg["agent_types"].map { |t| t["spawns_for"] || [] },
                 "an ownerless card in any work column — or approved in a gate — gets its own worker session (lost " \
                 "cards never sit unowned)"
    assert_equal [1, 0, 0, 0], cfg["agent_types"].map { |t| t["max_per_project"] },
                 "one lead per board; nothing else capped"
    assert_equal [0, 0, 0, 0], cfg["agent_types"].map { |t| t["max"] }
    assert_equal 0, cfg["concurrency"]["max_sessions"], "0 = no cap"
    assert_equal ["localclaude"], cfg["launchers"].select { |l| l["via_shell"] }.map { |l| l["key"] }
    gw = { "fullclaude" => "opus", "localclaude" => nil }
    assert_equal [nil, gw, gw, nil], cfg["agent_types"].map { |t| t["model"] }, "the model each type starts with"
    # Claude takes the last --model, so on localclaude a type's --model would replace the gateway's model with an
    # API one — no type may pass one under a via_shell (gateway) launcher
    kc = Busyyaks::Kanban.config
    shell = cfg["launchers"].select { |l| l["via_shell"] }.map { |l| l["key"] }
    kc.agent_types.each do |t|
      (t.launchers & shell).each { |k| assert_nil t.model_for(k), "#{t.key} on #{k}: --model would override its gateway model" }
    end
    # a worker / sub team runs the launcher of the board's running lead (localclaude lead → localclaude
    # sessions)
    assert_equal [nil, "lead", "lead", nil], cfg["agent_types"].map { |t| t["launcher_follows"] }
    assert_equal [%w[fullclaude localclaude]] * 4, cfg["agent_types"].map { |t| t["launchers"] }
    # no lead to follow → the configured spawn_launcher (no code default); lead, team and plain name theirs at the start
    assert_equal [nil, "fullclaude", nil, nil], cfg["agent_types"].map { |t| t["spawn_launcher"] }
    assert_equal "", cfg["table_prefix"], "busyyaks's tables keep their names"
    refute_empty cfg["theme"]
  end

  # config/kanban.example.yml is what a stranger copies (README Quickstart): it loads on the vendored engine and carries
  # nothing of one operator's box or workflow — one plain `claude` launcher in Claude Code's default permission mode,
  # no model names, prompts that name no column (an agent reads a card's transitions from kanban_card).
  def test_the_example_config_loads_and_is_generic
    path = File.join(ROOT, "config/kanban.example.yml")
    ex = AgentsKanban::HostConfig.load(path)
    assert_equal [["claude", "claude", [], false]], ex.launchers.map { |l| [l.key, l.command, l.args, l.via_shell] }
    assert_equal %w[lead worker team plain], ex.agent_type_keys
    assert(ex.agent_types.all? { |t| t.launchers == ["claude"] && t.model.nil? }, "one launcher, no model names")
    assert_equal %w[claude] * 4, ex.agent_types.map { |t| t.launcher!(nil) }, "one launcher = unambiguous"
    # a repo without CI must work: no CI URL demanded at handoff, no green-checks gate on approval (both commented options)
    assert_equal [false, nil], [ex.handoff.requires_ci_url, ex.approval]
    assert_nil ex.review_loop, "no review-loop columns of one operator's board (a commented option)"
    uncommented = File.readlines(path).reject { |l| l.lstrip.start_with?("#") }.join
    forbidden = /bypassPermissions|localclaude|fullclaude|\bopus\b|\bsonnet\b|Local:|local board|Deployed locally|
                 jenkins|qa-cookie|https?:\/\/|Ready to merge|Human Check|In progress|local_(?:agent|author|human|merged)|
                 Awaiting merge|Human input/xi
    assert_nil uncommented[forbidden], "operator-specific text in the example: #{uncommented[forbidden].inspect}"
    ex.agent_types.filter_map(&:prompt).each { |pr| refute_match(/\bTo do\b|Review PR|Merged/, pr) }
    assert_match(/transitions/, ex.agent_type("worker").prompt, "the worker reads where a card may go from kanban_card")
  end

  # The pin is git's content id of each vendored path (tree / blob ids: identical in the public engine repo and its
  # private local repo, whose commit shas differ), one table rendered into both VENDOR.md files by
  # scripts/vendor-kanban-engine.sh.
  def test_the_vendored_copies_carry_one_pin_table
    paths = %w[ruby fixtures react/src SPEC.md config.example.yml LICENSE]
    pins = %w[vendor/agents_kanban/VENDOR.md frontend/src/vendor/VENDOR.md].map do |f|
      File.read(File.join(ROOT, f)).scan(/^\| `([^`]+)` \| `(\h{40})` \|$/).to_h
    end
    assert_equal paths, pins.first.keys, "pin rows of vendor/agents_kanban/VENDOR.md"
    assert_equal pins.first, pins.last, "the ruby and react halves carry different pins"
  end

  def test_the_vendored_copies_name_the_public_engine_repo
    %w[vendor/agents_kanban/VENDOR.md frontend/src/vendor/VENDOR.md scripts/vendor-kanban-engine.sh].each do |f|
      text = File.read(File.join(ROOT, f))
      assert_includes text, "robertziel/busyyaks_agents_kanban_module", f
      refute_includes text, "busyyaks_kanban_engine", "#{f} names the old engine repo"
    end
  end
end
