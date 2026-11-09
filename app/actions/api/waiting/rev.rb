# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Waiting
        # GET /api/waiting/rev → {rev} — polled by the waiting widget; /api/waiting is fetched only when it changes
        class Rev < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            res.headers["Cache-Control"] = "no-store"
            answer(res, api(req).waiting_rev(store.projects))
          end
        end
      end
    end
  end
end
