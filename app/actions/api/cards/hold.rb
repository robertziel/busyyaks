# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Cards
        # POST /api/cards/:id/hold {on_hold: true|false} → {card, activity} — the operator's On hold
        class Hold < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).hold(id(req), body(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
