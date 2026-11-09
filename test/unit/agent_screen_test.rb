# frozen_string_literal: true

require "test_helper"
require "busyyaks/agent_screen"

# herdr's screen rules, ported: what an agent pane draws → blocked / working / idle, the matching rule named.
class AgentScreenTest < Minitest::Test
  def screen(name) = File.read(File.expand_path("../fixtures/screens/#{name}.txt", __dir__))
  CLAUDE = Busyyaks::AgentScreen::CLAUDE
  HERMES = Busyyaks::AgentScreen::HERMES
  def detect(*args) = Busyyaks::AgentScreen.detect(*args)

  def test_claude_screens
    assert_equal({ state: "idle", rule: "live_prompt_box" }, detect(CLAUDE, screen("claude_idle")))
    assert_equal({ state: "working", rule: "live_turn_working" }, detect(CLAUDE, screen("claude_working")))
    assert_equal({ state: "blocked", rule: "bash_permission_prompt" }, detect(CLAUDE, screen("claude_permission")))
    assert_equal({ state: "blocked", rule: "live_blocked_form" }, detect(CLAUDE, screen("claude_question")))
  end

  def test_dialog_words_in_the_transcript_above_the_prompt_box_do_not_block
    assert_equal "idle", detect(CLAUDE, screen("claude_transcript_mentions_dialog"))[:state]
  end

  def test_the_older_boxed_permission_prompt_blocks
    boxed = File.read(File.expand_path("../../vendor/agents_kanban/fixtures/screens/boxed_permission.txt", __dir__))
    assert_equal "blocked", detect(CLAUDE, boxed)[:state]
  end

  def test_osc_title_rules_and_priority
    assert_equal({ state: "working", rule: "osc_title_working" }, detect(CLAUDE, "", "⠋ Fix the build"))
    assert_equal({ state: "idle", rule: "osc_title_idle" }, detect(CLAUDE, "", "✳ Fix the build"))
    # a dialog on screen (980) beats the idle title (250)
    assert_equal "blocked", detect(CLAUDE, screen("claude_question"), "✳ Fix the build")[:state]
    assert_equal({ state: "blocked", rule: "osc_title_blocked" }, detect(HERMES, "", "⚠ approve rm"))
    assert_equal({ state: "working", rule: "osc_title_working" }, detect(HERMES, "", "⏳ thinking"))
  end

  def test_no_rule_is_unknown_never_idle
    assert_equal({ state: "unknown", rule: nil }, detect(CLAUDE, "just some shell output\n$ "))
    assert_equal({ state: "unknown", rule: nil }, detect(HERMES, screen("claude_idle")))
  end

  def test_regions
    s = Busyyaks::AgentScreen
    lines = "a\n\nb\nc\n"
    assert_equal "b\nc", s.region("bottom_non_empty_lines(2)", lines, "")
    box = "x\n#{'─' * 5}\n❯ hi\n#{'─' * 5}\nfoot\n"
    assert_equal "❯ hi", s.region("prompt_box_body", box, "")
    assert_equal "x", s.region("last_non_empty_above_prompt_box", box, "")
    assert_equal "foot", s.region("after_last_horizontal_rule", box, "")
    assert_raises(ArgumentError) { s.region("nope", box, "") }
  end
end
