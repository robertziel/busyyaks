# frozen_string_literal: true

require "busyyaks/setup_api"

module Busyyaks
  module Actions
    module API
      module Setup
        # GET /api/setup/browse?path=<host dir> → its subdirs for the projects dir picker (card 532)
        class Browse < Busyyaks::APIAction
          def handle(req, res)
            status, body = Busyyaks::SetupAPI.browse(path: req.params[:path].to_s)
            json(res, body, status: status)
          end
        end
      end
    end
  end
end
