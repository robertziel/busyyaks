# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Cards
        # GET /api/cards/:id/rev → {rev} — the open card dialog polls it
        class Rev < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).card_rev(id(req))) }
          end
        end
      end
    end
  end
end
