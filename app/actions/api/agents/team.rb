# frozen_string_literal: true

module Busyyaks
  module Actions
    module API
      module Agents
        # GET /api/agents/team?session=&socket= — one session's subagents, workflows, background tasks.
        class Team < Busyyaks::APIAction
          def handle(req, res)
            session = req.params[:session].to_s
            error!(res, 400, "session is required") if session.empty?

            r = LauncherClient.agent_tasks(session: session, socket: req.params[:socket].to_s)
            json(res, Busyyaks::Agents.team(r))
          end
        end
      end
    end
  end
end
