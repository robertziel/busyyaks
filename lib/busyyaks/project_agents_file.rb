# frozen_string_literal: true

require "digest"
require "fileutils"
require_relative "project_agents"
require_relative "skills"

module Busyyaks
  # Writing a repo's .busyyaks/agents.yml — the writer service's job (the only container with the repos
  # read-write; WorkflowFiles::Writer#project_agents): the project page's Settings tab sends the whole file text, the
  # sha it loaded, and the brief of each role the file adds that has none yet. Everything is checked first, against the
  # current agent settings and the board's columns, then written atomically — the briefs first (new files only), the
  # file last; a failure on the way removes the briefs it wrote. Never committed (the repo commits it).
  module ProjectAgentsFile
    class Refused < StandardError; end
    # the file changed on disk since the editor read it (or a brief appeared): nothing written
    class Conflict < StandardError; end

    module_function

    def sha(bytes) = Digest::SHA256.hexdigest(bytes)
    def path(repo) = File.join(repo, ProjectAgents::FILE)
    def brief_rel(role) = File.join(Skills::PROJECT_DIR, "skills", Skills::AGENTS, "#{role}.md")

    # → [bytes | nil, sha | nil] of the file on disk
    def current(repo)
      p = path(repo)
      return [nil, nil] unless File.exist?(p) || File.symlink?(p)
      raise Refused, "#{ProjectAgents::FILE} is not a regular file" if File.symlink?(p) || !File.file?(p)

      b = File.binread(p)
      [b, sha(b)]
    end

    # change = {base: the loaded sha | nil (no file), text: the file | nil (remove it), briefs: {role => markdown | nil}}
    # — markdown = the brief of a role the file adds (written first); nil = remove the brief of a role the file drops
    # (removed last, in the same save: a role and its brief go together — QA round 4)
    # types = ProjectAgents.types(…), presets = AgentPresets keys, board = {column key => column type},
    # settings = Skills::Settings (a brief's limits) → the written relative paths
    def write!(repo, change, types:, presets:, board:, settings:)
      raise Refused, "the change must be {base, text, briefs}" unless change.is_a?(Hash)

      Skills.no_link!(repo, File.join(repo, Skills::PROJECT_DIR)) if File.exist?(File.join(repo, Skills::PROJECT_DIR))
      _bytes, now = current(repo)
      raise Conflict, "#{ProjectAgents::FILE} changed on disk since it was read" unless now == change["base"]

      text = change["text"]
      briefs = change.fetch("briefs", {}) || {}
      raise Refused, "briefs must be {role: markdown}" unless briefs.is_a?(Hash)
      drop = briefs.select { |_, v| v.nil? }.keys
      return remove!(repo, drop) if text.nil?
      raise Refused, "text must be the file's YAML" unless text.is_a?(String)

      agents = ProjectAgents.parse!(text.b, types: types, presets: presets)
      ProjectAgents.board_columns!(agents, board)
      dropped!(repo, agents, drop)
      orphans!(repo, agents, types, drop)
      new_briefs = briefs!(repo, agents, briefs.compact, settings)
      written = []
      begin
        new_briefs.each do |role, body|
          put!(repo, brief_rel(role), body, fresh: true)
          written << brief_rel(role)
        end
        put!(repo, ProjectAgents::FILE, text, fresh: false, expected: now)
      rescue StandardError
        written.each { |rel| FileUtils.rm_f(File.join(repo, rel)) }
        raise
      end
      drop.each { |role| FileUtils.rm_f(File.join(repo, brief_rel(role))) }
      written + [ProjectAgents::FILE] + drop.map { |r| brief_rel(r) }
    rescue ProjectAgents::Invalid, Skills::Invalid => e
      raise Refused, e.message
    end

    # every role has its brief: on disk, or given here (only for a role that has none: a brief on disk is edited on its
    # own editor); a brief given for no role of the file → refused
    def briefs!(repo, agents, briefs, settings)
      extra = briefs.keys - agents.roles.keys
      raise Refused, "briefs for #{extra.join(', ')}: no such role in the file" if extra.any?

      missing = []
      out = agents.roles.keys.filter_map do |role|
        on_disk = File.exist?(File.join(repo, brief_rel(role)))
        if briefs.key?(role)
          raise Conflict, "#{brief_rel(role)} exists already: edit it on its own editor" if on_disk

          [role, Skills.agent_text!(briefs[role], settings, where: brief_rel(role))]
        else
          missing << role unless on_disk
          nil
        end
      end
      return out.to_h if missing.empty?

      raise Refused, "role #{missing.join(', ')} needs a brief (what a session of the role does): give it with the " \
                     "file — it is written as #{missing.map { |r| brief_rel(r) }.join(', ')}"
    end

    # an agents/<name>.md of the repo's layer that is neither an agent type nor a role of the new file would refuse
    # every launch (Skills.project): the file keeps that role until its brief is removed
    def orphans!(repo, agents, types, drop)
      dir = File.join(repo, Skills::PROJECT_DIR, "skills", Skills::AGENTS)
      return unless File.directory?(dir)

      left = Dir.children(dir).select { |f| f.end_with?(".md") }.map { |f| f.delete_suffix(".md") } -
             types.keys - agents.roles.keys - drop
      return if left.empty?

      raise Refused, "#{left.map { |r| brief_rel(r) }.join(', ')}: the brief of a role this file no longer has — " \
                     "remove it with the role in this save (\"remove its brief\"), or keep the role"
    end

    # a brief removed in this save: a role the file had and no longer has, its brief on disk (never a type's file)
    def dropped!(repo, agents, drop)
      had = Skills.roles_of(repo)
      drop.each do |role|
        raise Refused, "briefs: #{role} is a role of the new file — its brief stays" if agents.roles.key?(role)
        raise Refused, "briefs: #{role} is no role of the file on disk" unless had.include?(role)
        raise Refused, "briefs: #{brief_rel(role)} is not there" unless File.file?(File.join(repo, brief_rel(role)))
      end
    end

    # the file removed, with the brief of each role it has (all named in drop: never a brief left without its role)
    def remove!(repo, drop)
      roles = Skills.roles_of(repo)
      held = roles.select { |r| File.exist?(File.join(repo, brief_rel(r))) }
      left = held - drop
      unless left.empty?
        raise Refused, "the file's roles still have briefs (#{left.map { |r| brief_rel(r) }.join(', ')}): remove them " \
                       "with the file in this save"
      end
      extra = drop - held
      raise Refused, "briefs: #{extra.join(', ')}: no brief of a role of the file" if extra.any?

      FileUtils.rm_f(path(repo))
      drop.each { |role| FileUtils.rm_f(File.join(repo, brief_rel(role))) }
      [ProjectAgents::FILE] + drop.map { |r| brief_rel(r) }
    end

    # atomic: a temp file in .busyyaks (never in skills/, which a launch may read meanwhile), renamed over the target
    def put!(repo, rel, text, fresh:, expected: nil)
      target = File.join(repo, rel)
      FileUtils.mkdir_p(File.dirname(target))
      Skills.no_link!(repo, File.dirname(target))
      raise Refused, "#{rel} is a symlink: not written" if File.symlink?(target)

      tmp = File.join(repo, Skills::PROJECT_DIR, ".agents-write.#{Process.pid}.tmp")
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW, 0o644) do |f|
        f.write(text)
        f.fsync
      end
      if fresh
        raise Conflict, "#{rel} appeared on disk during the write" if File.exist?(target)
      elsif current(repo).last != expected
        raise Conflict, "#{rel} changed on disk during the write: not overwritten"
      end
      File.rename(tmp, target)
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end
  end
end
