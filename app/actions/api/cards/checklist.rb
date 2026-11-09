# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Cards
        # POST /api/cards/:id/checklists {title, items?} → 201 {card, activity}
        class Checklist < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).checklist_create(id(req), body(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
