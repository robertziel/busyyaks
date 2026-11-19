# frozen_string_literal: true

require "busyyaks/update_api"

module Busyyaks
  module Actions
    module API
      module UpdateSettings
        # GET /api/settings/update → this checkout vs its updates remote + the last update (card 536)
        class Show < Busyyaks::APIAction
          def handle(_req, res)
            status, body = Busyyaks::UpdateAPI.status
            json(res, body, status: status)
          end
        end
      end
    end
  end
end
