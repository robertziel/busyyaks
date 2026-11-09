# frozen_string_literal: true

require "busyyaks/search"
require "busyyaks/kanban"

module Busyyaks
  module Actions
    module API
      # GET /api/search?q= — the command palette's results across the whole app (lib/busyyaks/search.rb).
      class Search < Busyyaks::APIAction
        def handle(req, res)
          q = req.params[:q].to_s
          error!(res, 400, "q is longer than 200 characters") if q.length > 200
          agents, agents_error = agent_sessions
          search = Busyyaks::Search.new(Hanami.app["db.gateway"].connection,
                                        kanban_columns: Busyyaks::Kanban.columns, tables: Busyyaks::Kanban.default.tables)
          json(res, search.run(q, agents: agents, agents_error: agents_error))
        end

        private

        def agent_sessions
          snap = LauncherClient.agents
          [Busyyaks::Agents.groups(snap, store.projects).flat_map { |g| g[2] }, nil]
        rescue LauncherClient::Unavailable, LauncherClient::Refused => e
          [nil, e.message]
        end
      end
    end
  end
end
