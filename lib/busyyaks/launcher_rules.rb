# frozen_string_literal: true

require "fileutils"
require "pathname"
require "json"
require "tempfile"

module Busyyaks
  # The checks bin/launcher (and deploy/install-launcher.sh) run on what a container or .env hands it, as functions it
  # calls (pure Ruby: the host launcher requires this file alone) so the suite tests them without a host tmux.
  module LauncherRules
    class Invalid < StandardError; end

    # The prompt values the engine sends (Launch.prepare's vars); {dir} is the launcher's own, never the request's.
    LAUNCH_VARS = %w[slug session agent type cards].freeze

    module_function

    # config/busyyaks.yml `launch.start_seconds` (required, no default): how long bin/launcher waits after `tmux
    # new-session` for claude to come up (`claude --remote-control <session>` in the pane's tree) while the launcher's
    # command is still working (a shell function may start a gateway or an ssh forward first). A command that exits
    # into the pane's bare shell is refused at once, whatever this says.
    START_SECONDS = (1..600)

    def start_seconds!(value)
      return value if value.is_a?(Integer) && START_SECONDS.cover?(value)

      raise Invalid, "launch.start_seconds must be an integer #{START_SECONDS.min}..#{START_SECONDS.max} " \
                     "(seconds bin/launcher waits for a started agent to come up; got #{value.inspect})"
    end

    # config/busyyaks.yml `launch.scopes` (required key): null = this host runs no systemd user manager, every
    # session stays in the scope tmux gives its pane; or {lead_oomd: avoid | none, session_memory_max: "<n>K|M|G" | null}
    # — each session runs in its own systemd user scope `busyyaks-<session>` (systemd-run --user --scope): a LEAD's
    # scope carries ManagedOOMPreference=<lead_oomd> (avoid: the scope is MARKED avoid — `user.oomd_avoid=1` on its
    # cgroup, seen on this host — and per systemd.resource-control(5) oomd prefers other candidates; NOT verified under
    # real memory pressure), every other session's MemoryMax=<session_memory_max> (null = no cap; enforced by the
    # kernel's memory controller). 2026-11-15: oomd killed a lead's pane at 108 G.
    SCOPE_KEYS = %w[lead_oomd session_memory_max].freeze
    OOMD = %w[avoid none].freeze
    MEMORY = /\A[1-9][0-9]{0,6}[KMG]\z/

    def scopes!(value)
      return nil if value.nil?
      unless value.is_a?(Hash) && value.keys.sort == SCOPE_KEYS.sort
        raise Invalid, "launch.scopes must be null (no systemd user manager on this host) or {lead_oomd: avoid|none, " \
                       "session_memory_max: <n>K|M|G or null} (got #{value.inspect})"
      end
      raise Invalid, "launch.scopes.lead_oomd must be one of #{OOMD.join(', ')}" unless OOMD.include?(value["lead_oomd"])
      mem = value["session_memory_max"]
      unless mem.nil? || (mem.is_a?(String) && mem.match?(MEMORY))
        raise Invalid, "launch.scopes.session_memory_max must be null or <n>K|M|G (got #{mem.inspect})"
      end

      value.slice(*SCOPE_KEYS).freeze
    end

    # The argv a session runs: `argv` itself (no scopes), or wrapped in its own systemd user scope — a lead with the
    # oomd preference, anything else with its memory cap. systemd-run execs the command inside the scope, so the
    # launcher's start check (claude --remote-control <session> in the pane's tree) still finds it.
    def scoped(argv, scopes:, session:, lead:)
      return argv if scopes.nil?

      props = if lead
                scopes["lead_oomd"] == "none" ? [] : ["-p", "ManagedOOMPreference=#{scopes['lead_oomd']}"]
              else
                scopes["session_memory_max"] ? ["-p", "MemoryMax=#{scopes['session_memory_max']}"] : []
              end
      ["systemd-run", "--user", "--scope", "--quiet", "--collect", "--unit=busyyaks-#{session}", *props, "--", *argv]
    end

    # The leads THIS launcher started (lead-first boards): .env LAUNCHER_STATE_DIR/leads.json (the
    # launcher's own dir, 0700, outside every container mount), one {session, type, dir, key} per lead — the key the
    # engine minted for it (only its SHA-256 is in the database). A worker / sub team starts only under a lead recorded
    # here for the SAME repo dir and the lead type it runs under, whose tmux session runs; kanban_spawn's lead check
    # asks for the key (`lead_key` op) and the engine compares digests. The key is never put into the tmux session,
    # a log line or an answer other than that op's. Entries whose tmux session is gone are dropped on every write.
    class Leads
      KEY = /\A\h{64}\z/
      FIELDS = %w[dir key session type].freeze

      def initialize(dir)
        @dir = dir
        @file = File.join(dir, "leads.json")
        @lock = Mutex.new
        @lock.synchronize { read } # a corrupt file stops the start
      end

      def record(session:, type:, dir:, key:, alive:)
        raise Invalid, "lead key must be 64 hex characters" unless key.is_a?(String) && key.match?(KEY)

        @lock.synchronize do
          keep = read.reject { |e| e["session"] == session || !alive.call(e["session"]) }
          write(keep + [{ "session" => session, "type" => type, "dir" => dir, "key" => key }])
        end
      end

      def find(session) = @lock.synchronize { read.find { |e| e["session"] == session } }

      # The lead a session of `type` (under `lead_type`) may start under in `dir`: recorded by this launcher for that
      # dir and type, and running — else Invalid with what is missing.
      def under!(session, lead_type:, dir:, alive:)
        e = find(session)
        raise Invalid, "#{session} is no lead this launcher started: launch the #{lead_type} first" unless e
        unless e["type"] == lead_type
          raise Invalid, "#{session} is a #{e['type']}, not the #{lead_type} this session runs under"
        end
        raise Invalid, "#{session} leads #{e['dir']}, not #{dir}: a session runs under its own board's lead" \
          unless e["dir"] == dir
        raise Invalid, "the #{lead_type} session #{session} is not running: launch the #{lead_type} first" \
          unless alive.call(session)

        e
      end

      private

      def write(list)
        f = Tempfile.create(["leads", ".json.tmp"], @dir)
        begin
          f.write(JSON.generate(list))
          f.close
          File.rename(f.path, @file)
        ensure
          f.close unless f.closed?
          FileUtils.rm_f(f.path)
        end
      end

      def read
        return [] unless File.exist?(@file)

        list = begin
          JSON.parse(File.read(@file))
        rescue JSON::ParserError => e
          # the class and the line only: the parser's message quotes the unparsed text — a key fragment (review round 2)
          at = e.message[/line (\d+)/, 1]
          raise Invalid, "#{@file} is not valid JSON (#{e.class}#{at ? ", line #{at}" : ''}): fix or remove it"
        end
        ok = list.is_a?(Array) && list.all? do |e|
          e.is_a?(Hash) && e.keys.sort == FIELDS && e.values.all?(String) && e["key"].match?(KEY)
        end
        raise Invalid, "#{@file} is not a list of {session, type, dir, key}: fix or remove it" unless ok

        list
      end
    end

    # A launch's start clock (bin/launcher's start check): the WHOLE seconds passed since `started` (monotonic seconds,
    # floored — never rounded: 3.6 s is 3), and whether launch.start_seconds really passed. Overdue compares
    # the unfloored seconds, so a refusal never comes before start_seconds; the floored ones are only for the message.
    def start_elapsed(started, now) = (now - started).floor

    def start_overdue?(started, now, start_seconds) = now - started >= start_seconds

    # A container path under container_root → the repo dir's REAL path under projects_root (what tmux and the trust
    # check then use: a symlink swapped after this check is never followed). Refused: a path outside the root, an
    # empty / . / .. segment, a dir that is no git repo, and a symlink that leads out of projects_root.
    def host_dir(container_path, container_root:, projects_root:)
      rel = container_path.to_s.delete_prefix("#{container_root}/")
      raise ArgumentError, "path outside #{container_root}" if rel == container_path.to_s || rel.empty?
      raise ArgumentError, "bad path" if rel.split("/").any? { |seg| seg.empty? || seg == "." || seg == ".." }

      dir = File.join(projects_root, rel)
      raise ArgumentError, "not a git repo: #{dir}" unless File.directory?(dir) && File.exist?(File.join(dir, ".git"))

      real = File.realpath(dir)
      root = File.realpath(projects_root)
      raise ArgumentError, "#{dir} resolves to #{real}, outside #{root}" unless real.start_with?("#{root}/")

      real
    end

    # The type's prompt values: only the engine's keys from the request, {dir} last (the request cannot set it).
    def launch_vars(vars, dir:)
      raise ArgumentError, "vars must be an object" unless vars.is_a?(Hash)

      extra = vars.keys.map(&:to_s) - LAUNCH_VARS
      raise ArgumentError, "unknown vars #{extra.join(', ')} (allowed: #{LAUNCH_VARS.join(', ')})" if extra.any?

      vars.to_h { |k, v| [k.to_sym, v] }.merge(dir: dir)
    end

    # .env LAUNCHER_RUN_DIR → its real path, created 0700. Refused: a relative path; one under PROJECTS_ROOT (every
    # container mounts that, and a read-only mount does not stop connect() on a socket) or under the checkout (./data,
    # .env, the test service's .:/app); one that contains either; an existing one owned by another uid or open to group
    # / other (never repaired: what another user put there earlier would stay). A dir it cannot create → Invalid.
    def run_dir!(path, projects_root:, checkout:, uid:)
      raise Invalid, "LAUNCHER_RUN_DIR must be an absolute path (got #{path.inspect})" unless path.to_s.start_with?("/")

      real = resolve(path)
      # compose mounts the path AS WRITTEN and the launcher binds the real one: they must be the same path
      unless File.expand_path(path) == real
        raise Invalid, "LAUNCHER_RUN_DIR #{path} goes through a symlink (it is #{real}): write #{real}"
      end
      # ./data by its own real path too: a data dir symlinked out of the checkout is mounted by every container
      { "PROJECTS_ROOT" => projects_root, "the busyyaks checkout" => checkout,
        "./data" => File.join(checkout, "data"), }.each do |what, other|
        o = resolve(other)
        if inside?(real, o) || inside?(o, real)
          raise Invalid, "LAUNCHER_RUN_DIR #{path} (#{real}) overlaps #{what} (#{o}): every container mounts it, and " \
                         "a socket in it is reachable from all of them; put it outside both"
        end
      end
      parents!(real, uid)
      begin
        FileUtils.mkdir_p(real, mode: 0o700)
      rescue SystemCallError => e
        raise Invalid, "LAUNCHER_RUN_DIR #{real} cannot be created: #{e.message}"
      end
      st = File.stat(real)
      raise Invalid, "LAUNCHER_RUN_DIR #{real} is not a directory" unless st.directory?
      parent = File.stat(File.dirname(real))
      unless parent.uid == uid
        raise Invalid, "LAUNCHER_RUN_DIR #{real}: its parent #{File.dirname(real)} is owned by uid #{parent.uid}, not #{uid}"
      end
      unless st.uid == uid
        raise Invalid, "LAUNCHER_RUN_DIR #{real} is owned by uid #{st.uid}, not #{uid} (created by Docker before the " \
                       "launcher? remove it and run deploy/install-launcher.sh before compose starts)"
      end
      if st.mode.anybits?(0o077)
        raise Invalid, "LAUNCHER_RUN_DIR #{real} is mode #{format('%o', st.mode & 0o777)}: open to group / other; check " \
                       "what is in it, then chmod 700 #{real}"
      end

      real
    end

    # Every existing ancestor (up to /) is this uid's or root's and not writable by group / other — else another user
    # could swap a path component between the launcher's bind and compose's mount, or (a sticky /tmp too) create the
    # dir first while it is absent, after a reboot, so the containers mount theirs.
    def parents!(real, uid)
      dir = File.dirname(real)
      loop do
        if File.exist?(dir)
          st = File.lstat(dir)
          raise Invalid, "LAUNCHER_RUN_DIR #{real}: #{dir} is a symlink" if st.symlink?
          unless [uid, 0].include?(st.uid)
            raise Invalid, "LAUNCHER_RUN_DIR #{real}: its parent #{dir} is owned by uid #{st.uid}, not #{uid} or root"
          end
          if st.mode.anybits?(0o022)
            raise Invalid, "LAUNCHER_RUN_DIR #{real}: its parent #{dir} is writable by group / other " \
                           "(mode #{format('%o', st.mode & 0o7777)})"
          end
        end
        break if dir == "/"

        dir = File.dirname(dir)
      end
    end

    def inside?(path, dir) = path == dir || path.start_with?("#{dir.delete_suffix('/')}/")

    # the real path of a path that may not exist yet: its deepest existing ancestor resolved, the rest appended
    def resolve(path)
      p = Pathname.new(File.expand_path(path))
      rest = []
      until p.exist? || p.root?
        rest.unshift(p.basename.to_s)
        p = p.dirname
      end
      File.join(p.realpath.to_s, *rest).then { |s| s.length > 1 ? s.delete_suffix("/") : s }
    end
  end
end
