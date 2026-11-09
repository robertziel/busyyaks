# frozen_string_literal: true

require "busyyaks/github_network"

module Busyyaks
  module Actions
    module API
      module Github
        # GET /api/github?hours=24|168|720 — the GitHub network feed (GithubNetwork::Feed, unix timestamps) + its repo and
        # people lists and the dashboard feed rendered server-side by the tl:github renderer (same markup as the report
        # block, every item).
        class Show < Busyyaks::APIAction
          def handle(req, res)
            hours = Integer(req.params[:hours].to_s, exception: false)
            error!(res, 400, "hours must be a whole number 1..#{GithubNetwork::MAX_HOURS}") unless hours && (1..GithubNetwork::MAX_HOURS).cover?(hours)

            feed = GithubNetwork::Feed.call(GithubNetwork::Data.default, login: ENV.fetch("GITHUB_LOGIN"), hours: hours)
            d = GithubNetwork::Block.data(feed, max: nil)
            network = ReportBlocks.gh_network(d["network"])
            window = GithubNetwork::Block.window_label(hours)
            json(res, feed.merge(html: {
                                   repos: ReportBlocks.gh_repos_html(d["repos"] || [], network, 0, head: false),
                                   people: ReportBlocks.gh_people_html(d["people"] || [], network, 0, d["follows_since"],
                                                                       head: false),
                                   feed: ReportBlocks.gh_feed_html(d["feed"], network, window, head: false),
                                 }))
          end
        end
      end
    end
  end
end
