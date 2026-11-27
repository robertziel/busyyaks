# frozen_string_literal: true

require "busyyaks/project_agents_api"
require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module ProjectAgents
        # POST /api/projects/*slug/agents {base, text, briefs} → the repo's .busyyaks/agents.yml (+ new roles' briefs)
        # written through the writer service (200: re-read); 404, 409 changed on disk, 422 refused, 503 the writer is
        # down, 504 no answer in time (Busyyaks::ProjectAgentsAPI.save)
        class Save < Busyyaks::APIAction
          include KanbanAPI # body(req): the JSON body (a malformed one → 422)

          def handle(req, res)
            refusing(res) do
              status, out = Busyyaks::ProjectAgentsAPI.save(req.params[:slug].to_s, body(req), by: req.session[:email].to_s)
              json(res, out, status: status)
            rescue WriterClient::Unavailable => e
              json(res, { error: e.message }, status: 503)
            rescue WriterClient::NoAnswer => e
              json(res, { error: e.message }, status: 504)
            end
          end
        end
      end
    end
  end
end
