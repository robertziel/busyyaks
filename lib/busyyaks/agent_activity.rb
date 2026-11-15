# frozen_string_literal: true

module Busyyaks
  # What a working Claude Code pane is doing right now, read from the turn's status line (the spinner) and the tool
  # block above it, each phase only from what the screen shows (frames captured from real panes:
  # test/fixtures/screens/claude_*): thinking (the status line says so) · tool (a call that is still running draws
  # it) · writing (`settle`: the ↓ count rose between two reads) · subagents (no turn of its own runs; it waits for
  # background subagents) · nil (none of these is shown: "working", never a guess) — plus the elapsed time, the
  # token count, the running tool's name and, for a comment-writing kanban tool, the card it writes on. Only this
  # verdict leaves the host, never the screen text. A screen with neither a status line nor a subagent row → nil.
  # Pure Ruby, no dependencies: bin/launcher (host) requires this file alone.
  module AgentActivity
    PHASES = %w[thinking tool writing subagents].freeze

    # "✢ Combobulating… (23s · ↓ 1.6k tokens · thought for 2s)" — the glyphs of AgentScreen's live_turn_working rule
    SPINNER = /\A\s*[*·✢✳✶✻✽]\s+\S[^(]*…\s*(?:\((?<meta>[^()]*)\))?\s*\z/
    # the turn ended, its background agents still run (AgentScreen's background_agents_working)
    BACKGROUND = /\A\s*[*·✢✳✶✻✽]\s+Waiting for [1-9]\d* background agents? to finish/
    # a row of the subagent panel under the prompt box: "◯ general-purpose  <description>  7s · ↓ 71.7k tokens"
    # (the `main` row is the session itself)
    PANEL_ROW = /\A\s*[◯◉●]\s+(?!main\s*\z)[\w.-]+\s{2,}\S.*\s(?:\d+[hms]\s*)+·\s*[↓↑]\s*\d+(?:\.\d+)?k?\s+tokens?\s*\z/
    SUBAGENTS = { phase: "subagents", elapsed_s: nil, tokens: nil, tool: nil, card: nil }.freeze
    ELAPSED = /\A(?:(?<h>\d+)h\s*)?(?:(?<m>\d+)m\s*)?(?:(?<s>\d+)s)?\z/
    TOKENS = /\A(?<dir>[↓↑])\s*(?<n>\d+(?:\.\d+)?k?)\s+tokens?\z/
    # a tool call's header: "● Bash(ls)" · "● busyyaks - kanban_comment (MCP)(id: 459, …)"
    TOOL = /\A●\s+(?:(?<server>[\w.-]{1,40}) - )?(?<name>[A-Za-z][\w.-]{0,40})(?:\s+\(MCP\))?\((?<args>.*)\z/
    # a tool still running, by what only a running call draws (captured from Claude Code panes, test/fixtures/screens):
    # a named call's result line "⎿  Running…" / "⎿  Waiting…"; a shell call's live timer — "● Running 2 shell commands
    # · 2s…", its echo "⎿  $ sleep 12 (3s)" — or its "(ctrl+b ctrl+b (twice) to run in background)" hint. A plain
    # "Running <cmd>" line is NOT: it stays drawn after the call ended, while the next one is being written.
    RESULT_RUNNING = /\A\s*⎿\s+(?:Running|Waiting)…/
    LIVE_RUNNING = [
      /\A●\s+Running\b.*·\s*(?:\d+[hms]\s*)+…\s*\z/,
      /\A\s*⎿\s+\$\s\S.*\s\((?:\d+[hms]\s?)+\)\s*\z/,
      /\A\s*\(ctrl\+b ctrl\+b \(twice\) to run in background\)\s*\z/,
    ].freeze
    # kanban tools that write a comment on the card their `id` names
    COMMENT_TOOLS = %w[kanban_comment kanban_comment_edit kanban_ask kanban_attach kanban_handoff].freeze
    CARD_ARG = /(?:\A|[\s,])id:\s*(\d{1,9})\b/

    module_function

    # screen: the pane's text (tmux capture-pane). → {phase, elapsed_s, tokens, tool, card} or nil
    def claude(screen)
      lines = screen.to_s.delete("\r").lines.map(&:chomp)
      at = lines.rindex { |l| l.match?(SPINNER) || l.match?(BACKGROUND) }
      return lines.any? { |l| l.match?(PANEL_ROW) } ? SUBAGENTS.dup : nil unless at
      return SUBAGENTS.dup if lines[at].match?(BACKGROUND)

      meta = parse_meta(lines[at][SPINNER, :meta])
      tool = meta[:thinking] ? nil : running_tool(lines[0...at]) # a turn thinks between its tool calls, never during one
      tool ||= { name: nil, card: nil } if meta[:mcp_running]
      # writing is never assumed from what is NOT on screen: a status line that is neither thinking nor a running tool
      # has phase nil here, and `settle` names it writing only when its ↓ count rose since the previous read
      phase = if meta[:thinking] then "thinking"
              elsif tool then "tool"
              end
      { phase: phase, elapsed_s: meta[:elapsed_s], tokens: meta[:tokens], tool: tool && tool[:name],
        card: tool && tool[:card], }
    end

    STREAM_WINDOW_S = 30 # a previous read older than this is no base to compare with
    WRITING_S = 5 # the ↓ count steps by 0.1k: it rose within this many seconds = still streaming

    # One pane's reading + what the previous read of that pane saw (memo, nil on the first) at `now` (seconds) →
    # [activity, memo for the next read]. A status line with no phase of its own whose ↓ count rose (against a read at
    # most STREAM_WINDOW_S old) within the last WRITING_S is streaming output: writing. Anything else keeps its phase —
    # nil stays nil ("working"): no rise seen = not known to be writing.
    def settle(activity, memo, now)
      n = token_count(activity && activity[:tokens])
      return [activity, nil] unless n

      fresh = memo && now - memo[:at] <= STREAM_WINDOW_S
      rose_at = if fresh && n > memo[:tokens] then now
                elsif fresh then memo[:rose_at]
                end
      writing = activity[:phase].nil? && rose_at && now - rose_at <= WRITING_S
      activity = activity.merge(phase: "writing") if writing
      [activity, { tokens: n, at: now, rose_at: rose_at }]
    end

    # "↓ 12.9k" → 12900; an ↑ count (input sent) or none → nil
    def token_count(tokens)
      m = tokens.to_s.match(/\A↓ (\d+(?:\.\d+)?)(k?)\z/) or return nil
      (m[1].to_f * (m[2] == "k" ? 1000 : 1)).round
    end

    # the spinner's "(…)" parts → {elapsed_s, tokens, thinking}
    def parse_meta(meta)
      out = { elapsed_s: nil, tokens: nil, thinking: false, mcp_running: false }
      meta.to_s.split("·").map(&:strip).each do |part|
        e = part.match?(/\A\d+[hms]/) ? part.match(ELAPSED) : nil
        t = part.match(TOKENS)
        if e then out[:elapsed_s] = (e[:h].to_i * 3600) + (e[:m].to_i * 60) + e[:s].to_i
        elsif t then out[:tokens] = "#{t[:dir]} #{t[:n]}"
        elsif part.match?(/\A(?:still\s+)?thinking\b/) then out[:thinking] = true # "thinking with medium effort"
        elsif part.match?(/\A[1-9]\d*\s+MCP\s+tasks?\s+still\s+running/) then out[:mcp_running] = true
        end
      end
      out
    end

    # the tool running above the status line → {name, card} (name nil: running, not named); nil = none runs. Only the
    # newest block (from the last "●" line) counts: anything above it belongs to a call that ended.
    def running_tool(above)
      block = above.last(40)
      dot = block.rindex { |l| l.start_with?("●") }
      after = dot ? block[dot..] : block
      return { name: nil, card: nil } if after.any? { |l| LIVE_RUNNING.any? { |re| l.match?(re) } }
      return nil unless dot && after.any? { |l| l.match?(RESULT_RUNNING) }

      m = block[dot].match(TOOL) or return { name: nil, card: nil }
      name = m[:server] ? "#{m[:server]} · #{m[:name]}" : m[:name]
      card = COMMENT_TOOLS.include?(m[:name]) ? m[:args][CARD_ARG, 1]&.to_i : nil
      { name: name, card: card }
    end
  end
end
