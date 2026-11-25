# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Cards
        # POST /api/cards/:id/comment {body, transition?, column?} → 201 {card, activity, delivered, counts?} — a transition
        # = a comment action (posted and moved in one go); on a Human input card the operator's
        # comment is the answer
        class Comment < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).comment(id(req), body(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
