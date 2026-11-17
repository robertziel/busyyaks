# frozen_string_literal: true

require "English"
require_relative "collector/procfs"
require_relative "collector/families"
require_relative "collector/tmux"
require_relative "collector/snapshot"
require_relative "collector/server"
require_relative "launcher_rules"

module Busyyaks
  # busyyaks's agent-session collector (bin/collector, card #479): a host program — stdlib Ruby, like bin/launcher — that
  # walks this uid's tmux panes + /proc for coding agents (Collector::Families), writes the snapshot bin/launcher reads
  # (Collector::Snapshot) and answers its screen / send requests (Collector::Server). It runs at the paths
  # config/busyyaks.yml `agents.collector` names — the same two values the launcher reads, one place for each.
  module Collector
    class Invalid < StandardError; end

    # how often a snapshot is taken (the snapshot says it: interval_s; bin/launcher calls one older than 3 × stale)
    INTERVAL_S = 5

    module_function

    # A thread of bin/collector whose death ends the collector (review round 1): an exception that escapes it (accept
    # failing with EMFILE, a bug in a request) is logged with its reason, then die.(1) — the process exits non-zero and
    # its unit restarts it, never a live process whose socket nobody serves. A thread that ends normally (a connection
    # served) is fine. → the thread
    def supervised(name, log:, die:)
      Thread.new do
        Thread.current.report_on_exception = false
        yield
      ensure
        e = $ERROR_INFO
        if e
          log.call("collector: the #{name} thread died (#{e.class}: #{e.message}): exiting so the unit restarts it")
          die.call(1)
        end
      end
    end

    # The collector's dir: the snapshot and the read socket side by side in ONE dir, created 0700, this uid's, outside
    # every dir a container mounts (PROJECTS_ROOT, the checkout and ./data, LAUNCHER_RUN_DIR): the socket types into
    # sessions, so no container may reach it (LauncherRules.run_dir!, the launcher socket's own rule). → the dir
    def dir!(paths, projects_root:, checkout:, run_dir:, uid:)
      dir = File.dirname(paths.snapshot)
      unless File.dirname(paths.read_socket) == dir
        raise Invalid, "agents.collector: snapshot and read_socket must be in the same dir for bin/collector " \
                       "(#{dir} vs #{File.dirname(paths.read_socket)})"
      end

      LauncherRules.run_dir!(dir, projects_root: projects_root, checkout: checkout, uid: uid,
                                  name: "agents.collector dir", mounted: { "LAUNCHER_RUN_DIR" => run_dir })
    rescue LauncherRules::Invalid => e
      raise Invalid, e.message
    end

    # every family's engine name must be one config/engines.yml (+ config/busyyaks.yml engines) knows, as that family:
    # the launcher reads the pane by it
    def check_engines!(families, engines)
      families.each do |f|
        raise Invalid, "engine #{f.name.inspect} is not configured (#{engines.missing(f.name)})" unless engines.known?(f.name)

        got = engines.fetch(f.name).family.name
        raise Invalid, "engine #{f.name} is configured as family #{got}, the collector reads it as #{f.name}" if got != f.name
      end
      nil
    end
  end
end
