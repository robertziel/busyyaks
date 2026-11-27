# frozen_string_literal: true

require "busyyaks/project_agents_api"

module Busyyaks
  module Actions
    module API
      module ProjectAgents
        # GET /api/projects/*slug/agents → the repo's .busyyaks/agents.yml and what a launch does with it
        # (Busyyaks::ProjectAgentsAPI.show)
        class Show < Busyyaks::APIAction
          def handle(req, res)
            status, body = Busyyaks::ProjectAgentsAPI.show(req.params[:slug].to_s)
            json(res, body, status: status)
          end
        end
      end
    end
  end
end
