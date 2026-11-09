# frozen_string_literal: true

module Busyyaks
  # config/busyyaks.yml `agents.collector`: the agent-session collector bin/launcher reads, stated per deployment — no
  # default. `none` = this box runs no collector: the features that need one answer with OFF (said where they show),
  # everything else works. A mapping = the collector's snapshot file and read socket (host paths): the launcher refuses
  # to start while either is missing. Pure Ruby, no dependencies: bin/launcher (host) requires this file alone.
  module AgentCollector
    class Invalid < StandardError; end

    Paths = Struct.new(:snapshot, :read_socket, keyword_init: true)

    # what is off without a collector — the launcher's answer to every op that needs one, and its start line
    OFF = "agent-session collector off (config/busyyaks.yml agents.collector: none): no agents sidebar, no session " \
          "states on cards, no Clear idle, no subagent list, no typing card comments or answers into sessions, no " \
          "spotting a session stuck on a dialog before anyone comments"

    # bin/launcher's ops that read the collector (the rest — sessions, launch, dialog, answer, git, stop, … — use tmux)
    OPS = %w[agents agent_tasks reap_preview reap notify].freeze

    SHAPE = "agents must be a mapping {collector: none} or {collector: {snapshot: <file>, read_socket: <socket>}} " \
            "(host paths; README \"Agent sessions\")"

    module_function

    # the `agents` value → nil (collector: none) or Paths; anything else is refused with the expected shape
    def parse(agents)
      raise Invalid, SHAPE unless agents.is_a?(Hash) && agents.keys == ["collector"]

      c = agents["collector"]
      return nil if c == "none"
      raise Invalid, SHAPE unless c.is_a?(Hash) && c.keys.sort == %w[read_socket snapshot]

      c.each do |k, v|
        raise Invalid, "agents.collector.#{k} must be an absolute host path" unless v.is_a?(String) && v.start_with?("/")
      end
      Paths.new(snapshot: c["snapshot"], read_socket: c["read_socket"])
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
