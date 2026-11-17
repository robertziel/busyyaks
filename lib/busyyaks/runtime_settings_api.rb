# frozen_string_literal: true

require_relative "runtime_settings"
require_relative "kanban"

module Busyyaks
  # Settings → Runtime: the operator's read and write of the services' timing revisions, as
  # [status, body] (the actions are one line each; test/unit/runtime_settings_test.rb drives this directly).
  #   show       → 200 {revision: {id, author, at}, doc, keys: {key => {env, about}}, min, max, history (newest 20),
  #                     revisions}
  #   save(body) → 200 the same for the new revision · 409 base is not the newest · 422 refused (the validator's reason,
  #                verbatim)
  module RuntimeSettingsAPI
    module_function

    def show(db: Kanban.db)
      cur = RuntimeSettings.current(db) or raise RuntimeSettings::Missing, "no runtime settings revision"
      [200, { revision: cur.slice(:id, :author, :at), doc: cur[:doc],
              keys: RuntimeSettings::KEYS.transform_values { |env, about| { env: env, about: about } },
              min: RuntimeSettings::BOUNDS.min, max: RuntimeSettings::BOUNDS.max,
              history: RuntimeSettings.history(db), revisions: RuntimeSettings.revisions(db), },]
    end

    def save(body, by:, db: Kanban.db)
      return [422, { error: "body must be an object {base, doc}" }] unless body.is_a?(Hash)

      base = body["base"]
      return [422, { error: "base (the revision id the editor loaded) is required" }] unless base.is_a?(Integer)

      RuntimeSettings.save!(db, doc: body["doc"], base: base, author: by)
      show(db: db)
    rescue RuntimeSettings::Conflict => e
      [409, { error: e.message }]
    rescue RuntimeSettings::Refused => e
      [422, { error: e.message }]
    end
  end
end
