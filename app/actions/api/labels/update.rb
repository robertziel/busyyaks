# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Labels
        # POST|PATCH /api/labels/:id {name?, color?} → {label, labels}. A rename rewrites every card carrying it
        class Update < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).label_update(id(req), body(req))) }
          end
        end
      end
    end
  end
end
