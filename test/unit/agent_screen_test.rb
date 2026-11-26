# frozen_string_literal: true

require "test_helper"
require "busyyaks/agent_screen"
require "busyyaks/agent_activity"

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

  # background work still running under a finished turn is working, never idle
  def test_background_work_under_an_ended_turn_is_working
    bg = { state: "working", rule: "background_tasks_working" }
    assert_equal bg, detect(CLAUDE, screen("claude_background_monitor"))
    assert_equal bg, detect(CLAUDE, screen("claude_background_shells"))
    assert_equal bg, detect(CLAUDE, screen("claude_background_notice")) # a notice above the box, the box's ❯ + NBSP
    assert_equal "live_turn_working", detect(CLAUDE, screen("claude_background_tasks_turn"))[:rule]
    # a subagent row's "waiting on 1 shell" is not the session's footer
    rows = screen("claude_idle") + "\n  ● main\n  ◯ general-purpose  waiting on 1 shell · QA · since 7:36 PM\n"
    assert_equal "idle", detect(CLAUDE, rows)[:state]
    # a dialog in the place of the prompt box beats the footer
    assert_equal "blocked", detect(CLAUDE, "#{screen('claude_permission')}\n  ⏵⏵ bypass permissions on · 1 shell\n")[:state]
  end

  # the footer's counts: every one kept, a kind cut by "…" named whole, nothing else read as one
  def test_background_work_counts_in_the_footer
    rule = "─" * 20
    footer = ->(text) { "#{rule}\n❯ \n#{rule}\n  ⏵⏵ bypass permissions on #{text}\n" }
    {
      "· 1 monitor · ↓ to manage" => "1 monitor",
      "· 1 shell · 1 monitor · ↓ to manage" => "1 shell · 1 monitor",
      "· 1 shell, 1 monitor ·" => "1 shell · 1 monitor",
      "· 3 backgrou…" => "3 background tasks",
      "· 2 s…" => "2 shells",
      "· 1 mon…" => "1 monitor",
      "(shift+tab to cycle)" => nil,
      "(shift+tab to cycle) · PR #58" => nil,
      "· 1 sh" => nil, # cut with no "…" is not the footer's cut
      "· 2 shells running ·" => nil, # a kind word must end its part (·, ",", … or the line's end)
      "· 2 shellsx ·" => nil,
    }.each do |text, want|
      assert_equal want, Busyyaks::AgentScreen.background_work(footer.(text)), text
      assert_equal want ? "working" : "idle", detect(CLAUDE, footer.(text))[:state], text
    end
  end

  # no footer line: the subagent panel's rows come straight under the box — a row's "waiting on 1 shell ·" is that
  # subagent's (the count is not at the line's start nor after a "·"), so the session stays idle
  def test_a_subagent_row_right_under_the_box_is_no_footer
    rule = "─" * 20
    rows = "#{rule}\n❯ \n#{rule}\n  ◯ general-purpose  waiting on 1 shell · QA run · since Wednesday 7:36 PM\n"
    assert_equal "  ◯ general-purpose  waiting on 1 shell · QA run · since Wednesday 7:36 PM",
                 Busyyaks::AgentScreen.region("live_prompt_box_footer", rows, ""), "the row IS the line read as the footer"
    assert_nil Busyyaks::AgentScreen.background_work(rows)
    assert_equal "idle", detect(CLAUDE, rows)[:state]
  end

  # the screen rule and the activity's label read ONE definition: on every captured frame with no live turn and no
  # dialog, the rule fires exactly when there is a label, and the activity carries that label as its phase
  def test_the_rule_and_the_label_agree_on_every_frame
    frames = Dir[File.expand_path("../fixtures/screens/claude_*.txt", __dir__)]
    seen = frames.count do |f|
      text = File.read(f)
      verdict = detect(CLAUDE, text)
      next false if verdict[:state] == "blocked" || verdict[:rule] == "live_turn_working"

      label = Busyyaks::AgentScreen.background_work(text)
      assert_equal !label.nil?, verdict[:rule] == "background_tasks_working", File.basename(f)
      next false unless label

      assert_equal({ phase: "background", background: label },
                   Busyyaks::AgentActivity.claude(text).slice(:phase, :background), File.basename(f))
      true
    end
    assert_equal 3, seen, "the three claude_background_* frames with an ended turn"
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
    assert_equal "foot", s.region("live_prompt_box_footer", box, "")
    assert_equal "", s.region("live_prompt_box_footer", box.sub("❯ hi", "1. Yes"), ""), "no live prompt, no footer"
    assert_equal "", s.region("live_prompt_box_footer", "foot\n", "")
    assert_raises(ArgumentError) { s.region("nope", box, "") }
  end
end
