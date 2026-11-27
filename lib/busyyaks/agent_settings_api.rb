# frozen_string_literal: true

require_relative "agent_settings"
require_relative "config"
require_relative "kanban"
require_relative "skills"
require_relative "agent_presets"

module Busyyaks
  # Settings → Agents & launchers: the operator's read and write of the agent settings revisions, as
  # [status, body] (the actions are one line each; test/unit/agent_settings_test.rb drives this directly).
  #   show       → 200 {revision: {id, author, at}, doc, commands, history, preview, error, presets, colors,
  #                face_theme}
  #                presets = config/agent_presets.yml: the "Add from preset" list, each an agent type without
  #                launchers + its one-line description; colors = AgentSettings::COLORS {name => css} (a type's `color`);
  #                face_theme = {type key => css} the file's theme gives a type with no colour of its own
  #   save(body) → 200 the same for the new revision · 409 base is not the newest · 422 refused (the engine's or the
  #                allowlist's reason, verbatim)
  # `error` = why the CURRENT revision does not run (a command the host allowlist dropped since it was saved, a value an
  # upgraded engine refuses): shown on the page, never repaired here.
  module AgentSettingsAPI
    PREVIEW_SESSION = "SESSION" # the tmux name a launch gets; the preview shows where it goes
    PREVIEW_STAGE = "$LAUNCHER_STATE_DIR/skills/SESSION" # the launch's own skills stage (bin/launcher)
    PREVIEW_PROMPT = "<the type's prompt>"
    PREVIEW_TOKEN = "0" * 12 # a hermes launch's per-launch skill token (random), shown as <token>

    module_function

    def show(db: Kanban.db, commands: Config.load.launch_commands)
      cur = AgentSettings.current(db)
      preview, error = preview(cur[:doc], commands)
      body = { revision: cur.slice(:id, :author, :at), doc: cur[:doc], commands: commands,
               history: AgentSettings.history(db), preview: preview, error: error,
               presets: AgentPresets.load!, colors: AgentSettings::COLORS, face_theme: face_theme, }
      [200, body]
    end

    # {type key => css} the host config file's theme gives a type's faces: the colour a type with no `color`
    # of its own wears; a key in neither = the engine's hashed hue
    def face_theme(file = Kanban.file_config)
      prefix = "--ak-face-type-"
      file.fetch("theme", {}).select { |k, _| k.start_with?(prefix) }.transform_keys { |k| k.delete_prefix(prefix) }
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

    # Every agent type × each of its launchers → the argv a launch runs, as bin/launcher builds it: what busyyaks adds
    # for the session's skills and board MCP (Skills' delivery for the launcher's kind: claude_code --mcp-config
    # <stage>/mcp.json --plugin-dir <stage> and the prompt behind /busyyaks:session; hermes -s busyyaks-session-<token>)
    # included, the prompt itself shown as a placeholder. It is the AGENT's argv: bin/launcher runs it inside tmux
    # (`bash -ic '…; exec bash'` with the session's env) and, with launch.scopes set, a systemd user scope — the page
    # says so beside it rather than imitating those wrappers here.
    def preview(doc, commands)
      cfg = AgentSettings.allowed!(AgentSettings.host(Kanban.file_config, doc), commands)
      rows = cfg.agent_types.flat_map do |t|
        t.launchers.map do |lk|
          d = preview_delivery(cfg.launcher(lk).kind)
          argv = AgentsKanban::Launch.argv(cfg, type: t.key, launcher: lk, session: PREVIEW_SESSION,
                                                extra: d.extra(PREVIEW_STAGE),
                                                prompt: d.prompt(t.prompt && PREVIEW_PROMPT))
          { type: t.key, launcher: lk, model: t.model_for(lk), argv: argv.map { _1.gsub(PREVIEW_TOKEN, "<token>") } }
        end
      end
      [rows, nil]
    rescue AgentSettings::Error, AgentsKanban::ConfigError, AgentsKanban::Invalid, Skills::Invalid => e
      [[], e.message]
    end

    def preview_delivery(kind) = kind == "hermes" ? Skills::Hermes.new(PREVIEW_TOKEN) : Skills.delivery(kind)
  end
end
