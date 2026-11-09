# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Board
        # GET /api/boards → {columns, columns_order, waiting_columns, waiting, theme,
        #                    boards: [{project, counts, total, waiting, backlog_md}]}
        # (waiting = cards waiting for the operator: the config's `waiting` columns) — projects with cards or a backlog/.
        class Index < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            status, out = api(req).boards(store.projects)
            json(res, out.merge(theme: Kanban.config.theme), status: status)
          end
        end
      end
    end
  end
end
