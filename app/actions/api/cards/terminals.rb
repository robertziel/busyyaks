# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Cards
        # GET /api/cards/:id/terminals → {sessions: [{session, socket, type, agent, owner, live}], sessions_error} — the
        # agent sessions working on the card (its owner session, then the registrations acting as its assignee:
        # Store#card_sessions) for the card dialog's Terminals section. live = in tmux now; the launcher
        # down → live null for each and sessions_error says why, never "not running".
        class Terminals < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) do
              rows = kanban.card_sessions(id(req))
              live, error = live_names
              json(res, { sessions: rows.map { |r| row(r, live) }, sessions_error: error })
            end
          end

          private

          def row(r, live)
            r.slice(:session, :socket, :type, :agent, :owner, :project).merge(live: live && live.include?(r[:session]))
          end

          def live_names
            [LauncherClient.session_names, nil]
          rescue LauncherClient::Unavailable, LauncherClient::Refused => e
            [nil, e.message]
          end
        end
      end
    end
  end
end
