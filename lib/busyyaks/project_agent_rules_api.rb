# frozen_string_literal: true

require_relative "config"
require_relative "kanban"
require_relative "agent_rule_files"
require_relative "agent_rules_api"
require_relative "git_read"
require_relative "launcher_client"
require_relative "workflow_files"
require_relative "writer_client"

module Busyyaks
  # A project's Settings tab: every file of the repo's own `.busyyaks/skills/` (AgentRuleFiles) — agents/<type>.md
  # (add to, or with `mode: replace` replace, busyyaks's rules for the type) and on-demand skills <name>/SKILL.md + their
  # .md files (a busyyaks skill's name replaces that skill for this project) — as [status, body] (the actions are one
  # line each; test/unit/project_agent_rules_test.rb drives this).
  #   show(slug)       → 200 {project, dir (.busyyaks/skills), path (host), types: [{key, label, under, takes,
  #                           standalone}], files: {path => {body, sha, eol, kind (agent · skill · skill_ref), type |
  #                           skill, mode}}, creatable: [agents/<type>.md no file holds yet], errors: {path => why it is
  #                           not editable}, git: {path => committed | modified | added | ignored | untracked |
  #                           deleted}, git_error, max_bytes, launches: {state, reason, budget, replace_budget, layers,
  #                           checkout}, global, global_error} · 404 (a file's body has LF line ends; eol says what the
  #                           file has; a path is relative to dir)
  #   save(slug, body) → the writer's answer (WriterClient: the web mounts the repos read-only): 200 the same as show,
  #                      re-read · 404 · 409 a file changed on disk since it was read · 422 refused (the reason
  #                      verbatim) — body = {files: {path => {base: the loaded sha | null, body: markdown | null (remove)}}}
  # launches = what a launch does with these files, asked of bin/launcher (its own folder-trust decision, layer check
  # and override rule): state loaded · none (no .busyyaks/skills) · left (skills.project deny / the repo is not
  # trusted: the files are NOT read at launch) · refused (the layer is invalid: launches of this project are refused)
  # · unknown (the launcher did not answer — never guessed); layers = {type => Skills.composition}: per type, each
  # file a launch stages and each one the override rule replaced (and by which layer).
  module ProjectAgentRulesAPI
    module_function

    def show(slug, db: Kanban.db, skills: Config.load.skills, root: GitRead.mount)
      project = db[:projects].where(slug: slug.to_s).first or return [404, { error: "no project #{slug}" }]

      cfg = Kanban.config(db)
      types = cfg.agent_type_keys
      files, errors = AgentRuleFiles.read(project, types: types, settings: skills)
      creatable = types.map { |t| AgentRuleFiles.agent_path(t) } - files.keys - errors.keys
      git, git_error = git(project, files, errors, creatable, root)
      [200, { project: project[:slug], dir: AgentRuleFiles::REL, git: git, git_error: git_error,
              path: WorkflowFiles.on_host(File.join(project[:path], AgentRuleFiles::REL)),
              types: cfg.agent_types.map { |t| type_of(t) }, **global(db),
              files: files.transform_values { |f| f.except(:blob) }, creatable: creatable, errors: errors,
              max_bytes: skills.max_bytes, launches: launches(project, Kanban.revision_of(cfg)), },]
    end

    # an agent type as the page names it: key, the Launch bar's label, and what it is (under / takes / standalone)
    def type_of(type)
      { key: type.key, label: type.label, under: type.under, takes: type.takes, standalone: type.standalone ? true : false }
    end

    # busyyaks's own layers (Settings → Agent rules' view, from bin/launcher): what a project's file adds to or
    # replaces → {global: {agent_types, files} | nil, global_error}
    def global(db)
      status, view = AgentRulesAPI.view(db: db)
      return { global: nil, global_error: "#{status} · #{view[:error]}" } unless status == 200

      keys = %i[path source kind load skill description bytes html body replaced_by]
      files = view[:files].select { |f| f[:exists] }.map { |f| f.slice(*keys) }
      { global: { agent_types: view[:agent_types], files: files }, global_error: nil }
    end

    def save(slug, body, by:, db: Kanban.db, skills: Config.load.skills, root: GitRead.mount)
      return [404, { error: "no project #{slug}" }] unless db[:projects].where(slug: slug.to_s).count.positive?
      return [422, { error: "body must be an object {files}" }] unless body.is_a?(Hash) && body.key?("files")

      status, out = WriterClient.agent_rules_save(slug.to_s, body["files"], by: by)
      status == 200 ? show(slug, db: db, skills: skills, root: root) : [status, out]
    end

    # → [{path => state}, nil] or [{}, why git could not be read]
    def git(project, files, errors, creatable, root)
      [AgentRuleFiles.git_states(project, files, errors, also: creatable, root: root), nil]
    rescue GitRead::Failed => e
      [{}, e.message]
    end

    # {state, reason, budget / replace_budget: {type => the bytes its agents file may hold so its launch still starts,
    # adding / replacing} | nil, layers: {type => composition} | nil, checkout: the repo is busyyaks's own checkout
    # (`yaks update` refuses it while a tracked file is uncommitted) | nil}
    def launches(project, revision)
      r = LauncherClient.project_skills(path: project[:path], settings: revision)
      return launcher_refusal(r) unless r["ok"]

      state, reason = r.fetch("project_skills").split(": ", 2)
      { state: state, reason: reason, budget: r.fetch("budget"), replace_budget: r["replace_budget"],
        layers: r["layers"], checkout: r.fetch("checkout"), }
    rescue LauncherClient::Unavailable => e
      unknown(e.message)
    end

    def unknown(why) = { state: "unknown", reason: why, budget: nil, replace_budget: nil, layers: nil, checkout: nil }

    # the op's own refusals are 422 (an invalid layer, a type over its start budget, the folder-trust record: launches
    # ARE refused); an answer without a status is not this op's — an older launcher's "unknown op" — and any other
    # failure says nothing about launches: unknown, said, never "refused"
    def launcher_refusal(res)
      if res["status"] == 422
        return { state: "refused", reason: res["error"].to_s, budget: nil, replace_budget: nil, layers: nil,
                 checkout: nil, }
      end

      why = res["error"].to_s
      why = "launcher protocol error (#{why}): restart it (deploy/install-launcher.sh)" unless res["status"]
      unknown(why)
    end
  end
end
