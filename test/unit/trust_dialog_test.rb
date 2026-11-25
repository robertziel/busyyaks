# frozen_string_literal: true

require "test_helper"
require "busyyaks/trust_dialog"
require "busyyaks/agent_screen"
require_relative "../../vendor/agents_kanban/ruby/lib/agents_kanban/session_dialog"

# Claude Code's folder-trust prompt: a real capture (test/fixtures/screens/claude_trust.txt, the path
# replaced) — unnumbered choices, the cursor on "No, exit" — read as a dialog the page answers.
class TrustDialogTest < Minitest::Test
  def screen(name = "claude_trust") = File.read(File.expand_path("../fixtures/screens/#{name}.txt", __dir__))
  def parse(text) = Busyyaks::TrustDialog.parse(text)

  # the cause: the engine's parser reads no dialog on it, while the screen rules call the pane blocked
  def test_the_engine_parser_reads_no_dialog_on_the_real_prompt
    assert_nil AgentsKanban::SessionDialog.parse(screen)
    assert_equal "blocked", Busyyaks::AgentScreen.detect(Busyyaks::AgentScreen::CLAUDE, screen)[:state]
  end

  def test_the_real_prompt_is_a_dialog_with_both_choices_in_screen_order
    d = parse(screen)
    assert_equal [{ key: "1", label: "No, exit", free: false }, { key: "2", label: "Yes, I trust this folder", free: false }],
                 d[:options]
    assert_equal "/home/you/projects/app", d[:command]
    assert_equal "1", d[:cursor]
    refute d[:escape]
    refute d[:free_text]
    assert_match(/\ATrust this folder\?/, d[:question])
    assert_equal %w[1 2], AgentsKanban::SessionDialog.keys(d), "the card and page offer both choices, no Esc"
  end

  def moved(text) = text.sub("❯ No, exit", "  No, exit").sub("   Yes, I trust", " ❯ Yes, I trust")

  # moving the cursor is part of answering: the dialog keeps its hash
  def test_the_cursor_moves_and_the_hash_stays
    a = parse(screen)
    b = parse(moved(screen))
    assert_equal "2", b[:cursor]
    assert_equal a[:hash], b[:hash]
    assert_equal "Down", Busyyaks::TrustDialog.step(a, "2")
    assert_equal "Up", Busyyaks::TrustDialog.step(b, "1")
    assert_nil Busyyaks::TrustDialog.step(b, "2")
  end

  def test_another_folder_is_another_dialog
    refute_equal parse(screen)[:hash], parse(screen.sub("/home/you/projects/app", "/home/you/projects/other"))[:hash]
  end

  # the numbered form some Claude Code versions draw (bin/launcher's accept_trust takes both)
  def test_the_numbered_form
    d = parse("Do you trust the files in this folder?\n❯ 1. Yes, I trust this folder\n  2. No, exit\n\nEnter to confirm\n")
    assert_equal ["Yes, I trust this folder", "No, exit"], d[:options].map { |o| o[:label] }
    assert_equal "1", d[:cursor]
    assert_nil d[:command]
  end

  def test_anything_else_is_no_trust_dialog
    assert_nil parse(screen("claude_question"))
    assert_nil parse(screen("claude_idle"))
    assert_nil parse(screen.sub("❯ No, exit", "  No, exit")), "no cursor"
    assert_nil parse(screen.sub("   Yes, I trust this folder\n", "")), "one choice"
    assert_nil parse("we talked about Yes, I trust this folder and No, exit\n"), "quoted in a transcript"
    # the two choice lines an agent printed, with no footer under them (review round 1)
    assert_nil parse("Do you trust this folder?\n❯ No, exit\n  Yes, I trust this folder\n> "), "no footer"
    assert_nil parse(screen.sub("Enter to confirm · Esc to cancel", "")), "the real prompt without its footer"
    assert_nil parse("❯ No, exit\n  Yes, I trust this folder\nsomething else\nEnter to confirm\n"), "not right above the footer"
  end

  def test_refuse_answer
    d = parse(screen)
    assert_nil Busyyaks::TrustDialog.refuse_answer(screen, hash: d[:hash], key: "2")
    assert_match(/changed/, Busyyaks::TrustDialog.refuse_answer(screen, hash: "x", key: "2"))
    assert_match(/not a choice/, Busyyaks::TrustDialog.refuse_answer(screen, hash: d[:hash], key: "3"))
    assert_match(/not a choice/, Busyyaks::TrustDialog.refuse_answer(screen, hash: d[:hash], key: "esc"))
    assert_match(/no trust prompt/, Busyyaks::TrustDialog.refuse_answer("> ", hash: d[:hash], key: "2"))
  end
end
