# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module ChecklistItems
        # POST /api/checklist-items/:id/convert → 201 {card, activity, created: Card} — card/activity are the parent's
        class Convert < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).item_convert(id(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
