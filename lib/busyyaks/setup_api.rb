# frozen_string_literal: true

require_relative "agent_settings_api"
require_relative "config"
require_relative "launcher_client"
require_relative "clock"
require_relative "daily_report_settings"
require_relative "harnesses"

module Busyyaks
  # The first-run hello screen (/hello): the boot checks, where the projects come from, and the agent
  # launchers, as [status, body]. Writes only two things: a setup_completions row (complete) — the launchers and the
  # default go through AgentSettingsAPI.save like Settings → Agents & launchers. The projects dir (.env PROJECTS_ROOT,
  # a compose mount) and the allowed commands (config/busyyaks.yml launch.commands, a :ro host file) are host-only:
  # shown here, never written.
  #   show            → 200 {completed, checks, projects, agents}
  #   complete(by:)   → 200 the same, completed = the new row
  module SetupAPI
    TABLE = :setup_completions

    module_function

    def completed(db)
      row = db[TABLE].order(Sequel.desc(:id)).first
      row && { author: row[:author], at: row[:created_at] }
    end

    def completed?(db) = !db[TABLE].empty?

    # checks: each {key, label, ok, detail} — read now, in this order; a failed one says why, nothing is assumed
    def show(db:, store:, config:, github:, launcher: LauncherClient, env: ENV)
      projects = store.projects
      _, agents = AgentSettingsAPI.show(db: db, commands: config.launch_commands)
      [200, {
        completed: completed(db),
        checks: [database(env, db), scanner(store.last_scan), launcher_check(launcher), agents_check(agents),
                 github_check(github, env),],
        projects: { host_root: env.fetch("PROJECTS_ROOT"), mount: env.fetch("PROJECTS_MOUNT"),
                    roots: config.roots, search_depth: config.search_depth, repos: projects.size,
                    sample: projects.map { |p| p[:slug] }.sort.first(12), },
        agents: agents,
        daily_report: daily_report(db, config.daily_report_runners),
        kinds: kind_labels,
      },]
    end

    # GET /api/setup/harnesses: bin/launcher's `harnesses` probe joined with this host's allowlist (the
    # web's own config: launch.commands, the same list GET /api/setup's agents.commands carries):
    #   harnesses[]: the catalogue entry + {found, type, path, version, version_error} + launchable (an engine kind),
    #     allowed = the indexes of the launch.commands entries of its kind, allow_line = the exact launch.commands item
    #     to add (null: no engine kind — nothing to add)
    #   commands[]: each launch.commands entry's own command as the launch shell resolves it ({at, found, type, path})
    #   allowlist_in_sync: the launcher enforces the same launch.commands this process read. The launcher reads the file
    #     at its start; the web on every request, but through a single-file bind mount (a file an editor replaces on
    #     save stays the old one in a running container) — so after an edit either can be stale: false = restart both
    # The launcher down → 503 (only that: the page says "not running" by the status), a launcher started before this op
    # → 501, its probe failing → 500: the reason, never a partial "not found".
    def harnesses(launcher:, commands:, clock: Busyyaks::Clock)
      t = clock.monotonic
      res = launcher.harnesses
      by_name = res["commands"].to_h { |c| [c["command"], c] }
      list = res["harnesses"].map do |h|
        kind = h["kind"]
        allowed = kind ? commands.each_index.select { |i| commands[i]["kind"] == kind } : []
        line, note = kind ? allow_line(h) : [nil, nil]
        h.transform_keys(&:to_sym).merge(launchable: !kind.nil?, allowed: allowed, allow_line: line, allow_note: note)
      end
      # a command the launcher did not resolve = one it does not enforce yet (it read launch.commands before the edit):
      # unknown (found nil), never "not found"; the allowlist is then out of sync and the page says restart
      cmds = commands.each_with_index.map do |c, at|
        r = by_name[c["command"]]
        r ? { at: at, found: r["found"], type: r["type"], path: r["path"] } : { at: at, found: nil, type: nil, path: nil }
      end
      in_sync = res["allowlist"] == commands && cmds.none? { |c| c[:found].nil? }
      [200, { checked_at: clock.epoch, elapsed_ms: ((clock.monotonic - t) * 1000).round, shell: res["shell"],
              harnesses: list, commands: cmds, allowlist_in_sync: in_sync, },]
    rescue LauncherClient::Unavailable => e
      [503, { error: e.message }]
    rescue LauncherClient::Refused => e
      return [501, { error: "the launcher does not know the harnesses op: restart it (deploy/install-launcher.sh)" }] \
        if e.message == "unknown op"

      [500, { error: e.message }]
    end

    # [the launch.commands item to add, nil] or [nil, why there is none]: a program file runs as is; a shell function or
    # alias exists only in `bash -ic`, so its line says via_shell: true — allowed only for a kind whose start is
    # confirmed by remote control (AgentSettings refuses via_shell for the others: their process is the command)
    def allow_line(h)
      via_shell = h["found"] == true && h["type"] != "file"
      if via_shell && !AgentsKanban::Launch::KINDS.fetch(h["kind"]).remote_control?
        return [nil, "#{h['command']} is a shell #{h['type']}: #{h['kind']} needs a program on PATH to launch"]
      end

      args = h["launch_args"].map { |a| a.match?(/\A[\w.-]+\z/) ? a : a.inspect }.join(", ")
      ["- { kind: #{h['kind']}, command: #{h['command']}, args: [#{args}], via_shell: #{via_shell} }", nil]
    end

    # the engine kinds' labels (config/harnesses.yml, read here — no launcher needed): the launcher table's groups
    def kind_labels = Harnesses.load.select(&:kind).to_h { |h| [h.kind, h.label] }

    # the Summary's daily report row: the current Settings → Daily report revision, validated as the host runs it
    # saved: a revision exists (none = never set up: the page says "not set up" + Edit, not the host's sentence)
    def daily_report(db, runners)
      saved = !DailyReportSettings.current_id(db).nil?
      state, out = DailyReportSettings.resolve(db, runners)
      return { configured: false, saved: saved, schedule: nil, reason: out } unless state == :ok

      { configured: true, saved: true, schedule: out.to_h[:schedule], reason: nil }
    end

    def complete(by:, db:, **)
      raise ArgumentError, "who finished the setup is required" if by.to_s.empty?

      db[TABLE].insert(author: by.to_s, created_at: Busyyaks::Clock.epoch)
      show(db: db, **)
    end

    def count(n, noun) = "#{n} #{noun}#{'s' unless n == 1}"

    def check(key, label, ok, detail) = { key: key, label: label, ok: ok, detail: detail }

    def database(env, db)
      check("database", "Database", true, "#{env.fetch('DATABASE_ADAPTER')} · #{db.tables.size} tables")
    end

    def scanner(scan)
      return check("scanner", "Project scanner", false, "no scan has finished yet (compose service scanner)") unless scan
      return check("scanner", "Project scanner", false, "last scan failed: #{scan[:error]}") if scan[:error]

      check("scanner", "Project scanner", true, "#{scan[:repos]} repos · finished #{Time.at(scan[:finished_at]).utc.iso8601}")
    end

    def launcher_check(launcher)
      n = launcher.sessions.size
      check("launcher", "Host launcher", true, count(n, "tmux session"))
    rescue LauncherClient::Unavailable, LauncherClient::Refused => e
      check("launcher", "Host launcher", false, e.message)
    end

    def agents_check(agents)
      return check("agents", "Agent launchers", false, agents[:error]) if agents[:error]

      doc = agents[:doc]
      check("agents", "Agent launchers", true,
            "#{count(doc['launchers'].size, 'launcher')} · #{count(doc['agent_types'].size, 'agent type')} · " \
            "revision #{agents[:revision][:id]}")
    end

    def github_check(github, env)
      last = github.last_run(env.fetch("GITHUB_LOGIN"))
      return check("github", "GitHub collector", false, "no GitHub collection has run yet (compose service github)") unless last
      return check("github", "GitHub collector", false, last[:error].to_s) unless last[:ok]

      check("github", "GitHub collector", true, "last run #{Time.at(last[:finished_at]).utc.iso8601}")
    end
  end
end
