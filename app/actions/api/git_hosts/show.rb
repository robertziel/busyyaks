# frozen_string_literal: true

require "busyyaks/git_hosts_api"

module Busyyaks
  module Actions
    module API
      module GitHosts
        # GET /api/settings/git-hosts → the providers, the connected one, its collector's last run
        class Show < Busyyaks::APIAction
          def handle(_req, res)
            status, out = Busyyaks::GitHostsAPI.show
            json(res, out, status: status)
          end
        end
      end
    end
  end
end
