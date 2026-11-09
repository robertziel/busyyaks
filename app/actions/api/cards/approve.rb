# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Cards
        # POST /api/cards/:id/approve {approved: true|false} — the operator approves a card at its approval step
        # (rules.gates.approvals: the handoff check, the approve gate) or withdraws it
        class Approve < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).approve(id(req), body(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
