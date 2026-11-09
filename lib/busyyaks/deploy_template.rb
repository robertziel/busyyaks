# frozen_string_literal: true

module Busyyaks
  # Renders the reverse-proxy templates under deploy/ (`*.template`) from the deployment's .env, so no host, port or
  # certificate path is written into the repo. A placeholder is a NAME in double braces (nginx's own `$host` etc. stay
  # untouched). Every placeholder must have a non-empty, well-formed value: a missing or malformed one is an error
  # naming it, never a blank, a guess or a default. Pure Ruby, no dependencies: bin/render-deploy (host) requires
  # this file alone.
  module DeployTemplate
    PLACEHOLDER = /\{\{([A-Z0-9_]+)\}\}/

    class MissingValues < StandardError; end

    HOSTNAME = /\A(?=.{1,253}\z)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\z/i
    PORT = ->(p) { p.match?(/\A\d{1,5}\z/) && p.to_i.between?(1, 65_535) }
    UPSTREAM = lambda do |v|
      m = v.match(/\A(?:\[([0-9a-f:]+)\]|([^:\[\]]+)):(\d+)\z/i)
      m && (m[1] || m[2].match?(HOSTNAME)) && PORT.call(m[3])
    end
    PATH = %r{\A/[^\s;{}'"$]+\z}
    # The shape each value must have before it is written into an nginx / frpc file (a `;` or space would add a directive).
    FORMATS = {
      "PUBLIC_HOST" => [->(v) { v.match?(HOSTNAME) }, "a hostname"],
      "FRPC_SUBDOMAIN" => [->(v) { v.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i) }, "one DNS label"],
      "PROXY_UPSTREAM" => [UPSTREAM, "host:port (a hostname, IPv4 or [IPv6] and a port 1-65535)"],
      "WEB_HOST_PORT" => [PORT, "a port number 1-65535"],
      "TLS_CERT_PATH" => [->(v) { v.match?(PATH) }, "an absolute path without spaces or ; { } quotes $"],
      "TLS_KEY_PATH" => [->(v) { v.match?(PATH) }, "an absolute path without spaces or ; { } quotes $"],
    }.freeze

    # Values computed from other .env entries (one place per value), never read from .env themselves: nginx's upload
    # cap must cover the app's ATTACHMENT_MAX_BYTES plus multipart overhead (5 MiB).
    DERIVED = {
      "NGINX_MAX_BODY" => lambda do |env|
        bytes = env["ATTACHMENT_MAX_BYTES"]
        raise MissingValues, "ATTACHMENT_MAX_BYTES in .env must be a whole number of bytes (got #{bytes.to_s.inspect})" \
          unless bytes.to_s.match?(/\A\d+\z/)

        "#{(bytes.to_i / (1024 * 1024.0)).ceil + 5}m"
      end,
    }.freeze

    # env: the .env as KEY → value (Busyyaks::EnvFile, the one .env reader).
    def self.render(template, env)
      own = env.keys & DERIVED.keys
      raise MissingValues, "#{own.join(', ')} must not be set in .env: computed by bin/render-deploy" unless own.empty?

      names = template.scan(PLACEHOLDER).flatten.uniq
      values = names.to_h { |k| [k, DERIVED.key?(k) ? DERIVED[k].call(env) : env[k].to_s.strip] }
      missing = names.select { |k| values[k].empty? }
      raise MissingValues, "missing in .env: #{missing.join(', ')}" unless missing.empty?

      bad = names.select { |k| FORMATS.key?(k) && !FORMATS[k][0].call(values[k]) }
      raise MissingValues, bad.map { |k| "#{k} in .env must be #{FORMATS[k][1]} (got #{values[k].inspect})" }.join("; ") \
        unless bad.empty?

      template.gsub(PLACEHOLDER) { values.fetch(Regexp.last_match(1)) }
    end
  end
end
