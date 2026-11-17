# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "yaml"

module Busyyaks
  # The skills a session busyyaks launches gets — per launch only, never installed user-wide (an
  # independent `claude` / `hermes` on this host sees none of them). Two layers:
  #   busyyaks's own   <checkout>/skills/manifest.yml + skills/<name>/SKILL.md          (busyyaks PRs)
  #   a project's      <repo>/.busyyaks/skills.yml   + .busyyaks/skills/<name>/SKILL.md (that repo's committers)
  # A manifest: `version: 1` + `skills: {<name>: {types: all | [<agent type>…], load: start | on_demand}}`. bin/launcher
  # selects the skills of the launch's agent type from both, validates them (any failure refuses the launch), stages a
  # COPY under LAUNCHER_STATE_DIR/skills/<session>/ (0700; the repo dir itself is never handed to the CLI), writes the
  # entry skill `session` (the `load: start` bodies in order, busyyaks's first) and hands the stage to the CLI the way
  # its kind takes it (Delivery). Pure Ruby, stdlib only: the host launcher requires it.
  module Skills
    class Invalid < StandardError; end

    VERSION = 1
    NAME = /\A[a-z0-9-]{1,64}\z/
    ENTRY = "session" # the generated entry skill: no manifest may name one so
    LOADS = %w[start on_demand].freeze
    PROJECT = %w[allow deny].freeze
    SKILL_KEYS = %w[types load].freeze
    FRONT_KEYS = %w[name description].freeze
    BUSYYAKS = "busyyaks"
    PROJECT_DIR = ".busyyaks"

    # config/busyyaks.yml `skills` (required, no default): max_bytes = one skill dir's size, max_start_bytes = the
    # entry skill's (every `load: start` body of one launch), project = whether a repo's .busyyaks skills may load,
    # local_dir = this deployment's own skills dir (relative to the checkout, a manifest.yml + skill dirs like
    # skills/) or null for none
    Settings = Struct.new(:max_bytes, :max_start_bytes, :project, :local_dir, keyword_init: true)
    DEPLOYMENT = "deployment"

    # One validated skill: its manifest entry + the SKILL.md parts (frontmatter dropped from the body) + its files
    Skill = Struct.new(:name, :source, :types, :load, :description, :body, :files, :sha, keyword_init: true)

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

    # The busyyaks layer: <checkout>/skills, then the deployment's skills.local_dir (no name in both)
    def busyyaks!(checkout, types:, settings:)
      dir = File.join(checkout, "skills")
      own = load!(File.join(dir, "manifest.yml"), dir, root: checkout, source: BUSYYAKS, types: types, settings: settings)
      return own unless settings.local_dir

      ldir = File.join(checkout, settings.local_dir)
      local = load!(File.join(ldir, "manifest.yml"), ldir, root: checkout, source: DEPLOYMENT, types: types,
                                                           settings: settings)
      clash = local.map(&:name) & own.map(&:name)
      raise Invalid, "#{ldir}: #{clash.join(', ')} shadows a busyyaks skill: rename it" if clash.any?

      own + local
    end

    # A project's layer: <repo>/.busyyaks, nil when the repo has none
    def project(repo, types:, settings:, taken:)
      base = File.join(repo, PROJECT_DIR)
      manifest = File.join(base, "skills.yml")
      no_link!(repo, manifest)
      no_link!(repo, File.join(base, "skills"))
      return nil unless File.exist?(manifest) || File.exist?(File.join(base, "skills"))

      skills = load!(manifest, File.join(base, "skills"), root: repo, source: "project", types: types, settings: settings)
      clash = skills.map(&:name) & taken
      raise Invalid, "#{manifest}: #{clash.join(', ')} shadows a busyyaks skill: rename it" if clash.any?

      skills
    end

    # A manifest + its skills dir → [Skill], every rule checked (nothing is half-loaded: one refusal refuses all)
    def load!(manifest, dir, root:, source:, types:, settings:)
      no_link!(root, manifest)
      no_link!(root, dir)
      entries = manifest!(manifest, types)
      raise Invalid, "#{dir} missing (#{manifest} names #{entries.keys.join(', ')})" unless File.directory?(dir)

      dirs = Dir.children(dir).reject { |c| c == File.basename(manifest) && File.dirname(manifest) == dir }.sort
      unlisted = dirs - entries.keys
      absent = entries.keys - dirs
      raise Invalid, "#{dir}: #{unlisted.join(', ')} not in #{manifest}" if unlisted.any?
      raise Invalid, "#{dir}: #{absent.join(', ')} named in #{manifest} but missing" if absent.any?

      entries.map { |name, e| skill!(File.join(dir, name), name, e, root: root, source: source, settings: settings) }
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

    def manifest!(path, types)
      raise Invalid, "#{path} missing" unless File.file?(path)

      doc = begin
        YAML.safe_load_file(path)
      rescue Psych::Exception => e
        raise Invalid, "#{path}: #{e.message}"
      end
      raise Invalid, "#{path} must be {version, skills}" unless doc.is_a?(Hash) && doc.keys.sort == %w[skills version]
      raise Invalid, "#{path}: version must be #{VERSION} (got #{doc['version'].inspect})" unless doc["version"] == VERSION

      skills = doc["skills"]
      raise Invalid, "#{path}: skills must be a non-empty map name → {types, load}" unless skills.is_a?(Hash) && skills.any?

      skills.each do |name, e|
        name!(name, path)
        entry!(name, e, path, types)
      end
      skills
    end

    def name!(name, where)
      raise Invalid,
