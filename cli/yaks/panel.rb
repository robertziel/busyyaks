# frozen_string_literal: true

require_relative "../../lib/busyyaks/dashboard_url"

module Busyyaks
  module CLI
    # `yaks panel`: opens the dashboard (DashboardUrl.origin: https://PUBLIC_HOST, or http://127.0.0.1:WEB_HOST_PORT
    # while PUBLIC_HOST is empty) with xdg-open — the Linux desktop's opener; not on PATH → refused. Only from a
    # graphical session (DISPLAY or WAYLAND_DISPLAY set): over ssh / in tmux there is no browser to open, so it is refused
    # at once, naming why (xdg-open would try every text browser first). `--print` prints the URL instead (the
    # operator's choice, e.g. on a box without a desktop).
    module Panel
      module_function

      def run(ctx, args)
        print_only = false
        CLI.parse!(OptionParser.new { |o| o.on("--print") { print_only = true } }, args)
        CLI.no_more!(args)
        url = begin
          DashboardUrl.origin(ctx.dotenv)
        rescue DashboardUrl::Invalid => e
          raise Refused, ".env: #{e.message}"
        end
        return ctx.out.puts(url) || 0 if print_only
        unless Panel.graphical?(ctx.env)
          raise Refused, "no graphical session here (DISPLAY and WAYLAND_DISPLAY are unset): run yaks panel from a " \
                         "desktop session, or yaks panel --print for the URL (#{url})"
        end
        raise Refused, "xdg-open failed to open #{url}" unless ctx.runner.system("xdg-open", url)

        0
      end

      def graphical?(env) = %w[DISPLAY WAYLAND_DISPLAY].any? { |k| env[k].to_s != "" }
    end
  end
end
