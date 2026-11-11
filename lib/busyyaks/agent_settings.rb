# frozen_string_literal: true

require "json"
require "yaml"
require_relative "../../vendor/agents_kanban/ruby/lib/agents_kanban/host_config"

module Busyyaks
  # The agent settings: the engine host config's `launchers` (the commands that start an agent session) and
  # `agent_types` (what a session IS), kept in the DATABASE as revisions (table agent_settings: the newest row is the
  # current one, every earlier one stays as history) and edited on Settings → Agents & launchers. Everything else of
  # the host config stays in the file (KANBAN_CONFIG), which may no longer carry these two keys — one place per value.
  #
  # The guard: a launcher runs ON THE HOST, and a revision is written by whoever holds a dashboard session. So the host
  # keeps the exact INVOCATIONS any launcher may be — config/busyyaks.yml `launch.commands`, a host file (mounted
  # read-only into the containers): each entry is a whole {kind, command, args, via_shell}, and a launcher must equal
  # one of them. A dashboard session picks among those and names them (key, label); it cannot add an argument (a
  # `--settings` with hooks, an `--mcp-config`, a permission mode) the host did not list. Refused when saved here AND
  # when bin/launcher starts it (the launcher rebuilds the engine config from the revision it is handed: what the
  # container sends is never trusted past this check). What stays editable — the model id (the engine's MODEL
  # alphabet) and the prompt — is what the session is told, the same reach a card comment to that session has.
  #
  # Pure Ruby (json, yaml, the engine's HostConfig; the db is any Sequel database passed in): bin/launcher on the host
  # requires this file alone.
  module AgentSettings
    KEYS = %w[launchers agent_types].freeze
    TABLE = :agent_settings
    # the repo default: what the migration seeds as the first revision
    TEMPLATE = File.expand_path("../../config/agents.template.yml", __dir__)
    COMMAND = AgentsKanban::HostConfig::LAUNCHER_COMMAND

    class Error < StandardError; end
    # a save based on a revision that is no longer the newest (someone saved in between): reload, then save again
    class Conflict < Error; end
    # the revision is refused: the engine's validation, or a command not on the host allowlist
    class Refused < Error; end

    module_function

    # The host config FILE as a hash, without the two keys (a file that still carries them is refused: they moved here).
    def file_hash(path)
      raw = YAML.safe_load_file(path)
      raise Error, "#{path}: the host config must be a mapping" unless raw.is_a?(Hash)

      left = raw.keys & KEYS
      if left.any?
        raise Error, "#{path}: #{left.join(', ')} moved to the database: Settings → Agents & launchers " \
                     "edits them; import the file's with `bin/agent-settings import <file>`, then delete them here"
      end
      raw
    rescue Psych::Exception, SystemCallError => e
      raise Error, "#{path}: #{e.message}"
    end

    # A revision's document: exactly {launchers, agent_types} (their contents are the engine's to validate).
    def doc!(doc)
      raise Refused, "agent settings must be an object {launchers, agent_types}" unless doc.is_a?(Hash)

      unknown = doc.keys - KEYS
      missing = KEYS - doc.keys
      raise Refused, "agent settings: unknown keys #{unknown.join(', ')}" if unknown.any?
      raise Refused, "agent settings: missing keys #{missing.join(', ')}" if missing.any?

      doc
    end

    # The engine's host config: the file's settings + a revision's launchers and agent types. The engine refuses a bad
    # value (AgentsKanban::ConfigError / Invalid) — its message is the refusal.
    def host(file, doc) = AgentsKanban::HostConfig.new(file.merge(doc!(doc)))

    def template = doc!(YAML.safe_load_file(TEMPLATE))

    # The host config the board migrations older than the agent settings table run on (20261116, 20261122, 20261130):
    # they read the file's board-wide keys (review_loop, the enums) and never a launcher or agent type, so the agent part
    # is the template's, only to make the engine accept the file.
    def migration_host(path) = host(file_hash(path), template)

    INVOCATION_KEYS = %w[kind command args via_shell].freeze

    # config/busyyaks.yml `launch.commands` (required, non-empty): the invocations a launcher may be on this host,
    # each {kind, command, args, via_shell} with every key (kind: the engine's Launch::KINDS; the engine checks the
    # rest again when a launcher uses it). Unique.
    def commands!(value)
      unless value.is_a?(Array) && !value.empty?
        raise Error, "launch.commands must list the invocations a launcher may be on this host: [{kind, command, args, " \
                     "via_shell}], e.g. [{kind: claude_code, command: claude, args: [], via_shell: false}]"
      end

      list = value.map.with_index { |v, i| invocation!(v, "launch.commands[#{i}]") }
      twice = list.tally.find { |_, n| n > 1 }
      raise Error, "launch.commands: duplicate entry #{twice.first.inspect}" if twice

      list.freeze
    end

    def invocation!(v, where)
      raise Error, "#{where} must be a mapping with exactly #{INVOCATION_KEYS.join(', ')}" \
        unless v.is_a?(Hash) && v.keys.sort == INVOCATION_KEYS.sort
      raise Error, "#{where}.kind must be one of #{AgentsKanban::Launch::KINDS.keys.join(', ')}" \
        unless AgentsKanban::Launch::KINDS.key?(v["kind"])
      raise Error, "#{where}.command must match #{COMMAND.source}" \
        unless v["command"].is_a?(String) && v["command"].match?(COMMAND)
      raise Error, "#{where}.args must be a list of non-empty strings" \
        unless v["args"].is_a?(Array) && v["args"].all? { |a| a.is_a?(String) && !a.empty? }
      raise Error, "#{where}.via_shell must be true or false" unless [true, false].include?(v["via_shell"])
      # bin/launcher confirms a kind with no remote control by its command running in the pane: a shell function or
      # alias never is a process, so such a launch could only fail after launch.start_seconds — refused here instead
      if v["via_shell"] && !AgentsKanban::Launch::KINDS.fetch(v["kind"]).remote_control?
        raise Error, "#{where}: a #{v['kind']} invocation cannot be via_shell (its start is confirmed by the command's process)"
      end

      v.slice(*INVOCATION_KEYS).freeze
    end

    def invocation(l) = { "kind" => l.kind, "command" => l.command, "args" => l.args.to_a, "via_shell" => l.via_shell }
    def line(inv) = [inv["command"], *inv["args"]].join(" ") + (inv["via_shell"] ? " (via shell)" : "")

    # Every launcher equals one allowlisted invocation, else refused with the ones that do not.
    def allowed!(cfg, commands)
      off = cfg.launchers.reject { |l| commands.include?(invocation(l)) }
      return cfg if off.empty?

      raise Refused, "#{off.map { |l| "launcher #{l.key} (#{l.kind}: #{line(invocation(l))})" }.join(', ')}: not an " \
                     "invocation on this host's allowlist config/busyyaks.yml launch.commands " \
                     "(#{commands.map { |c| "#{c['kind']}: #{line(c)}" }.join('; ')})"
    end

    # The newest revision: {id, doc, author, at}; none → raised (the migration seeds one: a missing row is a broken DB).
    def current(db)
      row = db[TABLE].reverse(:id).first
      raise Error, "no agent settings revision in #{TABLE}: run the migrations (20261202000000 seeds the template)" if row.nil?

      { id: row[:id], doc: JSON.parse(row[:doc]), author: row[:author], at: row[:created_at] }
    end

    def current_id(db) = db[TABLE].max(:id)

    def history(db, limit: 20)
      db[TABLE].reverse(:id).limit(limit).select(:id, :author, :created_at).all
               .map { |r| { id: r[:id], author: r[:author], at: r[:created_at] } }
    end

    # Write a new revision from `doc`, based on revision `base` (the one the editor loaded): validated by the engine
    # against the file's settings, every command on `commands`, `base` still the newest → the new revision's id.
    def save!(db, file:, doc:, base:, author:, commands:, clock: -> { Time.now.to_i })
      begin
        allowed!(host(file, doc), commands)
      rescue AgentsKanban::ConfigError, AgentsKanban::Invalid => e
        raise Refused, e.message
      end
      raise Refused, "author is required" if author.to_s.empty?

      db.transaction do
        now = current_id(db)
        raise Conflict, "revision #{base} is not the newest (#{now} is): reload, then save again" unless now == base

        db[TABLE].insert(doc: JSON.generate(doc), author: author.to_s, created_at: clock.call)
      end
    end
  end
end
