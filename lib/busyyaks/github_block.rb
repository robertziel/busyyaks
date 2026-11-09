# frozen_string_literal: true

require_relative "kanban"

require "time"
require_relative "github_network"

module Busyyaks
  # tl:github — the GitHub network feed (repos the operator's followees starred, accounts they followed), styled after
  # GitHub's dashboard feed. The body is what GithubNetwork::Block writes from the snapshots (github_network's
  # block_markdown); check_report verifies every repo and person in it against those snapshots. Links go to github.com
  # only, pictures to avatars.githubusercontent.com only (the one image host the CSP allows besides 'self').
  module ReportBlocks
    module_function

    # GitHub linguist colours for the languages a feed is likely to show; any other language gets a plain grey dot
    GH_LANG = {
      "Ruby" => "#701516", "Python" => "#3572A5", "JavaScript" => "#f1e05a", "TypeScript" => "#3178c6", "Go" => "#00ADD8",
      "Rust" => "#dea584", "C" => "#555555", "C++" => "#f34b7d", "C#" => "#178600", "Java" => "#b07219", "Kotlin" => "#A97BFF",
      "Swift" => "#F05138", "Objective-C" => "#438eff", "Shell" => "#89e051", "HTML" => "#e34c26", "CSS" => "#663399",
      "SCSS" => "#c6538c", "Vue" => "#41b883", "Svelte" => "#ff3e00", "PHP" => "#4F5D95", "Elixir" => "#6e4a7e",
      "Erlang" => "#B83998", "Haskell" => "#5e5086", "Scala" => "#c22d40", "Clojure" => "#db5855", "Lua" => "#000080",
      "Dart" => "#00B4AB", "Zig" => "#ec915c", "Nix" => "#7e7eff", "Jupyter Notebook" => "#DA5B0B", "Dockerfile" => "#384d54",
      "MDX" => "#fcb32c", "Markdown" => "#083fa1", "Julia" => "#a270ba", "R" => "#198CE7", "Perl" => "#0298c3",
      "OCaml" => "#ef7a08", "Cuda" => "#3A4E3A", "Assembly" => "#6E4C13", "HCL" => "#844FBA", "Solidity" => "#AA6746",
      "Crystal" => "#000100", "Nim" => "#ffc200", "V" => "#4f87c4", "Mojo" => "#ff4c1f", "Gleam" => "#ffaff3",
      "Vim Script" => "#199f4b", "Emacs Lisp" => "#c065db", "TeX" => "#3D6117", "Makefile" => "#427819", "Astro" => "#ff5a03",
    }.freeze

    GH_ICON = {
      star: %(<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d=") \
        "M8 .25a.75.75 0 0 1 .673.418l1.882 3.815 4.21.612a.75.75 0 0 1 .416 1.279l-3.046 2.97.719 4.192a.751.751 0 0 " \
        "1-1.088.791L8 12.347l-3.766 1.98a.75.75 0 0 1-1.088-.79l.72-4.194L.818 6.374a.75.75 0 0 1 " \
        ".416-1.28l4.21-.611L7.327.668A.75.75 0 0 1 8 .25Z" \
        '"/></svg>',
      repo: %(<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d=") \
        "M2 2.5A2.5 2.5 0 0 1 4.5 0h8.75a.75.75 0 0 1 .75.75v12.5a.75.75 0 0 1-.75.75h-2.5a.75.75 0 0 1 0-1.5h1.75v-2h-8a1 " \
        "1 0 0 0-.714 1.7.75.75 0 1 1-1.072 1.05A2.495 2.495 0 0 1 2 11.5Zm10.5-1h-8a1 1 0 0 0-1 1v6.708A2.486 2.486 0 0 1 " \
        "4.5 9h8ZM5 12.25a.25.25 0 0 1 .25-.25h3.5a.25.25 0 0 1 .25.25v3.25a.25.25 0 0 1-.4.2l-1.45-1.087a.249.249 0 0 0-.3 " \
        "0L5.4 15.7a.25.25 0 0 1-.4-.2Z" \
        '"/></svg>',
      person: %(<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d=") \
        "M10.561 8.073a6.005 6.005 0 0 1 3.432 5.142.75.75 0 1 1-1.498.07 4.5 4.5 0 0 0-8.99 0 .75.75 0 0 1-1.498-.07 6.004 " \
        "6.004 0 0 1 3.431-5.142 3.999 3.999 0 1 1 5.123 0ZM10.5 5a2.5 2.5 0 1 0-5 0 2.5 2.5 0 0 0 5 0Z" \
        '"/></svg>',
      people: %(<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d=") \
        "M2 5.5a3.5 3.5 0 1 1 5.898 2.549 5.508 5.508 0 0 1 3.034 4.084.75.75 0 1 1-1.482.235 4 4 0 0 0-7.9 0 .75.75 0 0 " \
        "1-1.482-.236A5.507 5.507 0 0 1 3.102 8.05 3.493 3.493 0 0 1 2 5.5ZM11 4a3.001 3.001 0 0 1 2.22 5.018 5.01 5.01 0 0 " \
        "1 2.56 3.012.749.749 0 0 1-.885.954.752.752 0 0 1-.549-.514 3.507 3.507 0 0 0-2.522-2.372.75.75 0 0 " \
        "1-.574-.73v-.352a.75.75 0 0 1 .416-.672A1.5 1.5 0 0 0 11 5.5.75.75 0 0 1 11 4Zm-5.5-.5a2 2 0 1 0-.001 3.999A2 2 0 " \
        "0 0 5.5 3.5Z" \
        '"/></svg>',
      tag: %(<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d=") \
        "M1 7.775V2.75C1 1.784 1.784 1 2.75 1h5.025c.464 0 .91.184 1.238.513l6.25 6.25a1.75 1.75 0 0 1 0 2.474l-5.026 " \
        "5.026a1.75 1.75 0 0 1-2.474 0l-6.25-6.25A1.752 1.752 0 0 1 1 7.775Zm1.5 0c0 .066.026.13.073.177l6.25 6.250a.25.25 " \
        "0 0 0 .354 0l5.025-5.025a.25.25 0 0 0 0-.354l-6.25-6.25a.25.25 0 0 0-.177-.073H2.75a.25.25 0 0 0-.25.25ZM6 5a1 1 0 " \
        "1 1 0 2 1 1 0 0 1 0-2Z" \
        '"/></svg>',
      fork: %(<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d=") \
        "M5 5.372v.878c0 .414.336.75.75.75h4.5a.75.75 0 0 0 .75-.75v-.878a2.25 2.25 0 1 1 1.5 0v.878a2.25 2.25 0 0 1-2.25 " \
        "2.25h-1.5v2.128a2.251 2.251 0 1 1-1.5 0V8.5h-1.5A2.25 2.25 0 0 1 3.5 6.25v-.878a2.25 2.25 0 1 1 1.5 0ZM5 " \
        "3.25a.75.75 0 1 0-1.5 0 .75.75 0 0 0 1.5 0Zm6.75.75a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Zm-3 8.75a.75.75 0 1 0-1.5 " \
        "0 .75.75 0 0 0 1.5 0Z" \
        '"/></svg>',
      push: %(<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d=") \
        "M1 2.5A2.5 2.5 0 0 1 3.5 0h8.75a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0V1.5h-8a1 1 0 0 0-1 1v6.708A2.493 2.493 " \
        "0 0 1 3.5 9h3.25a.75.75 0 0 1 0 1.5H3.5a1 1 0 0 0 0 2h5.750a.75.75 0 0 1 0 1.5H3.5A2.5 2.5 0 0 1 1 11.5Zm13.23 " \
        "7.79-1.224-1.224v6.184a.75.75 0 0 1-1.5 0V9.066L10.28 10.29a.75.75 0 0 1-1.06-1.061l2.505-2.504a.75.75 0 0 1 1.06 " \
        "0L15.29 9.23a.751.751 0 0 1-.018 1.042.751.751 0 0 1-1.042.018Z" \
        '"/></svg>',
      eye: %(<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d=") \
        "M8 2c1.981 0 3.671.992 4.933 2.078 1.27 1.091 2.187 2.345 2.637 3.023a1.62 1.62 0 0 1 0 1.798c-.45.678-1.367 " \
        "1.932-2.637 3.023C11.67 13.008 9.981 14 8 14c-1.981 0-3.671-.992-4.933-2.078C1.797 10.83.88 9.576.43 8.898a1.62 " \
        "1.62 0 0 1 0-1.798c.45-.677 1.367-1.931 2.637-3.022C4.33 2.992 6.019 2 8 2ZM1.679 7.932a.12.12 0 0 0 0 " \
        ".136c.411.622 1.241 1.75 2.366 2.717C5.176 11.758 6.527 12.5 8 12.5c1.473 0 2.825-.742 3.955-1.715 1.124-.967 " \
        "1.954-2.096 2.366-2.717a.12.12 0 0 0 0-.136c-.412-.621-1.242-1.75-2.366-2.717C10.824 4.242 9.473 3.5 8 3.5c-1.473 " \
        "0-2.825.742-3.955 1.715-1.124.967-1.954 2.096-2.366 2.717ZM8 10a2 2 0 1 1-.001-3.999A2 2 0 0 1 8 10Z" \
        '"/></svg>',
      pulse: %(<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d=") \
        "M6 2c.306 0 .582.187.696.471L10 10.731l1.304-3.26A.751.751 0 0 1 12 7h3.25a.75.75 0 0 1 0 1.5h-2.742l-1.812 " \
        "4.528a.751.751 0 0 1-1.392 0L6 4.77 4.696 8.03A.75.75 0 0 1 4 8.5H.75a.75.75 0 0 1 " \
        "0-1.5h2.742l1.812-4.529A.751.751 0 0 1 6 2Z" \
        '"/></svg>',
      alert: %(<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d=") \
        "M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 " \
        "1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 " \
        "3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z" \
        '"/></svg>',
    }.freeze

    GH_TOPIC = /\A[a-z0-9][a-z0-9-]{0,49}\z/

    def b_github(d, _ctx)
      raise Invalid, "github must be a mapping {window, network?, repos?, people?, error?}" unless d.is_a?(Hash)

      window = req(d, "window").to_s
      network = gh_network(d["network"])
      repos = d["repos"].nil? ? [] : list!(d["repos"], "repos")
      people = d["people"].nil? ? [] : list!(d["people"], "people")
      more = d["more"].nil? ? {} : d["more"]
      raise Invalid, "more must be a mapping {repos?, people?}" unless more.is_a?(Hash)

      feed = d["feed"]
      unless feed.nil? || feed.is_a?(Hash)
        raise Invalid, "feed must be a mapping {items?, pushes?, activity?, more?, error?, since?, gap?}"
      end

      feed_n = feed ? Array(feed["items"]).size + feed.dig("more", "items").to_i : nil
      head = %(<header class="ghn-head">#{AgentsKanban::CardLinks::ICONS['github']}<b>GitHub network</b>) +
             %(<span class="ghn-window">#{e(window)}</span>) +
             %(<span class="ghn-counts">#{feed_n ? "#{gh_count(feed_n, 'feed item')} · " : ''}) +
             %(#{gh_count(repos.size + more["repos"].to_i, 'repo')} · ) +
             %(#{gh_count(people.size + more["people"].to_i, 'person', 'people')}</span>) +
             (d["collected"] ? %(<span class="ghn-at">collected #{e(gh_time(d["collected"]))}</span>) : "") + "</header>"
      err = if d["error"]
              %(<div class="ghn-error" role="alert">#{GH_ICON[:alert]}<span><b>collector</b> #{e(d["error"])}</span></div>)
            else
              ""
            end
      body = if repos.empty? && people.empty?
               d["error"] || feed ? "" : %(<p class="ghn-empty">nothing new in #{e(window)}</p>)
             else
               gh_repos_html(repos, network, more["repos"]) +
                 gh_people_html(people, network, more["people"], d["follows_since"])
             end
      head + err + (feed ? gh_feed_html(feed, network, window) : "") + body
    end

    def gh_network(n)
      return {} if n.nil?
      raise Invalid, "network must be a mapping login → avatar URL" unless n.is_a?(Hash)

      n.to_h do |login, av|
        [gh_login!(login), av.nil? ? nil : gh_avatar!(av)]
      end
    end

    def gh_repos_html(repos, network, more, head: true)
      return "" if repos.empty?

      items = repos.map do |r|
        name = req(r, "repo").to_s
        raise Invalid, "repo #{name.inspect} is not owner/name" unless name.match?(GithubNetwork::REPO)

        owner, short = name.split("/", 2)
        by = gh_by!(r["starred_by"], network, "starred_by")
        stars = r["stars"].nil? ? nil : int!(r["stars"], "stars")
        topics = r["topics"].nil? ? [] : Array(r["topics"])
        raise Invalid, "topics must be a list of words" unless topics.all? { |t| t.is_a?(String) && t.match?(GH_TOPIC) }

        hot = if by.size > 1
                %(<span class="ghn-hot" title="starred by #{by.size} people you follow">#{GH_ICON[:star]}#{by.size}</span>)
              else
                ""
              end
        when_ = r["starred_at"] && %(<span class="ghn-when">starred #{e(gh_time(r["starred_at"]))}</span>)
        %(<li class="ghn-item">#{gh_actor_line(by, network, 'starred', GH_ICON[:star])}) +
          gh_repo_card(owner, short, r["description"], r["language"]&.to_s, stars, topics, r["avatar"],
                       hot: hot, foot: when_) +
          "</li>"
      end
      (head ? %(<h4 class="ghn-sub">#{GH_ICON[:repo]}Starred <span>#{repos.size + more.to_i}</span></h4>) : "") +
        %(<ol class="ghn-feed">#{items.join}</ol>) + gh_more(more, "repo")
    end

    # a repo card as GitHub's feed draws it: owner avatar + owner/name, description, topics, language · stars
    def gh_repo_card(owner, short, description, lang, stars, topics, avatar, hot: "", foot: nil)
      url = "https://github.com/#{owner}/#{short}"
      av = if avatar
             %(<img class="ghn-owner" src="#{e(gh_av(gh_avatar!(avatar), 40))}" alt="" loading="lazy" width="20" height="20">)
           else
             ""
           end
      star_link = stars && (%(<a class="ghn-stars" href="#{e(url)}/stargazers" target="_blank" rel="noopener" ) +
                            %(title="#{stars} stargazers">#{GH_ICON[:star]}#{gh_k(stars)}</a>))
      f = [lang && %(<span class="ghn-lang"><i style="--lang:#{GH_LANG.fetch(lang, '#8b949e')}"></i>#{e(lang)}</span>),
           star_link,
           foot,].compact.join
      topic_links = topics.first(5).map do |t|
        %(<a class="ghn-topic" href="https://github.com/topics/#{e(t)}" target="_blank" rel="noopener">#{e(t)}</a>)
      end
      %(<article class="ghn-card"><header>#{av}<a class="ghn-name" href="#{e(url)}" target="_blank" rel="noopener">) +
        %(<span class="ghn-o">#{e(owner)}</span><span class="ghn-sl">/</span><b>#{e(short)}</b></a>#{hot}</header>) +
        (description ? %(<p class="ghn-desc">#{e(description)}</p>) : "") +
        (topics.empty? ? "" : %(<div class="ghn-topics">#{topic_links.join}</div>)) +
        (f.empty? ? "" : %(<footer>#{f}</footer>)) + "</article>"
    end

    FEED_KINDS = %w[release repo public fork member tag star].freeze
    ACTIVITY_LABEL = {
      "comments" => %w[comment comments], "issues" => %w[issue issues], "pull_requests" => ["pull request", "pull requests"],
      "reviews" => %w[review reviews], "discussions" => %w[discussion discussions], "other" => ["other event", "other events"],
    }.freeze

    def gh_repo_link(name)
      name = name.to_s
      raise Invalid, "repo #{name.inspect} is not owner/name" unless name.match?(GithubNetwork::REPO)

      %(<a class="ghn-rl" href="https://github.com/#{e(name)}" target="_blank" rel="noopener">#{e(name)}</a>)
    end

    # the feed section: items (one GitHub-feed entry each), pushes per repo (one line each), the rest counted
    def gh_feed_html(f, network, window, head: true)
      items = f["items"].nil? ? [] : list!(f["items"], "feed.items")
      pushes = f["pushes"].nil? ? [] : list!(f["pushes"], "feed.pushes")
      activity = f["activity"].nil? ? {} : f["activity"]
      more = f["more"].nil? ? {} : f["more"]
      raise Invalid, "feed.activity must be a mapping category → count" unless activity.is_a?(Hash)
      raise Invalid, "feed.more must be a mapping {items?, pushes?}" unless more.is_a?(Hash)

      since = f["since"] && (%(<span class="ghn-note" title="GitHub keeps the last 300 feed events: ) +
                             %(the feed is complete from the first stored one on">since #{e(gh_time(f["since"]))}</span>))
      gap = f["gap"] && (%(<span class="ghn-note ghn-gapnote" title="more than 300 events between two reads: ) +
                         %(some may be missing">gap at #{e(gh_time(f["gap"]))}</span>))
      notes = [since, gap].compact.join
      count = items.size + more["items"].to_i
      out = head ? %(<h4 class="ghn-sub">#{GH_ICON[:pulse]}Feed <span>#{count}</span>#{notes}</h4>) : ""
      if f["error"]
        out += %(<div class="ghn-error" role="alert">#{GH_ICON[:alert]}<span><b>feed</b> #{e(f["error"])}</span></div>)
      end
      out += %(<ol class="ghn-feed">#{items.map { |i| gh_feed_item(i, network) }.join}</ol>) unless items.empty?
      out += gh_more(more["items"], "feed item")
      out += gh_pushes_html(pushes, network) unless pushes.empty?
      out += gh_more(more["pushes"], "pushed repo")
      parts = activity.map do |k, n|
        one, many = ACTIVITY_LABEL[k.to_s] || raise(Invalid, "feed.activity: unknown category #{k.to_s.inspect}")
        n = int!(n, "feed.activity.#{k}")
        %(<span><b>#{n}</b> #{n == 1 ? one : many}</span>)
      end
      unless parts.empty?
        out += %(<p class="ghn-activity">#{GH_ICON[:pulse]}<span class="ghn-alab">also</span>#{parts.join}) +
               %(<a href="/github">by repo on /github</a></p>)
      end
      if items.empty? && pushes.empty? && parts.empty? && !f["error"]
        out += %(<p class="ghn-empty">no feed events in #{e(window)}</p>)
      end
      out
    end

    def gh_feed_item(i, network)
      kind = req(i, "kind").to_s
      unless FEED_KINDS.include?(kind)
        raise Invalid, "feed item kind #{kind.inspect} is not one of #{FEED_KINDS.join(', ')}"
      end

      actor = gh_by!([req(i, "actor")], network, "feed actor")
      repo = req(i, "repo").to_s
      link = gh_repo_link(repo)
      at = i["at"] ? %(<time class="ghn-at2">#{e(gh_time(i["at"]))}</time>) : ""
      topics = i["topics"].nil? ? [] : Array(i["topics"])
      raise Invalid, "topics must be a list of words" unless topics.all? { |t| t.is_a?(String) && t.match?(GH_TOPIC) }

      stars = i["stars"].nil? ? nil : int!(i["stars"], "stars")
      card = lambda do |name|
        owner, short = name.split("/", 2)
        gh_repo_card(owner, short, i["description"], i["language"]&.to_s, stars, topics, i["avatar"])
      end
      line, body =
        case kind
        when "release"
          tag = req(i, "tag").to_s
          title = i["name"].to_s.strip.empty? ? tag : i["name"].to_s
          owner, short = repo.split("/", 2)
          rel = "https://github.com/#{repo}/releases/tag/#{ERB::Util.url_encode(tag)}"
          tail = %(<a class="ghn-rl" href="#{e(rel)}" target="_blank" rel="noopener">#{e(title)}</a> of #{link})
          badge = i["prerelease"] ? '<span class="ghn-pre">Pre-release</span>' : '<span class="ghn-latest">Release</span>'
          [gh_actor_line(actor, network, "released", GH_ICON[:tag], tail: tail, at: at),
           %(<article class="ghn-card ghn-release"><header>) +
             %(<a class="ghn-name" href="https://github.com/#{e(repo)}" target="_blank" rel="noopener">) +
             %(<span class="ghn-o">#{e(owner)}</span><span class="ghn-sl">/</span><b>#{e(short)}</b></a></header>) +
             %(<p class="ghn-relname"><a href="#{e(rel)}" target="_blank" rel="noopener">#{e(title)}</a></p>) +
             %(<footer><span class="ghn-tag">#{GH_ICON[:tag]}#{e(tag)}</span>#{badge}</footer></article>),]
        when "repo"
          [gh_actor_line(actor, network, "created a repository", GH_ICON[:repo], tail: link, at: at), card.call(repo)]
        when "public" then [gh_actor_line(actor, network, "made public", GH_ICON[:eye], tail: link, at: at), card.call(repo)]
        when "fork"
          forkee = req(i, "forkee").to_s
          tail = "#{gh_repo_link(forkee)} from #{link}"
          [gh_actor_line(actor, network, "forked", GH_ICON[:fork], tail: tail, at: at), card.call(forkee)]
        when "member"
          m = gh_login!(req(i, "member"))
          tail = %(<a class="ghn-actor" href="https://github.com/#{e(m)}" target="_blank" rel="noopener">#{e(m)}</a> to #{link})
          [gh_actor_line(actor, network, "added", GH_ICON[:person], tail: tail, at: at), ""]
        when "tag"
          tail = %(<b class="ghn-ref">#{e(req(i, 'ref'))}</b> in #{link})
          [gh_actor_line(actor, network, "created tag", GH_ICON[:tag], tail: tail, at: at), ""]
        when "star" then [gh_actor_line(actor, network, "starred", GH_ICON[:star], tail: link, at: at), ""]
        end
      %(<li class="ghn-item ghn-k-#{kind}">#{line}#{body}</li>)
    end

    def gh_pushes_html(pushes, network)
      rows = pushes.map do |x|
        repo = req(x, "repo").to_s
        by = gh_by!(x["by"], network, "feed pushes by")
        n = int!(req(x, "pushes"), "pushes")
        br = x["branches"].nil? ? nil : int!(x["branches"], "branches")
        branches = br && br > 1 ? %( <span class="ghn-dim">· #{br} branches</span>) : ""
        tail = %(<b>#{n}</b> #{n == 1 ? 'time' : 'times'} to #{gh_repo_link(repo)}#{branches})
        at = x["at"] ? %(<time class="ghn-at2">#{e(gh_time(x["at"]))}</time>) : ""
        %(<li>#{gh_actor_line(by, network, 'pushed', GH_ICON[:push], tail: tail, at: at)}</li>)
      end
      %(<ul class="ghn-pushes">#{rows.join}</ul>)
    end

    def gh_people_html(people, network, more, since, head: true)
      return "" if people.empty?

      items = people.map do |p|
        login = gh_login!(req(p, "login"))
        by = gh_by!(p["followed_by"], network, "followed_by")
        url = "https://github.com/#{login}"
        av = if p["avatar"]
               %(<img src="#{e(gh_av(gh_avatar!(p["avatar"]), 96))}" alt="" loading="lazy" width="48" height="48">)
             else
               %(<span class="ghn-noav">#{e(login[0].upcase)}</span>)
             end
        followers = p["followers"].nil? ? nil : int!(p["followers"], "followers")
        meta = [followers && %(<span>#{GH_ICON[:people]}<b>#{gh_k(followers)}</b> followers</span>),
                p["you_follow"] == true ? %(<span class="ghn-you">you follow</span>) : nil,].compact.join
        %(<li class="ghn-item">#{gh_actor_line(by, network, 'followed', GH_ICON[:person])}) +
          %(<article class="ghn-card ghn-person">) +
          %(<a class="ghn-av" href="#{e(url)}" target="_blank" rel="noopener">#{av}</a><div class="ghn-pmain">) +
          %(<a class="ghn-pname" href="#{e(url)}" target="_blank" rel="noopener">) +
          %(#{p["name"] ? %(<b>#{e(p["name"])}</b>) : ''}<span>#{e(login)}</span></a>) +
          (p["bio"] ? %(<p class="ghn-desc">#{e(p["bio"])}</p>) : "") +
          (meta.empty? ? "" : %(<footer>#{meta}</footer>)) + "</div></article></li>"
      end
      note = if since
               %(<span class="ghn-note" title="follows have no date on GitHub: ) +
                 %(they are known from the first collection on">since #{e(gh_time(since))}</span>)
             else
               ""
             end
      (head ? %(<h4 class="ghn-sub">#{GH_ICON[:person]}Followed <span>#{people.size + more.to_i}</span>#{note}</h4>) : "") +
        %(<ol class="ghn-feed">#{items.join}</ol>) + gh_more(more, "person", "people")
    end

    # "[avatars] alice, bob and 2 others starred"
    def gh_actor_line(by, network, verb, icon, tail: nil, at: nil)
      stack = by.first(4).map do |l|
        av = network[l]
        inner = if av
                  %(<img src="#{e(gh_av(av, 48))}" alt="" loading="lazy" width="22" height="22">)
                else
                  %(<span class="ghn-noav">#{e(l[0].upcase)}</span>)
                end
        %(<a href="https://github.com/#{e(l)}" target="_blank" rel="noopener" title="@#{e(l)}">#{inner}</a>)
      end.join
      names = by.first(3).map do |l|
        %(<a class="ghn-actor" href="https://github.com/#{e(l)}" target="_blank" rel="noopener">#{e(l)}</a>)
      end
      names = names.size > 1 ? "#{names[0..-2].join(', ')} and #{names[-1]}" : names.first
      names += %( and #{by.size - 3} more) if by.size > 3
      %(<div class="ghn-actors"><span class="ghn-stack">#{stack}</span>) +
        %(<span class="ghn-line">#{names} <span class="ghn-verb">#{icon}#{verb}</span>#{tail ? " #{tail}" : ''}</span>) +
        %(#{at}</div>)
    end

    def gh_by!(list, network, what)
      raise Invalid, "#{what} must be a non-empty list of logins" unless list.is_a?(Array) && list.any?

      list.map do |l|
        gh_login!(l).tap { |x| raise Invalid, "#{what}: @#{x} is not in network" unless network.empty? || network.key?(x) }
      end
    end

    def gh_login!(l)
      l = l.to_s
      raise Invalid, "#{l.inspect} is not a GitHub login" unless l.match?(GithubNetwork::LOGIN)

      l
    end

    def gh_avatar!(u)
      u = u.to_s
      unless u.match?(GithubNetwork::AVATAR)
        raise Invalid, "avatar #{u[0, 60].inspect} must be an https://avatars.githubusercontent.com/ URL"
      end

      u
    end

    # the avatar at a size (GitHub serves ?s=<px>)
    def gh_av(url, px) = "#{url}#{url.include?('?') ? '&' : '?'}s=#{px}"

    def gh_more(n, one, many = "#{one}s")
      return "" unless n.to_i.positive?

      %(<p class="ghn-more"><a href="/github">+#{n.to_i} more #{n.to_i == 1 ? one : many} on /github</a></p>)
    end

    def gh_count(n, one, many = "#{one}s") = %(<b>#{n}</b> #{n == 1 ? one : many})

    def gh_k(n)
      return n.to_s if n < 1000
      return "#{(n / 1000.0).round(1).to_s.delete_suffix('.0')}k" if n < 100_000

      "#{(n / 1000.0).round}k"
    end

    def gh_time(v)
      t = v.is_a?(Time) ? v : Time.iso8601(v.to_s)
      t.localtime.strftime("%b %-d, %H:%M")
    rescue ArgumentError
      raise Invalid, "time #{v.to_s[0, 40].inspect} is not ISO 8601"
    end

    # check_report's provenance check: every repo / person a tl:github block names must be in the collector's snapshots —
    # each starred_by login has that star stored, each followed_by login that (non-baseline) follow. → ["…"] problems
    def github_unverified(md, db, login: ENV.fetch("GITHUB_LOGIN"))
      md.to_s.scan(FENCE).select { |name, _| name == "github" }.each_with_index.flat_map do |(_, body), i|
        d = begin
          YAML.safe_load(body, permitted_classes: [Date, Time])
        rescue Psych::Exception
          next [] # a broken block is already in `broken`
        end
        next [] unless d.is_a?(Hash)

        where = "tl:github (block #{i + 1})"
        stars = Array(d["repos"]).select { |r| r.is_a?(Hash) }.flat_map do |r|
          Array(r["starred_by"]).filter_map do |l|
            next unless db[:gh_stars].where(login: l.to_s, repo: r["repo"].to_s).empty?

            "#{where}: #{r['repo']} — no stored star by @#{l}"
          end
        end
        follows = Array(d["people"]).select { |p| p.is_a?(Hash) }.flat_map do |p|
          Array(p["followed_by"]).filter_map do |l|
            next unless db[:gh_follows].where(follower: l.to_s, followee: p["login"].to_s, baseline: false).empty?

            "#{where}: @#{p['login']} — no stored new follow by @#{l}"
          end
        end
        stars + follows + (d["feed"].is_a?(Hash) ? feed_unverified(d, db, login, where) : [])
      end
    end

    # every feed item is a stored event of that kind, actor and repo (and tag / fork / member / ref); pushes and activity
    # counts are at most what the window [to - window, to] holds (events arriving late can only add to the store)
    def feed_unverified(d, db, login, where)
      f = d["feed"]
      items = Array(f["items"]).select { |i| i.is_a?(Hash) }.filter_map do |i|
        row = db[:gh_events].where(login: login, id: i["id"].to_s).first
        label = "#{where}: feed #{i['kind']} #{i['repo']} (event #{i['id'].inspect})"
        next "#{label} — no stored event" unless row

        dg = JSON.parse(row[:digest])
        want = { "kind" => GithubNetwork.feed_kind(row[:type], row[:action], dg), "actor" => row[:actor], "repo" => row[:repo] }
        want.merge!({ "release" => { "tag" => dg["tag"] }, "fork" => { "forkee" => dg["forkee"] },
                      "member" => { "member" => dg["member"] }, "tag" => { "ref" => dg["ref"] }, }.fetch(i["kind"].to_s, {}))
        bad = want.reject { |k, v| i[k].to_s == v.to_s }.keys
        "#{label} — #{bad.join(', ')} not as stored" unless bad.empty?
      end
      pushes = Array(f["pushes"]).select { |x| x.is_a?(Hash) }
      activity = f["activity"].is_a?(Hash) ? f["activity"] : {}
      return items if pushes.empty? && activity.empty?

      hours = d["window"].to_s[/\A(\d+)([hd])\z/] && ($2 == "d" ? $1.to_i * 24 : $1.to_i)
      to = begin
        Time.iso8601(d["to"].to_s).to_i
      rescue ArgumentError
        nil
      end
      return items + ["#{where}: feed pushes/activity need window (e.g. 1d) and to (ISO 8601)"] unless hours && to

      fe = GithubNetwork::FeedEvents.call(GithubNetwork::Data.new(db), login: login, from: to - (hours * 3600), to: to)
      stored = fe[:pushes].to_h { |x| [x[:repo], x] }
      items + pushes.flat_map do |x|
        s = stored[x["repo"].to_s]
        next ["#{where}: feed pushes to #{x['repo']} — no stored push in the window"] unless s

        to_repo = "#{where}: feed pushes to #{x['repo']}"
        (x["pushes"].to_i > s[:pushes] ? ["#{to_repo} — #{x['pushes']} > #{s[:pushes]} stored"] : []) +
          (Array(x["by"]).map(&:to_s) - s[:actors]).map { |l| "#{to_repo} — no stored push by @#{l}" }
      end + activity.filter_map do |k, n|
        have = fe[:activity][k.to_s].to_i
        "#{where}: feed activity #{k} — #{n} > #{have} stored" if n.to_i > have
      end
    end
  end
end
