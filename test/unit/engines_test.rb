# frozen_string_literal: true

require "test_helper"
require "busyyaks/engines"

# which engine runs which behaviour family is config; the families are code; no engine name in the code.
class EnginesTest < Minitest::Test
  E = Busyyaks::Engines

  COLLECTOR = %w[claudeapi localclaude hermes] # agent_engines' engine names (its engines.py `name`s)

  def test_the_committed_defaults_cover_claude_and_every_collector_engine
    t = E.load(nil)
    assert_equal %w[claude claudeapi localclaude hermes], t.names
    assert_equal %w[Claude Claude Local Hermes], t.names.map { |n| t.fetch(n).label }
    assert_equal %w[claude claude claude hermes], t.names.map { |n| t.fetch(n).family.name }
  end

  def test_the_deployment_adds_and_relabels
    t = E.load({ "claude" => { "label" => "Claude Code", "family" => "claude" },
                 "wrap" => { "label" => "W", "family" => "claude" }, })
    assert_equal ["Claude Code", "W"], [t.fetch("claude").label, t.fetch("wrap").label]
    assert_raises(E::Invalid) { E.load(nil, defaults_path: "/nope.yml") }
  end

  def test_families_carry_the_behaviour
    t = E.load({ "h" => { "label" => "Hermes", "family" => "hermes" } })
    assert t.fetch("claude").family.typeable?
    refute t.fetch("h").family.typeable?
    assert_same Busyyaks::AgentScreen::HERMES, t.fetch("h").family.rules
  end

  def test_unknown_engine_is_loud
    e = assert_raises(E::Unknown) { E.load(nil).fetch("codex") }
    assert_match(/engine "codex" is not configured .*known: claude, claudeapi/, e.message)
    refute E.load(nil).known?("codex")
  end

  # what bin/launcher puts on each pane and refuses to type into (its only engine logic)
  def test_launcher_pane_and_untypeable
    t = E.load(nil)
    assert_equal({ label: "Local", family: t.fetch("claude").family }, t.pane("localclaude"))
    assert_equal "Hermes", t.pane("hermes")[:label]
    assert_match(/"codex" is not configured/, t.pane("codex")[:error])
    assert_equal [], t.untypeable(%w[claudeapi localclaude claudeapi])
    assert_equal [["hermes", "family hermes"], ["codex", "not configured"]], t.untypeable(%w[claudeapi hermes codex])
    COLLECTOR.each { |n| assert t.known?(n), n }
  end

  def test_bad_entries_are_refused
    [{ "x" => { "label" => "", "family" => "claude" } }, { "x" => { "label" => "X", "family" => "claude", "y" => 1 } },
     { "bad name" => { "label" => "X", "family" => "claude" } }, { "x" => "claude" },].each do |v|
      assert_raises(E::Invalid, v.inspect) { E.load(v) }
    end
    assert_raises(E::Invalid) { E.load(["claude"]) }
  end

  def test_no_engine_name_literal_in_code
    root = File.expand_path("../..", __dir__)
    files = %w[bin/launcher lib/busyyaks/agents.rb lib/busyyaks/agent_screen.rb lib/busyyaks/engines.rb]
            .map { |f| File.join(root, f) }
    files.each { |f| refute_match(/claudeapi|localclaude/, File.read(f), f) }
  end
end
