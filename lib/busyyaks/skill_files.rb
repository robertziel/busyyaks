# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "skills"
require_relative "agent_rule_files"

module Busyyaks
  # busyyaks's OWN skills layers as files of its checkout — skills/busyyaks (core, agents/<type>.md, on-demand skills)
  # and the deployment's skills.local_dir — edited on Settings → Agent rules and written here, by the writer service
  # only (the one container with PROJECTS_ROOT mounted read-write; the checkout must be under it). They are tracked in
  # the busyyaks repo: a save leaves an uncommitted change there, never a commit (`yaks update` refuses a checkout with
  # one until it is committed).
  #
  # The rules are the launch's own: the changed tree is copied to a scratch dir, the changes applied there, and
  # Skills.busyyaks! + check_selection! read it for every agent type — any refusal a launch would give refuses the
  # save, verbatim, and nothing is written. Then each file is replaced atomically (a temp file beside the layer dir,
  # never inside it: a launch reading the layer meanwhile refuses anything that is not a skill file), and a failure on
  # the way puts back the files already written.
  module SkillFiles
    Refused = AgentRuleFiles::Refused
    Conflict = AgentRuleFiles::Conflict

    module_function

    # the layer dirs of this checkout (relative), busyyaks's first
    def layer_dirs(settings) = [Skills::OWN_DIR, settings.local_dir].compact

    # the files a save may touch: every .md file the layers hold now (Skills reads them: nothing else is a skill file),
    # plus agents/<type>.md of each layer (a new one may be made). → {rel path => :skill | :agent}
    def editable(checkout, types:, settings:)
      layers = Skills.busyyaks!(checkout, types: types, settings: settings)
      out = {}
      layers.each do |l|
        ([l.core].compact + l.skills).each do |s|
          s.files.each_key { |f| out[File.join(s.dir, f)] = :skill }
        end
      end
      layer_dirs(settings).product(types).each { |d, t| out[File.join(d, Skills::AGENTS, "#{t}.md")] = :agent }
      out
    rescue Skills::Invalid => e
      raise Refused, "busyyaks's skills cannot be read as they are (#{e.message}): fix it in the checkout first"
    end

    def read_bytes(checkout, rel)
      path = File.join(checkout, rel)
      Skills.no_link!(checkout, path)
      return nil unless File.exist?(path)
      raise Refused, "#{rel} is not a regular file" unless File.file?(path)

      File.binread(path)
    rescue Skills::Invalid => e
      raise Refused, e.message
    end

    # changes = {rel path => {"base" => the sha the editor loaded | nil, "body" => markdown | nil (remove: an agents
    # file only)}}; projects = [{slug, path}]: the scanned repos whose own agents/<type>.md a launch adds to these
    # layers (check_projects!) → the paths written or removed
    def write!(checkout, changes, types:, settings:, projects: [])
      plan = plan!(checkout, changes, types: types, settings: settings)
      check_tree!(checkout, plan, types: types, settings: settings, projects: projects) unless plan.empty?
      apply!(checkout, plan, settings)
      plan.map { |c| c[:path] }
    end

    # each file written in turn; ANY failure on the way (the file system, a link that appeared: Refused) puts back the
    # files already written, and names any that could not be
    def apply!(checkout, plan, settings)
      done = []
      plan.each do |c|
        put(checkout, c[:path], c[:text], settings)
        done << c
      end
    rescue SystemCallError, Refused => e
      left = done.filter_map do |c|
        put(checkout, c[:path], c[:old], settings)
        nil
      rescue SystemCallError, Refused
        c[:path]
      end
      raise Refused, "not written (#{e.message}): every file is as it was" if left.empty?

      raise Refused, "not written (#{e.message}), and #{left.join(', ')} could not be put back: check the checkout"
    end

    def plan!(checkout, changes, types:, settings:)
      raise Refused, "files must be an object {path => {base, body}}" unless changes.is_a?(Hash)

      allowed = editable(checkout, types: types, settings: settings)
      unknown = changes.keys - allowed.keys
      if unknown.any?
        raise Refused, "#{unknown.join(', ')}: not a file of busyyaks's skills layers (#{layer_dirs(settings).join(', ')})"
      end

      changes.filter_map do |rel, change|
        unless change.is_a?(Hash) && change.keys.sort == %w[base body]
          raise Refused, "#{rel}: a change is {base: the loaded sha or null, body: markdown or null}"
        end

        old = read_bytes(checkout, rel)
        text = change["body"].nil? ? nil : text!(rel, change["body"], old, allowed[rel], settings)
        raise Refused, "#{rel}: a skill file cannot be removed here (blank refused)" if text.nil? && allowed[rel] == :skill

        conflict!(rel, old, change["base"])
        next if old == text&.b

        { path: rel, text: text, old: old }
      end
    end

    def text!(rel, body, old, kind, settings)
      text = if kind == :agent
               Skills.agent_text!(body, settings, where: rel)
             else
               raise Refused, "#{rel} must be markdown text" unless body.is_a?(String)

               t = body.dup.force_encoding(Encoding::UTF_8)
               raise Refused, "#{rel} is not UTF-8" unless t.valid_encoding?
               raise Refused, "#{rel} is blank: a skill file holds text" if t.strip.empty?

               t
             end
      crlf = old && AgentRuleFiles.eol_of(old.dup.force_encoding(Encoding::UTF_8).scrub) == AgentRuleFiles::CRLF
      crlf ? text.gsub(/\r?\n/, "\r\n") : text
    rescue Skills::Invalid => e
      raise Refused, e.message
    end

    def conflict!(rel, old, base)
      return if (old && AgentRuleFiles.sha(old)) == base

      what = if old.nil? then "was removed on disk"
             elsif base.nil? then "was made on disk"
             else "changed on disk"
             end
      raise Conflict, "#{rel} #{what} since the editor read it: nothing written"
    end

    # the layers as they would be after the save, read the way a launch reads them: every rule (frontmatter, sizes,
    # max_start_bytes per type, no !`…` line, no link) is Skills' own — and every project's launch with them
    def check_tree!(checkout, plan, types:, settings:, projects: [])
      Dir.mktmpdir("busyyaks-skills-check") do |tmp|
        layer_dirs(settings).each do |d|
          src = File.join(checkout, d)
          next unless File.directory?(src)

          FileUtils.mkdir_p(File.dirname(File.join(tmp, d)))
          FileUtils.cp_r(src, File.join(tmp, d))
        end
        plan.each do |c|
          path = File.join(tmp, c[:path])
          next FileUtils.rm_f(path) if c[:text].nil?

          FileUtils.mkdir_p(File.dirname(path))
          File.binwrite(path, c[:text])
        end
        begin
          own = Skills.busyyaks!(tmp, types: types, settings: settings)
          types.each { |t| Skills.check_selection!(Skills.select(own, t), settings) }
        rescue Skills::Invalid => e
          raise Refused, "not written: #{e.message.gsub("#{tmp}/", '')}"
        end
        check_projects!(Skills.busyyaks!(checkout, types: types, settings: settings), own, projects,
                        types: types, settings: settings)
      end
    end

    # A project's own agents/<type>.md adds to the entry skill busyyaks's layers start: grown here, they can push a
    # project's launch of that type over max_start_bytes, and every such launch there would be refused. A launch that
    # works now and would not after the save → refused, naming each project and type. Every scanned repo with a layer
    # is checked (whether a launch reads it also depends on the folder trust, the launcher's: a repo left out today may
    # be trusted tomorrow), unless skills.project is deny. A layer already invalid, or a launch already over, is not
    # this save's doing: not counted.
    def check_projects!(before, after, projects, types:, settings:)
      return if settings.project == "deny"

      over = projects.flat_map do |p|
        layer = project_layer(p[:path], types, settings) or next []
        types.select { |t| layer.agents.key?(t) }.filter_map do |t|
          next unless fits?(before + [layer], t, settings)

          begin
            Skills.check_selection!(Skills.select(after + [layer], t), settings)
            nil
          rescue Skills::Invalid => e
            "#{p[:slug]}: #{e.message}"
          end
        end
      end
      return if over.empty?

      raise Refused, "not written: every launch of these would be refused (a project's own " \
                     "#{Skills::PROJECT_DIR}/skills/agents/<type>.md adds to it) — #{over.join('; ')}"
    end

    def project_layer(path, types, settings)
      Skills.project(path, types: types, settings: settings)
    rescue Skills::Invalid, SystemCallError
      nil
    end

    def fits?(layers, type, settings)
      Skills.check_selection!(Skills.select(layers, type), settings)
      true
    rescue Skills::Invalid
      false
    end

    # text (nil = remove) as the file, never through a symlink; the temp file beside the layer dir, same file system
    def put(checkout, rel, text, settings)
      path = File.join(checkout, rel)
      Skills.no_link!(checkout, path)
      return FileUtils.rm_f(path) if text.nil?

      layer = layer_dirs(settings).find { |d| rel.start_with?("#{d}/") } or raise Refused, "#{rel}: no layer"
      FileUtils.mkdir_p(File.dirname(path))
      tmp = File.join(checkout, File.dirname(layer), ".busyyaks-skill-#{File.basename(rel)}.#{Process.pid}.tmp")
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW, 0o644) do |f|
        f.write(text)
        f.fsync
      end
      File.rename(tmp, path)
    rescue Skills::Invalid => e
      raise Refused, e.message
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end
  end
end
