# frozen_string_literal: true

module Busyyaks
  # An agent pane's state read from what it draws: blocked (a dialog / question waits for a person) · working · idle.
  # A port of herdr's screen detection (https://github.com/herdrdev/herdr, Apache-2.0, commit ee5bfb5): its rule
  # engine (src/detect/manifest.rs — regions, contains / regex / line_regex / all / any / not gates, highest priority
  # wins) and its Claude Code + Hermes manifests (distribution/agent-detection/{claude,hermes}.toml, rules kept with
  # their ids, priorities and patterns; Rust regex syntax translated to Ruby).
  # One difference: herdr calls a known agent with no matching rule `idle`; here it is `unknown` (no rule = nobody
  # can tell — never a guessed state).
  # Which engine name is read by which manifest is config (Busyyaks::Engines), not this file.
  # Pure Ruby, no dependencies: bin/launcher (host) requires this file alone.
  module AgentScreen
    STATES = %w[blocked working idle unknown].freeze

    Rule = Struct.new(:id, :state, :priority, :region, :gate, keyword_init: true)

    def self.r(id, state, priority, region, **gate)
      Rule.new(id: id, state: state, priority: priority, region: region, gate: gate)
    end

    SPIN = "[*·✢✳✶✻✽]"
    SPIN_NO_2733 = "[*·✢✶✻✽]"
    NAV = [{ contains: ["tab/arrow keys to navigate"] }, { contains: ["arrow keys to navigate"] },
           { contains: ["arrows to navigate"] }, { contains: ["↑/↓ to navigate"] }, { contains: ["↑↓ to navigate"] },].freeze
    YES_NO = [/\A\s*❯?\s*yes\b/i, /\A\s*❯?\s*1\.\s*yes\b/i, /\A\s*❯?\s*2\.\s*yes\b/i,
              /\A\s*❯?\s*2\.\s*no\b/i, /\A\s*❯?\s*3\.\s*no\b/i,].freeze
    # Pieces of the two longest screen regexes below, written so that each regex's source is exactly what it was.
    GAP = '(?:[ \t]+|\n[ \t]*)' # a run of blanks, or a line break and the next line's indent
    MCP_RUNNING = "[1-9]\\d*#{GAP}MCP#{GAP}tasks?#{GAP}still#{GAP}running".freeze
    FORM_KEYS = '[ \t]*enter\s+to\s+' \
                '(?:confirm|select\s+·\s+(?:(?:tab/arrow|arrow)\s+keys|arrows|↑/↓|↑↓)\s+to\s+navigate)' \
                '\s+·\s+esc\s+to\s+cancel[ \t]*\n'
    TASK_LIST = '(?:\n(?:[ \t]*\n)*[ \t]+\d+ tasks? \(\d+ done, (?:\d+ in progress, )?\d+ open\)' \
                '(?:\n[ \t]+[◻◼✔][ \t]+[^\n]+)+(?:\n[ \t]+…[ \t]+\+\d+[ \t]+pending)?)?'

    CLAUDE = [
      r("osc_title_working", "working", 1100, "osc_title", regex: [/\A[⠀-⣿◐-◓] /]),
      r("live_turn_working", "working", 970, "bottom_non_empty_lines(12)",
        any: [{ line_regex: [/\A\s*[⏸⏵].*esc to interrupt(?:\s|·|\z)/] },
              { line_regex: [/\A\s*#{SPIN}\s+\S.*…(?:\s+\(\d+[smh](?:\s|·)|\s*\z)/] },]),
      r("background_agents_working", "working", 965, "last_non_empty_above_prompt_box",
        line_regex: [/\A\s*#{SPIN_NO_2733}\s+Waiting for [1-9]\d* background agents? to finish\s*\z/]),
      r("background_mcp_task_working", "working", 965, "bottom_non_empty_lines(12)",
        regex: [/^#{SPIN_NO_2733}[ \t]+\S[^\n]*?(?:\n[ \t]+[^\n]*?){0,3}·#{GAP}#{MCP_RUNNING}[ \t]*$/],
        not: [{ contains: ["do you want to proceed?"] }, { contains: ["esc to cancel"] },
              { contains: ["waiting for permission"] }, { contains: ["do you want to allow this connection?"] },
              { contains: ["tab to amend"] }, { contains: ["ctrl+e to explain"] },]),
      r("btw_overlay_working", "working", 975, "bottom_non_empty_lines(5)",
        line_regex: [/\A\s*\/btw(?:\s|\z)/, /esc to close\s*\z/i]),
      r("transcript_viewer", "unknown", 1000, "bottom_non_empty_lines(3)", contains: ["showing detailed transcript"],
        any: [{ contains: ["ctrl+o", "to toggle"] }, { contains: ["ctrl+e", "show all"] }, { contains: ["ctrl+e", "collapse"] },
              { contains: ["↑↓ scroll"] }, { contains: ["? for shortcuts"] },]),
      r("live_blocked_form", "blocked", 980, "after_last_horizontal_rule", contains: ["esc to cancel"],
        any: [{ contains: ["enter to confirm"] }, { contains: ["enter to select"], any: NAV }]),
      r("live_blocked_form_named_session", "blocked", 980, "whole_recent",
        regex: [/(?:\A|\n)#{FORM_KEYS}(?:[ \t]*\n)*[ \t]*─{3,}[^\n]*#{TASK_LIST}(?:\n[ \t]*)*\z/i]),
      r("dynamic_workflow_prompt", "blocked", 980, "whole_recent", contains: ["run a dynamic workflow?", "esc to cancel"]),
      r("mcp_elicitation_prompt", "blocked", 980, "whole_recent", contains: ["esc to cancel"],
        line_regex: [/\A\s*MCP server ["“].+["”] requests your input\s*\z/i],
        all: [{ any: [{ line_regex: [/\A\s*❯?\s*Accept\b/] }, { line_regex: [/\A\s*❯?\s*Decline\b/] }] }]),
      r("live_prompt_box", "idle", 950, "prompt_box_body", line_regex: [/\A\s*❯/],
        not: [{ contains: ["enter to select"] }, { contains: ["esc to cancel"] }, { contains: ["tab/arrow keys"] },
              { contains: ["arrow keys to navigate"] }, { contains: ["↑/↓ to navigate"] },]),
      r("model_picker_menu", "unknown", 900, "whole_recent",
        contains: ["select model", "enter to set as default", "esc to cancel"],
        not: [{ contains: ["do you want to proceed?"] }, { contains: ["enter to select"] }]),
      r("bash_permission_prompt", "blocked", 850, "whole_recent", contains: ["do you want to proceed?"],
        any: [{ contains: ["bash command"] }, { contains: ["bash("] }, { contains: ["contains expansion"] },
              { contains: ["tab to amend"] }, { contains: ["ctrl+e to explain"] },],
        all: [{ any: YES_NO.map { |re| { line_regex: [re] } } }]),
      r("generic_permission_prompt", "blocked", 840, "after_last_horizontal_rule",
        contains: ["do you want to proceed?", "esc to cancel"],
        all: [{ any: [/\A\s*❯?\s*1\.\s*yes\b/i, /\A\s*2\.\s*yes\b/i, /\A\s*2\.\s*no\b/i, /\A\s*3\.\s*no\b/i]
                       .map { |re| { line_regex: [re] } } }]),
      r("legacy_no_prompt_blocker", "blocked", 300, "whole_recent",
        any: [{ contains: ["do you want to"], any: [{ contains: ["yes"] }, { contains: ["❯"] }] },
              { contains: ["would you like to"], any: [{ contains: ["yes"] }, { contains: ["❯"] }] },
              { contains: ["waiting for permission"] }, { contains: ["do you want to allow this connection?"] },
              { contains: ["tab to amend"] }, { contains: ["ctrl+e to explain"] },
              { contains: ["do you want to proceed?", "esc to cancel"] },
              { contains: ["review your answers"] }, { contains: ["skip interview and plan immediately"] },],
        not: [{ regex: [/^[ \t]*❯[ \t]*$/] }]),
      r("osc_title_idle", "idle", 250, "osc_title", regex: [/\A✳ /]),
    ].freeze

    HERMES = [
      r("osc_title_blocked", "blocked", 1100, "osc_title", regex: [/\A⚠[︎️]?(?:\s|\z)/]),
      r("osc_title_working", "working", 1050, "osc_title", regex: [/\A⏳[︎️]?(?:\s|\z)/]),
      r("dangerous_command_approval", "blocked", 900, "bottom_non_empty_lines(14)",
        any: [{ contains: ["dangerous"] }, { contains: ["approval"] }, { contains: ["allow once", "deny"] },
              { line_regex: [/\A\s*[▸>]?\s*1\.\s*allow/i] },],
        all: [{ any: [{ contains: ["enter confirm"] }, { contains: ["enter to confirm"] }, { contains: ["↑/↓ to select"] },
                      { contains: ["show full command"] },] }]),
      r("clarification_prompt", "blocked", 900, "bottom_non_empty_lines(14)",
        any: [{ contains: ["hermes needs your"] }, { line_regex: [/\A\s*ask\s+\S/] }, { contains: ["type your answer"] }],
        all: [{ any: [{ contains: ["enter confirm"] }, { contains: ["enter to confirm"] }, { contains: ["enter send"] },
                      { contains: ["press enter"] }, { contains: ["↑/↓ select"] }, { contains: ["↑/↓ to select"] },
                      { contains: ["other (type"] },] }]),
      r("credential_prompt", "blocked", 900, "bottom_non_empty_lines(14)",
        any: [{ contains: ["sudo password"] }, { contains: ["skill setup"] }, { contains: ["🔑", "for "] }]),
      r("confirmation_prompt", "blocked", 900, "bottom_non_empty_lines(14)",
        all: [{ any: [{ contains: ["approve once", "cancel"] }, { contains: ["start a new session", "keep going"] }] },
              { any: [{ contains: ["enter to confirm"] }, { contains: ["enter confirm"] }, { contains: ["type 1/2/3"] },
                      { contains: ["y/n quick"] },] },]),
      r("interrupt_status_working", "working", 950, "bottom_non_empty_lines(5)",
        any: [{ contains: ["msg=interrupt"] }, { contains: ["ctrl+c to interrupt"] }]),
      r("classic_cancel_working", "working", 500, "bottom_non_empty_lines(5)", contains: ["ctrl+c cancel"]),
      r("osc_title_idle", "idle", 100, "osc_title", regex: [/\A✓[︎️]?(?:\s|\z)/]),
    ].freeze

    module_function

    # rules: a family's manifest (Engines::Family#rules — which engine runs which family is config).
    # → {state:, rule:} — rule nil when nothing matched (state "unknown").
    def detect(rules, screen, title = "")
      screen = screen.to_s.delete("\r")
      best = rules.select { |rule| matches?(rule.gate, region(rule.region, screen, title.to_s)) }.max_by(&:priority)
      best ? { state: best.state, rule: best.id } : { state: "unknown", rule: nil }
    end

    def matches?(gate, text, lower = text.downcase)
      return false unless Array(gate[:contains]).all? { |n| lower.include?(n.downcase) }
      return false unless Array(gate[:regex]).all? { |re| text.match?(re) }
      return false unless Array(gate[:line_regex]).all? { |re| text.each_line.any? { |l| l.chomp.match?(re) } }
      return false unless Array(gate[:all]).all? { |g| matches?(g, text, lower) }
      return false if Array(gate[:any]).any? && Array(gate[:any]).none? { |g| matches?(g, text, lower) }

      Array(gate[:not]).none? { |g| matches?(g, text, lower) }
    end

    def region(spec, screen, title)
      lines = screen.lines.map(&:chomp)
      case spec
      when "osc_title" then title
      when "whole_recent" then screen
      when "prompt_box_body"
        top = prompt_box_top(lines) or return ""
        body = lines[(top + 1)..]
        body.take_while { |l| !rule?(l) }.join("\n")
      when "last_non_empty_above_prompt_box" then above_prompt_box(lines).reverse.find { |l| !l.strip.empty? }.to_s
      when "after_last_horizontal_rule"
        i = lines.rindex { |l| rule?(l) }
        i ? lines[(i + 1)..].join("\n") : screen
      when /\Abottom_non_empty_lines\((\d+)\)\z/
        idx = lines.each_index.reject { |i| lines[i].strip.empty? }.last(Integer(Regexp.last_match(1)))
        idx.empty? ? "" : lines[idx.first..].join("\n")
      else raise ArgumentError, "unknown region #{spec}"
      end
    end

    def above_prompt_box(lines)
      top = prompt_box_top(lines)
      top ? lines[0...top] : lines
    end

    # the second horizontal rule from the bottom = the prompt box's top border
    def prompt_box_top(lines)
      seen = 0
      (lines.size - 1).downto(0) do |i|
        next unless rule?(lines[i])

        seen += 1
        return i if seen == 2
      end
      nil
    end

    def rule?(line)
      t = line.strip
      n = t[/\A─*/].size
      return false if n.zero?

      t[n..].lstrip.empty? || n >= 3
    end
  end
end
