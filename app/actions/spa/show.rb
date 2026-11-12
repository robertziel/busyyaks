# frozen_string_literal: true

require "busyyaks/setup_api"

module Busyyaks
  module Actions
    module Spa
      # The single-page app's shell, for every signed-in page GET. Rendered by Hanami so it carries the CSRF token
      # and the signed-in email as <meta>; the hashed bundle names come from Vite's manifest (public/app, built in
      # the image's node stage). No built frontend → 503 saying so, never a blank page.
      # The board theme (config/kanban.yml `theme`) is written onto :root here, so every --ak-* consumer sees it — the
      # Board (which also sets it inline), the Launch bar outside the board, and the Select menus portalled out of
      # both: one place for the mapping, never a second copy in app.css.
      class Show < Busyyaks::Action
        MANIFEST = "public/app/.vite/manifest.json"
        ENTRY = "src/main.tsx"

        # setup = "pending" until someone finished the hello screen (SetupAPI): the client then opens /hello
        def handle(_req, res)
          root = Hanami.app.root
          path = root.join(MANIFEST)
          unless path.file?
            res.status = 503
            res.headers["Content-Type"] = "text/plain; charset=utf-8"
            res.body = "frontend not built: #{MANIFEST} missing (npm run build in frontend/, see Dockerfile)"
            return
          end

          entry = JSON.parse(File.read(path)).fetch(ENTRY)
          res.format = :html
          res.headers["Cache-Control"] = "no-store"
          res.body = ERB.new(File.read(root.join("app/templates/app.html.erb")), trim_mode: "-").result_with_hash(
            h: Helpers, csrf: res.session[:_csrf_token].to_s, email: res.session[:email], scripts: Auth.provider.scripts(:app),
            sign_out: Auth.provider.sign_out? ? "/logout" : "", theme_css: theme_css,
            setup: SetupAPI.completed?(Kanban.db) ? "done" : "pending",
            js: "/app/#{entry.fetch('file')}", css: Array(entry["css"]).map { |f| "/app/#{f}" }
          )
        end

        # ":root { --ak-ink: var(--ink); … }". Written as is: the engine accepts a theme value at config load only from an
        # allowlist of CSS value characters, with quotes paired, parentheses balanced and no /* (HostConfig#parse_theme), so
        # no value can end, break or swallow this rule or the <style> — a bad theme stops the boot.
        def theme_css
          decls = Kanban.config.theme.map { |name, value| "#{name}: #{value};" }
          ":root { #{decls.join(' ')} }"
        end
      end
    end
  end
end
