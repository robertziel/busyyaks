# frozen_string_literal: true

require "optparse"
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

    class Refused < StandardError; end
    class Usage < StandardError; end

    # home: the checkout · env: the process env (PATH, HOME) · runner: what spawns (Runner; a recording fake in tests)
    # os: `uname -s` · ruby: the running Ruby's version · http: Http (a fake in tests)
    Context = Data.define(:home, :env, :runner, :out, :err, :os, :ruby, :http) do
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
      ["env KEY...", "`export KEY='value'` lines from .env, for eval (bin/env)"],
      ["doctor", "every host tool the stack needs, per feature; exit 1 if one is missing"],
      ["help", "this list"],
    ].freeze

    module_function

    def run(argv, home:, env:, out: $stdout, err: $stderr, os: Host.os, ruby: RUBY_VERSION, runner: nil, http: Http)
      ctx = Context.new(home: home, env: env, runner: runner || Runner.new(env), out: out, err: err, os: os, ruby: ruby,
                        http: http)
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
      case (cmd = args.shift)
      when "server" then Server.run(ctx, args)
      when "panel" then Panel.run(ctx, args)
      when "env" then env(ctx, args)
      when "doctor" then Doctor.run(ctx, args)
      when "help", "-h", "--help" then ctx.out.puts(usage) || 0
      when nil then raise Usage, "no command"
      else raise Usage, "unknown command #{cmd.inspect}"
      end
    end

    def env(ctx, keys)
      raise Usage, "env needs at least one KEY" if keys.empty?

      ctx.out.puts EnvFile.shell_exports(ctx.dotenv, keys)
      0
    rescue EnvFile::Invalid => e
      raise Refused, e.message
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
require_relative "yaks/doctor"
