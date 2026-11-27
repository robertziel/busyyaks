# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "yaml"
require_relative "board_mcp"
require_relative "agent_presets"

module Busyyaks
  # The skills a session busyyaks launches gets — per launch only, never installed user-wide (an
  # independent `claude` / `hermes` on this host sees none of them), read from the checkout at every launch (an update
  # merged into it applies from the next launch: nothing to install). Layers, each a dir of the same shape:
  #   busyyaks's own   <checkout>/skills/busyyaks            (busyyaks PRs)
  #   the deployment   <checkout>/<skills.local_dir>, or none
  #   a project's      <repo>/.busyyaks/skills               (that repo's committers; its agents/<type>.md are also
  #                                                           edited on the project page's Settings tab: AgentRuleFiles)
  # A layer: core/SKILL.md (+ .md files; busyyaks's layer only, required: every session) · agents/<type>.md (the
  # agent type keys of the agent settings: what a session of that type does) · <name>/SKILL.md (on-demand skills).
  #
  # THE OVERRIDE RULE (one place: `select`; every view and every save check calls it). Layers apply in order —
  # busyyaks → the deployment → the project; a later layer:
  #   agents/<type>.md  ADDS to the earlier layers' agents/<type>.md (default), or REPLACES them when the file starts
  #                     with the frontmatter `---\nmode: replace\n---` (then only core + this file's body start the
  #                     type's session; `mode: add` says the default). The frontmatter of an agents file is that one
  #                     key or none. busyyaks's own layer has nothing before it: `mode: replace` there is refused.
  #   <name>/SKILL.md   with the name of an earlier layer's on-demand skill REPLACES that skill (all its files) for
  #                     the launches that read this layer; any other name adds a skill.
  #   core              is NOT replaceable by a layer (a `core/` dir there is refused): the core skill is the one
  #                     place the board's rules reach a session (the MCP server sends none) and every board's sessions
  #                     share it, so a project changes what its sessions do through agents/<type>.md (add or replace)
  #                     and its skills; core itself is edited for every session on Settings → Agent rules.
  # bin/launcher selects core + the launch's agents/<type>.md of every layer + the on-demand skills, validates them
  # (any failure refuses the launch), stages a COPY under LAUNCHER_STATE_DIR/skills/<session>/ (0700; the repo dir
  # itself is never handed to the CLI), writes the entry skill `session` (core, then each layer's agents/<type>.md,
  # then the on-demand list) and hands the stage to the CLI the way its kind takes it (Delivery). Pure Ruby, stdlib
  # only: the host launcher requires it.
  module Skills
    class Invalid < StandardError; end

    NAME = /\A[a-z0-9-]{1,64}\z/
    ENTRY = "session" # the generated entry skill
    CORE = "core"     # busyyaks's core skill: every session
    AGENTS = "agents" # <type>.md per agent type key
    RESERVED = [ENTRY, CORE, AGENTS].freeze
    PROJECT = %w[allow deny].freeze
    FRONT_KEYS = %w[name description].freeze
    # an on-demand skill's optional frontmatter key: who dispatches it and when, one line (Settings → Agent rules shows
    # it; the staged SKILL.md carries name + description only)
    OPTIONAL_FRONT_KEYS = %w[dispatch].freeze
    BUSYYAKS = "busyyaks"
    DEPLOYMENT = "deployment"
    PROJECT_SOURCE = "project"
    PROJECT_DIR = ".busyyaks"
    OWN_DIR = "skills/busyyaks" # busyyaks's layer, relative to the checkout
    # a repo's pre-layout manifest: never read; while it is there the repo's skills are left, the launch says why
    OLD_MANIFEST = "skills.yml"
    MOVE = "no manifests now — move each skill to .busyyaks/skills/<name>/SKILL.md and each type's part to " \
           ".busyyaks/skills/agents/<type>.md, then delete it (docs/DEPLOY.md § Skills)"

    # config/busyyaks.yml `skills` (required, no default): max_bytes = one skill dir's / agent file's size,
    # max_start_bytes = the entry skill's (core + the type's agent files of one launch), project = whether a repo's
    # .busyyaks/skills may load, local_dir = this deployment's own layer (relative to the checkout, the shape of
    # skills/busyyaks minus core) or null for none
    Settings = Struct.new(:max_bytes, :max_start_bytes, :project, :local_dir, keyword_init: true)

    # One on-demand skill (or core): the SKILL.md parts (frontmatter dropped from the body) + its files
    # dir = the skill's dir relative to its layer's root (the checkout or the repo); replaces = the source of the
    # earlier layer's skill of the same name it stands in for (select), or nil
    Skill = Struct.new(:name, :source, :description, :body, :files, :sha, :dir, :replaces, :dispatch, keyword_init: true)
    # One agents/<type>.md of a layer; path = relative to its layer's root; text = the file, body = the text after its
    # frontmatter (what the entry skill holds); mode = "add" | "replace" (MODES); replaces = the sources of the
    # earlier parts it stands in for (select)
    Part = Struct.new(:type, :source, :text, :body, :sha, :path, :mode, :replaces, keyword_init: true)
    # One layer: its source, core (busyyaks's only), agents (type → Part), on-demand skills
    Layer = Struct.new(:source, :core, :agents, :skills, keyword_init: true)
    # What one launch of `type` gets: core, the type's parts (busyyaks → deployment → project, a replace dropping the
    # earlier ones), the on-demand skills (one per name, the latest layer's) and what the override rule left out:
    # replaced = [{kind: "agent" | "skill", path (an agents file's path · a skill's dir), source, by (the source that
    # replaced it)}], in layer order
    Selection = Struct.new(:type, :core, :parts, :skills, :replaced, keyword_init: true)
    MODES = %w[add replace].freeze

    module_function

    def settings!(hash)
      raise Invalid, "skills must be {max_bytes, max_start_bytes, project: allow|deny, local_dir}" unless hash.is_a?(Hash)

      keys = %w[max_bytes max_start_bytes project local_dir]
      extra = hash.keys - keys
      missing = keys - hash.keys
      raise Invalid, "skills: unknown keys #{extra.join(', ')}" if extra.any?
      raise Invalid, "skills: missing #{missing.join(', ')}" if missing.any?

      %w[max_bytes max_start_bytes].each do |k|
        v = hash[k]
        raise Invalid, "skills.#{k} must be a positive integer (bytes; got #{v.inspect})" unless v.is_a?(Integer) && v.positive?
      end
      unless PROJECT.include?(hash["project"])
        raise Invalid, "skills.project must be #{PROJECT.join(' or ')} (got #{hash['project'].inspect})"
      end

      local = hash["local_dir"]
      relative = local.is_a?(String) && local.match?(%r{\A[A-Za-z0-9_][A-Za-z0-9._/-]*\z}) && !local.split("/").include?("..")
      unless local.nil? || relative
        raise Invalid, "skills.local_dir must be null or a dir relative to the checkout (got #{local.inspect})"
      end
      if local == "skills" || local&.start_with?("skills/")
        raise Invalid, "skills.local_dir must not be inside skills/ (busyyaks's own skills dir)"
      end

      Settings.new(max_bytes: hash["max_bytes"], max_start_bytes: hash["max_start_bytes"], project: hash["project"],
                   local_dir: local)
    end

    # The busyyaks layers: <checkout>/skills/busyyaks (core required), then the deployment's skills.local_dir (whose
    # skills / agents files may replace busyyaks's: the override rule, select)
    # Their agents/<key>.md may name a type of the settings or a PRESET (config/agent_presets.yml): the
    # brief a preset type runs with ships beside it, before any deployment adds the type.
    def busyyaks!(checkout, types:, settings:)
      known = presets! | types
      own = layer!(File.join(checkout, OWN_DIR), root: checkout, source: BUSYYAKS, types: known, settings: settings)
      return [own] unless settings.local_dir

      [own, layer!(File.join(checkout, settings.local_dir), root: checkout, source: DEPLOYMENT, types: known,
                                                             settings: settings),]
    end

    def presets!
      AgentPresets.keys
    rescue AgentPresets::Invalid => e
      raise Invalid, e.message
    end

    # A project's layer: <repo>/.busyyaks/skills, nil when the repo has none. Its agents/<key>.md may also name a
    # ROLE of the repo's .busyyaks/agents.yml (ProjectAgents) — the role's brief.
    def project(repo, types:, settings:)
      dir = File.join(repo, PROJECT_DIR, "skills")
      no_link!(repo, dir)
      return nil unless File.exist?(dir)

      layer!(dir, root: repo, source: PROJECT_SOURCE, types: types | roles_of(repo), settings: settings)
    end

    AGENTS_FILE = File.join(PROJECT_DIR, "agents.yml") # a board's agent types (ProjectAgents)
    AGENTS_FILE_MAX = 16_384

    # The repo's .busyyaks/agents.yml as text, nil when it has none — the ONE read of it (ProjectAgents.load!,
    # roles_of): no symlink on the way, a regular file within AGENTS_FILE_MAX, UTF-8; else Invalid
    def agents_file!(repo)
      path = File.join(repo, AGENTS_FILE)
      dir = File.join(repo, PROJECT_DIR)
      no_link!(repo, dir) if File.symlink?(dir)
      return nil unless File.exist?(path) || File.symlink?(path)

      no_link!(repo, path)
      raise Invalid, "#{AGENTS_FILE} is not a regular file" unless File.file?(path)
      raise Invalid, "#{AGENTS_FILE} is #{File.size(path)} bytes, over #{AGENTS_FILE_MAX}" if File.size(path) > AGENTS_FILE_MAX

      text = File.binread(path).force_encoding(Encoding::UTF_8)
      raise Invalid, "#{AGENTS_FILE} is not UTF-8" unless text.valid_encoding?

      text
    rescue SystemCallError => e
      raise Invalid, "#{AGENTS_FILE}: #{e.message}"
    end

    # The role names .busyyaks/agents.yml declares (its `roles` keys) — only which brief files the layer holds; the
    # file itself is validated whole by ProjectAgents (bin/launcher, the writer). Unreadable → Invalid.
    def roles_of(repo)
      text = agents_file!(repo) or return []
      raw = YAML.safe_load(text)
      roles = raw.is_a?(Hash) ? raw.fetch("roles", {}) : nil
      raise Invalid, "#{AGENTS_FILE}: roles must be a mapping" unless roles.is_a?(Hash)

      roles.keys.select { |k| k.is_a?(String) && k.match?(NAME) }
    rescue Psych::Exception => e
      raise Invalid, "#{AGENTS_FILE}: #{e.message}"
    end

    # One layer dir → Layer, every rule checked (nothing is half-loaded: one refusal refuses all):
    #   core/SKILL.md (+ .md)   busyyaks's layer only, required there
    #   agents/<type>.md        optional; <type> = an agent type key of the agent settings
    #   <name>/SKILL.md (+ .md) on-demand skills
    def layer!(dir, root:, source:, types:, settings:)
      no_link!(root, dir)
      raise Invalid, "#{dir} missing" unless File.exist?(dir)
      raise Invalid, "#{dir} is not a directory" unless File.directory?(dir)

      own = source == BUSYYAKS
      children = Dir.children(dir).sort
      children.each do |c|
        path = File.join(dir, c)
        raise Invalid, "#{path}: a skills dir holds directories only (core, agents, <skill>)" unless File.directory?(path)
        next if c == AGENTS || (own && c == CORE)
        if c == CORE
          raise Invalid, "#{path}: core is busyyaks's core skill, not replaceable by a layer — edit it for every " \
                         "session on Settings → Agent rules (#{OWN_DIR}/core), or add to it with agents/<type>.md"
        end
        raise Invalid, "#{path}: #{ENTRY} is the generated entry skill's name" if c == ENTRY
        raise Invalid, "#{path}: skill name #{c.inspect} must match #{NAME.source}" unless c.match?(NAME)
      end
      raise Invalid,
