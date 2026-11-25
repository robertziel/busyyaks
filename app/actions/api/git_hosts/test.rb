# frozen_string_literal: true

require "busyyaks/git_hosts_api"

module Busyyaks
  module Actions
    module API
      module GitHosts
        # POST /api/settings/git-hosts/test → the stored token checked again by its host (200 {ok, login, same}), 422
        # refused (none connected, the token rejected), 503 the host or the github service unreachable, 504
        class Test < Busyyaks::APIAction
          def handle(req, res)
            status, out = Busyyaks::GitHostsAPI.test(by: req.session[:email].to_s)
            json(res, out, status: status)
          end
        end
      end
    end
  end
end
