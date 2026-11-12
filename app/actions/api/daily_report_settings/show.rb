# frozen_string_literal: true

require "busyyaks/daily_report_settings_api"

module Busyyaks
  module Actions
    module API
      module DailyReportSettings
        # GET /api/settings/daily-report → the current daily report settings revision, the host runner allowlist and
        # the history (Busyyaks::DailyReportSettingsAPI.show)
        class Show < Busyyaks::APIAction
          def handle(_req, res)
            status, body = Busyyaks::DailyReportSettingsAPI.show
            json(res, body, status: status)
          end
        end
      end
    end
  end
end
