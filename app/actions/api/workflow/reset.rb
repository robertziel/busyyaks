# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Workflow
        # DELETE /api/projects/*slug/workflow → the template board again for this project (refused while cards sit in a
        # column the template lacks)
        class Reset < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).board_shape_reset(slug(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
