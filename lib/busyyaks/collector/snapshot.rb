# frozen_string_literal: true

require "json"
require "socket"
require_relative "../clock"
require_relative "../launcher_rules"

module Busyyaks
  module Collector
    # The snapshot bin/launcher reads (its `agents` op; test/integration/collector_test.rb runs both): version 1,
    # {version, generated_at, host, interval_s, error, sessions: [{name, socket, attached, created, activity, windows,
    # panes: [{target, pane_id, pid, cwd, started, engine, <FACTS>, unknown}]}]}. A session is listed once, with every
    # pane of it that runs an agent; sessions with none are not listed. What leaves: tmux's session facts, the pane's
    # target and the family's facts — never the pane's contents or its environment; of its argv only what a family reads
    # from it (Claude Code's model and effort, shape-checked).
    module Snapshot
      VERSION = 1
      CWD_MAX = 4096

      # A pane send/screen may act on: the agent the snapshot saw there (its pid AND start time: a pid reused by another
      # process is not it).
      Target = Struct.new(:socket, :name, :pane_id, :pid, :start_ticks, :family, keyword_init: true)

      module_function

      # → [snapshot, {[socket, name] => Target of its first agent pane}]
      def build(rows_by_socket, procfs:, families:, interval_s:, error: nil, now: Clock.now.to_f, host: Socket.gethostname)
        procs = procfs.processes
        kids = procfs.children(procs)
        boot = procfs.btime
        by_comm = families.to_h { |f| [f.comm, f] }
        sessions = {}
        targets = {}
        rows_by_socket.each do |label, rows|
          rows.each do |r|
            # only the sessions busyyaks starts (`by_…`, LauncherRules::SESSION_PREFIX): a session the operator started by
            # hand is never read — not its processes, its screen or its facts (2026-11-24)
            next unless LauncherRules.busyyaks_session?(r["session_name"])

            found = agent(r["pane_pid"], procs, kids, by_comm, procfs) or next
            process, family = found
            key = [label, r["session_name"]]
            s = sessions[key] ||= { "name" => r["session_name"], "socket" => label, "attached" => r["session_attached"],
                                    "created" => r["session_created"], "activity" => 0,
                                    "windows" => r["session_windows"], "panes" => [], }
            s["activity"] = [s["activity"], r["session_activity"], r["window_activity"]].max
            s["panes"] << { "target" => "#{r['window_index']}.#{r['pane_index']}", "pane_id" => r["pane_id"],
                            "pid" => process.pid, "cwd" => procfs.cwd(process.pid)&.[](0, CWD_MAX),
                            "started" => procfs.started(process, boot), "engine" => family.name,
                            **family.facts(process, procfs), }
            # screen / send address a session's FIRST agent pane (the panes come in tmux's window.pane order)
            targets[key] ||= Target.new(socket: label, name: r["session_name"], pane_id: r["pane_id"], pid: process.pid,
                                        start_ticks: process.start_ticks, family: family)
          end
        end
        list = sessions.values.sort_by { |s| [s["socket"] == "default" ? 0 : 1, s["socket"], s["name"]] }
        list.each { |s| s["panes"].sort_by! { |p| p["target"].split(".").map(&:to_i) } }
        [{ "version" => VERSION, "generated_at" => now, "host" => host, "interval_s" => interval_s, "error" => error,
           "sessions" => list, }, targets,]
      end

      # the pane's outermost process whose comm is a family's, if that family claims it → [process, family] or nil.
      # The walk stops at such a process either way: an agent's own children are never searched for a second one.
      def agent(pane_pid, procs, kids, by_comm, procfs)
        stack = [pane_pid]
        seen = {}
        found = []
        until stack.empty?
          pid = stack.pop
          next if seen[pid] || !procs.key?(pid)

          seen[pid] = true
          family = by_comm[procs[pid].comm]
          if family
            found << [procs[pid], family] if family.claims?(pid, procfs)
            next
          end
          stack.concat(kids.fetch(pid, []))
        end
        found.min_by { |p, _| p.pid }
      end

      # write-then-rename in the same dir, mode 0600: a reader sees the old file or the new one, never half of either
      def write_atomic(path, data)
        tmp = File.join(File.dirname(path), ".#{File.basename(path)}.#{Process.pid}.tmp")
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC | File::EXCL, 0o600) { |f| f.write(data) }
        File.rename(tmp, path)
      ensure
        File.unlink(tmp) if tmp && File.exist?(tmp)
      end
    end

    # The last snapshot's targets: what the read socket may act on (a session not in it does not exist there).
    class Latest
      def initialize
        @lock = Mutex.new
        @targets = {}
      end

      def set(targets) = @lock.synchronize { @targets = targets }

      def lookup(name, socket) = @lock.synchronize { @targets[[socket, name]] }
    end
  end
end
