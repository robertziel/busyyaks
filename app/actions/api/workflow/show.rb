# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Workflow
        # GET /api/projects/*slug/workflow → the project's board shape: {columns: [{key, label, type, x, y}],
        # transitions: [{name, from, to, by}], rules, types, updated_by, updated} — its own rows (the template's copy until
        # edited)
        class Show < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).board_shape(slug(req))) }
          end
        end
      end
    end
  end
end
