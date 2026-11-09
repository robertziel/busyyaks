# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Board
        # POST /api/projects/*slug/board {title, column, description?, labels?, assignee?, priority?, due?, parent?,
        # metadata?} → 201 {card, activity}
        class Create < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).create(slug(req), body(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
