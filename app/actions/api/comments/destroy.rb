# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Comments
        # DELETE /api/comments/:id → {card, activity}. Only the author; the deletion stays in the history
        class Destroy < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).comment_delete(id(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
