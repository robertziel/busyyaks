# frozen_string_literal: true

require "etc"
require "json"
require "optparse"
require_relative "../lib/busyyaks/clock"
require_relative "../lib/busyyaks/env_file"
require_relative "../lib/busyyaks/deploy_template"

module Busyyaks
  # `yaks`: the operator's command line over one busyyaks checkout (bin/yaks, reached through a symlink on PATH).
  # A host program like bin/launcher, so it lives in cli/, outside lib/ (the services' code: autoloaded, and never
  # spawning — test/unit/no_git_spawn_test.rb); it requires only the pure files of lib/busyyaks it names.
  # The checkout IS the install: `home` = the real path of bin/yaks's parent — the one place that says which checkout
  # `yaks` runs, no env var, no search. Every command wraps what the checkout already runs (docker compose, bin/env,
  # the deploy/ installers) and never re-implements it. Pure Ruby stdlib: the host has no bundler.
  #
  # Exit codes: 0 done · 1 failed or refused (the reason on stderr) · 2 usage.
  module CLI
    # The host Ruby `yaks` (and bin/launcher, bin/env) is written for; older → refused at start. The suite's `host`
    # gate runs the host-side tests on this version (scripts/ci/test.sh host).
    MIN_RUBY = "3.2"
    # The stack's long-running services: every compose service without a `profiles:` key (test/unit/compose_test.rb).
    SERVICES = %w[web mcp scanner github notifier].freeze

    # the commands that run the stack (Host.stack!: Linux only); desktop and help run on any Unix with a desktop
    STACK_COMMANDS = %w[server panel env doctor].freeze

    class Refused < StandardError; end
    class Usage < StandardError; end

    # home: the checkout · env: the process env (PATH, HOME) · runner: what spawns (Runner; a recording fake in tests)
    # os: `uname -s` · ruby: the running Ruby's version · http: Http (a fake in tests)
    Context = Data.define(:home, :env, :runner, :out, :err, :os, :ruby, :http, :stdin) do
      # .env of this checkout (the one reader); a missing or malformed file → Refused naming it
      def dotenv
        EnvFile.read(File.join(home, ".env"))
      rescue EnvFile::Invalid => e
        raise Refused, e.message
      end

      # .env's value of each key: one missing or empty → Refused naming every one; a port that is not one, or an
      # MCP_HOST that is not loopback (EnvFile::SHAPES: the bearer is never sent elsewhere) → Refused naming the key
      def dotenv_values(*keys)
        values = dotenv
        missing = keys.reject { |k| values[k].to_s != "" }
        raise Refused, ".env: missing or empty #{missing.join(', ')}" unless missing.empty?

        keys.each { |k| CLI.shape!(k, values[k]) }
        values.slice(*keys)
      end

      def compose(*args) = ["docker", "compose", "--project-directory", home, "-f", File.join(home, "docker-compose.yml"),
                            *args,]
    end

    COMMANDS = [
      ["server status", "every service, /up, MCP tools/list, the launcher unit and its socket; exit 1 if any is down"],
      ["server logs [SERVICE] [-f]", "docker compose logs of the stack (or of one service); -f follows"],
      ["panel [--print]", "open the dashboard in the browser (xdg-open); --print prints its URL instead"],
      ["desktop install --browser NAME", "busyyaks in the app menu: the server chooser in its own window (Linux, BSD, macOS)"],
      ["desktop open --browser NAME", "the chooser now: Local (the default) and the saved servers, each in its own window"],
      ["desktop uninstall", "remove that entry"],
      ["env KEY...", "`export KEY='value'` lines from .env, for eval (bin/env)"],
      ["env --ports", "this server's host name and ports as JSON (what `yaks remote connect` asks over ssh)"],
      ["remote add|remove TARGET", "save / forget a busyyaks server reached over ssh (a Host alias or user@host)"],
      ["remote list", "the saved servers (connects to nothing)"],
      ["remote connect TARGET [--mcp]", "forward its dashboard (and MCP) to this machine over ssh, until ssh ends"],
      ["remote attach TARGET SESSION", "an agent's terminal on that server, here, over ssh"],
      ["remote --stdio", "server side of attach: ssh's stdin/stdout ↔ the launcher socket"],
      ["doctor", "every host tool the stack needs, per feature, and the first start's checks; exit 1 if one fails"],
      ["help", "this list"],
    ].freeze

    module_function

    def run(argv, home:, env:, out: $stdout, err: $stderr, os: Host.os, ruby: RUBY_VERSION, runner: nil, http: Http,
            stdin: $stdin)
      ctx = Context.new(home: home, env: env, runner: runner || Runner.new(env), out: out, err: err, os: os, ruby: ruby,
                        http: http, stdin: stdin)
      Host.check!(ctx)
      dispatch(ctx, argv.dup)
    rescue Usage => e
      err.puts "yaks: #{e.message}", "", usage
      2
    rescue Refused => e
      err.puts "yaks: #{e.message}"
      1
    end

    def dispatch(ctx, args)
      cmd = args.shift
      # the stack's commands need Linux; an unknown name falls through to the usage error first
      Host.stack!(ctx) if STACK_COMMANDS.include?(cmd)
      case cmd
      when "server" then Server.run(ctx, args)
      when "panel" then Panel.run(ctx, args)
      when "desktop" then Desktop.run(ctx, args)
      when "remote" then Remote.run(ctx, args)
      when "env" then env(ctx, args)
      when "doctor" then Doctor.run(ctx, args)
      when "help", "-h", "--help" then ctx.out.puts(usage) || 0
      when nil then raise Usage, "no command"
      else raise Usage, "unknown command #{cmd.inspect}"
      end
    end

    def env(ctx, keys)
      return ports(ctx, keys.drop(1)) if keys.first == "--ports"
      raise Usage, "env needs at least one KEY" if keys.empty?

      ctx.out.puts EnvFile.shell_exports(ctx.dotenv, keys)
      0
    rescue EnvFile::Invalid => e
      raise Refused, e.message
    end

    # `env --ports`: what a remote `yaks remote connect` forwards — this machine's name and the loopback ports
    # web and MCP are published on. No secret: the MCP bearer stays here.
    def ports(ctx, args)
      no_more!(args)
      env = ctx.dotenv_values("WEB_HOST_PORT", "MCP_HOST", "MCP_HOST_PORT")
      ctx.out.puts JSON.generate(host: Etc.uname.fetch(:nodename), web_port: Integer(env["WEB_HOST_PORT"]),
                                 mcp_host: env["MCP_HOST"], mcp_port: Integer(env["MCP_HOST_PORT"]))
      0
    end

    # Parses `args` with `opts` (an OptionParser); an unknown flag is a usage error naming it.
    def parse!(opts, args)
      opts.parse!(args)
    rescue OptionParser::ParseError => e
      raise Usage, e.message
    end

    # .env values with a required shape, checked before they are used: the ports (DeployTemplate::PORT) and
    # EnvFile::SHAPES (MCP_HOST)
    PORTS = %w[WEB_HOST_PORT MCP_HOST_PORT].freeze

    def shape!(key, value)
      raise Refused, ".env: #{key} must be a port number 1-65535 (got #{value.inspect})" \
        if PORTS.include?(key) && !DeployTemplate::PORT.call(value)

      EnvFile.shape!(key, value)
    rescue EnvFile::Invalid => e
      raise Refused, ".env: #{e.message}"
    end

    def no_more!(args)
      raise Usage, "unexpected #{args.join(' ').inspect}" unless args.empty?
    end

    def usage
      width = COMMANDS.map { |c, _| c.size }.max
      ["usage: yaks <command>", "", *COMMANDS.map { |c, what| "  yaks #{c.ljust(width)}  #{what}" }].join("\n")
    end
  end
end

# the commands (after CLI's constants, which they read)
require_relative "yaks/runner"
require_relative "yaks/host"
require_relative "yaks/http"
require_relative "yaks/server"
require_relative "yaks/panel"
require_relative "yaks/desktop"
require_relative "yaks/remote"
require_relative "yaks/chooser"
require_relative "yaks/doctor"
