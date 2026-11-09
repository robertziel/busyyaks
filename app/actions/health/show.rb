# frozen_string_literal: true

module Busyyaks
  module Actions
    module Health
      class Show < Busyyaks::Action
        def public? = true

        def handle(_req, res)
          res.headers["Content-Type"] = "text/plain"
          res.body = "ok"
        end
      end
    end
  end
end
