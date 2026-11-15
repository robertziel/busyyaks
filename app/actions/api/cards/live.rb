# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Cards
        # GET /api/cards/:id/live → {sessions: {name => live}} — what the card's agent sessions do now; the
        # open card dialog polls it
        class Live < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            answer(res, card_live(id(req)))
          end
        end
      end
    end
  end
end
