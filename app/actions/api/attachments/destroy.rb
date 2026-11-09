# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Attachments
        # DELETE /api/attachments/:id → {card, activity}. Soft delete, logged; the web user is the operator: may delete any
        class Destroy < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).attachment_delete(id(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
