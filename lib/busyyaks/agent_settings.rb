# frozen_string_literal: true

require "json"
require "yaml"
require_relative "../../vendor/agents_kanban/ruby/lib/agents_kanban/host_config"
require_relative "clock"
require_relative "launcher_rules"

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
    # busyyaks's own per-type keys `opt_in` and `color` are checked and taken out first: the engine never
    # sees them. A type's colour goes into the theme as its face token (over the file's), so every face of the type —
    # the board (its inline theme), the shell's :root, the lanes, the sidebar — wears it.
    def host(file, doc)
      d = doc!(doc)
      types = d["agent_types"]
      return AgentsKanban::HostConfig.new(file.merge(d)) unless types.is_a?(Array) # the engine's refusal

      types.each { |t| busyyaks_keys!(t) if t.is_a?(Hash) }
      AgentsKanban::HostConfig.new(themed(file, types).merge(
                                     d.merge("agent_types" => types.map { |t| t.is_a?(Hash) ? t.except(*OWN) : t })
                                   ))
    end

    # the file with the types' face colours over its theme (a theme that is no mapping: the engine's refusal, as is)
    def themed(file, types)
      tokens = face_tokens(types)
      return file if tokens.empty? || !file["theme"].is_a?(Hash)

      file.merge("theme" => file["theme"].merge(tokens))
    end

    def busyyaks_keys!(t)
      opt_in!(t)
      color!(t)
    end

    # A type's face colour: one name of COLORS — skin tokens, so it reads in every skin; absent = the theme's
    # token for the type, else the engine's hue hashed from the key. Defined here once: the page's swatches are these.
    COLOR = "color"
    COLORS = {
      "blue" => "var(--vivid-blue)", "green" => "var(--vivid-green)", "orange" => "var(--vivid-orange)",
      "red" => "var(--vivid-red)", "yellow" => "var(--vivid-yellow)", "purple" => "var(--vivid-purple)",
      "teal" => "var(--vivid-teal)", "pink" => "var(--vivid-pink)",
      "gold" => "color-mix(in srgb, var(--vivid-yellow) 70%, var(--ink))",
    }.freeze

    def color!(t)
      return unless t.key?(COLOR)
      return if COLORS.key?(t[COLOR])

      raise AgentsKanban::ConfigError, "agent type #{t['key']}: color must be one of #{COLORS.keys.join(', ')} " \
                                       "(got #{t[COLOR].inspect})"
    end

    # {"--ak-face-type-<key>" => css} of the types that name a colour
    def face_tokens(types)
      types.select { |t| t.is_a?(Hash) && COLORS.key?(t[COLOR]) && t["key"].is_a?(String) }
           .to_h { |t| ["--ak-face-type-#{t['key'].gsub(/[^a-zA-Z0-9_-]/, '-')}", COLORS.fetch(t[COLOR])] }
    end

    # OPT-IN agent types: `opt_in: true` on a type = a board runs it only when its repo's
    # .busyyaks/agents.yml lists it under `use` (ProjectAgents) — a copywriter exists for every board and joins none
    # uninvited. Only the lead starts one, for a card: so it runs `under` a lead and is `launchable: false` (never on a
    # Launch bar a board did not ask for). Absent / false = every board runs it, as before.
    OPT_IN = "opt_in"
    # the per-type keys that are busyyaks's, never the engine's
    OWN = [OPT_IN, COLOR].freeze

    def opt_in!(t)
      return unless t.key?(OPT_IN)

      v = t[OPT_IN]
      raise AgentsKanban::ConfigError, "agent type #{t['key']}: opt_in must be true or false" unless [true, false].include?(v)
      return unless v && !(t["under"] && t["launchable"] == false)

      raise AgentsKanban::ConfigError,
            "agent type #{t['key']}: opt_in: true needs `under: <lead type>` and `launchable: false` — an opt-in type " \
            "is started only by its lead, for a card on a board whose .busyyaks/agents.yml uses it"
    end

    # The opt-in type keys of a revision's doc
    def opt_in(doc) = doc.fetch("agent_types").select { |t| t[OPT_IN] == true }.map { |t| t["key"] }

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

    # The revision with every agent type's session_name carrying LauncherRules::SESSION_PREFIX (the `by_` rename,
    # 2026-11-24) → the new doc, or nil when every name has it already (nothing to write).
    def prefixed(doc)
      types = doc.fetch("agent_types")
      return nil if types.all? { |t| t["session_name"].to_s.start_with?(LauncherRules::SESSION_PREFIX) }

      doc.merge("agent_types" => types.map do |t|
        name = t["session_name"].to_s
        name.start_with?(LauncherRules::SESSION_PREFIX) ? t : t.merge("session_name" => "#{LauncherRules::SESSION_PREFIX}#{name}")
      end)
    end

    # The lead's NAME (2026-11-25, the operator: "what's sub team? where is lead?"): a type's label is what it IS — the
    # pages, the Launch bar and the board's "no lead: press …" all show it — and "Launch" was the old lead type's label,
    # a button text, not a name. The revision with every lead type (one another type runs `under`) labelled "Launch"
    # renamed TEAM_LEAD → the new doc, or nil when none is (nothing to write).
    TEAM_LEAD = "Team lead"
    OLD_LEAD_LABEL = "Launch"

    def lead_named(doc)
      types = doc.fetch("agent_types")
      leads = types.map { |t| t["under"] }.compact
      renamed = types.map do |t|
        leads.include?(t["key"]) && t["label"] == OLD_LEAD_LABEL ? t.merge("label" => TEAM_LEAD) : t
      end
      renamed == types ? nil : doc.merge("agent_types" => renamed)
    end

    # The Launch bar (2026-11-25, the operator: workers come only from the lead's kanban_spawn; the lead's button says
    # what it does): the template's worker type (key WORKER, under a lead, no launch_label) gets `launchable: false`, and
    # every lead type named TEAM_LEAD with no launch_label gets LAUNCH_LEAD as its button text → the new doc, or nil
    # when nothing changes (a revision that says either key already is the operator's: left alone).
    WORKER = "worker"
    LAUNCH_LEAD = "Launch team lead"

    def launch_bar(doc)
      types = doc.fetch("agent_types")
      leads = types.map { |t| t["under"] }.compact
      out = types.map do |t|
        if t["key"] == WORKER && t["under"] && !t.key?("launchable") && !t.key?("launch_label")
          t.merge("launchable" => false)
        elsif leads.include?(t["key"]) && t["label"] == TEAM_LEAD && !t.key?("launch_label")
          t.merge("launch_label" => LAUNCH_LEAD)
        else
          t
        end
      end
      out == types ? nil : doc.merge("agent_types" => out)
    end

    # Every launcher equals one allowlisted invocation, else refused with the ones that do not.
    def allowed!(cfg, commands)
      # the same test as bin/launcher's (LauncherRules.busyyaks_session?): the prefix and a name after it
      unnamed = cfg.agent_types.reject { |t| LauncherRules.busyyaks_session?(t.session_name) }
      if unnamed.any?
        raise Refused, unnamed.map { |t| "agent type #{t.key}: session_name #{t.session_name.inspect}" }.join(", ") +
                       " must start with \"#{LauncherRules::SESSION_PREFIX}\" — every session busyyaks starts is " \
                       "named so, and busyyaks touches no tmux session without it"
      end
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

    # The engine keys lead-first boards removed — a revision written before it carries them.
    PRE_LEAD_FIRST = %w[spawns_for spawn_launcher launcher_follows].freeze

    # A revision written before lead-first boards in today's shape, or nil when it has none of the removed
    # keys (nothing to convert). The lead = the type the others `launcher_follows`; it takes the column types any type
    # `spawns_for` (an ownerless card becomes the lead's: it starts the worker with kanban_spawn), every type that
    # followed it or spawned for cards runs `under` it, and `spawn_launcher` goes (nothing picks a launcher). No such
    # lead while a type spawns for cards → Error: the revision cannot say who leads, a person must. A type left under no
    # lead becomes `standalone` when it is a plain session (no prompt, adopts nothing); any other → Error (review round
    # 1: no type runs leaderless by omission).
    def lead_first(doc)
      types = doc.fetch("agent_types")
      return nil if types.none? { |t| t.keys.intersect?(PRE_LEAD_FIRST) }

      leads = types.filter_map { |t| t["launcher_follows"] }.uniq
      spawning = types.select { |t| Array(t["spawns_for"]).any? }
      if leads.size != 1 && (spawning.any? || leads.size > 1)
        raise Error, "agent settings: cannot convert to lead-first boards — #{leads.size} followed types " \
                     "(#{leads.join(', ')}) for #{spawning.map { |t| t['key'] }.join(', ')}: save one on Settings → " \
                     "Agents & launchers with `under: <lead type>`"
      end
      lead = leads.first
      work = spawning.flat_map { |t| t["spawns_for"] }.uniq
      out = types.map do |t|
        n = t.except(*PRE_LEAD_FIRST)
        n["under"] = lead if lead && t["key"] != lead && (t["launcher_follows"] == lead || Array(t["spawns_for"]).any?)
        n["takes"] = (t["takes"] + work).uniq if t["key"] == lead
        n
      end
      out.each do |n|
        next if n["under"] || n["standalone"] || n["key"] == lead

        unless n["prompt"].nil? && n["takes"] == []
          raise Error, "agent settings: cannot convert to lead-first boards — agent type #{n['key']} would " \
                       "run under no lead: save one on Settings → Agents & launchers with `under: <lead type>`"
        end
        n["standalone"] = true
      end
      doc.merge("agent_types" => out)
    end

    # Write a new revision from `doc`, based on revision `base` (the one the editor loaded): validated by the engine
    # against the file's settings, every command on `commands`, `base` still the newest → the new revision's id.
    def save!(db, file:, doc:, base:, author:, commands:, clock: -> { Busyyaks::Clock.epoch })
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
