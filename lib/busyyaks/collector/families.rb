# frozen_string_literal: true

require "json"

module Busyyaks
  module Collector
    # How bin/collector finds a coding agent in a tmux pane and what it may say about it: one class per engine family
    # (the same family names as Busyyaks::Engines — config/engines.yml maps an engine name to one), so a new engine is a
    # new class here, never an `if engine ==` branch. A pane's agent is its OUTERMOST process whose comm is a family's;
    # the walk never looks inside it (whatever an agent spawns — shells, tools, subagents — is not a second session).
    # Every pane carries every FACT key: nil = not known, with the reason under `unknown` — never a guess.
    FACTS = %w[model context effort version session_id status waiting_for title status_at subagents_running].freeze

    # what argv may say, by shape: anything else is dropped, never clipped into the snapshot (a prompt can ride in argv)
    MODEL = /\A[A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,199}\z/
    EFFORT = /\A[a-z]{1,32}\z/
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    class Family
      def name = raise(NotImplementedError)
      def comm = raise(NotImplementedError)

      # is this process (its comm is ours) really this family's agent?
      def claims?(_pid, _procfs) = true

      # {FACT => value} for the agent process, plus "unknown" => {FACT => why} for each nil
      def facts(_process, _procfs) = raise(NotImplementedError)

      private

      def complete(known, unknown)
        facts = FACTS.to_h { |k| [k, known[k]] }
        reasons = FACTS.select { |k| facts[k].nil? }.to_h { |k| [k, unknown.fetch(k, "not read by busyyaks's collector")] }
        facts.merge("unknown" => reasons)
      end

      # `--flag value` / `--flag=value`, the LAST one wins (as a CLI parser reads it); a value that looks like a flag,
      # or anything after a bare `--`, is refused
      def flag(argv, name)
        val = nil
        argv.drop(1).each_with_index do |a, i|
          break if a == "--"

          if a == name
            nxt = argv[i + 2]
            val = nxt.nil? || nxt.start_with?("-") ? nil : nxt
          elsif a.start_with?("#{name}=")
            val = a.delete_prefix("#{name}=")
          end
        end
        val
      end

      def shaped(value, shape) = value.is_a?(String) && value.match?(shape) ? value : nil
      def clip(value, max) = value.is_a?(String) && !value.empty? ? value[0, max] : nil
    end

    # Claude Code: comm `claude`. Its own per-process record, `<.env CLAUDE_SESSIONS_DIR>/<pid>.json`, says the session
    # id, status (idle · busy · waiting + what for), title and when the status changed — trusted only while its
    # procStart is the process's start time (a recycled pid is another process).
    class ClaudeCode < Family
      STATUSES = %w[idle busy waiting].freeze
      RECORD_MAX = 64 * 1024

      def initialize(sessions_dir)
        super()
        @sessions_dir = sessions_dir
      end

      def name = "claude"
      def comm = "claude"

      def facts(process, procfs)
        argv = procfs.argv(process.pid)
        exe = procfs.exe(process.pid).to_s
        version = File.basename(File.dirname(exe)) == "versions" ? clip(File.basename(exe), 64) : nil
        rec, why = record(process)
        known = { "model" => shaped(flag(argv, "--model"), MODEL), "effort" => shaped(flag(argv, "--effort"), EFFORT),
                  "version" => version, }
        known.merge!(rec) if rec
        complete(known, unknown(why, rec))
      end

      private

      def unknown(why, rec)
        out = { "model" => "no --model in its argv", "effort" => "no --effort in its argv",
                "version" => "its executable is not under a versions/ dir",
                "context" => "its context window is in its environment, which this collector never reads",
                "subagents_running" => "busyyaks's collector does not count subagents", }
        unless rec
          %w[session_id status waiting_for title status_at].each { |k| out[k] = why }
          return out
        end
        out["status"] = "its record's status is #{rec['raw_status'].inspect}, not one of #{STATUSES.join(' · ')}"
        out["waiting_for"] = "not waiting"
        out["title"] = "its record has no name"
        out["status_at"] = "its record has no statusUpdatedAt"
        out
      end

      # → [{session_id, status, waiting_for, title, status_at, raw_status}, nil] or [nil, why]
      def record(process)
        path = File.join(@sessions_dir, "#{process.pid}.json")
        raw = File.open(path, File::RDONLY | File::NONBLOCK) do |f|
          # a FIFO or a device there would park the loop on a read: only a regular file is a record
          return [nil, "its record #{path} is not a regular file"] unless f.stat.file?

          f.read(RECORD_MAX)
        end
        d = JSON.parse(raw.to_s)
        return [nil, "its record #{path} is not an object"] unless d.is_a?(Hash)
        mine = d["pid"] == process.pid && d["procStart"].to_s == process.start_ticks.to_s
        return [nil, "its record #{path} is another process's (pid reused)"] unless mine
        return [nil, "its record #{path} has no session id"] unless d["sessionId"].is_a?(String) && d["sessionId"].match?(UUID)

        status = STATUSES.include?(d["status"]) ? d["status"] : nil
        at = d["statusUpdatedAt"]
        [{ "session_id" => d["sessionId"], "status" => status, "raw_status" => d["status"],
           "waiting_for" => status == "waiting" ? clip(d["waitingFor"], 80) : nil, "title" => clip(d["name"], 200),
           "status_at" => at.is_a?(Numeric) && at.positive? ? at / 1000.0 : nil, }, nil,]
      rescue Errno::ENOENT
        [nil, "no Claude Code record #{path}"]
      rescue SystemCallError, JSON::ParserError => e
        [nil, "its record #{path} is unreadable: #{e.class}"]
      end
    end

    # Hermes: comm `hermes` and its launcher's bootstrap in argv (argv is read to confirm the shape only — a Hermes prompt
    # can ride in it, so nothing from argv leaves). It keeps no per-process status file: its state (working · blocked on
    # an approval · idle) is read off its screen by bin/launcher (AgentScreen::HERMES), the one source for it.
    class Hermes < Family
      MARKERS = %w[hermes_bootstrap hermes_cli].freeze

      def name = "hermes"
      def comm = "hermes"

      # `hermes gateway run` is Hermes's daemon (the same bootstrap, its words after the -c script), never a session
      def claims?(pid, procfs)
        argv = procfs.argv(pid)
        return false unless MARKERS.any? { |m| argv.join(" ").include?(m) }

        script = argv.index("-c")
        script.nil? || argv[script + 2] != "gateway"
      end

      def facts(_process, _procfs)
        record = "Hermes's own record (state.db) is not read by busyyaks's collector"
        complete({}, { "status" => "Hermes keeps no status file: bin/launcher reads its state off its screen",
                       "waiting_for" => "Hermes keeps no status file: an approval on its screen shows as blocked",
                       "status_at" => "Hermes keeps no status file", "session_id" => record, "title" => record,
                       "model" => record, "effort" => record, "context" => record, "version" => record,
                       "subagents_running" => record, })
      end
    end

    # the families bin/collector walks for, in order (each family's comm is distinct)
    def self.families(claude_sessions_dir:) = [ClaudeCode.new(claude_sessions_dir), Hermes.new]
  end
end
