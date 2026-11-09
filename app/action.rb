# auto_register: false
# frozen_string_literal: true

require "digest"

require "hanami/action"
require "erb"
require "json"
require "busyyaks/auth"
require "busyyaks/markdown"
require "busyyaks/store"
require "busyyaks/config"
require "busyyaks/launcher_client"
require "busyyaks/tree"
require "busyyaks/github"
require "busyyaks/heatmap"
require "busyyaks/report_blocks"
require "busyyaks/agents"
require "busyyaks/api"

module Busyyaks
  class Action < Hanami::Action
    # Hanami registers the CSRF callbacks in every env but test. This app's tests cover CSRF (a JSON mutation
    # without X-CSRF-Token must be a 403), so in test they are registered here — same methods, same order.
    before :set_csrf_token, :verify_csrf_token if Hanami.env?(:test)

    # Every page needs a signed-in, allowlisted person unless the action opts out.
    before :require_login

    private

    def public? = false
    def api?(req) = req.path.start_with?("/api/")

    def handle_invalid_csrf_token(req, res)
      res.session.clear
      return halt 403 unless api?(req)

      res.headers["Content-Type"] = "application/json; charset=utf-8"
      halt 403, JSON.dump(error: "invalid CSRF token")
    end

    # The auth provider (Busyyaks::Auth) is asked on every request: one that stops vouching for someone (an email
    # dropped from its allowlist) ends their access at once, not when their cookie expires. Its answer is the
    # request's identity, session[:email]. A page redirects to /login (a GET carries itself as ?next=, so a deep
    # link survives the sign-in); the JSON API answers 401 and the SPA goes to /login?next=<its page> itself.
    def require_login(req, res)
      return if public?
      return if Auth.identify(res.session)

      return res.redirect_to(login_path(req)) unless api?(req)

      res.headers["Content-Type"] = "application/json; charset=utf-8"
      halt 401, JSON.dump(error: "not signed in")
    end

    def login_path(req)
      return "/login" unless req.get? && req.fullpath != "/"

      "/login?next=#{ERB::Util.url_encode(Auth.next_path!(req.fullpath))}"
    rescue Auth::Invalid => e
      halt 400, e.message
    end

    def store = Store.default

    def render(res, name, status: 200, **locals)
      root = Hanami.app.root
      locals = { email: res.session[:email], title: "busyyaks" }.merge(locals)
                 .merge(csrf: res.session[:_csrf_token].to_s, scripts: Auth.provider.scripts(:login))
      inner = erb(root.join("app/templates/#{name}.html.erb"), locals)
      res.format = :html
      res.status = status
      res.body = erb(root.join("app/templates/layout.html.erb"), locals.merge(content: inner))
    end

    def erb(path, locals) = ERB.new(File.read(path), trim_mode: "-").result_with_hash(locals.merge(h: Helpers))

    module Helpers
      # Puma serves requests on several threads, all reading and filling the one digest cache
      ASSETS_LOCK = Mutex.new

      module_function

      def e(s) = ERB::Util.h(s.to_s)

      # A /static URL with its content's digest: "/static/app.css" → "/static/app.css?v=<12 hex>". The
      # shell and the server pages name every /static file this way, so a browser never pairs new HTML with a stale
      # cached copy (the old app.css drew the new logos as two 22px squares). A file that is not there raises —
      # the page never names an asset it cannot serve.
      def asset(path)
        raise ArgumentError, "not a /static path: #{path}" unless path.start_with?("/static/")

        file = Hanami.app.root.join("public#{path}")
        raise ArgumentError, "missing static asset: #{file}" unless file.file?

        mtime = file.mtime.to_f
        ASSETS_LOCK.synchronize do
          hit = (@assets ||= {})[path]
          next hit[1] if hit && hit[0] == mtime

          url = "#{path}?v=#{Digest::SHA256.file(file).hexdigest[0, 12]}"
          @assets[path] = [mtime, url]
          url
        end
      end
    end
  end
end
