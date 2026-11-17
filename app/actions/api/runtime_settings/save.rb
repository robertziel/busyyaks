# frozen_string_literal: true

require "busyyaks/runtime_settings_api"
require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module RuntimeSettings
        # POST /api/settings/runtime {base, doc} → a new revision (200), 409 when base is not the newest, 422
        # refused (Busyyaks::RuntimeSettingsAPI.save)
        class Save < Busyyaks::APIAction
          include KanbanAPI # body(req): the JSON body (a malformed one → 400)

          def handle(req, res)
            refusing(res) do
              status, out = Busyyaks::RuntimeSettingsAPI.save(body(req), by: req.session[:email].to_s)
              json(res, out, status: status)
            end
          end
        end
      end
    end
  end
end
