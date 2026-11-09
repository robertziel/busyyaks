# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Labels
        # POST /api/projects/*slug/labels {name, color} → 201 {label, labels}
        class Create < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).label_create(slug(req), body(req))) }
          end
        end
      end
    end
  end
end
