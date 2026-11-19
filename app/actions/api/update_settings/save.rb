# frozen_string_literal: true

require "busyyaks/update_api"

module Busyyaks
  module Actions
    module API
      module UpdateSettings
        # POST /api/settings/update {step: check} → a check now · {step: apply, mode: tags|branch, sha} → the update
        # started on the host (card 536)
        class Save < Busyyaks::APIAction
          def handle(req, res)
            status, body = case req.params[:step].to_s
                           when "check" then Busyyaks::UpdateAPI.check
                           when "apply"
                             Busyyaks::UpdateAPI.apply(mode: req.params[:mode].to_s, sha: req.params[:sha].to_s)
                           else [400, { error: "step must be check or apply" }]
                           end
            json(res, body, status: status)
          end
        end
      end
    end
  end
end
