# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Cards
        # POST /api/cards/:id/dialog-answer {key} → {card, activity} — the operator (web, session + CSRF; no MCP tool)
        # answers the session dialog on this card; the launcher presses the key only while the screen still shows it
        # (422 otherwise, 503 launcher down)
        class DialogAnswer < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).dialog_answer(id(req), body(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
