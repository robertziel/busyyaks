# frozen_string_literal: true

require "busyyaks/setup_api"

module Busyyaks
  module Actions
    module API
      module Setup
        # GET /api/setup/harnesses → the agent CLIs on the host, read by bin/launcher now (Busyyaks::SetupAPI.harnesses;
        # card 520). Its own request: the probe spawns processes, the boot checks stay instant.
        class Harnesses < Busyyaks::APIAction
          def handle(_req, res)
            commands = begin
              Config.load.launch_commands
            rescue Config::Invalid => e # an edit that broke config/busyyaks.yml: its reason, as JSON
              return json(res, { error: "config/busyyaks.yml: #{e.message}" }, status: 500)
            end
            status, body = Busyyaks::SetupAPI.harnesses(launcher: Busyyaks::LauncherClient, commands: commands)
            json(res, body, status: status)
          end
        end
      end
    end
  end
end
