# frozen_string_literal: true

require "busyyaks/setup_api"

module Busyyaks
  module Actions
    module API
      module Setup
        # POST /api/setup/complete → records who finished the hello screen (Busyyaks::SetupAPI.complete); the shell stops
        # opening /hello
        class Complete < Busyyaks::APIAction
          def handle(req, res)
            status, body = Busyyaks::SetupAPI.complete(by: req.session[:email].to_s, **Show.deps(store))
            json(res, body, status: status)
          end
        end
      end
    end
  end
end
