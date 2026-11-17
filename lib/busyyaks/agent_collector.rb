# frozen_string_literal: true

require "io/wait"
require_relative "clock"

module Busyyaks
  # config/busyyaks.yml `agents.collector`: the agent-session collector bin/launcher reads, stated per deployment — no
  # default. `none` = this box runs no collector: the features that need one answer with OFF (said where they show),
  # everything else works. A mapping = the collector's snapshot file and read socket (host paths): the launcher refuses
  # to start while either is missing. Pure Ruby, no dependencies: bin/launcher (host) requires this file alone.
  module AgentCollector
    class Invalid < StandardError; end

    # a line not read whole within its deadline / over its size: the reader names the collector it waited for
    class Slow < StandardError; end
    class TooLarge < StandardError; end

    # snapshot + read_socket: host paths. tmux_timeout_seconds: bin/collector's deadline on each tmux call (a hung tmux
    # = that request's error, never a hang). answer_timeout_seconds: bin/launcher's (and `yaks doctor`'s) deadline on
    # the collector's whole answer line — above a send's worst case: SEND_CALLS tmux calls, each at its deadline
    Paths = Struct.new(:snapshot, :read_socket, :tmux_timeout_seconds, :answer_timeout_seconds, keyword_init: true)
    KEYS = %w[answer_timeout_seconds read_socket snapshot tmux_timeout_seconds].freeze
    SEND_CALLS = 4 # a send: capture-pane (the dialog check), load-buffer, paste-buffer, send-keys Enter
    TMUX_MAX_S = 60
    # an answer: a screen (bin/collector caps it at 512 KiB) as JSON, escapes included
    ANSWER_MAX = 4 * 1024 * 1024

    # what is off without a collector — the launcher's answer to every op that needs one, and its start line
    OFF = "agent-session collector off (config/busyyaks.yml agents.collector: none): no agents sidebar, no session " \
          "states on cards, no Clear idle, no subagent list, no typing card comments or answers into sessions, no " \
          "spotting a session stuck on a dialog before anyone comments"

    # bin/launcher's ops that read the collector (the rest — sessions, launch, dialog, answer, git, stop, … — use tmux)
    OPS = %w[agents agent_tasks reap_preview reap notify].freeze

    SHAPE = "agents must be a mapping {collector: none} or {collector: {snapshot: <file>, read_socket: <socket>, " \
            "tmux_timeout_seconds: <1..#{TMUX_MAX_S}>, answer_timeout_seconds: <n>}} (host paths; README \"Agent sessions\")"

    module_function

    # the `agents` value → nil (collector: none) or Paths; anything else is refused with the expected shape
    def parse(agents)
      raise Invalid, SHAPE unless agents.is_a?(Hash) && agents.keys == ["collector"]

      c = agents["collector"]
      return nil if c == "none"
      raise Invalid, SHAPE unless c.is_a?(Hash) && c.keys.sort == KEYS

      %w[snapshot read_socket].each do |k|
        v = c[k]
        raise Invalid, "agents.collector.#{k} must be an absolute host path" unless v.is_a?(String) && v.start_with?("/")
      end
      tmux = c["tmux_timeout_seconds"]
      unless tmux.is_a?(Integer) && tmux.between?(1, TMUX_MAX_S)
        raise Invalid, "agents.collector.tmux_timeout_seconds must be an Integer 1..#{TMUX_MAX_S}"
      end
      answer = c["answer_timeout_seconds"]
      unless answer.is_a?(Integer) && answer > SEND_CALLS * tmux
        raise Invalid, "agents.collector.answer_timeout_seconds must be an Integer above #{SEND_CALLS} × " \
                       "tmux_timeout_seconds (#{SEND_CALLS * tmux}): a send is #{SEND_CALLS} tmux calls"
      end
      Paths.new(snapshot: c["snapshot"], read_socket: c["read_socket"], tmux_timeout_seconds: tmux,
                answer_timeout_seconds: answer)
    end

    # One whole line from io within `seconds` (the deadline covers the whole line, not the first byte: a peer that
    # sends half a line and stops costs `seconds`, never a parked reader). → the line (its newline kept), or nil at EOF
    # before any byte; a line ended by EOF without its newline is returned as it is. Slow past the deadline, TooLarge
    # past `max` bytes.
    def read_line(io, seconds, max:)
      deadline = Clock.monotonic + seconds
      buf = String.new(encoding: Encoding::BINARY)
      loop do
        i = buf.index("\n")
        if i
          raise TooLarge, "a line over #{max} bytes" if i + 1 > max

          return buf[0..i].force_encoding(Encoding::UTF_8)
        end
        raise TooLarge, "a line over #{max} bytes" if buf.bytesize > max

        left = deadline - Clock.monotonic
        raise Slow, "no whole line within #{seconds}s" unless left.positive? && io.wait_readable(left)

        chunk = io.read_nonblock(65_536, exception: false)
        next if chunk == :wait_readable
        return buf.empty? ? nil : buf.force_encoding(Encoding::UTF_8) if chunk.nil?

        buf << chunk
      end
    end

    # the launcher's answer to `op` when it needs a collector this box does not run (collector nil = none), else nil.
    # unsupported: the notifier marks a ping failed with the reason instead of retrying it. 422: a configured choice,
    # not an outage (the web serves the launcher's refusal as 422 too).
    def refusal(collector, op)
      return nil unless collector.nil? && OPS.include?(op)

      { ok: false, error: OFF, unsupported: true, status: 422 }
    end

    # bin/launcher's start check: a collector the config names must be there (else: start it, or say none)
    def check!(paths)
      unless File.file?(paths.snapshot)
        raise Invalid, "agents.collector.snapshot #{paths.snapshot} is not a file: start the collector, or set " \
                       "agents.collector: none"
      end
      return if File.socket?(paths.read_socket)

      raise Invalid, "agents.collector.read_socket #{paths.read_socket} is not a unix socket: start the collector, or " \
                     "set agents.collector: none"
    end
  end
end
