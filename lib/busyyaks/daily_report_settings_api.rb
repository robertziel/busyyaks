# frozen_string_literal: true

require_relative "daily_report_settings"
require_relative "config"
require_relative "kanban"

module Busyyaks
  # Settings → Daily report: the operator's read and write of the daily report settings revisions, as
  # [status, body] (the actions are one line each; test/unit/daily_report_settings_test.rb drives this directly).
  #   show       → 200 {revision: {id, author, at} | null, doc | null, runners, keys, history (newest 20), revisions, error}
  #   save(body) → 200 the same for the new revision · 409 base is not the newest · 422 refused (the validator's or the
  #                allowlist's reason, verbatim)
  # `error` = why the CURRENT revision does not run (none saved, a runner the host allowlist dropped since): shown on the
  # page, never repaired here.
  module DailyReportSettingsAPI
    module_function

    def show(db: Kanban.db, runners: Config.load.daily_report_runners)
      cur = DailyReportSettings.current(db)
      state, out = DailyReportSettings.resolve(db, runners)
      [200, { revision: cur&.slice(:id, :author, :at), doc: cur&.dig(:doc), runners: runners,
              host_keys: DailyReportSettings::HOST_KEYS, runner_keys: DailyReportConfig::RUNNERS,
              history: DailyReportSettings.history(db), revisions: DailyReportSettings.revisions(db),
              error: state == :ok ? nil : out, },]
    end

    def save(body, by:, db: Kanban.db, runners: Config.load.daily_report_runners)
      return [422, { error: "body must be an object {base, doc}" }] unless body.is_a?(Hash) && body.key?("base")

      base = body["base"]
      return [422, { error: "base (the revision id the editor loaded, null for none) is required" }] \
        unless base.nil? || base.is_a?(Integer)

      DailyReportSettings.save!(db, doc: body["doc"], base: base, author: by, runners: runners)
      show(db: db, runners: runners)
    rescue DailyReportSettings::Conflict => e
      [409, { error: e.message }]
    rescue DailyReportSettings::Refused => e
      [422, { error: e.message }]
    end
  end
end
