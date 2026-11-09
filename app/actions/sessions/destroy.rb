# frozen_string_literal: true

module Busyyaks
  module Actions
    module Sessions
      # Sign out: the session ends, back to the sign-in page. Provider none has no session to end → the app.
      class Destroy < Busyyaks::Action
        def public? = true

        def handle(_req, res)
          return res.redirect_to("/") unless Auth.provider.sign_out?

          Auth.sign_out(res.session)
          res.redirect_to("/login")
        end
      end
    end
  end
end