"#{where}: skill name #{name.inspect} must match #{NAME.source}" unless name.is_a?(String) && name.match?(NAME)
      raise Invalid, "#{where}: #{ENTRY} is the generated entry skill's name" if name == ENTRY
    end

    def entry!(name, e, path, types)
      raise Invalid, "#{path}: #{name} must be {types, load}" unless e.is_a?(Hash) && e.keys.sort == SKILL_KEYS.sort
      raise Invalid, "#{path}: #{name}.load must be #{LOADS.join(' or ')}" unless LOADS.include?(e["load"])

      t = e["types"]
      return if t == "all"

      unless t.is_a?(Array) && t.any? && t.all?(String)
        raise Invalid, "#{path}: #{name}.types must be all or a list of agent types"
      end
      unknown = t - types
      raise Invalid, "#{path}: #{name}.types #{unknown.join(', ')} not an agent type (#{types.join(', ')})" if unknown.any?
    end

    # One skill dir: regular .md files only (no link, no subdir), SKILL.md with frontmatter exactly name + description
    def skill!(dir, name, entry, root:, source:, settings:)
      no_link!(root, dir)
      raise Invalid, "#{dir} must be a directory" unless File.directory?(dir)

      files = Dir.children(dir).sort.to_h do |f|
        path = File.join(dir, f)
        unless File.file?(path) && !File.symlink?(path) && f.end_with?(".md")
          raise Invalid, "#{path}: a skill holds regular .md files only"
        end

        no_link!(root, path)
        [f, File.binread(path)]
      end
      raise Invalid, "#{dir}/SKILL.md missing" unless files.key?("SKILL.md")

      size = files.values.sum(&:bytesize)
      raise Invalid, "#{dir} is #{size} bytes, over skills.max_bytes #{settings.max_bytes}" if size > settings.max_bytes

      files.each { |f, b| no_shell_inline!(File.join(dir, f), b.dup.force_encoding(Encoding::UTF_8).scrub) }
      front, body = frontmatter!(files["SKILL.md"], File.join(dir, "SKILL.md"))
      raise Invalid, "#{dir}/SKILL.md: name #{front['name'].inspect} must be its dir's #{name}" unless front["name"] == name

      sha = Digest::SHA256.hexdigest(files.sort.map { |f, b| "#{f}\0#{b}" }.join("\0"))
      Skill.new(name: name, source: source, types: entry["types"], load: entry["load"],
                description: front["description"], body: body, files: files, sha: sha)
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

    # One launch's skills → [selected, project_skills]: busyyaks's for `type`, then the repo's (only when
    # skills.project is allow AND the repo is trusted — the folder-trust decision, LaunchTrust.refusal — else
    # "left: <why>", nothing of it read); project_skills = "loaded" · "none" (no .busyyaks) · "left: <why>"
    def plan!(checkout:, repo:, type:, types:, settings:, trust_refusal:)
      own = busyyaks!(checkout, types: types, settings: settings)
      status, theirs = project_layer(repo, type: type, types: types, settings: settings, trust_refusal: trust_refusal,
                                           taken: own.map(&:name))
      [check_selection!(select(own, type) + theirs, type, settings), status]
    end

    def project_layer(repo, type:, types:, settings:, trust_refusal:, taken:)
      return ["none", []] unless File.exist?(File.join(repo, PROJECT_DIR))
      return ["left: config/busyyaks.yml skills.project is deny", []] if settings.project == "deny"
      return ["left: #{trust_refusal}", []] if trust_refusal

      skills = project(repo, types: types, settings: settings, taken: taken)
      return ["none", []] if skills.nil?

      picked = select(skills, type)
      [picked.empty? ? "none for #{type}" : "loaded", picked]
    end

    # The skills of one agent type, in manifest order
    def select(skills, type) = skills.select { |s| s.types == "all" || s.types.include?(type) }

    # What a launch of `type` gets: at least one `load: start` skill, their bodies within max_start_bytes
    def check_selection!(selected, type, settings)
      start = selected.select { |s| s.load == "start" }
      raise Invalid, "agent type #{type}: no `load: start` skill (skills/manifest.yml)" if start.empty?

      size = start.sum { |s| s.body.bytesize }
      if size > settings.max_start_bytes
        raise Invalid,
