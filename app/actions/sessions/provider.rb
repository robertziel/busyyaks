# frozen_string_literal: true

module Busyyaks
  module Actions
    module Sessions
      # GET|POST /auth/*path: the auth provider's own endpoints (its token exchange, its script). Public — the
      # provider decides; CSRF still applies to the POSTs. Not one of its paths → 404.
      class Provider < Busyyaks::Action
        def public? = true

        def handle(req, res)
          return if Auth.provider.endpoint(req.request_method, req.params[:path].to_s, req, res)

          res.status = 404
          res.headers["Content-Type"] = "application/json"
          res.body = JSON.dump(error: "no such auth endpoint")
        end
      end
    end
  end
end
