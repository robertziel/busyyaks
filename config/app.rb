# frozen_string_literal: true

require "hanami"
require_relative "../lib/busyyaks/kanban"
require_relative "../lib/busyyaks/config"
require_relative "../lib/busyyaks/auth"
require_relative "../lib/busyyaks/session_cookie"
require_relative "../lib/busyyaks/git_read"
require_relative "../lib/busyyaks/host_guard"
require_relative "../lib/busyyaks/skins"

module Busyyaks
  class App < Hanami::App
    # secret ≥ 64 bytes, Secure / SameSite from .env (SESSION_COOKIE_*), HttpOnly — checked here, at boot
    config.actions.sessions = :cookie, Busyyaks::SessionCookie.options(ENV)

    # Sign-in: the provider named by config/busyyaks.yml `auth` (none, or a provider directory), built at
    # boot — a missing key or settings the provider refuses stop it. The CSP is the core's sources + the provider's
    # (Busyyaks::Auth::CSP_BASE: 'self', and GitHub's avatar CDN for the /github feed's avatars).
    Busyyaks::Auth.setup!(Busyyaks::Auth.build(Busyyaks::Config.load.auth, root: File.expand_path("..", __dir__)))
      .banner&.then { |b| warn(b) } # provider none: AUTH DISABLED, in every process's log at every boot
    Busyyaks::Auth.csp_sources.each { |k, v| config.actions.content_security_policy[k] = v }

    # A malformed JSON body (Hanami's body parser, before any action) is the client's fault: 400, not 500.
    config.render_error_responses["Hanami::Middleware::BodyParser::BodyParsingError"] = :bad_request

    # The kanban engine's config file (KANBAN_CONFIG; its launchers / agent types are database revisions, checked on
    # use and on save: AgentSettings) and the attachments' env (ATTACHMENTS_DIR, the size cap, the type
    # allowlist) are read at boot: a missing key, an unknown column or type fails the boot, never a default.
    Busyyaks::Kanban.check_file!
    # the custom skins (skins/<key>.yml, card #361): every file read and checked here — a bad one stops the boot
    Busyyaks::Skins.all
    ENV.fetch("ATTACHMENTS_DIR")
    Busyyaks::Kanban.policy
    # the limits of every read of a scanned repo (GIT_READ_*): checked here, so a service never starts without them
    Busyyaks::GitRead.limits
    # ... and the host path of the projects mount (PROJECTS_ROOT), where a linked worktree's gitdir: points
    Busyyaks::GitRead.host_root

    # DNS rebinding: only the Hosts this deployment names (PUBLIC_HOST; 127.0.0.1 / localhost on WEB_HOST_PORT) are
    # answered, and a mutation's Origin / Referer must be that host's own — in front of every route and asset. Read at
    # boot: a missing or malformed value, or provider none with a PUBLIC_HOST, stops it (Busyyaks::HostGuard).
    config.middleware.use Busyyaks::HostGuard, Busyyaks::HostGuard.origins(ENV, provider: Busyyaks::Auth.provider)

    config.logger.filters += ["token"]
    config.logger.level = ENV.fetch("LOG_LEVEL").to_sym
    # /static: shared assets (fonts, icon, app.css — also the login page's). /app: the Vite build, hashed under
    # /app/assets, so it may be cached forever; the shell (app.html.erb) names the current files.
    config.middleware.use Rack::Static, urls: ["/static", "/app"], root: "public",
                                        header_rules: [[%r{\A/app/assets/},
                                                        { "cache-control" => "public, max-age=31536000, immutable" },],
                                                       # /static: named with ?v=<digest> by the pages (Helpers.asset);
                                                       # revalidated every load so a bare /static URL is never stale
                                                       [%r{\A/static/}, { "cache-control" => "no-cache" }],]
  end
end
