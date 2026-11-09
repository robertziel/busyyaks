# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Waiting
        # GET /api/waiting → {waiting_columns, total, projects: [{slug, icon, count, cards: [{id, title, column, column_label,
        # kind, since, needs_operator, blocked, question_first_line, blocked_first_line, handoff_first_line}]}]} — the cards
        # waiting for the operator on every board (the engine's Api#waiting: the flagged cards in any column + the cards
        # in the gate columns). busyyaks adds each project's icon, each card's kind: "ask" = flagged needs_operator (a
        # question, in whatever column), "review" = in a gate column (work to check / a PR to merge), "blocked" = flagged
        # blocked_external, else the column's own key — and its owner_session (null = none), which the widget matches
        # against /api/agents to show whether that agent is running / blocked.
        class Index < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            res.headers["Cache-Control"] = "no-store"
            projects = store.projects
            status, body = api(req).waiting(projects)
            body = Index.enrich(body, projects, kanban.waiting_cards(projects.map { |p| p[:slug] })) if status == 200
            answer(res, [status, body])
          end

          def self.enrich(body, projects, waiting)
            icons = projects.to_h { |p| [p[:slug], Busyyaks::API.icon_url(p)] }
            owners = waiting.by_slug.values.flatten.to_h { |c| [c[:id], c[:owner_session]] }
            body.merge(projects: body[:projects].map do |g|
              b = waiting.boards.fetch(g[:slug])
              cards = g[:cards].map { |c| c.merge(kind: kind(c, b), owner_session: owners[c[:id]]) }
              g.merge(icon: icons[g[:slug]], cards: cards)
            end)
          end

          def self.kind(card, board)
            return "ask" if card[:needs_operator]
            return "blocked" if card[:blocked] # a flag beats the column: the card waits for the blocker, not a review
            return "review" if board.gate?(card[:column])

            card[:column]
          end
        end
      end
    end
  end
end
