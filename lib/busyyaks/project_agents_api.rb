# frozen_string_literal: true

require_relative "kanban"
require_relative "launcher_client"
require_relative "writer_client"
require_relative "workflow_files"
require_relative "project_agents_file"
require_relative "agent_presets"

module Busyyaks
  # The project page's Settings tab → Agent types: the repo's .busyyaks/agents.yml — which opt-in agent types
  # the board uses, its own roles, which type or role works each column — as [status, body].
  #   show(slug)       → 200 {project, file, path (host), text | null, sha | null, error (unreadable), columns: [{key,
  #                      label, type}], types: [{key, label, opt_in}] (the types a lead starts), presets: [keys],
  #                      launches: {state, reason, agents} (bin/launcher's project_agents op: loaded · none · left +
  #                      why (the file is NOT read: untrusted / skills.project deny) · refused + why (an invalid file:
  #                      every launch on the board is refused) · unknown + why (the launcher did not answer)),
  #                      briefs: {name => exists}, roles: [the file's role names]} · 404
  #   save(slug, body) → the writer's answer: 200 the same as show, re-read · 404 · 409 · 422 — body = {base, text,
  #                      briefs: {role => markdown (a new role's brief) | null (remove a dropped role's brief)}}
  module ProjectAgentsAPI
    module_function

    def show(slug, db: Kanban.db)
      project = db[:projects].where(slug: slug.to_s).first or return [404, { error: "no project #{slug}" }]

      cfg = Kanban.config(db)
      rev = Kanban.revision_of(cfg)
      text, sha, error = read(project)
      board = Kanban.default.board_of(project[:slug])
      opt_in = AgentSettings.opt_in(rev[:doc])
      [200, { project: project[:slug], file: ProjectAgents::FILE, text: text, sha: sha, error: error,
              path: WorkflowFiles.on_host(ProjectAgentsFile.path(project[:path])),
              columns: board.keys.map { |k| { key: k, label: board.label(k), type: board.type_of(k).key } },
              types: cfg.agent_types.select(&:under).map { |t| { key: t.key, label: t.label, opt_in: opt_in.include?(t.key) } },
              presets: presets, launches: launches(project, rev), briefs: briefs(project), roles: roles(project), },]
    end

    def save(slug, body, by:, db: Kanban.db)
      return [404, { error: "no project #{slug}" }] unless db[:projects].where(slug: slug.to_s).count.positive?
      return [422, { error: "body must be an object {base, text, briefs}" }] unless body.is_a?(Hash)

      status, out = WriterClient.project_agents_save(slug.to_s, body.slice("base", "text", "briefs"), by: by)
      status == 200 ? show(slug, db: db) : [status, out]
    end

    # → [text | nil, sha | nil, error | nil]
    def read(project)
      bytes, sha = ProjectAgentsFile.current(project[:path])
      return [nil, nil, nil] if bytes.nil?

      text = bytes.dup.force_encoding(Encoding::UTF_8)
      text.valid_encoding? ? [text, sha, nil] : [nil, sha, "#{ProjectAgents::FILE} is not UTF-8"]
    rescue ProjectAgentsFile::Refused, SystemCallError => e
      [nil, nil, e.message]
    end

    # every role brief file the repo's layer holds now, by name ({name => true}): the editor asks a brief for a new role
    def briefs(project)
      dir = File.join(project[:path], Skills::PROJECT_DIR, "skills", Skills::AGENTS)
      return {} unless File.directory?(dir)

      Dir.children(dir).select { |f| f.end_with?(".md") }.to_h { |f| [f.delete_suffix(".md"), true] }
    end

    # the role names of the file on disk (Skills.roles_of: the one read; unreadable → none, the file's own error says
    # why) — the editor offers "remove its brief" for each, so a role and its brief go in one save
    def roles(project)
      Skills.roles_of(project[:path])
    rescue Skills::Invalid
      []
    end

    def presets
      AgentPresets.keys
    end

    # the loaded file's columns against the board NOW (BoardAgents#state refuses every spawn the same way): why, or nil
    def stale_columns(project, agents)
      return nil unless agents

      b = Kanban.default.board_of(project[:slug])
      ProjectAgents.board_columns!(ProjectAgents.from_h(agents), b.keys.to_h { |k| [k, b.type_of(k).key] })
      nil
    rescue ProjectAgents::Invalid => e
      "kanban_spawn and kanban_assign_worker are refused: #{e.message}"
    end

    # bin/launcher's answer for the file (its own trust decision); a 422 = the file is invalid: launches ARE refused
    def launches(project, revision)
      r = LauncherClient.project_agents(path: project[:path], settings: revision)
      if r["ok"]
        state, reason = r.fetch("state").split(": ", 2)
        stale = stale_columns(project, r["agents"])
        return { state: "refused", reason: stale, agents: r["agents"] } if stale

        return { state: state, reason: reason, agents: r["agents"] }
      end
      return { state: "refused", reason: r["error"].to_s, agents: nil } if r["status"] == 422

      why = r["error"].to_s
      why = "launcher protocol error (#{why}): restart it (deploy/install-launcher.sh)" unless r["status"]
      { state: "unknown", reason: why, agents: nil }
    rescue LauncherClient::Unavailable => e
      { state: "unknown", reason: e.message, agents: nil }
    end
  end
end
