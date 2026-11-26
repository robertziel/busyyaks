# frozen_string_literal: true

require "test_helper"
require "busyyaks/agent_activity"
require "busyyaks/engines"

# What a working Claude Code pane does now, read from its status line + the tool block above it. The
# claude_* screens are frames captured from a real Claude Code pane (transcript text and paths replaced): a phase is
# named only from what the screen shows, never assumed from what it does not.
class AgentActivityTest < Minitest::Test
  A = Busyyaks::AgentActivity
  BOX = <<~TXT
    ────────────────────────────────────────
    ❯
    ────────────────────────────────────────
      ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt
  TXT
  NONE = { phase: nil, elapsed_s: nil, tokens: nil, tool: nil, card: nil, background: nil }.freeze
  SUBAGENTS = NONE.merge(phase: "subagents").freeze

  def screen(name) = File.read(File.expand_path("../fixtures/screens/#{name}.txt", __dir__))
  def read(body) = A.claude("#{body}\n\n#{BOX}")

  def test_thinking_as_claude_code_draws_it
    assert_equal NONE.merge(phase: "thinking", elapsed_s: 18, tokens: "↓ 1.2k", background: "1 shell"),
                 A.claude(screen("claude_thinking")) # the frame's footer: "· 1 shell ·"
    assert_equal NONE.merge(phase: "thinking", elapsed_s: 28, tokens: "↓ 1.2k", background: "1 shell"),
                 A.claude(screen("claude_still_thinking"))
  end

  def test_a_running_shell_call_by_its_live_timer
    assert_equal NONE.merge(phase: "tool", elapsed_s: 178, tokens: "↓ 15.1k", background: "1 shell"),
                 A.claude(screen("claude_shell_running"))
    # each live marker alone is enough: the header's timer, the echo's timer, the background hint
    assert_equal "tool", read("● Running 1 shell command · 4s…\n\n✶ Brewing… (9s · ↓ 1k tokens)")[:phase]
    assert_equal "tool", read("● Ran.\n  ⎿  $ make test (12s)\n\n✶ Brewing… (9s · ↓ 1k tokens)")[:phase]
    assert_equal "tool",
                 read("● Ran.\n     (ctrl+b ctrl+b (twice) to run in background)\n\n✶ Brewing… (9s · ↓ 1k tokens)")[:phase]
  end

  def test_an_ended_call_still_drawn_is_no_running_tool
    assert_equal NONE.merge(elapsed_s: 64, tokens: "↓ 5.2k", background: "1 shell"), A.claude(screen("claude_shell_ended"))
    assert_equal NONE.merge(elapsed_s: 30, tokens: "↓ 2.5k", background: "1 shell"),
                 A.claude(screen("claude_shell_ended_cut"))
    assert_nil A.claude(screen("claude_working"))[:phase]
    # a live marker above a newer "●" line belongs to a call that ended
    assert_nil read("● Running 1 shell command · 4s…\n\n● Here is what I found.\n\n✳ Brewing… (40s · ↓ 2k tokens)")[:phase]
  end

  def test_a_named_call_and_the_card_a_comment_tool_writes_on
    a = read("● Done reading.\n\n● Bash(docker compose ps)\n  ⎿  Running…\n\n" \
             "✢ Combobulating… (1m 5s · ↓ 1.6k tokens · thought for 2s)")
    assert_equal NONE.merge(phase: "tool", elapsed_s: 65, tokens: "↓ 1.6k", tool: "Bash"), a
    a = read("● busyyaks - kanban_comment (MCP)(id: 459, body: \"[Author Agent] · …\")\n  ⎿  Running…\n\n· Writing… (3s)")
    assert_equal NONE.merge(phase: "tool", elapsed_s: 3, tool: "busyyaks · kanban_comment", card: 459), a
    # every kanban tool names the card its `id:` acts on (a lead reading a card is on it); other ids are not cards
    other = read("● busyyaks - kanban_card (MCP)(id: 12)\n  ⎿  Running…\n\n· Reading… (3s)")
    assert_equal ["busyyaks · kanban_card", 12], other.values_at(:tool, :card)
    edit = read("● busyyaks - kanban_comment_edit (MCP)(comment_id: 77, body: \"x\")\n  ⎿  Running…\n\n· Editing… (3s)")
    assert_nil edit[:card]
    assert_nil read("● Bash(echo id: 5)\n  ⎿  Running…\n\n· Running… (3s)")[:card], "only kanban tools name a card"
    assert_nil read("● Bash(ls)\n  ⎿  Running…\n\n✻ Pondering… (12s · ↑ 340 tokens · thinking)")[:tool] # thinks, no call
  end

  def test_a_turn_that_only_waits_for_its_subagents
    assert_equal SUBAGENTS, read("● Started the QA agent.\n\n✻ Waiting for 1 background agent to finish")
    panel = "● Started.\n\n#{BOX}  ● main\n  ◯ general-purpose  Screen sample: sleep 90s              7s · ↓ 71.7k tokens\n"
    assert_equal SUBAGENTS, A.claude(panel)
    assert_nil A.claude("● Done.\n\n#{BOX}  ● main\n") # the panel's own row is no subagent
  end

  # the turn ended while work it started in the background runs — the footer under the live prompt box counts
  # it (frames captured from real panes); a subagent row's own "waiting on 1 shell" is never the session's
  def test_a_turn_that_ended_waiting_on_its_background_work
    assert_equal NONE.merge(phase: "background", background: "1 monitor"), A.claude(screen("claude_background_monitor"))
    assert_equal NONE.merge(phase: "background", background: "3 shells"), A.claude(screen("claude_background_shells"))
    # a live turn keeps its own phase and says the background work beside it
    turn = A.claude(screen("claude_background_tasks_turn"))
    assert_equal [nil, 72, "3 background tasks"], turn.values_at(:phase, :elapsed_s, :background)
    footer = BOX.sub("· esc to interrupt", "· 2 shells · ↓ to manage")
    assert_equal SUBAGENTS.merge(background: "2 shells"),
                 A.claude("● Started.\n\n✻ Waiting for 1 background agent to finish\n\n#{footer}")
    # no count in the footer, a count only in a subagent row, or a footer under no live prompt → none
    assert_nil A.claude(screen("claude_idle"))
    rows = "#{BOX.sub(' · esc to interrupt', '')}\n  ● main\n  ◯ general-purpose  waiting on 1 shell · QA · since 7:36 PM\n"
    assert_nil A.claude("● Done.\n\n#{rows}")
    assert_nil A.claude("● Done.\n\n  ⏵⏵ bypass permissions on · 1 monitor · ↓ to manage\n")
  end

  # a wait that never ends must show its age — from the turn-end line's "done H:MM", the reading's
  # clock given; no clock, no line, or a weekday written → unknown, never guessed
  def test_a_background_wait_shows_how_long_it_has_lasted
    at = ->(h, m) { Time.new(2026, 11, 26, h, m, 37, "+01:00") }
    assert_equal 397, A.claude(screen("claude_background_monitor"), at.(13, 31))[:elapsed_s] # done 1:25 PM
    assert_equal 1837, A.claude(screen("claude_background_shells"), at.(14, 2))[:elapsed_s] # done 1:32 PM, rows below
    assert_nil A.claude(screen("claude_background_monitor"))[:elapsed_s], "no clock given"
    turn = ->(line) { "● Waiting.\n\n#{line}\n\n#{BOX.sub('· esc to interrupt', '· 1 monitor · ↓ to manage')}" }
    # the most recent such moment: before midnight, read after it
    assert_equal 1237, A.claude(turn.("✻ Brewed for 2s · done 11:50 PM · 1 monitor still running"),
                                Time.new(2026, 11, 27, 0, 10, 37, "+01:00"))[:elapsed_s]
    assert_equal 37, A.claude(turn.("✻ Brewed for 2s · done 12:10 AM"), Time.new(2026, 11, 27, 0, 10, 37, "+01:00"))[:elapsed_s]
    assert_equal 0, A.claude(turn.("✻ Brewed for 2s · done 12:00 PM"), Time.new(2026, 11, 27, 12, 0, 0, "+01:00"))[:elapsed_s]
    assert_equal 60, A.claude(turn.("✻ Brewed for 2s · done 13:25"), Time.new(2026, 11, 27, 13, 26, 0, "+01:00"))[:elapsed_s]
    [
      "✻ Brewed for 2s · done Wednesday 7:36 PM", # not today: no weekday arithmetic
      "✻ Brewed for 2s · done 13:61",
      "✻ Brewed for 2s · done 13:25 PM",
      "● Done, back at 1:25 PM.", # a transcript line, not the turn-end line
    ].each do |line|
      a = A.claude(turn.(line), at.(13, 31))
      assert_equal ["background", nil], a.values_at(:phase, :elapsed_s), line
    end
    # a right-aligned notice under the turn-end line (captured from a real pane) is stepped over, nothing else
    assert_equal({ phase: "background", background: "2 shells", elapsed_s: 4124 },
                 A.claude(screen("claude_background_notice"), Time.new(2026, 11, 26, 14, 24, 44, "+01:00"))
                  .slice(:phase, :background, :elapsed_s)) # done 1:16 PM, read 14:24:44
    notice = "#{' ' * 40}✔ Update installed · Restart to update"
    assert_equal 397, A.claude(turn.("✻ Brewed for 2s · done 1:25 PM\n#{notice}\n#{notice}"), at.(13, 31))[:elapsed_s]
    assert_nil A.claude(turn.("✻ Brewed for 2s · done 1:25 PM\n● A later line of the transcript."), at.(13, 31))[:elapsed_s]
    # a live turn's elapsed is its status line's, never the done line's
    assert_equal 72, A.claude(screen("claude_background_tasks_turn"), at.(13, 31))[:elapsed_s]
  end

  def test_mcp_tasks_still_running_read_as_a_tool
    assert_equal NONE.merge(phase: "tool", elapsed_s: 9), read("● Here.\n\n✻ Brewing… (9s · 2 MCP tasks still running)")
  end

  def test_no_status_line_is_nil
    assert_nil read("● All done.")
    assert_nil A.claude("")
  end

  # writing = the ↓ count rose between two reads of the pane (bin/launcher keeps the memo per pane)
  def test_settle_names_writing_only_from_a_rising_count
    at = ->(tokens, phase = nil) { NONE.merge(phase: phase, tokens: tokens) }
    a, memo = A.settle(at.("↓ 5.2k"), nil, 100.0)
    assert_nil a[:phase] # a first read: nothing to compare with
    a, memo = A.settle(at.("↓ 5.4k"), memo, 103.0)
    assert_equal "writing", a[:phase]
    a, memo = A.settle(at.("↓ 5.4k"), memo, 106.0)
    assert_equal "writing", a[:phase] # within WRITING_S of the rise (the count steps by 0.1k)
    a, memo = A.settle(at.("↓ 5.4k"), memo, 109.0)
    assert_nil a[:phase] # no rise for longer than WRITING_S
    a, = A.settle(at.("↓ 9.9k"), memo, 109.0 + A::STREAM_WINDOW_S + 1)
    assert_nil a[:phase] # a base older than STREAM_WINDOW_S proves nothing
    a, = A.settle(at.("↓ 9.9k", "thinking"), { tokens: 1, at: 0.0, rose_at: 0.0 }, 1.0)
    assert_equal "thinking", a[:phase] # a phase the screen names is kept
    assert_equal [nil, nil], A.settle(nil, { tokens: 1, at: 0.0, rose_at: nil }, 1.0)
    assert_equal [1000, 12_900, 997, nil], ["↓ 1k", "↓ 12.9k", "↓ 997", "↑ 340"].map { |t| A.token_count(t) }
  end

  def test_only_the_claude_family_reads_it
    t = Busyyaks::Engines.load({ "h" => { "label" => "Hermes", "family" => "hermes" } })
    assert_nil t.fetch("h").family.activity("✻ Pondering… (12s · thinking)")
    assert_equal "thinking", t.fetch("claude").family.activity("✻ Pondering… (12s · thinking)")[:phase]
  end
end
