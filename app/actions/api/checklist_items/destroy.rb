# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module ChecklistItems
        # DELETE /api/checklist-items/:id → {card, activity}
        class Destroy < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).item_delete(id(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
