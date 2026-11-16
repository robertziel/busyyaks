# frozen_string_literal: true

require "yaml"

module Busyyaks
  module CLI
    # `yaks doctor`: each host tool README § Requirements names, with the features that need it — the daily report's
    # only when config/busyyaks.yml has `daily_report_runners` (what the host may run for it; the settings themselves are
    # in the database). One row per tool, plus one for that file (missing, unreadable or still holding the
    # moved `daily_report` block: FAIL, and the daily report's tools are not asked); exit 1 when one is missing.
    # `yaks panel`'s needs (xdg-open, a graphical session) are OPTIONAL — a server without a desktop runs the stack
    # fine: shown `miss`, never counted.
    # Then the first start's checks, read-only — `bin/setup check` makes what they look for: `.env` parses
    # and every key docker-compose.yml requires is set, config/kanban.yml is there, HOST_UID:HOST_GID is this user,
    # PROJECTS_ROOT is a directory written as its real path, ./data and LAUNCHER_RUN_DIR exist and are this user's
    # (the run dir 0700). A missing .env is one FAIL row; the rows that read it are then not asked.
    module Doctor
      TOOLS = [
        ["docker", "the stack (yaks server)"],
        ["git", "the launcher"],
        ["tmux", "the launcher"],
        ["claude", "the launcher"],
        ["systemctl", "the launcher, the daily report (systemd --user)"],
        ["xdg-open", "yaks panel"],
      ].freeze
      DAILY = %w[jq curl flock timeout].freeze
      OPTIONAL = ["xdg-open", "graphical session"].freeze
      MOVED = "daily_report moved to Settings → Daily report: bin/daily-report-settings import, then remove it"

      module_function

      def run(ctx, args)
        CLI.no_more!(args)
        rows = TOOLS.map { |t, why| tool(ctx, t, why) }
        rows << compose(ctx) << user_manager(ctx) << graphical(ctx)
        config, daily = config(ctx)
        rows << config
        rows += DAILY.map { |t| tool(ctx, t, "the daily report") } if daily
        rows << ["ruby", true, "#{ctx.ruby} (>= #{MIN_RUBY})", "yaks, the launcher, bin/env"]
        rows += first_start(ctx)
        width = rows.map { |t, _, _, _| t.size }.max
        found = rows.map { |_, _, f, _| f.size }.max
        rows.each do |t, ok, f, why|
          mark = if ok then "ok" else OPTIONAL.include?(t) ? "miss" : "FAIL" end
          ctx.out.puts "#{mark.ljust(4)}  #{t.ljust(width)}  #{f.ljust(found)}  #{why}"
        end
        rows.all? { |t, ok, _, _| ok || OPTIONAL.include?(t) } ? 0 : 1
      end

      def graphical(ctx)
        ok = Panel.graphical?(ctx.env)
        ["graphical session", ok, ok ? "DISPLAY / WAYLAND_DISPLAY set" : "none (ssh / tmux): yaks panel --print", "yaks panel"]
      end

      def tool(ctx, name, why)
        path = ctx.runner.which(name)
        [name, !path.nil?, path || "not on PATH", why]
      end

      def compose(ctx)
        out, ok = ctx.runner.which("docker") ? ctx.runner.capture("docker", "compose", "version", "--short") : ["", false]
        ["docker compose", ok, ok ? out.strip : "the compose plugin is missing", "the stack (yaks server)"]
      end

      def user_manager(ctx)
        ok = ctx.runner.which("systemctl") && ctx.runner.capture("systemctl", "--user", "show-environment").last
        ["systemd --user", ok == true, ok ? "running" : "no user manager (loginctl enable-linger)",
         "the launcher, the daily report",]
      end

      SETUP = "the first start (bin/setup check)"

      # the first start's rows (module comment)
      def first_start(ctx)
        values = EnvFile.read(File.join(ctx.home, ".env"))
        [env_row(ctx, values), kanban_row(ctx), user_row(values), projects_row(values),
         owned_dir("./data", File.join(ctx.home, "data"), values["HOST_UID"]),
         owned_dir("LAUNCHER_RUN_DIR", values["LAUNCHER_RUN_DIR"], values["HOST_UID"], mode: 0o700),]
      rescue EnvFile::Invalid => e
        [[".env", false, e.message.sub(/ \(cp .env.example .env\)\z/, ": bin/setup"), SETUP]]
      end

      def env_row(ctx, values)
        compose = File.join(ctx.home, "docker-compose.yml")
        return [".env", false, "no docker-compose.yml beside it", SETUP] unless File.file?(compose)

        required = EnvFile.compose_required(File.read(compose))
        empty = required.select { |k| values[k].to_s.empty? }
        found = empty.empty? ? "the #{required.size} keys compose requires set" : "empty: #{empty.join(', ')}"
        [".env", empty.empty?, found, SETUP]
      end

      def kanban_row(ctx)
        ok = File.file?(File.join(ctx.home, "config/kanban.yml"))
        ["config/kanban.yml", ok, ok ? "present" : "missing: bin/setup", SETUP]
      end

      def user_row(values)
        mine = "#{Process.uid}:#{Process.gid}"
        set = "#{values['HOST_UID']}:#{values['HOST_GID']}"
        ["HOST_UID:HOST_GID", set == mine, set == mine ? "#{set} (you)" : "#{set}, you are #{mine}", SETUP]
      end

      def projects_row(values)
        root = values["PROJECTS_ROOT"].to_s
        found = if root.empty? then "empty in .env"
                elsif !File.directory?(root) then "#{root}: not a directory"
                elsif File.realpath(root) != root then "#{root} is not its real path: write #{File.realpath(root)}"
                end
        ["PROJECTS_ROOT", found.nil?, found || root, SETUP]
      end

      # a dir that must exist, owned by HOST_UID (and have `mode`, when given)
      def owned_dir(name, path, uid, mode: nil)
        return [name, false, "empty in .env", SETUP] if path.to_s.empty?

        st = File.stat(path)
        found = if !st.directory? then "#{path}: not a directory"
                elsif st.uid.to_s != uid.to_s then "#{path} is owned by uid #{st.uid}, not HOST_UID #{uid}"
                elsif mode && (st.mode & 0o777) != mode then format("%s has mode %o, not %o", path, st.mode & 0o777, mode)
                end
        [name, found.nil?, found || path, SETUP]
      rescue SystemCallError
        [name, false, "#{path}: missing (bin/setup check creates it)", SETUP]
      end

      # → [row, whether it has `daily_report_runners`]
      def config(ctx)
        file = File.join(ctx.home, "config/busyyaks.yml")
        unless File.file?(file)
          return [["config/busyyaks.yml", false, "missing: cp config/busyyaks.example.yml config/busyyaks.yml",
                   "every service",], false,]
        end

        doc = YAML.safe_load_file(file)
        doc = {} unless doc.is_a?(Hash)
        if doc.key?("daily_report")
          return [["config/busyyaks.yml", false, MOVED, "every service"], false]
        end

        daily = doc.key?("daily_report_runners")
        [["config/busyyaks.yml", true, daily ? "daily_report_runners set" : "no daily_report_runners", "every service"],
         daily,]
      rescue Psych::Exception, SystemCallError => e
        [["config/busyyaks.yml", false, e.message.lines.first.strip, "every service"], false]
      end
    end
  end
end
