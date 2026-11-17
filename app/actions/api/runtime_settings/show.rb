# frozen_string_literal: true

require "busyyaks/runtime_settings_api"

module Busyyaks
  module Actions
    module API
      module RuntimeSettings
        # GET /api/settings/runtime → the current runtime settings revision (the services' timing), its keys
        # and the history (Busyyaks::RuntimeSettingsAPI.show)
        class Show < Busyyaks::APIAction
          def handle(_req, res)
            status, body = Busyyaks::RuntimeSettingsAPI.show
            json(res, body, status: status)
          end
        end
      end
    end
  end
end
