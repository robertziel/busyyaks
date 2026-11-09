# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Comments
        # POST|PATCH /api/comments/:id {body} → {card, activity}. Only the comment's author (422 with the reason)
        class Update < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).comment_update(id(req), body(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
