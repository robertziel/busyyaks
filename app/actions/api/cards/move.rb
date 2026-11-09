# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Cards
        # POST /api/cards/:id/move {column, position?} → {card, counts, delivered}
        class Move < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).move(id(req), body(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
