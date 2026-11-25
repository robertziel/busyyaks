# frozen_string_literal: true

require "busyyaks/git_hosts_api"

module Busyyaks
  module Actions
    module API
      module GitHosts
        # DELETE /api/settings/git-hosts → none connected (200), 503 github service down, 504
        class Disconnect < Busyyaks::APIAction
          def handle(req, res)
            status, out = Busyyaks::GitHostsAPI.disconnect(by: req.session[:email].to_s)
            json(res, out, status: status)
          end
        end
      end
    end
  end
end
