# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Board
        # GET /api/projects/*slug/board/rev[?archived=1] → {rev} — polled by the board every few seconds; the full board is
        # fetched only when this changes
        class Rev < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { res.headers["Cache-Control"] = "no-store"
                            answer(res, api(req).board_rev(slug(req), archived: req.params[:archived] == "1")) }
          end
        end
      end
    end
  end
end
