# frozen_string_literal: true

module Busyyaks
  module Actions
    module Sessions
      # The sign-in page: the core's card + logo around the auth provider's body. Signed in already (provider none:
      # always) → `next`. ?next= (Auth.next_path!) is where sign-in returns: on the card as data-next, which the
      # provider's script navigates to once signed in; absent = "/" (no page was asked for); not a path of this app → 400.
      class New < Busyyaks::Action
        def public? = true

        def handle(req, res)
          raw = req.params[:next]
          target = raw.nil? ? "/" : Auth.next_path!(raw)
          return res.redirect_to(target) if Auth.identify(res.session)

          render(res, "login", title: "sign in", body: Auth.provider.login_html(Helpers), next_path: target)
        rescue Auth::Invalid => e
          halt 400, e.message
        end
      end
    end
  end
end
