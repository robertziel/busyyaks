# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Board
        # GET /api/projects/*slug/board[?column=&archived=1] — docs/API-kanban.md
        class Show < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) do
              answer(res, api(req).board(slug(req), column: req.params[:column].to_s, archived: req.params[:archived] == "1"))
            end
          end
        end
      end
    end
  end
end
