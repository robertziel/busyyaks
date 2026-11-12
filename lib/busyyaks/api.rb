# frozen_string_literal: true

require "shellwords"
require_relative "tree"
require_relative "dashboard_url"
require_relative "github"
require_relative "markdown"
require_relative "heatmap"
require_relative "daily_stats"
require_relative "github_prs"
require_relative "agents"

module Busyyaks
  # JSON shapes for the SPA (frontend/src/types.ts mirrors them). Rows come from Store; the launcher state
  # from LauncherClient. Nothing here guesses: a missing value is null, an unreachable launcher is an error string.
  module API
    module_function

    def project(p, sessions = {})
      live = sessions[p[:path]] || []
      { slug: p[:slug], path: p[:path], remote: p[:remote], repo_url: Github.repo_url(p[:remote]), branch: p[:branch],
        own: p[:own], last_commit_at: p[:last_commit_at], commits_window: p[:commits_window], mine_window: p[:mine_window],
        dirty: p[:dirty], unpushed: p[:unpushed], scanned_at: p[:scanned_at], present: p[:present],
        icon: icon_url(p), sessions: live.map { |s| session(s) }, }
    end

    # The repo's own icon, served by GET /api/icons/*slug; ?v= busts the cache when the file changes. nil = none.
    def icon_url(p)
      return nil unless p[:icon_path]

      "/api/icons/#{p[:slug].split('/').map { |s| ERB::Util.url_encode(s) }.join('/')}?v=#{p[:icon_mtime]}"
    end

    def session(s)
      { name: s["name"], created: s["created"], attached: s["attached"] ? true : false, terminal_url: terminal_url(s["name"]),
        claude_url: s["claude_url"], ssh_attach: ssh_attach(s["name"]), }
    end

    # The command that attaches to a session from the operator's own machine (SSH_ATTACH_TEMPLATE). The name is
    # shell-quoted: it is pasted into a terminal.
    def ssh_attach(name) = ENV.fetch("SSH_ATTACH_TEMPLATE").gsub("{session}", Shellwords.escape(name.to_s))

    # The session in the team terminal view (TEAM_TERMINAL_URL, e.g. the chat Code section:
    # https://host/code/#s={session}&sock={socket}). Required env: no template, no link — boot fails, not a guess.
    def terminal_url(name, socket = "default")
      ENV.fetch("TEAM_TERMINAL_URL")
         .gsub("{session}", ERB::Util.url_encode(name.to_s))
         .gsub("{socket}", ERB::Util.url_encode(socket.to_s))
    end

    # Busyyaks::Tree nodes → nested JSON; folders carry totals, repos the project.
    def tree(nodes, sessions = {})
      nodes.map do |n|
        if n.folder?
          up = n.unpushed_known
          { type: "folder", name: n.name, path: n.path, repos: n.repos.size,
            last_commit_at: n.last_commit_at.zero? ? nil : n.last_commit_at,
            commits_window: n.sum(:commits_window), mine_window: n.sum(:mine_window), dirty: n.sum(:dirty),
            unpushed: up.empty? ? nil : up.sum, live: n.repos.sum { |r| (sessions[r.path] || []).size },
            children: tree(n.children, sessions), }
        else
          { type: "repo", name: n.name, project: project(n.project, sessions) }
        end
      end
    end

    def commit(c, remote)
      { sha: c[:sha], subject: c[:subject], author: c[:author], email: c[:email], committed_at: c[:committed_at],
        mine: c[:mine], project_slug: c[:project_slug], url: Github.commit_url(remote, c[:sha]), }
    end

    FENCED = /^```.*?^```[ \t]*$/m

    # A report without its body: the first prose line (fenced blocks skipped) and the digest of its tl:* blocks.
    def report_row(r, store, ctx = Markdown.report_ctx(store))
      excerpt = r[:body_md].to_s.gsub(FENCED, "").lines.map(&:strip).find { |l| !l.empty? && !l.start_with?("#", "|") }.to_s
      { id: r[:id], date: r[:date], title: r[:title], author: r[:author], created_at: r[:created_at],
        chars: r[:body_md].to_s.length, excerpt: excerpt.gsub(/[*`]/, "")[0, 180],
        digest: ReportBlocks.digest(r[:body_md], ctx), }
    end

    # Full report: body rendered server-side (sanitized markdown + tl:* components + SHA links) and its headings.
    def report(r, store)
      ctx = Markdown.report_ctx(store)
      html = Markdown.report(r[:body_md], store, ctx)
      toc = Markdown.headings(html).map { |lvl, id, text| { level: lvl, id: id, text: text } }
      report_row(r, store, ctx).merge(html: html, toc: toc)
    end

    def note(n)
      { id: n[:id], author: n[:author], created_at: n[:created_at], body: n[:body], html: Markdown.render(n[:body]) }
    end

    # The SPA URL that opens a card on its project's board (the engine's "card #N" chips, search hits, reports).
    def card_path(slug, id) = DashboardUrl.card_path(slug, id)

    def agents(snap, groups, icons = {})
      sessions = groups.flat_map { |g| g[2] }
      { generated_at: snap["generated_at"], age_s: snap["age_s"], interval_s: snap["interval_s"],
        collector_error: snap["collector_error"], stale: snap["age_s"].to_f > 3 * snap["interval_s"].to_f,
        totals: { sessions: sessions.size, busy: sessions.count(&:busy?), subagents: sessions.sum(&:subagents),
                  blocked: sessions.count(&:blocked?), review: sessions.count { |s| s.state == "review" },
                  finished: sessions.count { |s| s.state == "finished" }, unread: sessions.count(&:unread?),
                  you: sessions.count { |s| s.blocked? || s.state == "review" || s.unread? }, },
        groups: groups.map do |label, slug, ss|
          { label: label, slug: slug, icon: slug && icons[slug],
            state: ss.map(&:state).min_by { |st| Agents::STATES.index(st) }, sessions: ss.map { |s| agent_session(s) }, }
        end, }
    end

    def agent_session(s)
      { key: s.key, name: s.name, socket: s.socket, terminal_url: terminal_url(s.name, s.socket), claude_url: s.claude_url,
        ssh_attach: ssh_attach(s.name), attached: s.attached, activity: s.activity,
        state: s.state, state_by: s.state_by, unread: s.unread?, turn_ended_at: s.turn_ended_at, seen_at: s.seen_at,
        cards_known: s.cards_known?,
        cards: s.open_cards.map do |c|
          agent_card(c, column_label: c[:column_label], column_type: c[:column_type], gate_hold: c[:gate_hold],
                        blocked_external: c[:blocked_external])
        end,
        cards_finished: s.finished_cards.size,
        subagents: s.subagents, engines: s.engines, title: s.title, cwd: s.cwd, model: s.model,
        waiting_for: s.waiting_for, dialogs: s.dialogs, screen_errors: s.screen_errors,
        asks: s.asks.map { |c| agent_card(c, question: c[:question].to_s[0, 300]) },
        reviews: s.reviews.map { |c| agent_card(c, pr_url: c[:pr_url]) }, }
    end

    # A card in an agent row: id, board, title, the row's own fields, then the board link (that key order is the JSON's)
    def agent_card(c, **fields)
      { id: c[:id], slug: c[:project_slug], title: c[:title], **fields, path: card_path(c[:project_slug], c[:id]) }
    end
  end
end
