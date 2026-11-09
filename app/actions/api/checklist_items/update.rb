# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module ChecklistItems
        # POST|PATCH /api/checklist-items/:id {body?, done?} → {card, activity}
        class Update < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).item_update(id(req), body(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
