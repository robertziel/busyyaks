# frozen_string_literal: true

require "yaml"
require_relative "skills"

module Busyyaks
  # A board's agent types: `<repo>/.busyyaks/agents.yml`, committed in the repo (".busyyaks is the place
  # where any user of busyyaks defines, overrides or changes any agent-related markdown"), read only for a trusted
  # repo (the folder-trust decision, LaunchTrust — bin/launcher decides it, its `project_agents` op answers it):
  #
  #   use: [copywriter]                       the OPT-IN agent types (AgentSettings::OPT_IN) this board runs
  #   roles:                                  this project's own types: a ROLE over an agent type of the settings
  #     changelog: {label: Changelog writer, like: worker}
  #   columns:                                which type or role the lead starts for a card in that column
  #     docs: copywriter
  #
  # A role is NOT an engine agent type (those are the deployment's: launchers, model, prompt, caps — a repo never sets
  # them, so it never widens what runs on the host): its session registers as its `like` type and gets one more part,
  # the role's brief `.busyyaks/skills/agents/<role>.md` (required), after that type's. Every key is optional; a key
  # given is checked whole and anything unknown is refused (never ignored, never a plain worker instead).
  # Pure Ruby, stdlib only: bin/launcher, the writer, the web and the MCP server require it.
  module ProjectAgents
    class Invalid < StandardError; end

    FILE = File.join(Skills::PROJECT_DIR, "agents.yml")
    KEYS = %w[use roles columns].freeze
    ROLE_KEYS = %w[label like].freeze
    NAME = /\A[a-z][a-z0-9_-]{0,31}\z/
    COLUMN = /\A[A-Za-z0-9_-]{1,64}\z/
    MAX_BYTES = Skills::AGENTS_FILE_MAX
    # column types a lead never starts a session for (the engine's parked / terminal types)
    NO_WORK = %w[parked done cancelled].freeze

    # What the agent settings say of one type: under = the lead type it runs under (nil = a lead or standalone),
    # opt_in = AgentSettings::OPT_IN
    TypeInfo = Struct.new(:key, :under, :opt_in, keyword_init: true)
    Role = Struct.new(:key, :label, :like, keyword_init: true)
    Agents = Struct.new(:use, :roles, :columns, keyword_init: true) do
      def to_h = { use: use, roles: roles.transform_values { |r| { label: r.label, like: r.like } }, columns: columns }
      # the type or role the lead starts for a card in `column`, nil = none named (any type the board runs)
      def for_column(column) = columns[column.to_s]
    end
    EMPTY = Agents.new(use: [], roles: {}, columns: {}).freeze

    module_function

    # {key => TypeInfo} from the engine's host config + the revision's opt-in keys
    def types(cfg, opt_in)
      cfg.agent_types.to_h { |t| [t.key, TypeInfo.new(key: t.key, under: t.under, opt_in: opt_in.include?(t.key))] }
    end

    # The repo's file → Agents, or nil when it has none. Read like a skills layer: no symlink on the way, within
    # MAX_BYTES, UTF-8; every role's brief present. presets = AgentPresets keys (a role may not take one's name).
    def load!(repo, types:, presets:)
      text = Skills.agents_file!(repo) or return nil

      agents = parse!(text, types: types, presets: presets)
      briefs!(repo, agents)
      agents
    rescue Skills::Invalid => e
      raise Invalid, e.message
    end

    # Every role has its brief .busyyaks/skills/agents/<role>.md
    def briefs!(repo, agents)
      agents.roles.each_key do |k|
        rel = File.join(Skills::PROJECT_DIR, "skills", Skills::AGENTS, "#{k}.md")
        raise Invalid, "#{FILE}: role #{k} has no brief #{rel} (what a session of the role does)" \
          unless File.file?(File.join(repo, rel))
      end
    end

    def parse!(bytes, types:, presets:)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      raise Invalid, "#{FILE} is not UTF-8" unless text.valid_encoding?

      raw = begin
        YAML.safe_load(text)
      rescue Psych::Exception => e
        raise Invalid, "#{FILE}: #{e.message}"
      end
      raise Invalid, "#{FILE} must be a mapping of #{KEYS.join(', ')}" unless raw.is_a?(Hash)

      unknown = raw.keys - KEYS
      raise Invalid, "#{FILE}: unknown keys #{unknown.join(', ')} (#{KEYS.join(', ')})" if unknown.any?

      use = use!(raw.fetch("use", []), types)
      roles = roles!(raw.fetch("roles", {}), types, use, presets)
      columns = columns!(raw.fetch("columns", {}), types, use, roles)
      Agents.new(use: use, roles: roles, columns: columns)
    end

    def use!(v, types)
      raise Invalid, "#{FILE}: use must be a list of opt-in agent type keys" unless v.is_a?(Array) && v.all?(String)

      twice = v.tally.find { |_, n| n > 1 }
      raise Invalid, "#{FILE}: use lists #{twice.first} twice" if twice

      opt = types.values.select(&:opt_in).map(&:key)
      v.each do |k|
        raise Invalid, "#{FILE}: use: no agent type #{k} (opt-in types: #{list(opt)})" unless types.key?(k)
        raise Invalid, "#{FILE}: use: #{k} is not an opt-in type — every board runs it already" unless types[k].opt_in
      end
      v.freeze
    end

    def roles!(v, types, use, presets)
      raise Invalid, "#{FILE}: roles must be a mapping {role: {label, like}}" unless v.is_a?(Hash)

      v.to_h do |k, r|
        where = "#{FILE}: role #{k}"
        raise Invalid, "#{where}: the name must match #{NAME.source}" unless k.is_a?(String) && k.match?(NAME)
        raise Invalid, "#{where}: an agent type of the settings has that name" if types.key?(k)
        raise Invalid, "#{where}: a preset agent type has that name (config/agent_presets.yml)" if presets.include?(k)
        raise Invalid, "#{where} must be {#{ROLE_KEYS.join(', ')}}" unless r.is_a?(Hash) && r.keys.sort == ROLE_KEYS.sort

        label = r["label"]
        raise Invalid, "#{where}: label must be one line of 1-60 characters" \
          unless label.is_a?(String) && label.strip.length.between?(1, 60) && !label.include?("\n")

        like = r["like"]
        spawnable!(like, types, use, where: "#{where}: like")
        [k, Role.new(key: k, label: label.strip, like: like).freeze]
      end.freeze
    end

    def columns!(v, types, use, roles)
      raise Invalid, "#{FILE}: columns must be a mapping {column key: agent type or role}" unless v.is_a?(Hash)

      v.each do |col, name|
        raise Invalid, "#{FILE}: columns: #{col.inspect} is not a column key" unless col.is_a?(String) && col.match?(COLUMN)
        next if roles.key?(name)

        spawnable!(name, types, use, where: "#{FILE}: columns.#{col}", roles: roles)
      end
      v.dup.freeze
    end

    # A type a lead starts for a card: one of the settings that runs under a lead; an opt-in one only when `use` lists it
    def spawnable!(name, types, use, where:, roles: {})
      known = types.values.select(&:under).map(&:key) + roles.keys
      raise Invalid, "#{where}: #{name.inspect} is no agent type a lead starts (#{list(known)})" \
        unless name.is_a?(String) && types[name]&.under
      raise Invalid, "#{where}: #{name} is opt-in and not under use" if types[name].opt_in && !use.include?(name)
    end

    # The mapped columns against the board's: each a column of it that holds work ({key => column type})
    def board_columns!(agents, board)
      agents.columns.each_key do |col|
        type = board[col]
        raise Invalid, "#{FILE}: columns: the board has no column #{col} (#{list(board.keys)})" unless type
        raise Invalid, "#{FILE}: columns: #{col} is a #{type} column — no session works a card there" if NO_WORK.include?(type)
      end
      agents
    end

    # kanban_spawn's rule (the MCP server asks it before the engine starts anything). state = the launcher's answer for
    # the repo's file: "loaded" (agents = Agents) · "none" · "left: <why>" (untrusted / skills.project deny: the file is
    # NOT read). type = the agent type asked for, role = the role asked for (nil = none). Refused → Invalid naming what
    # to ask for instead; nothing is ever started as something else.
    def spawn!(state:, agents:, column:, column_label:, type:, role:, opt_in:)
      loaded = state == "loaded"
      if state.start_with?("left")
        raise Invalid, "this board's #{FILE} is not read (#{state.delete_prefix('left: ')}): no session is started for " \
                       "its cards until the repo is trusted (config/busyyaks.yml launch.trusted_paths) or the file is " \
                       "removed — never a plain #{type} instead of what the file names"
      end
      if role
        raise Invalid, "role #{role}: this board's #{FILE} is #{state} — a role comes only from a loaded file" unless loaded

        r = agents.roles[role] or raise Invalid, "no role #{role} in #{FILE} (roles: #{list(agents.roles.keys)})"
        raise Invalid, "role #{role} runs as agent type #{r.like}: kanban_spawn(type: #{r.like}, role: #{role})" \
          unless type == r.like
      end
      if opt_in.include?(type) && !(loaded && agents.use.include?(type))
        raise Invalid, "agent type #{type} is opt-in and this board does not use it (#{FILE}: " \
                       "#{loaded ? "use: #{list(agents.use)}" : state})"
      end
      want = loaded ? agents.for_column(column) : nil
      return if want.nil? || want == (role || type)

      raise Invalid, "column #{column_label} takes #{want} (#{FILE}): kanban_spawn(#{spawn_args(agents, want)})"
    end

    # kanban_assign_worker's rule: a worker given a card in a mapped column is of that type or role. worker = {type,
    # role} busyyaks recorded when it started it (session_roles), nil = not recorded (started before roles were recorded).
    def assign!(state:, agents:, column:, column_label:, worker:, session:)
      if state.start_with?("left")
        raise Invalid, "this board's #{FILE} is not read (#{state.delete_prefix('left: ')}): no card is handed to a " \
                       "worker until the repo is trusted or the file is removed"
      end
      want = state == "loaded" ? agents.for_column(column) : nil
      return if want.nil?
      raise Invalid, "column #{column_label} takes #{want} (#{FILE}); #{session}'s type is not recorded — start one " \
                     "with kanban_spawn(#{spawn_args(agents, want)})" if worker.nil?

      got = worker[:role] || worker[:type]
      return if got == want

      raise Invalid, "column #{column_label} takes #{want} (#{FILE}); #{session} is a #{got} — give it a card of its " \
                     "kind, or start a #{want} with kanban_spawn(#{spawn_args(agents, want)})"
    end

    def spawn_args(agents, name)
      r = agents.roles[name]
      r ? "type: #{r.like}, role: #{name}" : "type: #{name}"
    end

    # The launcher's answer back into Agents (the MCP server and the web read it as JSON)
    def from_h(h)
      roles = h.fetch("roles").to_h { |k, r| [k, Role.new(key: k, label: r.fetch("label"), like: r.fetch("like")).freeze] }
      Agents.new(use: h.fetch("use"), roles: roles, columns: h.fetch("columns"))
    end

    def list(keys) = keys.empty? ? "none" : keys.join(", ")
  end
end
