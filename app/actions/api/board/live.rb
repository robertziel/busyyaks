# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Board
        # GET /api/projects/*slug/board/live → {sessions: {name => live}} — what the board's agent sessions do now; the
        # board polls it for the working glow
        class Live < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            res.headers["Cache-Control"] = "no-store"
            answer(res, board_live(slug(req)))
          end
        end
      end
    end
  end
end
