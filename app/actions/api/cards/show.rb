# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Cards
        # GET /api/cards/:id → {card, activity, links, pings, …}
        class Show < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).card(id(req))) }
          end
        end
      end
    end
  end
end
