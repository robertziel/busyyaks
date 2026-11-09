# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Cards
        # POST|PATCH /api/cards/:id {title?, description?, labels?, assignee?, priority?, due?, due_done?, cover?, parent?,
        # metadata?} → {card, activity}
        class Update < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).update(id(req), body(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
