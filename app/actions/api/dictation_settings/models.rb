# frozen_string_literal: true

require "busyyaks/dictation_settings_api"
require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module DictationSettings
        # POST /api/settings/dictation/models {url, token} → the models that server lists, nothing saved (200
        # {models, models_error}), 422 refused (Busyyaks::DictationSettingsAPI.models)
        class Models < Busyyaks::APIAction
          include KanbanAPI # body(req): the JSON body (a malformed one → 400)

          def handle(req, res)
            refusing(res) do
              status, out = Busyyaks::DictationSettingsAPI.models(body(req))
              json(res, out, status: status)
            end
          end
        end
      end
    end
  end
end
