# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Cards
        # POST /api/cards/:id/pr-unassign {pr_url, reason} — the operator takes one PR off the card's list (logged
        # with the reason, kept in metadata prs_removed). PRs are assigned only by the agents that open them.
        class PrUnassign < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).pr_unassign(id(req), body(req), by: req.session[:email])) }
          end
        end
      end
    end
  end
end
