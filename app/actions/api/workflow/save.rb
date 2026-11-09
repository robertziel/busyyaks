# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Workflow
        # POST /api/projects/*slug/workflow {columns, transitions} → the saved board shape (the engine's boards tables, replaced
        # as a whole); 422 with the reason when it does not validate or drops a column that still holds cards
        class Save < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).board_shape_save(slug(req), body(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
