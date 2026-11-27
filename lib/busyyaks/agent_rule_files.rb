# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"
require_relative "skills"
require_relative "git_read"

module Busyyaks
  # A project's agent markdown IS its repo's own skills layer, `<repo>/.busyyaks/skills/` (Skills: read by
  # bin/launcher at each launch, only for a session busyyaks starts, only when skills.project is allow and the repo is
  # trusted): agents/<type>.md (add to or, with `mode: replace`, replace busyyaks's rules for the type) and on-demand
  # skills <name>/SKILL.md + their .md reference files (a busyyaks skill's name replaces that skill for this project).
  # The project page's Settings tab shows EVERY file there and edits, makes and removes them: read here (the web mounts
  # the repos read-only), written through the writer service (WorkflowFiles::Writer#agent_rules: the one container
  # with the repos mounted read-write). No database copy: the file is the rule.
  #
  # A save is checked the way a launch reads the layer: the layer as it would be after the save is copied to a scratch
  # repo and read with Skills.project + Skills.select + check_selection! for every agent type against busyyaks's own
  # layers (the writer's `check`) — frontmatter, sizes, max_start_bytes, no !`…` line, no link, the override rule —
  # and any refusal a launch would give refuses the save, verbatim, with nothing written.
  #
  # Nothing a CLI loads by itself: Claude Code reads CLAUDE.md / .claude/, Codex and Hermes AGENTS.md / their own dot
  # dirs — none reads `.busyyaks/`. A session started from a terminal in the repo gets none of it.
  module AgentRuleFiles
    REL = File.join(Skills::PROJECT_DIR, "skills")
    # a file of the layer, relative to REL: agents/<type>.md, or <skill>/<file>.md (one level, .md only: Skills' shape)
    FILE = %r{\A(?:#{Skills::AGENTS}/[a-z0-9-]{1,64}\.md|[a-z0-9-]{1,64}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}\.md)\z}

    class Refused < StandardError; end
    # a file is not what the editor loaded (changed, made or removed on disk meanwhile): nothing is written
    class Conflict < StandardError; end

    module_function

    def rel(path) = File.join(REL, path)
    def sha(bytes) = Digest::SHA256.hexdigest(bytes)
    def blob(bytes) = Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0#{bytes}")
    def agent_path(type) = File.join(Skills::AGENTS, "#{type}.md")

    # what a path of the layer is → {kind: "agent", type} · {kind: "skill" | "skill_ref", skill}; Refused when it is
    # no file a layer may hold
    def kind!(path, types)
      raise Refused, "#{path.inspect}: not a file of #{REL} (agents/<type>.md or <skill>/<file>.md)" unless
        path.is_a?(String) && path.match?(FILE)

      dir, name = path.split("/")
      if dir == Skills::AGENTS
        type = name.delete_suffix(".md")
        raise Refused, "#{rel(path)}: #{type} is not an agent type (#{types.join(', ')})" unless types.include?(type)

        return { kind: "agent", type: type }
      end
      if [Skills::CORE, Skills::ENTRY].include?(dir)
        raise Refused, "#{rel(path)}: #{dir} is busyyaks's #{dir == Skills::CORE ? 'core skill' : 'entry skill'} — " \
                       "not a project's (core is edited for every session on Settings → Agent rules)"
      end

      { kind: name == "SKILL.md" ? "skill" : "skill_ref", skill: dir }
    end

    # Every file the layer holds now → [paths, errors]: paths = the files a launch would read (relative to REL);
    # errors = {path => why it is not one} (a symlink, a dir where a file belongs, not .md, a name a launch refuses)
    def list(project)
      root = project.fetch(:path)
      base = File.join(root, REL)
      Skills.no_link!(root, base)
      return [[], {}] unless File.exist?(base)
      raise Refused, "#{REL} is not a directory" unless File.directory?(base)

      paths = []
      errors = {}
      Dir.children(base).sort.each do |d|
        top = File.join(base, d)
        unless real_dir?(top)
          errors[d] =
"#{REL}/#{d}: #{File.symlink?(top) ? 'a symlink' : 'a skills dir holds directories only (agents, <skill>)'}"
          next
        end

        Dir.children(top).sort.each do |f|
          path = "#{d}/#{f}"
          full = File.join(top, f)
          if File.symlink?(full)
            errors[path] = "#{rel(path)} is a symlink: skills are read from real files only"
          elsif !File.file?(full)
            errors[path] = "#{rel(path)} is not a regular file"
          elsif !path.match?(FILE)
            errors[path] = "#{rel(path)}: not a file a launch reads (agents/<type>.md or <skill>/<file>.md)"
          else
            paths << path
          end
        end
      end
      [paths, errors]
    rescue Skills::Invalid => e
      raise Refused, e.message
    end

    def real_dir?(path) = File.directory?(path) && !File.symlink?(path)

    # One file's bytes, or nil (no file). Refused: a symlink on the way, not a regular file, too big.
    def read_bytes(project, path, settings)
      root = project.fetch(:path)
      full = File.join(root, rel(path))
      Skills.no_link!(root, full)
      return nil unless File.exist?(full)
      raise Refused, "#{rel(path)} is not a regular file" unless File.file?(full)

      size = File.size(full)
      raise Refused, "#{rel(path)} is #{size} bytes, over skills.max_bytes #{settings.max_bytes}" if size > settings.max_bytes

      File.binread(full)
    rescue Skills::Invalid => e
      raise Refused, e.message
    end

    # What the editor shows → [files, errors]: files = {path => {body, sha, eol, blob, kind, type | skill, mode}} for
    # each file of the layer that reads as UTF-8 — body with LF line ends (a textarea's), eol = "crlf" when every line
    # of the file ends CRLF (a save writes them back), else "lf"; sha = the bytes on disk (a save's base); blob = their
    # git blob id (git_states); mode = an agents file's "add" | "replace" (its frontmatter; nil when unreadable) —
    # errors = {path => why it cannot be edited here}. A whole-layer refusal (the dir is a link) is errors[""].
    def read(project, types:, settings:)
      paths, errors = list(project)
      files = {}
      paths.each do |path|
        k = kind!(path, types)
        bytes = read_bytes(project, path, settings)
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        raise Refused, "#{rel(path)} is not UTF-8" unless text.valid_encoding?

        eol = eol_of(text)
        files[path] = { body: eol == CRLF ? text.gsub("\r\n", "\n") : text, sha: sha(bytes), eol: eol, blob: blob(bytes),
                        **k, mode: k[:kind] == "agent" ? mode_of(text) : nil, }
      rescue Refused => e
        errors[path] = e.message
      end
      [files, errors]
    rescue Refused => e
      [{}, { "" => e.message }]
    end

    def mode_of(text)
      Skills.agent_mode!(text, "").first
    rescue Skills::Invalid
      nil
    end

    CRLF = "crlf"
    LF = "lf"

    # "crlf" when the text has line ends and every one is CRLF; anything else (LF, none, mixed) is "lf": written as typed
    def eol_of(text) = text.include?("\r\n") && !text.match?(/(?<!\r)\n/) ? CRLF : LF

    # The editor's Save: changes = {path (relative to REL) => {"base" => the sha it loaded | nil (no file), "body" =>
    # markdown | nil (remove the file)}}. Everything is checked before anything is written — every path a file the
    # layer may hold, every file still the bytes of its base (else Conflict), the layer as it would be read by `check`
    # (->(scratch repo) { … }: the writer's launch check, raising Skills::Invalid) — then each file is replaced
    # atomically (a temp file renamed over it; a skill dir left empty is removed with its last file); a failure on the
    # way puts the files already written back, and names any that could not be. A file whose lines end CRLF keeps them.
    # → the paths written or removed.
    def write!(project, changes, types:, settings:, check:)
      plan = begin
        plan!(project, changes, types: types, settings: settings).tap { |pl| check_tree!(project, pl, check) unless pl.empty? }
      rescue SystemCallError => e
        raise Refused, "not written (#{e.message}): every file is as it was"
      end
      apply!(project, plan)
      plan.map { |c| c[:path] }
    end

    def apply!(project, plan)
      done = []
      plan.each do |c|
        put(project, c[:path], c[:text])
        done << c
      end
    rescue SystemCallError, Refused => e
      left = restore(project, done)
      raise Refused, "not written (#{e.message}): every file is as it was" if left.empty?

      raise Refused, "not written (#{e.message}), and #{left.join(', ')} could not be put back: " \
                     "#{left.size == 1 ? 'it holds' : 'they hold'} the new text — check the repo"
    end

    # the files already written, put back as they were → the ones that could not be (still changed on disk)
    def restore(project, done)
      done.reverse.filter_map do |c|
        put(project, c[:path], c[:old])
        nil
      rescue SystemCallError, Refused
        rel(c[:path])
      end
    end

    # The layer as it would be after the save, in a scratch repo, handed to `check` (the launch's reading of it)
    def check_tree!(project, plan, check)
      Dir.mktmpdir("busyyaks-rules-check") do |tmp|
        src = File.join(project.fetch(:path), REL)
        dst = File.join(tmp, REL)
        FileUtils.mkdir_p(File.dirname(dst))
        File.directory?(src) ? FileUtils.cp_r(src, dst) : FileUtils.mkdir_p(dst)
        # the repo's .busyyaks/agents.yml beside it: its roles are the names agents/<role>.md may have
        agents = File.join(project.fetch(:path), Skills::AGENTS_FILE)
        FileUtils.cp(agents, File.join(tmp, Skills::AGENTS_FILE)) if File.file?(agents) && !File.symlink?(agents)
        plan.each do |c|
          path = File.join(dst, c[:path])
          if c[:text].nil?
            FileUtils.rm_f(path)
            prune(dst, c[:path])
          else
            FileUtils.mkdir_p(File.dirname(path))
            File.binwrite(path, c[:text])
          end
        end
        begin
          check.call(tmp)
        rescue Skills::Invalid => e
          raise Refused, "not written: #{e.message.gsub("#{tmp}/", '')}"
        end
      end
    end

    # a skill dir with no file left goes with its last file (an empty skill dir is a refused skill: no SKILL.md)
    def prune(base, path)
      dir = File.dirname(path)
      return if dir == Skills::AGENTS

      full = File.join(base, dir)
      Dir.rmdir(full) if File.directory?(full) && Dir.empty?(full)
    end

    # What git holds of each file, for the page to say "tracked" and "uncommitted change": {path => state} —
    # committed (the bytes on disk are HEAD's) · modified (tracked, other bytes) · added (in the index, not in HEAD) ·
    # ignored (git's ignore rules hide it: it will not be committed) · untracked · deleted (in HEAD or the index, no
    # file: every file git holds under the layer is asked, so a removed one is named) — a path whose file is there but
    # could not be read (`errors`) is left out (its editor says why; it is not "deleted"). `files`, `errors` = read's;
    # `also` = more paths to answer (the agents/<type>.md no file holds yet). One GitRead child (libgit2); its refusal
    # raises GitRead::Failed (said on the page, never guessed).
    def git_states(project, files, errors, also: [], root: GitRead.mount)
      asked = (files.keys + also).uniq.map { |p| rel(p) }
      r = GitRead.call("tracked", path: project.fetch(:path), root: root, files: asked, under: REL)
      r.fetch("files").filter_map do |full, git|
        path = full.delete_prefix("#{REL}/")
        next if errors.key?(path)

        state = git_state(files[path], git)
        state && [path, state]
      end.to_h
    end

    def git_state(file, git)
      head = git["head"]
      return head || git["tracked"] ? "deleted" : nil unless file
      return file[:blob] == head ? "committed" : "modified" if head
      return "added" if git["tracked"]

      git["ignored"] ? "ignored" : "untracked"
    end

    def plan!(project, changes, types:, settings:)
      raise Refused, "files must be an object {path => {base, body}}" unless changes.is_a?(Hash)

      changes.filter_map do |path, change|
        k = kind!(path, types)
        unless change.is_a?(Hash) && change.keys.sort == %w[base body]
          raise Refused, "#{rel(path)}: a change is {base: the loaded sha or null, body: markdown or null}"
        end

        old = read_bytes(project, path, settings)
        text = change["body"].nil? ? nil : text!(path, k[:kind], change["body"], old, settings)
        conflict!(path, old, change["base"])
        next if old == text&.b

        { path: path, text: text, old: old }
      end
    end

    # the text as it is written: checked (an agents file: Skills.agent_text!; a skill file: UTF-8, not blank, within
    # max_bytes, no !`…` line — the rest is the launch's own reading, check_tree!), in the line endings of the file
    # it replaces
    def text!(path, kind, body, old, settings)
      where = rel(path)
      text = kind == "agent" ? Skills.agent_text!(body, settings, where: where) : skill_text!(body, settings, where)
      text = text.gsub(/\r?\n/, "\r\n") if old && eol_of(old.dup.force_encoding(Encoding::UTF_8).scrub) == CRLF
      text
    rescue Skills::Invalid => e
      raise Refused, e.message
    end

    def skill_text!(body, settings, where)
      raise Refused, "#{where} must be markdown text (got #{body.class})" unless body.is_a?(String)

      text = body.dup.force_encoding(Encoding::UTF_8)
      raise Refused, "#{where} is not UTF-8" unless text.valid_encoding?
      raise Refused, "#{where} is blank: a skill file holds text — remove the file instead" if text.strip.empty?
      if text.bytesize > settings.max_bytes
        raise Refused, "#{where} is #{text.bytesize} bytes, over skills.max_bytes #{settings.max_bytes}"
      end

      Skills.no_shell_inline!(where, text)
      text
    end

    def conflict!(path, old, base)
      return if (old && sha(old)) == base

      what = if old.nil? then "was removed on disk"
             elsif base.nil? then "was made on disk"
             else "changed on disk"
             end
      raise Conflict, "#{rel(path)} #{what} since the editor read it: nothing written"
    end

    # text (or nil = no file) as the file, never through a symlink; a skill dir left empty goes with its last file
    def put(project, path, text)
      root = project.fetch(:path)
      full = File.join(root, rel(path))
      Skills.no_link!(root, full)
      if text.nil?
        FileUtils.rm_f(full)
        return prune(File.join(root, REL), path)
      end

      FileUtils.mkdir_p(File.dirname(full))
      # the temp file beside workflow.yml, never in skills/: a launch that reads the layer meanwhile (or after a killed
      # writer) refuses anything there that is not a skill file. Same file system.
      tmp = File.join(root, Skills::PROJECT_DIR, ".rule-#{path.tr('/', '-')}.#{Process.pid}.tmp")
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW, 0o644) do |f|
        f.write(text)
        f.fsync
      end
      File.rename(tmp, full)
    rescue Skills::Invalid => e
      raise Refused, e.message
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end
  end
end
