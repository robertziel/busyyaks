# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Cards
        # POST /api/cards/:id/archive {archived: true|false} → {card, activity}
        class Archive < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).archive(id(req), body(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
