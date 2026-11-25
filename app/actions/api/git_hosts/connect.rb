# frozen_string_literal: true

require "busyyaks/git_hosts_api"
require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module GitHosts
        # POST /api/settings/git-hosts {provider, token} → connected (200), 422 refused, 503 github service down, 504
        class Connect < Busyyaks::APIAction
          include KanbanAPI # body(req): the JSON body (a malformed one → 400)

          def handle(req, res)
            refusing(res) do
              status, out = Busyyaks::GitHostsAPI.connect(body(req), by: req.session[:email].to_s)
              json(res, out, status: status)
            end
          end
        end
      end
    end
  end
end
