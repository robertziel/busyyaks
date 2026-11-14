# frozen_string_literal: true

require "busyyaks/app_manifest"

module Busyyaks
  module Actions
    module Manifest
      # GET /manifest.webmanifest: the web app manifest that makes the SPA installable as a desktop app (Chrome / Edge
      # "Install busyyaks": its own window, a dock / taskbar icon, an app-menu entry). Public: a browser
      # fetches a manifest without the session cookie, and it names nothing but the brand and the /static icons.
      class Show < Busyyaks::Action
        def public? = true

        def handle(_req, res)
          res.headers["Content-Type"] = "application/manifest+json; charset=utf-8"
          res.headers["Cache-Control"] = "no-cache"
          res.body = JSON.generate(AppManifest.build)
        end
      end
    end
  end
end
