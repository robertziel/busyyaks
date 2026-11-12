# frozen_string_literal: true

require_relative "agent_settings_api"
require_relative "config"
require_relative "launcher_client"

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
      },]
    end

    def complete(by:, db:, **)
      raise ArgumentError, "who finished the setup is required" if by.to_s.empty?

      db[TABLE].insert(author: by.to_s, created_at: Time.now.to_i)
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
