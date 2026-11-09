# frozen_string_literal: true

require "ipaddr"

module Busyyaks
  # THE .env reader of every host-side program (bin/launcher, bin/render-deploy, bin/env for the shell scripts). Docker
  # compose reads the same file, so only what every reader takes the same way is accepted:
  #
  #   KEY=value            KEY="value"            KEY='value'            # a comment line            (blank lines)
  #
  # Anything a reader would rewrite differently is an error naming the line, never guessed: a `$` (compose and the shell
  # interpolate it), an inline comment (` #` after a value: compose cuts it, a plain split kept it), a backslash inside
  # double quotes (escapes), an unclosed quote or a quote inside the value, `export `, spaces around `=`, a key given twice.
  # Pure Ruby, no dependencies: host scripts require this file alone.
  module EnvFile
    class Invalid < StandardError; end

    KEY = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    # Values with a required shape, checked wherever they are read (bin/env, the MCP server's boot): MCP_HOST is the
    # address the MCP port is published on — loopback only, the MCP is never exposed (IPv4: it is written into URLs bare).
    SHAPES = {
      "MCP_HOST" => [->(v) { (ip = IPAddr.new(v)).ipv4? && ip.loopback? && v.match?(/\A[\d.]+\z/) },
                     "an IPv4 loopback address (127.0.0.1 … 127.255.255.254): the MCP is never exposed",],
    }.freeze

    module_function

    def read(path)
      raise Invalid, "no .env at #{path} (cp .env.example .env)" unless File.file?(path)

      parse(File.read(path), path: path)
    end

    # → { "KEY" => "value" }
    def parse(text, path:)
      text.each_line.with_index(1).each_with_object({}) do |(line, n), h|
        line = line.chomp
        next if line.strip.empty? || line.lstrip.start_with?("#")

        where = "#{path}:#{n}"
        raise Invalid, "#{where}: not KEY=value" unless line.include?("=")

        key, raw = line.split("=", 2)
        unless key.match?(KEY)
          raise Invalid, "#{where}: #{key.inspect} is not a variable name (no `export `, no spaces around =)"
        end
        raise Invalid, "#{where}: #{key} is set twice" if h.key?(key)

        h[key] = value(raw, "#{where}: #{key}")
      end
    end

    def value(raw, where)
      if raw.start_with?('"', "'")
        m = raw.match(/\A(["'])([^"']*)\1\z/)
        raise Invalid, "#{where}: an unclosed quote, a quote inside the value, or text after the closing quote" unless m
        if m[1] == '"' && m[2].include?("\\")
          raise Invalid, "#{where}: a backslash inside double quotes (escapes are not supported)"
        end

        raw = m[2]
      elsif raw.match?(/\s#/)
        raise Invalid, "#{where}: an inline comment (` #`): put comments on their own line"
      elsif raw.match?(/\s/)
        raise Invalid, "#{where}: an unquoted value with spaces: quote it"
      end
      raise Invalid, "#{where}: a `$` (variable interpolation is not supported): write the value out" if raw.include?("$")

      raw
    end

    # A value of SHAPES must have its shape: → the value, or Invalid naming the key.
    def shape!(key, value)
      check, what = SHAPES[key]
      return value unless check

      ok = begin
        check.call(value)
      rescue IPAddr::Error
        false
      end
      ok ? value : raise(Invalid, "#{key} must be #{what} (got #{value.inspect})")
    end

    # `export KEY='value'` lines for `eval` in a shell script (bin/env), each value single-quoted.
    def shell_exports(env, keys)
      missing = keys.reject { |k| env.key?(k) && !env[k].empty? }
      raise Invalid, ".env: missing or empty #{missing.join(', ')}" unless missing.empty?

      keys.each { |k| shape!(k, env[k]) }

      keys.map { |k| "export #{k}='#{env[k].gsub("'", %q('\\\\''))}'" }.join("\n")
    end
  end
end
