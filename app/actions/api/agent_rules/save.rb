# frozen_string_literal: true

require "busyyaks/agent_rules_api"
require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module AgentRules
        # POST /api/settings/agent-rules {files: {path => {base, body}}} → busyyaks's own skills files written in its
        # checkout through the writer service (200: re-read); 409 a file changed on disk since the editor read it, 422
        # refused, 503 the writer or the launcher is down, 504 the writer took it but did not answer in time
        class Save < Busyyaks::APIAction
          include KanbanAPI # body(req): the JSON body (a malformed one → 422)

          def handle(req, res)
            refusing(res) do
              status, out = Busyyaks::AgentRulesAPI.save(body(req), by: req.session[:email].to_s)
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
