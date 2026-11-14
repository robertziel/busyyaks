# frozen_string_literal: true

require "erb"
require "cgi"
require "set"
require_relative "report_blocks"
require_relative "kanban"
require_relative "github"

module Busyyaks
  # Reports arrive over MCP; raw HTML in them is dropped (commonmarker's unsafe: false). The card half — descriptions,
  # comments, checklist items, @mentions, attachment pictures — is the vendored engine's renderer (Kanban.markdown);
  # this module keeps the REPORT rendering (tl:* blocks, commit chips) busyyaks alone has.
  module Markdown
    CardLinks = AgentsKanban::CardLinks
    SHA_CODE = %r{<code>([0-9a-f]{7,40})</code>}
    SECTION_STATUS = %r{(<h2 id="[^"]*">(?:(?!</h2>).)*</h2>)\s*(<p class="tl-status">(?:(?!</p>).)*</p>)}m
    module_function

    # what the report components need: the tracked slugs (repo chips link only to those) and the markdown renderer
    # + GitHub-style references: `refs` links branches / files / PRs / commits a line names inside the repo its block
    # names; `sha_chip` renders a known commit as glyph + short sha + subject (compact: no subject); `repo_url` adds the GitHub
    # mark to the repo chips that head a repo's own block (tl:cards, tl:repos).
    def report_ctx(store)
      projects = store.projects.to_h { |p| [p[:slug], p] }
      branches = {}
      commit_url = lambda do |c|
        p = projects[c[:project_slug]]
        Github.commit_url(p && p[:remote], c[:sha]) || "/commit/#{c[:sha]}"
      end
      { slugs: projects.keys.to_set, md: method(:render),
        repo_url: ->(slug) { (p = projects[slug]) && Github.repo_url(p[:remote]) },
        sha_chip: lambda do |sha, compact = false|
          c = store.commits_by_sha([sha.to_s])[sha.to_s]
          next %(<code>#{ERB::Util.h(sha)}</code>) unless c

          CardLinks.commit_chip(sha.to_s, commit_url.call(c), c[:subject], compact: compact)
        end,
        refs: lambda do |slug, html|
          p = Github.work_project(projects[slug.to_s])
          return html unless p && html.include?("<code>") || p && html.match?(/#\d|\.\w{1,8}\b|[0-9a-f]{7}/)

          text = CGI.unescapeHTML(html.gsub(/<[^>]+>/, " "))
          links = report_links(text, p, store, branches)
          # outside a card "PR #N" and "card #N" resolve (no activity, no board): a bare #N stays text
          refs = card_refs(repo: Github.repo_url(p[:remote]))
          CardLinks.linkify(html, links.reject { |l| l[:kind] == "repo" }, refs: refs)
        end, }
    end

    # A report line's links inside its repo. A checkout the port cannot read (never scanned, a failed read) links what
    # needs no checkout (PRs, commits, sites); the scan's error on the dashboard says why the repo was not read.
    def report_links(text, project, store, branches)
      card = { title: text, notes: "" }
      commits = ->(shas) { store.commits_by_sha(shas) }
      CardLinks.build(card, [], project, commits: commits, git: Kanban.git_port, branch_cache: branches)
    rescue GitPort::Unavailable
      CardLinks.build(card, [], project.merge(path: nil), commits: commits, git: Kanban.git_port)
    end

    # Report HTML: tl:* component blocks and inline tokens (ReportBlocks), then every `sha` that is a known commit
    # linked to /commit/<sha>.
    def report(md, store, ctx = report_ctx(store))
      src, blocks = ReportBlocks.extract(md, ctx)
      html = ReportBlocks.inline(ReportBlocks.inject(render(src), blocks), ctx)
      html = CardLinks.linkify(html, [], refs: card_refs) # "card #N" anywhere in the report (a repo block already did its own)
      # a status line right under a section heading is that section's meta ("0 cards in Human Check"): it sits on the
      # heading's row, so it never reads as one of the section's items
      html = html.gsub(SECTION_STATUS) { %(<div class="tl-sechead">#{Regexp.last_match(1)}#{Regexp.last_match(2)}</div>) }
      known = store.commits_by_sha(html.scan(SHA_CODE).flatten.uniq)
      remotes = store.projects.to_h { |p| [p[:slug], p[:remote]] }
      html.gsub(SHA_CODE) do
        sha = Regexp.last_match(1)
        c = known[sha]
        next Regexp.last_match(0) unless c

        CardLinks.commit_chip(sha, Github.commit_url(remotes[c[:project_slug]], c[:sha]) || "/commit/#{c[:sha]}", c[:subject])
      end
    end

    # [[level, id, text]] for h2/h3 headings (commonmarker's header_ids anchors).
    def headings(html)
      html.scan(%r{<h([23]) id="([^"]+)">(.*?)</h\1>}m).map { |l, id, t| [l.to_i, id, CGI.unescapeHTML(t.gsub(/<[^>]+>/, ""))] }
    end

    # Kanban descriptions, comments and checklist items: the engine's renderer (one render for the API, the MCP preview
    # and the saved rows). Reports and notes use the same CommonMark options through `render`.
    def card(md) = Kanban.markdown.card(md)
    def inline(md) = Kanban.markdown.inline(md)
    def render(md) = Kanban.markdown.render(md)

    # #N references outside a card (a report, a note): no activity, no board — "card #N" names a card of any board (a
    # chip with data-card-id: the hover preview), "PR #N" a PR of `repo` (nil = none), a bare #N stays text.
    def card_refs(repo: nil)
      CardLinks::Refs.new(repo: repo, activity_ids: Set.new, slug: nil, card_slugs: ->(ids) { Kanban.default.card_slugs(ids) },
                          card_path: ->(slug, id) { API.card_path(slug, id) })
    end

    # a note: the shared renderer, then its "card #N" references as chips
    def note(md) = CardLinks.linkify(render(md), [], refs: card_refs)
  end
end
