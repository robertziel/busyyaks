# frozen_string_literal: true

require "busyyaks/agent_rules_api"

module Busyyaks
  module Actions
    module API
      module AgentRules
        # GET /api/settings/agent-rules → busyyaks's own skills layers per agent type, in the order a launch stages them,
        # read from bin/launcher (Busyyaks::AgentRulesAPI.show); 503 the launcher is down or too old
        class Show < Busyyaks::APIAction
          def handle(_req, res)
            status, body = Busyyaks::AgentRulesAPI.show
            json(res, body, status: status)
          end
        end
      end
    end
  end
end
