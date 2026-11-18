# frozen_string_literal: true

require "busyyaks/setup_api"

module Busyyaks
  module Actions
    module API
      module Setup
        # GET /api/setup/projects-root → the current projects dir + the last change (card 532)
        class ProjectsRoot < Busyyaks::APIAction
          def handle(_req, res)
            status, body = Busyyaks::SetupAPI.projects_root(step: "status")
            json(res, body, status: status)
          end
        end
      end
    end
  end
end
