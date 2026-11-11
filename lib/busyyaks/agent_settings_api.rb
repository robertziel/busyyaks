# frozen_string_literal: true

require_relative "agent_settings"
require_relative "config"
require_relative "kanban"

module Busyyaks
  # Settings → Agents & launchers: the operator's read and write of the agent settings revisions, as
  # [status, body] (the actions are one line each; test/unit/agent_settings_test.rb drives this directly).
  #   show       → 200 {revision: {id, author, at}, doc, commands, history, preview, error}
  #   save(body) → 200 the same for the new revision · 409 base is not the newest · 422 refused (the engine's or the
  #                allowlist's reason, verbatim)
  # `error` = why the CURRENT revision does not run (a command the host allowlist dropped since it was saved, a value an
  # upgraded engine refuses): shown on the page, never repaired here.
  module AgentSettingsAPI
    PREVIEW_SESSION = "SESSION" # the tmux name a launch gets; the preview shows where it goes

    module_function

    def show(db: Kanban.db, commands: Config.load.launch_commands)
      cur = AgentSettings.current(db)
      preview, error = preview(cur[:doc], commands)
      body = { revision: cur.slice(:id, :author, :at), doc: cur[:doc], commands: commands,
               history: AgentSettings.history(db), preview: preview, error: error, }
      [200, body]
    end

    def save(body, by:, db: Kanban.db, commands: Config.load.launch_commands)
      base = body["base"]
      return [422, { error: "base (the revision id the editor loaded) is required" }] unless base.is_a?(Integer)

      AgentSettings.save!(db, file: Kanban.file_config, doc: body["doc"], base: base, author: by, commands: commands)
      show(db: db, commands: commands)
    rescue AgentSettings::Conflict => e
      [409, { error: e.message }]
    rescue AgentSettings::Refused => e
      [422, { error: e.message }]
    end

    # Every agent type × each of its launchers → the argv a launch runs (the prompt, typed after it, not shown).
    def preview(doc, commands)
      cfg = AgentSettings.allowed!(AgentSettings.host(Kanban.file_config, doc), commands)
      rows = cfg.agent_types.flat_map do |t|
        t.launchers.map do |lk|
          { type: t.key, launcher: lk, model: t.model_for(lk),
            argv: AgentsKanban::Launch.argv(cfg, type: t.key, launcher: lk, session: PREVIEW_SESSION), }
        end
      end
      [rows, nil]
    rescue AgentSettings::Error, AgentsKanban::ConfigError, AgentsKanban::Invalid => e
      [[], e.message]
    end
  end
end
