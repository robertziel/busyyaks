# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Checklists
        # POST /api/checklists/:id/items {body} → 201 {card, activity}
        class Item < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).item_create(id(req), body(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
