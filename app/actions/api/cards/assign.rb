# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Cards
        # POST /api/cards/:id/assign {assignee} ("" or null unassigns) → {card, activity}
        class Assign < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).assign(id(req), body(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
