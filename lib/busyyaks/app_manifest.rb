# frozen_string_literal: true

require_relative "skins"

module Busyyaks
  # The web app manifest (GET /manifest.webmanifest): the SPA installed as a desktop app — the same Vite
  # bundle the server serves, in a window of its own. Colours are the default skin's (skins/light.yml `--bg`, card
  # #241): the window's title bar before the page paints; the page's own skin choice takes over once it does.
  # Icons: public/static/icon-<size>.png, rendered from icon.svg by scripts/icons/render-png.
  module AppManifest
    ICON_SIZES = [192, 512].freeze
    DEFAULT_SKIN = "light"

    module_function

    def build(skins = Skins.all)
      # a base skin sets every token (Skins.bases!), so light.yml always has --bg
      bg = skins.find { _1["key"] == DEFAULT_SKIN }.fetch("tokens").fetch("--bg")
      {
        name: "busyyaks", short_name: "busyyaks", id: "/", start_url: "/", scope: "/",
        display: "standalone", background_color: bg, theme_color: bg,
        icons: ICON_SIZES.map { |s| { src: "/static/icon-#{s}.png", sizes: "#{s}x#{s}", type: "image/png" } } +
          [{ src: "/static/icon.svg", sizes: "any", type: "image/svg+xml" }],
      }
    end
  end
end
