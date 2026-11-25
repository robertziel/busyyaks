# frozen_string_literal: true

require_relative "git_hosts"
require_relative "github_network"
require_relative "kanban"

module Busyyaks
  # Settings → Git hosts as [status, body]; the actions are one line each.
  #   show              → 200 {providers: [{key, label, available, note}], current: {provider, label, login, token_hint,
  #                       author, at} | null, collector: {ok, error, at} | null (the last GitHub run of that login)}
  #   connect(body, by) → the github service's answer: 200 {current} · 422 refused (unknown / coming-soon provider, a
  #                       token the host rejects) · 503 the service is down · 504 no answer
  #   test(by)          → 200 {ok: true, login, same} (the stored token asked again, nothing written) · 422 · 503 · 504
  #   disconnect(by)    → 200 {current: null} · 503 · 504
  module GitHostsAPI
    module_function

    def show(db: Kanban.db)
      cur = GitHosts.current(db)
      [200, { providers: GitHosts.listing, current: cur, collector: collector(db, cur) }]
    end

    def connect(body, by:, client: GitHosts::Client)
      return [422, { error: "body must be an object {provider, token}" }] unless body.is_a?(Hash)

      relay { client.connect(body["provider"].to_s, body["token"].to_s, by: by) }
    end

    def disconnect(by:, client: GitHosts::Client) = relay { client.disconnect(by: by) }
    # Test connection: the stored token checked again by its host → 200 {ok, login, same} · 422 · 503 · 504
    def test(by:, client: GitHosts::Client) = relay { client.test(by: by) }

    def relay
      yield
    rescue GitHosts::Client::Unavailable => e
      [503, { error: e.message }]
    rescue GitHosts::Client::NoAnswer => e
      [504, { error: e.message }]
    end

    def collector(db, cur)
      return nil unless cur && cur[:provider] == "github"

      run = GithubNetwork::Data.new(db).last_run(cur[:login])
      run && { ok: run[:ok] ? true : false, error: run[:error], at: run[:finished_at] }
    end
  end
end
