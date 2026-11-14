# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module SessionBoards
        # GET /api/session-boards[?archived=1] → the engine's Api#session_boards: {idle_hours, slug_prefix,
        # session_boards: [{slug, session, archived, last_activity, expires, columns, cards}]} — every agent session's own
        # board (written only by that session through the kanban_session_board tool), read-only here.
        # config/kanban.yml session_boards: null → 404 with the reason.
        class Index < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            res.headers["Cache-Control"] = "no-store"
            answer(res, api(req).session_boards(archived: req.params[:archived].to_s == "1"))
          end
        end
      end
    end
  end
end
