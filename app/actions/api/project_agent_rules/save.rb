# frozen_string_literal: true

require "busyyaks/project_agent_rules_api"
require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module ProjectAgentRules
        # POST /api/projects/*slug/agent-rules {files: {type => {base, body}}} → the project's rules per agent type
        # written as the repo's .busyyaks/skills/agents/<type>.md, through the writer service (200: the files re-read);
        # 404 no such project, 409 a file changed on disk since the editor read it, 422 refused, 503 the writer is
        # down, 504 it took the request but did not answer in time (Busyyaks::ProjectAgentRulesAPI.save)
        class Save < Busyyaks::APIAction
          include KanbanAPI # body(req): the JSON body (a malformed one → 422)

          def handle(req, res)
            refusing(res) do
              status, out = Busyyaks::ProjectAgentRulesAPI.save(req.params[:slug].to_s, body(req),
                                                                by: req.session[:email].to_s)
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
