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
