# frozen_string_literal: true

require "busyyaks/agent_settings_api"

module Busyyaks
  module Actions
    module API
      module AgentSettings
        # GET /api/settings/agents → the current agent settings revision (launchers + agent types), the host allowlist,
        # the history and the argv each type × launcher runs (Busyyaks::AgentSettingsAPI.show)
        class Show < Busyyaks::APIAction
          def handle(_req, res)
            status, body = Busyyaks::AgentSettingsAPI.show
            json(res, body, status: status)
          end
        end
      end
    end
  end
end