"#{File.join(dir, CORE)}/SKILL.md missing (every session starts with it)" if own && !children.include?(CORE)

      core = own ? skill!(File.join(dir, CORE), CORE, root: root, source: source, settings: settings) : nil
      agents = if children.include?(AGENTS)
                 agents!(File.join(dir, AGENTS), root: root, source: source, types: types,
               settings: settings)
else
  {}
end
      skills = (children - RESERVED).map { |n| skill!(File.join(dir, n), n, root: root, source: source, settings: settings) }
      Layer.new(source: source, core: core, agents: agents, skills: skills)
    end

    # agents/: <type>.md per agent type, regular files, plain markdown
    def agents!(dir, root:, source:, types:, settings:)
      no_link!(root, dir)
      Dir.children(dir).sort.to_h do |f|
        path = File.join(dir, f)
        unless File.file?(path) && !File.symlink?(path) && f.end_with?(".md")
          raise Invalid, "#{path}: agents/ holds <agent type>.md files only"
        end

        type = f.delete_suffix(".md")
        raise Invalid, "#{path}: #{type} is not an agent type (#{types.join(', ')})" unless types.include?(type)

        no_link!(root, path)
        size = File.size(path)
        raise Invalid, "#{path} is #{size} bytes, over skills.max_bytes #{settings.max_bytes}" if size > settings.max_bytes

        text = File.binread(path).force_encoding(Encoding::UTF_8)
        raise Invalid, "#{path} is not UTF-8" unless text.valid_encoding?

        no_shell_inline!(path, text)
        mode, body = agent_mode!(text, path)
        if mode == "replace" && source == BUSYYAKS
          raise Invalid, "#{path}: mode: replace in busyyaks's own layer — there is no earlier layer to replace"
        end

        [type, Part.new(type: type, source: source, text: text, body: body, sha: Digest::SHA256.hexdigest(text),
                        path: path.delete_prefix("#{root}/"), mode: mode, replaces: []),]
      end
    end

    # Every component of `path` below `root` is a real file or dir (never a symlink), and its real path stays under
    # root's: a link in a repo's .busyyaks (to ~/.ssh, another repo) would copy what it points at into the stage
    def no_link!(root, path)
      rel = path.delete_prefix("#{root}/")
      raise Invalid, "#{path} is not under #{root}" if rel == path

      cur = root
      rel.split("/").each do |seg|
        cur = File.join(cur, seg)
        raise Invalid, "#{cur} is a symlink: skills are read from real files under #{root} only" if File.symlink?(cur)
      end
      return unless File.exist?(path)

      real = File.realpath(path)
      top = File.realpath(root)
      raise Invalid, "#{path} resolves to #{real}, outside #{top}" unless real.start_with?("#{top}/")
    end

    # Claude Code runs a skill's !`command` lines when the skill is invoked (its shell preprocessing): no skill busyyaks
    # hands a session may hold one — refused, never stripped
    SHELL_INLINE = /!`/

    def no_shell_inline!(path, text)
      text.each_line.with_index(1) do |line, n|
        raise Invalid,
"#{path}:#{n}: !`…` (Claude Code runs it as a shell command): not allowed in a skill" if line.match?(SHELL_INLINE)
      end
    end

    # An agents/<type>.md's optional frontmatter: none → ["add", text]; `---\nmode: add|replace\n---` → [mode, the text
    # after it]; any other frontmatter (another key, another value, not YAML) → Invalid naming the file
    AGENT_FRONT = /\A---\r?\n(.*?)^---\r?\n/m

    def agent_mode!(text, path)
      m = text.match(AGENT_FRONT) or return ["add", text]

      front = begin
        YAML.safe_load(m[1])
      rescue Psych::Exception => e
        raise Invalid, "#{path}: frontmatter #{e.message}"
      end
      unless front.is_a?(Hash) && front.keys == ["mode"] && MODES.include?(front["mode"])
        raise Invalid, "#{path}: an agents file's frontmatter is exactly `mode: add` or `mode: replace` (or none: add)"
      end

      [front["mode"], m.post_match]
    end

    # A text about to be written as an agents/<type>.md (the project page's Settings tab, AgentRuleFiles; Settings →
    # Agent rules, SkillFiles): what agents! refuses when it reads one — not UTF-8, over skills.max_bytes, a !`…` line,
    # a frontmatter other than `mode` — plus blank (no rules = no file; `mode: replace` with nothing after it is a
    # file: it replaces the earlier layers' rules with none). `where` names it in the refusal. → the text as UTF-8.
    def agent_text!(body, settings, where:)
      raise Invalid, "#{where} must be markdown text (got #{body.class})" unless body.is_a?(String)

      text = body.dup.force_encoding(Encoding::UTF_8)
      raise Invalid, "#{where} is not UTF-8" unless text.valid_encoding?

      mode, rest = agent_mode!(text, where)
      raise Invalid, "#{where} is blank: remove the file instead" if mode == "add" && rest.strip.empty?
      if text.bytesize > settings.max_bytes
        raise Invalid, "#{where} is #{text.bytesize} bytes, over skills.max_bytes #{settings.max_bytes}"
      end

      no_shell_inline!(where, text)
      text
    end

    # One skill dir: regular .md files only (no link, no subdir), SKILL.md with frontmatter exactly name + description
    def skill!(dir, name, root:, source:, settings:)
      no_link!(root, dir)
      raise Invalid, "#{dir} must be a directory" unless File.directory?(dir)

      names = Dir.children(dir).sort
      names.each do |f|
        path = File.join(dir, f)
        unless File.file?(path) && !File.symlink?(path) && f.end_with?(".md")
          raise Invalid, "#{path}: a skill holds regular .md files only"
        end

        no_link!(root, path)
      end
      raise Invalid, "#{dir}/SKILL.md missing" unless names.include?("SKILL.md")

      # the size from the file system first: an oversized file is refused before it is read
      size = names.sum { |f| File.size(File.join(dir, f)) }
      raise Invalid, "#{dir} is #{size} bytes, over skills.max_bytes #{settings.max_bytes}" if size > settings.max_bytes

      files = names.to_h { |f| [f, File.binread(File.join(dir, f))] }

      files.each { |f, b| no_shell_inline!(File.join(dir, f), b.dup.force_encoding(Encoding::UTF_8).scrub) }
      front, body = frontmatter!(files["SKILL.md"], File.join(dir, "SKILL.md"))
      raise Invalid, "#{dir}/SKILL.md: name #{front['name'].inspect} must be its dir's #{name}" unless front["name"] == name

      sha = Digest::SHA256.hexdigest(files.sort.map { |f, b| "#{f}\0#{b}" }.join("\0"))
      Skill.new(name: name, source: source, description: front["description"], body: body, files: files, sha: sha,
                dir: dir.delete_prefix("#{root}/"), dispatch: front["dispatch"])
    end

    def frontmatter!(text, path)
      text = text.dup.force_encoding(Encoding::UTF_8)
      raise Invalid, "#{path} is not UTF-8" unless text.valid_encoding?

      m = text.match(/\A---\r?\n(.*?)^---\r?\n/m)
      raise Invalid, "#{path}: no frontmatter (--- name, description ---)" unless m

      front = begin
        YAML.safe_load(m[1])
      rescue Psych::Exception => e
        raise Invalid, "#{path}: frontmatter #{e.message}"
      end
      keys = front.is_a?(Hash) ? front.keys : []
      unless (FRONT_KEYS - keys).empty? && (keys - FRONT_KEYS - OPTIONAL_FRONT_KEYS).empty? &&
             front.values.all? { |v| v.is_a?(String) && !v.strip.empty? && !v.include?("\n") }
        raise Invalid, "#{path}: frontmatter must be exactly #{FRONT_KEYS.join(' + ')} (+ optional " \
                       "#{OPTIONAL_FRONT_KEYS.join(', ')}), each one line of text"
      end

      [front, m.post_match]
    end

    # One launch's skills → [Selection, project_skills]: busyyaks's layers for `type`, then the repo's (only when
    # skills.project is allow AND the repo is trusted — the folder-trust decision, LaunchTrust.refusal — else
    # "left: <why>", nothing of it read); project_skills = "loaded" · "none" (no .busyyaks/skills) · "left: <why>"
    # role: a ROLE of the repo's .busyyaks/agents.yml the session runs (bin/launcher checked it against the
    # file): its brief, the project layer's agents/<role>.md, follows the type's parts — required, so the repo's layer
    # must be loaded.
    def plan!(checkout:, repo:, type:, types:, settings:, trust_refusal:, role: nil)
      own = busyyaks!(checkout, types: types, settings: settings)
      status, theirs = project_layer(repo, types: types, settings: settings, trust_refusal: trust_refusal)
      sel = select(own + theirs, type)
      sel = with_role(sel, theirs, role, status) if role
      [check_selection!(sel, settings), status]
    end

    def with_role(sel, theirs, role, status)
      raise Invalid, "role #{role}: the repo's .busyyaks/skills is #{status} — its brief cannot load" unless status == "loaded"

      part = theirs.first.agents[role] or
        raise Invalid, "role #{role}: no brief #{PROJECT_DIR}/skills/#{AGENTS}/#{role}.md"
      if part.mode == "replace"
        raise Invalid, "#{part.path}: a role's brief follows its type's parts — mode: replace is for an agent type's file"
      end

      sel.dup.tap { _1.parts = sel.parts + [part] }
    end

    # Why a repo's own .busyyaks/skills are left out of a launch (nil = they load): the deployment's setting, then the
    # folder-trust decision
    def left_reason(settings, trust_refusal)
      return "config/busyyaks.yml skills.project is deny" if settings.project == "deny"

      trust_refusal
    end

    # What a launch in `repo` does with the repo's own layer, without starting anything (bin/launcher's `project_skills`
    # op, for the project page's Settings tab) → {status, budget, replace_budget, layers}: status = "loaded" · "none" ·
    # "left: <why>"; budget / replace_budget = {type => the bytes its project agents/<type>.md may hold} when it adds /
    # replaces (project_budget); layers = {type => composition} — what a launch of the type stages, each earlier
    # layer's file marked when the override rule replaced it (`composition`: the launch's own select). Every type's
    # launch is planned: an invalid layer, or a type whose entry skill would be over max_start_bytes, raises Invalid —
    # as that launch would.
    # roles = {role => its type} of the repo's .busyyaks/agents.yml: each role's launch is planned too.
    def project_status(checkout:, repo:, types:, settings:, trust_refusal:, roles: {})
      own = busyyaks!(checkout, types: types, settings: settings)
      status, theirs = project_layer(repo, types: types, settings: settings, trust_refusal: trust_refusal)
      layers = own + theirs
      types.each { |t| check_selection!(select(layers, t), settings) }
      roles.each { |r, t| check_selection!(with_role(select(layers, t), theirs, r, status), settings) } if status == "loaded"
      { status: status, budget: budget(own, types, settings), replace_budget: replace_budget(own, types, settings),
        layers: types.to_h { |t| [t, composition(layers, t)] }, }
    end

    # What a launch of `type` stages from `layers`, in launch order, with what the override rule left out — the
    # project tab's per-type view: {start: [{path, source, kind (core · core_ref · agent), mode, replaced_by}],
    # on_demand: [{name, source, dir, replaces, replaced_by}]} — replaced_by = the source that replaced it (it is NOT
    # staged), nil = staged; replaces = the source it stands in for. From select (one definition of the rule).
    def composition(layers, type)
      sel = select(layers, type)
      by = sel.replaced.to_h { |r| [[r[:kind], r[:path]], r[:by]] }
      core = sel.core
      core_files = (["SKILL.md"] + (core.files.keys - ["SKILL.md"]).sort).map do |f|
        { path: File.join(core.dir, f), source: core.source, kind: f == "SKILL.md" ? "core" : "core_ref", mode: nil,
          replaced_by: nil, }
      end
      parts = layers.filter_map { |l| l.agents[type] }.map do |p|
        { path: p.path, source: p.source, kind: "agent", mode: p.mode, replaced_by: by[["agent", p.path]] }
      end
      kept = sel.skills.to_h { |s| [s.dir, s] }
      skills = layers.flat_map(&:skills).map do |s|
        { name: s.name, source: s.source, dir: s.dir, replaces: kept[s.dir]&.replaces,
          replaced_by: by[["skill", s.dir]], }
      end
      { start: core_files + parts, on_demand: skills }
    end

    # {type => bytes}: what a project's agents/<type>.md may hold so a launch of the type still starts — the entry
    # skill's limit (max_start_bytes) less busyyaks's own share of it (core + its layers' agents/<type>.md), never
    # more than one file's own limit (max_bytes), never below 0.
    def project_budget(checkout:, types:, settings:)
      budget(busyyaks!(checkout, types: types, settings: settings), types, settings)
    end

    # {type => bytes}: the same for a project file with `mode: replace` — only core stays before it
    def replace_budget(own, types, settings)
      core = own.first.core.body.bytesize
      types.to_h { |t| [t, (settings.max_start_bytes - core).clamp(0, settings.max_bytes)] }
    end

    def budget(own, types, settings)
      types.to_h do |t|
        sel = select(own, t)
        used = sel.core.body.bytesize + sel.parts.sum { |p| p.body.bytesize }
        [t, (settings.max_start_bytes - used).clamp(0, settings.max_bytes)]
      end
    end

    def project_layer(repo, types:, settings:, trust_refusal:)
      dir = File.join(repo, PROJECT_DIR, "skills")
      old = File.join(repo, PROJECT_DIR, OLD_MANIFEST)
      return ["left: #{old} is the old manifest layout: #{MOVE}", []] if File.exist?(old) || File.symlink?(old)
      return ["none", []] unless File.exist?(dir) || File.symlink?(dir) || File.symlink?(File.join(repo, PROJECT_DIR))

      left = left_reason(settings, trust_refusal)
      return ["left: #{left}", []] if left

      layer = project(repo, types: types, settings: settings)
      layer.nil? ? ["none", []] : ["loaded", [layer]]
    end

    # What a launch of `type` gets from the layers, in layer order — THE OVERRIDE RULE (the module's header): an agents
    # file with mode replace drops the earlier layers' agents/<type>.md, one with mode add follows them; an on-demand
    # skill of a name an earlier layer has stands in for that one, in its place in the list. Nothing is changed in the
    # layers (the parts and skills returned are copies carrying `replaces`).
    def select(layers, type)
      parts = []
      skills = {}
      replaced = []
      layers.each do |l|
        p = l.agents[type]
        if p&.mode == "replace"
          replaced.concat(parts.map { |x| { kind: "agent", path: x.path, source: x.source, by: p.source } })
          parts = [p.dup.tap { _1.replaces = parts.map(&:source).uniq }]
        elsif p
          parts << p
        end
        l.skills.each do |s|
          prev = skills[s.name]
          replaced << { kind: "skill", path: prev.dir, source: prev.source, by: s.source } if prev
          skills[s.name] = prev ? s.dup.tap { _1.replaces = prev.source } : s
        end
      end
      Selection.new(type: type, core: layers.first.core, parts: parts, skills: skills.values, replaced: replaced)
    end

    # The files one launch of `type` stages, in the order the entry skill holds them (entry_body): core's SKILL.md,
    # core's reference files, each layer's agents/<type>.md, then every on-demand skill's files. → [{path (relative to
    # its layer's root), source, kind (core · core_ref · agent · skill · skill_ref), load (start · on_demand), skill?,
    # description?, type?, text (the file's bytes)}]
    def staged_files(selection)
      core = selection.core
      skill_files(core, "core", "start") +
        selection.parts.map do |p|
          { path: p.path, source: p.source, kind: "agent", load: "start", type: p.type, text: p.text }
        end +
        selection.skills.flat_map { |s| skill_files(s, "skill", "on_demand") }
    end

    def skill_files(skill, kind, load)
      names = ["SKILL.md"] + (skill.files.keys - ["SKILL.md"]).sort
      names.map do |f|
        main = f == "SKILL.md"
        { path: File.join(skill.dir, f), source: skill.source, kind: main ? kind : "#{kind}_ref", load: load,
          skill: skill.name, description: main ? skill.description : nil, dispatch: main ? skill.dispatch : nil,
          text: skill.files.fetch(f), }
      end
    end

    # What every launch busyyaks starts gets from busyyaks's own layers (skills/busyyaks + skills.local_dir), per agent
    # type — read and checked as a launch reads them (busyyaks!, select, check_selection!), nothing staged:
    # → {files: [every file once, in the order of the first type that stages it: staged_files' entries + bytes],
    #    types: {type => {start: [paths the entry skill holds, in order], on_demand: [skill names], start_bytes,
    #    budget: what its project's agents/<type>.md may still hold}}, creatable: [agents/<type>.md paths no layer
    #    has yet]}. An invalid layer, or a type over max_start_bytes, raises Invalid — as that launch would.
    def global_view(checkout:, types:, settings:)
      own = busyyaks!(checkout, types: types, settings: settings)
      files = {}
      view = types.to_h do |t|
        sel = check_selection!(select(own, t), settings)
        staged = staged_files(sel)
        staged.each { |f| files[f[:path]] ||= f.except(:type).merge(bytes: f[:text].bytesize, replaced_by: nil) }
        start = staged.select { |f| f[:load] == "start" }
        [t, { start: start.map { |f| f[:path] }, on_demand: sel.skills.map(&:name),
              start_bytes: sel.core.body.bytesize + sel.parts.sum { |p| p.body.bytesize }, },]
      end
      replaced_files(own, types).each { |f| files[f[:path]] ||= f }
      budget(own, types, settings).each { |t, b| view[t][:budget] = b }
      dirs = [OWN_DIR, settings.local_dir].compact
      creatable = dirs.product(types).map { |d, t| File.join(d, AGENTS, "#{t}.md") } - files.keys
      { files: files.values, types: view, creatable: creatable }
    end

    # The files of busyyaks's layers the override rule leaves out of every launch (a deployment skill of a busyyaks
    # skill's name, a deployment agents file with mode: replace): still files of the checkout, still edited on the
    # page — each with replaced_by = the source that stands in for it (composition, the launch's own select)
    def replaced_files(own, types)
      out = []
      types.each do |t|
        comp = composition(own, t)
        comp[:start].select { |f| f[:replaced_by] }.each do |f|
          part = own.filter_map { |l| l.agents[t] }.find { |p| p.path == f[:path] }
          out << { path: part.path, source: part.source, kind: "agent", load: "start", skill: nil, description: nil,
                   text: part.text, bytes: part.text.bytesize, replaced_by: f[:replaced_by], }
        end
        comp[:on_demand].select { |k| k[:replaced_by] }.each do |k|
          skill = own.flat_map(&:skills).find { |x| x.dir == k[:dir] }
          skill_files(skill, "skill", "on_demand").each do |f|
            out << f.merge(bytes: f[:text].bytesize, replaced_by: k[:replaced_by])
          end
        end
      end
      out.uniq { |f| f[:path] }
    end

    # bin/launcher's skills_layers answer (Settings → Agent rules): global_view with each file's text as UTF-8 (one
    # that is not: text nil + its error), where the writer reaches the checkout (checkout.mount, or nil + error: its
    # saves go there) and the limits
    def layers_answer(checkout:, types:, settings:, projects_root:, container_root:)
      view = global_view(checkout: checkout, types: types, settings: settings)
      files = view[:files].map do |f|
        text = f[:text].dup.force_encoding(Encoding::UTF_8)
        ok = text.valid_encoding?
        f.merge(text: ok ? text : nil, error: ok ? nil : "#{f[:path]} is not UTF-8")
      end
      mount, why = checkout_mount(checkout, projects_root: projects_root, container_root: container_root)
      { files: files, types: view[:types], creatable: view[:creatable],
        checkout: { host: File.realpath(checkout), mount: mount, error: why },
        limits: { max_bytes: settings.max_bytes, max_start_bytes: settings.max_start_bytes, project: settings.project,
                  local_dir: settings.local_dir, }, }
    end

    # Where the writer service reaches this checkout (it mounts PROJECTS_ROOT read-write at PROJECTS_MOUNT): → [the
    # container path, nil] or [nil, why it cannot] — never a guess
    def checkout_mount(checkout, projects_root:, container_root:)
      real = File.realpath(checkout)
      top = File.realpath(projects_root)
      return [File.join(container_root, real.delete_prefix(top)), nil] if real.start_with?("#{top}/")

      [nil, "the busyyaks checkout #{real} is not under PROJECTS_ROOT #{top}: the writer service cannot write it — " \
            "edit the files in the checkout and commit them to its branch, or move the checkout under PROJECTS_ROOT",]
    end

    # The entry skill (core + the type's agent files) within max_start_bytes
    def check_selection!(selection, settings)
      size = selection.core.body.bytesize + selection.parts.sum { |p| p.body.bytesize }
      if size > settings.max_start_bytes
        roles = selection.parts.map(&:type).uniq - [selection.type] # a project role's brief (with_role)
        what = roles.empty? ? "agent type #{selection.type}" : "agent type #{selection.type} with role #{roles.join(', ')}"
        files = ["agents/#{selection.type}.md", *roles.map { |r| "agents/#{r}.md" }].join(" + ")
        raise Invalid, "#{what}: core + #{files} are #{size} bytes, over skills.max_start_bytes #{settings.max_start_bytes}"
      end

      selection
    end

    # The entry skill's markdown body: core, then each layer's agents/<type>.md, then the on-demand skills by their
    # delivered names (the Skill tool / the CLI loads those when the work needs them)
    def entry_body(selection, delivery)
      t = selection.type
      out = +"# busyyaks session (agent type #{t})\n\n"
      out << "The skills busyyaks gave this session. Follow them for every card you work.\n"
      refs = selection.core.files.keys - ["SKILL.md"]
      out << "\n#{selection.core.body.strip}\n"
      out << "\nReference files beside this skill: #{refs.map { |f| "`#{f}`" }.join(', ')}.\n" if refs.any?
      selection.parts.each do |p|
        instead = p.replaces.to_a.any? ? ", replaces #{p.replaces.join(' + ')}" : ""
        head = p.type == t ? "Agent type #{t}" : "Agent role #{p.type}" # a project role's brief (with_role)
        out << "\n## #{head} (#{p.source}#{instead})\n\n#{p.body.strip}\n"
      end
      if selection.skills.any?
        out << "\n## Load when needed\n\n"
        out << "The text above names these skills by their short name; load each by the name given here.\n\n"
        selection.skills.each do |s|
          instead = s.replaces ? ", replaces #{s.replaces}'s" : ""
          out << "- `#{delivery.ref(s.name)}` (#{s.source}#{instead}): #{s.description}\n"
        end
      end
      out
    end

    # Writes the stage (a fresh dir, 0700) → the receipt [{name, source, sha, load}] (the entry skill last)
    def stage!(selection, dest, delivery)
      FileUtils.rm_rf(dest)
      FileUtils.mkdir_p(dest, mode: 0o700)
      File.chmod(0o700, dest)
      delivery.layout(dest)
      selection.skills.each { |s| write_skill(dest, delivery, s.name, s.description, s.body, s.files) }
      entry = entry_body(selection, delivery)
      desc = "The busyyaks board workflow for this session (start here)"
      write_skill(dest, delivery, ENTRY, desc, entry, selection.core.files)
      core = selection.core
      [{ name: CORE, source: core.source, sha: core.sha, load: "start" }] +
        selection.parts.map { |p| { name: "#{AGENTS}/#{p.type}", source: p.source, sha: p.sha, load: "start" } } +
        selection.skills.map { |s| { name: s.name, source: s.source, sha: s.sha, load: "on_demand" } } +
        [{ name: ENTRY, source: BUSYYAKS, sha: Digest::SHA256.hexdigest(entry), load: "start" }]
    end

    # a skill as the CLI reads it: SKILL.md with frontmatter rewritten to the delivered name (hermes resolves a skill
    # by its frontmatter name), the other .md files copied as they are
    def write_skill(dest, delivery, name, description, body, files)
      dir = delivery.skill_dir(dest, name)
      FileUtils.mkdir_p(dir, mode: 0o700)
      front = { "name" => delivery.skill_name(name), "description" => description }.to_yaml.delete_prefix("---\n")
      File.write(File.join(dir, "SKILL.md"), "---\n#{front}---\n#{body}")
      files.each { |f, b| File.binwrite(File.join(dir, f), b) unless f == "SKILL.md" }
    end

    # Stages of sessions no longer running: removed (a stage lives while its session does)
    def sweep(stages_dir, live)
      return [] unless File.directory?(stages_dir)

      Dir.children(stages_dir).reject { |s| live.include?(s) }.each { |s| FileUtils.rm_rf(File.join(stages_dir, s)) }
    end

    # How the stage reaches a CLI, per launcher kind (the engine's Launch::KINDS). A kind with no class here = refused.
    class Delivery
      def layout(_dest) = nil
      def env(_dest) = {}
      def prompt(rendered) = rendered
    end

    # Claude Code: the stage is a plugin (`--plugin-dir`, this session only; skills namespaced `busyyaks:<name>`),
    # and the prompt starts with `/busyyaks:session`: a slash-invoked skill loads for certain, the rest = arguments
    class ClaudeCode < Delivery
      def layout(dest)
        FileUtils.mkdir_p(File.join(dest, ".claude-plugin"), mode: 0o700)
        File.write(File.join(dest, ".claude-plugin/plugin.json"), JSON.generate({ name: BUSYYAKS }))
      end

      def skill_dir(dest, name) = File.join(dest, "skills", name)
      def skill_name(name) = name
      def ref(name) = "#{BUSYYAKS}:#{name}"
      # --mcp-config first: it takes several values, and --plugin-dir ends them before the prompt (measured)
      def extra(dest) = ["--mcp-config", BoardMcp.claude_path(dest), "--plugin-dir", dest]
      def prompt(rendered) = rendered ? "/#{ref(ENTRY)} #{rendered}" : "/#{ref(ENTRY)}"
    end

    # Hermes: the stage holds a skills dir (<stage>/busyyaks-skills) its config's `skills.external_dirs` reaches through
    # the line `${BUSYYAKS_SKILLS_DIR}/busyyaks-skills`, the variable set for this session only (tmux -e). Measured on
    # hermes v0.21.5: entries pass os.path.expandvars, relative ones are anchored at HERMES_HOME and a
    # dir that does not exist is skipped — so UNSET (every other run) leaves `${BUSYYAKS_SKILLS_DIR}/busyyaks-skills`
    # literal under HERMES_HOME: no such dir, nothing loaded; set EMPTY it is `/busyyaks-skills`: none either (a bare
    # `${BUSYYAKS_SKILLS_DIR}` line would be HERMES_HOME itself then — not used). `-s busyyaks-session-<token>` with the skill
    # missing makes hermes exit with "Unknown skill(s)": a visible failed start. After the start, bin/launcher asks
    # hermes itself (`skills list` through the allowlisted command, with this launch's environment) whether
    # the entry skill is listed and enabled.
    #
    # Every name carries a per-launch token (busyyaks-<name>-<token>): hermes resolves a name local skills dir first,
    # so a user's own `busyyaks-session` would shadow the stage's — a name nobody else has cannot be shadowed.
    class Hermes < Delivery
      VAR = "BUSYYAKS_SKILLS_DIR"
      SUBDIR = "busyyaks-skills"
      LINE = "${#{VAR}}/#{SUBDIR}".freeze
      TOKEN = /\A\h{12}\z/

      def initialize(token = SecureRandom.hex(6))
        super()
        raise ArgumentError, "token must be 12 hex digits" unless token.match?(TOKEN)

        @token = token
      end

      def skill_dir(dest, name) = File.join(dest, SUBDIR, skill_name(name))
      def skill_name(name) = "#{BUSYYAKS}-#{name}-#{@token}"
      def ref(name) = skill_name(name)
      def extra(_dest) = ["-s", skill_name(ENTRY)]
      def env(dest) = { VAR => dest }

      # `hermes skills list` (v0.21.5: Name │ Category │ Source │ Trust │ Status, run with this launch's environment) →
      # nil when the entry skill's row says enabled, else why
      def listed(output, home)
        entry = skill_name(ENTRY)
        row = output.lines.map { |l| l.split(/[│┃|]/).map(&:strip).reject(&:empty?) }.find { |c| c.first == entry }
        fix = "#{File.join(home, 'config.yaml')} needs `- #{LINE}` under skills.external_dirs (inert for every run " \
              "busyyaks does not start)"
        return "hermes does not list #{entry}: #{fix}" unless row
        return nil if row.last == "enabled"

        "hermes lists #{entry} as #{row.last}, not enabled (skills.disabled in #{File.join(home, 'config.yaml')}?)"
      end
    end

    def delivery(kind)
      case kind
      when "claude_code" then ClaudeCode.new
      when "hermes" then Hermes.new
      else raise Invalid, "launcher kind #{kind}: busyyaks has no way to hand it skills (claude_code, hermes)"
      end
    end
  end
end
