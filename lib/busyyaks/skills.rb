# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "yaml"

module Busyyaks
  # The skills a session busyyaks launches gets — per launch only, never installed user-wide (an
  # independent `claude` / `hermes` on this host sees none of them), read from the checkout at every launch (an update
  # merged into it applies from the next launch: nothing to install). Layers, each a dir of the same shape:
  #   busyyaks's own   <checkout>/skills/busyyaks            (busyyaks PRs)
  #   the deployment   <checkout>/<skills.local_dir>, or none
  #   a project's      <repo>/.busyyaks/skills               (that repo's committers)
  # A layer: core/SKILL.md (+ .md files; busyyaks's layer only, required: every session) · agents/<type>.md (the
  # agent type keys of the agent settings: what a session of that type does) · <name>/SKILL.md (on-demand skills).
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
    Skill = Struct.new(:name, :source, :description, :body, :files, :sha, keyword_init: true)
    # One agents/<type>.md of a layer
    Part = Struct.new(:type, :source, :body, :sha, keyword_init: true)
    # One layer: its source, core (busyyaks's only), agents (type → Part), on-demand skills
    Layer = Struct.new(:source, :core, :agents, :skills, keyword_init: true)
    # What one launch of `type` gets: core, the type's parts (busyyaks → deployment → project), the on-demand skills
    Selection = Struct.new(:type, :core, :parts, :skills, keyword_init: true)

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

    # The busyyaks layers: <checkout>/skills/busyyaks (core required), then the deployment's skills.local_dir
    def busyyaks!(checkout, types:, settings:)
      own = layer!(File.join(checkout, OWN_DIR), root: checkout, source: BUSYYAKS, types: types, settings: settings)
      return [own] unless settings.local_dir

      local = layer!(File.join(checkout, settings.local_dir), root: checkout, source: DEPLOYMENT, types: types,
                                                              settings: settings)
      unique!([own, local], File.join(checkout, settings.local_dir))
      [own, local]
    end

    # A project's layer: <repo>/.busyyaks/skills, nil when the repo has none
    def project(repo, types:, settings:, taken:)
      base = File.join(repo, PROJECT_DIR)
      dir = File.join(base, "skills")
      no_link!(repo, dir)
      return nil unless File.exist?(dir)

      layer = layer!(dir, root: repo, source: PROJECT_SOURCE, types: types, settings: settings)
      clash = layer.skills.map(&:name) & taken
      raise Invalid, "#{dir}: #{clash.join(', ')} shadows a busyyaks skill: rename it" if clash.any?

      layer
    end

    # the layers' on-demand names are unique → the last layer
    def unique!(layers, where)
      names = layers[0..-2].flat_map { |l| l.skills.map(&:name) }
      clash = layers.last.skills.map(&:name) & names
      raise Invalid, "#{where}: #{clash.join(', ')} shadows a busyyaks skill: rename it" if clash.any?
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
        raise Invalid, "#{path}: #{c} is busyyaks's core skill: rename it" if c == CORE
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

        body = File.binread(path).force_encoding(Encoding::UTF_8)
        raise Invalid, "#{path} is not UTF-8" unless body.valid_encoding?

        no_shell_inline!(path, body)
        [type, Part.new(type: type, source: source, body: body, sha: Digest::SHA256.hexdigest(body))]
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
      Skill.new(name: name, source: source, description: front["description"], body: body, files: files, sha: sha)
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
      unless front.is_a?(Hash) && front.keys.sort == FRONT_KEYS.sort && front.values.all? { |v|
 v.is_a?(String) && !v.strip.empty? }
        raise Invalid, "#{path}: frontmatter must be exactly #{FRONT_KEYS.join(' + ')} (non-empty strings)"
      end

      [front, m.post_match]
    end

    # One launch's skills → [Selection, project_skills]: busyyaks's layers for `type`, then the repo's (only when
    # skills.project is allow AND the repo is trusted — the folder-trust decision, LaunchTrust.refusal — else
    # "left: <why>", nothing of it read); project_skills = "loaded" · "none" (no .busyyaks/skills) · "left: <why>"
    def plan!(checkout:, repo:, type:, types:, settings:, trust_refusal:)
      own = busyyaks!(checkout, types: types, settings: settings)
      status, theirs = project_layer(repo, types: types, settings: settings, trust_refusal: trust_refusal,
                                           taken: own.flat_map { |l| l.skills.map(&:name) })
      [check_selection!(select(own + theirs, type), settings), status]
    end

    def project_layer(repo, types:, settings:, trust_refusal:, taken:)
      dir = File.join(repo, PROJECT_DIR, "skills")
      old = File.join(repo, PROJECT_DIR, OLD_MANIFEST)
      return ["left: #{old} is the old manifest layout: #{MOVE}", []] if File.exist?(old) || File.symlink?(old)
      return ["none", []] unless File.exist?(dir) || File.symlink?(dir) || File.symlink?(File.join(repo, PROJECT_DIR))
      return ["left: config/busyyaks.yml skills.project is deny", []] if settings.project == "deny"
      return ["left: #{trust_refusal}", []] if trust_refusal

      layer = project(repo, types: types, settings: settings, taken: taken)
      layer.nil? ? ["none", []] : ["loaded", [layer]]
    end

    # What a launch of `type` gets from the layers, in layer order
    def select(layers, type)
      core = layers.first.core
      Selection.new(type: type, core: core, parts: layers.filter_map { |l| l.agents[type] },
                    skills: layers.flat_map(&:skills))
    end

    # The entry skill (core + the type's agent files) within max_start_bytes
    def check_selection!(selection, settings)
      size = selection.core.body.bytesize + selection.parts.sum { |p| p.body.bytesize }
      if size > settings.max_start_bytes
        raise Invalid,
"agent type #{selection.type}: core + agents/#{selection.type}.md are #{size} bytes, " \
"over skills.max_start_bytes #{settings.max_start_bytes}"
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
      selection.parts.each { |p| out << "\n## Agent type #{t} (#{p.source})\n\n#{p.body.strip}\n" }
      if selection.skills.any?
        out << "\n## Load when needed\n\n"
        out << "The text above names these skills by their short name; load each by the name given here.\n\n"
        selection.skills.each { |s| out << "- `#{delivery.ref(s.name)}` (#{s.source}): #{s.description}\n" }
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
      def extra(dest) = ["--plugin-dir", dest]
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
