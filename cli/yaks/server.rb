# frozen_string_literal: true

require_relative "../../lib/busyyaks/dashboard_url"

module Busyyaks
  module CLI
    # `yaks server …`: the compose stack of this checkout. Every compose call names its project dir and file (works from
    # any cwd; compose reads .env and COMPOSE_PROFILES there, as `docker compose` in the checkout does).
    module Server
      LAUNCHER_UNIT = "busyyaks-launcher.service"
      # compose services `logs` takes: the stack's + the postgres profile's
      LOG_SERVICES = [*SERVICES, "postgres"].freeze

      module_function

      def run(ctx, args)
        case (sub = args.shift)
        when "status"
          CLI.no_more!(args)
          status(ctx)
        when "logs" then logs(ctx, args)
        when nil then raise Usage, "server needs a subcommand (status, logs)"
        else raise Usage, "unknown server subcommand #{sub.inspect}"
        end
      end

      def logs(ctx, args)
        follow = false
        CLI.parse!(OptionParser.new { |o| o.on("-f", "--follow") { follow = true } }, args)
        raise Usage, "logs takes at most one SERVICE" if args.size > 1
        if args.any? && !LOG_SERVICES.include?(args.first)
          raise Usage, "unknown service #{args.first.inspect} (#{LOG_SERVICES.join(', ')})"
        end

        ctx.runner.exec(*ctx.compose("logs", *("--follow" if follow), *args))
        0
      end

      # One row per check, `ok` or `FAIL` + why; exit 1 when any failed.
      def status(ctx)
        env = ctx.dotenv_values("WEB_HOST_PORT", "MCP_HOST", "MCP_HOST_PORT", "MCP_TOKEN", "LAUNCHER_RUN_DIR")
        rows = services(ctx) + [web(ctx, env), mcp(ctx, env), launcher_unit(ctx), launcher_socket(env)]
        width = rows.map { |name, _, _| name.size }.max
        rows.each { |name, ok, what| ctx.out.puts "#{(ok ? 'ok' : 'FAIL').ljust(4)}  #{name.ljust(width)}  #{what}" }
        rows.all? { |_, ok, _| ok } ? 0 : 1
      end

      def services(ctx)
        out, ok = ctx.runner.capture(*ctx.compose("ps", "--services", "--status", "running"))
        return [["compose", false, "docker compose ps failed"]] unless ok

        running = out.split
        SERVICES.map { |s| [s, running.include?(s), running.include?(s) ? "running" : "not running"] }
      end

      # DashboardUrl::LOOPBACK, not a value: compose publishes web on loopback only, written out
      # ("127.0.0.1:${WEB_HOST_PORT}" in docker-compose.yml; HostGuard answers that Host) — unlike MCP, whose address
      # is .env MCP_HOST
      def web(ctx, env)
        port = env.fetch("WEB_HOST_PORT")
        host = DashboardUrl::LOOPBACK
        code, = ctx.http.get(host, port, "/up", { "Host" => "#{host}:#{port}" })
        ["web /up", code == 200, "HTTP #{code}"]
      rescue Http::Down => e
        ["web /up", false, e.message]
      end

      # the stateless tools/list a deploy checks (docs/DEPLOY.md); the bearer goes in a header, never in argv
      def mcp(ctx, env)
        body = JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/list")
        headers = { "Authorization" => "Bearer #{env.fetch('MCP_TOKEN')}", "Content-Type" => "application/json" }
        code, res = ctx.http.post(env.fetch("MCP_HOST"), env.fetch("MCP_HOST_PORT"), "/mcp", headers, body)
        return ["mcp tools/list", false, "HTTP #{code}"] unless code == 200

        answer = JSON.parse(res)
        return ["mcp tools/list", false, "the answer is not a JSON object"] unless answer.is_a?(Hash)

        tools = answer.dig("result", "tools")
        return ["mcp tools/list", false, "no tools in the answer"] unless tools.is_a?(Array)

        ["mcp tools/list", true, "#{tools.size} tools"]
      rescue Http::Down => e
        ["mcp tools/list", false, e.message]
      rescue JSON::ParserError
        ["mcp tools/list", false, "the answer is not JSON"]
      end

      def launcher_unit(ctx)
        out, ok = ctx.runner.capture("systemctl", "--user", "is-active", LAUNCHER_UNIT)
        [LAUNCHER_UNIT, ok, out.strip.empty? ? "systemctl --user is-active failed" : out.strip]
      end

      def launcher_socket(env)
        sock = File.join(env.fetch("LAUNCHER_RUN_DIR"), "launcher.sock")
        ["launcher socket", File.socket?(sock), File.socket?(sock) ? sock : "#{sock}: no socket"]
      end
    end
  end
end
