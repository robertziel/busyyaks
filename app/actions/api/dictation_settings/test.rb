# frozen_string_literal: true

require "busyyaks/dictation_settings_api"
require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module DictationSettings
        # POST /api/settings/dictation/test {doc} → one second of silence through the doc's server + model, not saved (200
        # {text, words, ms}), 422 refused, 502 the server's error (Busyyaks::DictationSettingsAPI.check)
        class Test < Busyyaks::APIAction
          include KanbanAPI # body(req): the JSON body (a malformed one → 400)

          def handle(req, res)
            refusing(res) do
              status, out = Busyyaks::DictationSettingsAPI.check(body(req))
              json(res, out, status: status)
            end
          end
        end
      end
    end
  end
end
