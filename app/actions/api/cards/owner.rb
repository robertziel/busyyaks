# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Cards
        # POST /api/cards/:id/owner {session, socket?} — the tmux session responsible for the card ("" clears it)
        class Owner < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).owner(id(req), body(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