"agent type #{type}: the start skills are #{size} bytes, over skills.max_start_bytes #{settings.max_start_bytes}"
      end

      selected
    end

    # The entry skill's markdown body: each start skill under its own heading, then the on-demand ones by their
    # delivered names (the Skill tool / the CLI loads those when the work needs them)
    def entry_body(selected, delivery)
      start = selected.select { |s| s.load == "start" }
      later = selected.reject { |s| s.load == "start" }
      out = +"# busyyaks session\n\nThe skills busyyaks gave this session. Follow them for every card you work.\n"
      start.each { |s| out << "\n## #{s.name} (#{s.source})\n\n#{s.body.strip}\n" }
      if later.any?
        out << "\n## Load when needed\n\n"
        later.each { |s| out << "- `#{delivery.ref(s.name)}` (#{s.source}): #{s.description}\n" }
      end
      out
    end

    # Writes the stage (a fresh dir, 0700) → the receipt [{name, source, sha, load}] (the entry skill last)
    def stage!(selected, dest, delivery)
      FileUtils.rm_rf(dest)
      FileUtils.mkdir_p(dest, mode: 0o700)
      File.chmod(0o700, dest)
      delivery.layout(dest)
      selected.each { |s| write_skill(dest, delivery, s.name, s.description, s.body, s.files) }
      entry = entry_body(selected, delivery)
      desc = "The busyyaks board workflow for this session (start here)"
      write_skill(dest, delivery, ENTRY, desc, entry, {})
      selected.map { |s| { name: s.name, source: s.source, sha: s.sha, load: s.load } } +
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
    # hermes itself (`skills list` in the session process's own environment: its HERMES_HOME, its variable) whether
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

      # `hermes skills list` (v0.21.5: Name │ Category │ Source │ Trust │ Status, run in the session's environment) →
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
