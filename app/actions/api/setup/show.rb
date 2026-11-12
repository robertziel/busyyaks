# frozen_string_literal: true

require "busyyaks/setup_api"
require "busyyaks/github_network"

module Busyyaks
  module Actions
    module API
      module Setup
        # GET /api/setup → the hello screen's boot checks, projects and agent settings (Busyyaks::SetupAPI.show)
        class Show < Busyyaks::APIAction
          def handle(_req, res)
            status, body = Busyyaks::SetupAPI.show(**Show.deps(store))
            json(res, body, status: status)
          end

          def self.deps(store)
            { db: Kanban.db, store: store, config: Config.load, github: Busyyaks::GithubNetwork::Data.default }
          end
        end
      end
    end
  end
end
