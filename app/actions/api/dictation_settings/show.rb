# frozen_string_literal: true

require "busyyaks/dictation_settings_api"

module Busyyaks
  module Actions
    module API
      module DictationSettings
        # GET /api/settings/dictation → what the mic runs (the token redacted), the models its server lists, the history
        # (Busyyaks::DictationSettingsAPI.show)
        class Show < Busyyaks::APIAction
          def handle(_req, res)
            status, body = Busyyaks::DictationSettingsAPI.show
            json(res, body, status: status)
          end
        end
      end
    end
  end
end
