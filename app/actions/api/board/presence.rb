# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Board
        # GET /api/projects/*slug/board/presence → {cards: {id => [{session, agent, type, why, live}]}} — the agents at
        # work on each card right now, polled by the board for the faces on its cards
        class Presence < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            res.headers["Cache-Control"] = "no-store"
            answer(res, board_presence(slug(req)))
          end
        end
      end
    end
  end
end
