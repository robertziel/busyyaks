# frozen_string_literal: true

require "busyyaks/project_agent_rules_api"

module Busyyaks
  module Actions
    module API
      module ProjectAgentRules
        # GET /api/projects/*slug/agent-rules → the project's rules per agent type (its .busyyaks/skills/agents files)
        # and what a launch does with them
        # (the project's Settings tab; Busyyaks::ProjectAgentRulesAPI.show)
        class Show < Busyyaks::APIAction
          def handle(req, res)
            status, body = Busyyaks::ProjectAgentRulesAPI.show(req.params[:slug].to_s)
            json(res, body, status: status)
          end
        end
      end
    end
  end
end
