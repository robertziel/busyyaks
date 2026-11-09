# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Labels
        # DELETE /api/labels/:id → {labels}. The label leaves the set and every card of the board
        class Destroy < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).label_delete(id(req))) }
          end
        end
      end
    end
  end
end
