# frozen_string_literal: true

require "digest"

module Busyyaks
  # Claude Code's folder-trust prompt as a session dialog the operator answers from the page. bin/launcher
  # answers it itself only for a trusted repo (LaunchTrust); any other repo keeps it on screen for the operator — but
  # its choices are drawn WITHOUT numbers (`❯ No, exit` / `  Yes, I trust this folder`, the cursor on one), so the
  # engine's SessionDialog (numbered options, a digit pressed) reads no dialog there and the page had nothing to press.
  # Here: the prompt read off the screen, its choices keyed 1..n in screen order, and the cursor row, so the launcher's
  # `answer` op moves the cursor onto the chosen label (checked on screen) and presses Enter. Pure Ruby, no dependency:
  # loaded by bin/launcher and bin/collector alone.
  #
  # → nil, or {question, command (the workspace path), options: [{key, label, free: false}], escape: false,
  #   free_text: false, hash, cursor (the key under the cursor)} — the SessionDialog shape, so the same page, card and
  #   answer route take it. The hash leaves the cursor out (moving it is part of answering).
  module TrustDialog
    YES = "Yes, I trust this folder"
    NO = "No, exit"
    CHOICE = /\A\s*(❯)?\s*(?:\d{1,2}\.\s+)?(#{Regexp.escape(YES)}|#{Regexp.escape(NO)})\s*\z/
    FOOT = /Enter to confirm/i
    QUESTION = "Trust this folder? Claude Code then runs the repo's own settings, hooks and MCP servers"

    module_function

    def prompt?(text) = text.to_s.include?(YES) && text.to_s.match?(/trust this folder|Do you trust/i)

    def parse(screen)
      return nil unless prompt?(screen)

      lines = screen.to_s.lines.map(&:rstrip)
      # the prompt as Claude Code draws it ends in its footer: two lines an agent printed are no dialog
      foot = lines.rindex { |l| l.match?(FOOT) } or return nil
      # ... right under its two choices (the last two lines above it): each once, one under the cursor
      rows = lines[0...foot].reject { |l| l.strip.empty? }.last(2).map { |l| l.match(CHOICE) }
      return nil unless rows.all?

      rows = rows.map { |m| { label: m[2], cursor: !m[1].nil? } }
      return nil unless rows.map { |r| r[:label] }.sort == [NO, YES] && rows.count { |r| r[:cursor] } == 1

      options = rows.each_with_index.map { |r, i| { key: (i + 1).to_s, label: r[:label], free: false } }
      path = workspace(lines)
      norm = ["trust", path, *options.map { |o| "#{o[:key]}. #{o[:label]}" }].compact
      { question: QUESTION, command: path, options: options, escape: false, free_text: false,
        hash: Digest::SHA256.hexdigest(norm.join("\n")), cursor: options[rows.index { |r| r[:cursor] }][:key], }
    end

    # the path under "Accessing workspace:" (Claude Code's current prompt), nil when the screen does not show one
    def workspace(lines)
      at = lines.index { |l| l.match?(/Accessing workspace:/i) } or return nil
      lines[(at + 1)..(at + 3)].to_a.map(&:strip).find { |l| l.start_with?("/") }
    end

    # Why answering `key` on this screen is refused (nil = answer it): the dialog must still be the one the operator
    # saw (its hash) and `key` one of its choices.
    def refuse_answer(screen, hash:, key:)
      d = parse(screen)
      return "no trust prompt on its screen any more" unless d
      return "the trust prompt on its screen changed" unless d[:hash] == hash.to_s
      return "#{key} is not a choice of the trust prompt (#{d[:options].map { |o| o[:key] }.join(', ')})" \
        unless d[:options].any? { |o| o[:key] == key.to_s }

      nil
    end

    # The key to press to move the cursor one step toward `key` ("Up" / "Down"), or nil when it is on it.
    def step(d, key)
      at = d[:options].index { |o| o[:key] == d[:cursor] }
      to = d[:options].index { |o| o[:key] == key.to_s }
      return nil if at == to

      to > at ? "Down" : "Up"
    end
  end
end
