# frozen_string_literal: true

require_relative "kanban"

require "yaml"
require "erb"
require "json"
require "cgi"

require_relative "kanban"

module Busyyaks
  # The report component library: what a model writes inside a report's markdown to get rich UI instead of
  # plain tables. A component is a fenced block whose info string is `tl:<name>` and whose body is YAML:
  #
  #   ```tl:stats
  #   - { label: Commits, value: 35, tone: accent }
  #   ```
  #
  # plus inline tokens written as code spans: `repo:acme/x` (repo chip → project page), `ok:shipped`,
  # `warn:69 dirty`, `bad:failed`, `info:note` (status pills). Commit SHAs in code spans already link.
  #
  # A block that does not parse or breaks its schema renders as a visible error box naming the block and the
  # reason — never dropped, never guessed. CATALOG is the single source for the MCP `report_components` tool,
  # the /reports/components gallery and the tests (every example must render without an error box).
  module ReportBlocks
    class Invalid < StandardError; end

    TONES = %w[neutral accent ok warn bad info].freeze
    FENCE = /^```tl:([a-z]+)[ \t]*\n(.*?)^```[ \t]*$/m
    INLINE = %r{<code>(repo|ok|warn|bad|info):([^<]{1,120})</code>}

    CATALOG = [
      { name: "stats",
        summary: "Row of headline figures (KPI tiles). Use first, for the totals; with prev, each tile shows its change.",
        schema: "list of {label, value, tone?, sub?, prev?, good?} — value: number or short text; " \
                "sub: small line under the label; " \
                "prev: yesterday's number (value must then be a number) → ▲/▼ change; " \
                "good: up|down — which direction is good (colours the change)",
        example: <<~Y, },
          - { label: Commits 24h, value: 49, prev: 12, good: up, tone: accent }
          - { label: Repos active, value: 5, prev: 2, good: up }
          - { label: Uncommitted, value: 52, prev: 48, good: down, tone: warn, sub: in 2 repos }
          - { label: Unpushed, value: 31, prev: 31, good: down, tone: warn }
          - { label: Human Check, value: 0, tone: ok, sub: cards waiting }
        Y
      { name: "cards", summary: "Per-repo card grid: the main body of a daily report — numbers, what shipped, what is at risk.",
        schema: "list of {repo, status?, branch?, upstream?, commits?, prev?, mine?, dirty?, unpushed?, files?, add?, del?, " \
                "shipped?, risks?, shas?} — " \
                "status: a tone; upstream: true|false (false → no-upstream pill); prev: commits the 24h before; " \
                "shipped / risks: lists of short markdown lines (≤ 4 each, no prose); shas: list",
        example: <<~Y, },
          - repo: acme/shop
            status: bad
            branch: feat/checkout-v2
            upstream: false
            commits: 25
            prev: 0
            dirty: 49
            files: 229
            add: 15659
            del: 2891
            shipped: ["Checkout = cart × region tax (one pass)", "Price rules v2 for every region"]
            risks: ["**Breaking:** region now required (migration)", "25 commits exist only on this box"]
            shas: [5ca1ab1e, c0ffee01]
          - repo: inference
            status: ok
            branch: local
            upstream: true
            commits: 1
            prev: 7
            unpushed: 0
            shipped: ["chat: cut-off answers left out of history"]
            shas: [decafbad]
        Y
      { name: "flags", summary: "Risk / flag list: breaking changes, security, work that exists only on this box. Worst first.",
        schema: "list of {level: bad|warn|info, kind, text, repo?, sha?} — " \
                "kind: a short tag (≤ 24 chars, e.g. breaking, security, no upstream, unpushed); text: markdown",
        example: <<~Y, },
          - { level: bad, kind: no upstream, repo: acme/shop, text: "25 commits + 49 dirty files on a branch with no remote" }
          - { level: warn, kind: breaking, repo: acme/shop, sha: feedf00d, text: "No default region — old checkout requests now fail" }
          - { level: info, kind: unpushed, repo: blog, text: "22 commits ahead of `origin/main`" }
        Y
      { name: "needs",
        summary: "What needs the operator: kanban cards in Human input (an agent's open question) and " \
                 "Human Check (only the operator moves them on), and decisions.",
        schema: "list of {title, repo, card?, column?, since?, ask?} — card: kanban card id (links to the card); " \
                "since: when it started waiting; ask: markdown, the decision needed",
        example: <<~Y, },
          - { title: Security remediation plan, repo: blog, card: 4, column: Human Check, since: 2025-03-01 22:10, ask: "Approve the fix order: auth first" }
          - { title: Rebuild the image after the SPA merge, repo: blog, ask: "Choose a deploy window" }
        Y
      { name: "churn", summary: "Compact changed-files summary per repo: files touched, lines +/−, where.",
        schema: "list of {repo, files, add, del, top?} — integers ≥ 0; top: list of the busiest top-level dirs (≤ 4)",
        example: <<~Y, },
          - { repo: acme/shop, files: 229, add: 15659, del: 2891, top: [app, python, spec] }
          - { repo: blog, files: 12, add: 10214, del: 2, top: [src] }
          - { repo: inference, files: 2, add: 26, del: 3, top: [chat] }
        Y
      { name: "repos", summary: "Per-repo status rows: the main body of a daily report.",
        schema: "list of {repo, status?, commits?, mine?, dirty?, unpushed?, summary?, shas?} — " \
                "status: a tone; summary: markdown; shas: list",
        example: <<~Y, },
          - repo: blog
            status: warn
            commits: 6
            mine: 6
            dirty: 7
            unpushed: 21
            summary: "Pricing page moved to `/plans/`; docs content"
            shas: [0badcaf, deadbee]
          - repo: acme/shop
            status: bad
            commits: 22
            dirty: 69
            summary: "Checkout v2, region allowlist — **22 commits never pushed**"
          - repo: inference
            status: ok
            commits: 1
            summary: "chat: partial answers left out of history"
        Y
      { name: "actions", summary: "Prioritised to-do list (the \"Act on\" section). Max ~5.",
        schema: "list of {text, priority: high|med|low, repo?} — text: markdown",
        example: <<~Y, },
          - { priority: high, repo: acme/shop, text: "Push `feat/checkout-v2` (22 commits, no upstream)" }
          - { priority: med, repo: blog, text: "Commit 7 new benchmark pages" }
          - { priority: low, text: "Prune stale clones: old-api-2, scratch-copy" }
        Y
      { name: "callout", summary: "One highlighted message: a risk, a failure, a decision needed.",
        schema: "{tone, title, body?} — body: markdown",
        example: <<~Y, },
          tone: bad
          title: Secrets file modified
          body: "`shop/.kamal/secrets` changed and is uncommitted — check before any commit."
        Y
      { name: "bars", summary: "Horizontal bar chart: compare one number across items.",
        schema: "{title?, unit?, items: list of {label, value, tone?}} — value: number ≥ 0",
        example: <<~Y, },
          title: Commits, 7 days
          unit: commits
          items:
            - { label: inference, value: 184 }
            - { label: api, value: 161 }
            - { label: mobile, value: 118 }
            - { label: blog, value: 25, tone: ok }
        Y
      { name: "progress", summary: "Done / total per item (rollouts, migrations, checklists).",
        schema: "list of {label, done, total, tone?} — numbers, 0 ≤ done ≤ total",
        example: <<~Y, },
          - { label: Repos pushed, done: 70, total: 82 }
          - { label: Audit fixes, done: 11, total: 16, tone: warn }
        Y
      { name: "diffstat", summary: "Changed files with +/− lines, GitHub style.",
        schema: "list of {path, add, del} — integers ≥ 0",
        example: <<~Y, },
          - { path: lib/busyyaks/scanner.rb, add: 48, del: 12 }
          - { path: app/templates/home.html.erb, add: 30, del: 41 }
          - { path: public/static/reports.css, add: 140, del: 0 }
        Y
      { name: "timeline", summary: "What happened when: deploys, incidents, a day's sequence.",
        schema: "list of {time, text, tone?, repo?, sha?} — text: markdown",
        example: <<~Y, },
          - { time: "21:33", tone: ok, repo: auth, sha: f00dfac, text: "busyyaks audience deployed" }
          - { time: "22:31", tone: info, text: "tunnel restarted — tunnels down ~12 s" }
          - { time: "22:36", tone: ok, text: "First daily report posted" }
        Y
      { name: "spark", summary: "Small trend lines: a number over time, one row per series.",
        schema: "list of {label, values: list of numbers (≥ 2), unit?, tone?}",
        example: <<~Y, },
          - { label: Commits/day, values: [4, 9, 3, 12, 7, 15, 35], tone: accent }
          - { label: Dirty files, values: [30, 32, 41, 44, 48, 48, 48], tone: warn }
        Y
      { name: "github",
        summary: "GitHub network feed: your github.com/feed (releases, new repos, forks… + pushes per repo + counts), " \
                 "repos the people you follow starred, accounts they followed. " \
                 "Paste github_network's block_markdown verbatim — never write repos or logins yourself.",
        schema: "{window, to?, collected?, error?, follows_since?, network?: {login: avatar}, " \
                "repos?: list of {repo, description?, language?, stars?, topics?, avatar?, starred_by, starred_at?}, " \
                "people?: list of {login, name?, bio?, avatar?, followers?, followed_by, you_follow?}, " \
                "more?: {repos?, people?}, " \
                "feed?: {error?, since?, gap?, items?: list of {id, kind: release|repo|public|fork|member|tag|star, " \
                "actor, repo, at, " \
                "tag?, name?, prerelease?, forkee?, member?, ref?, description?, language?, stars?, topics?, avatar?}, " \
                "pushes?: list of {repo, pushes, branches?, by, at?}, " \
                "activity?: {comments?, issues?, pull_requests?, reviews?, discussions?, other?}, " \
                "more?: {items?, pushes?}}} — " \
                "written by the MCP tool github_network (block_markdown); " \
                "check_report verifies every repo / person / feed event against the collector's snapshots; " \
                "avatars only from avatars.githubusercontent.com",
        example: <<~Y, },
          window: 1d
          to: "2025-03-02T10:00:00+01:00"
          collected: "2025-03-02T10:00:00+01:00"
          network:
            octocat: https://avatars.githubusercontent.com/u/583231?v=4
            defunkt: https://avatars.githubusercontent.com/u/2?v=4
          feed:
            items:
              - id: "18915908648"
                kind: release
                actor: octocat
                repo: octocat/hello-world
                at: "2025-03-02T09:13:16+01:00"
                tag: v1.2.0
                name: Hello World 1.2
              - id: "18874699322"
                kind: repo
                actor: defunkt
                repo: defunkt/new-thing
                at: "2025-03-02T08:51:44+01:00"
                description: A new thing
                language: Ruby
                stars: 3
            pushes:
              - repo: octocat/hello-world
                pushes: 4
                branches: 2
                by: [octocat]
                at: "2025-03-02T09:10:00+01:00"
            activity: {comments: 12, pull_requests: 3, issues: 2}
          repos:
            - repo: ggml-org/llama.cpp
              description: LLM inference in C/C++
              language: C++
              stars: 89231
              topics: [ggml, llama, inference]
              avatar: https://avatars.githubusercontent.com/u/134263123?v=4
              starred_by: [octocat, defunkt]
              starred_at: "2025-03-02T08:12:00+01:00"
            - repo: rails/rails
              description: Ruby on Rails
              language: Ruby
              stars: 57012
              avatar: https://avatars.githubusercontent.com/u/4223?v=4
              starred_by: [defunkt]
              starred_at: "2025-03-01T19:40:00+01:00"
          people:
            - login: mojombo
              name: Tom Preston-Werner
              bio: Founder of GitHub
              avatar: https://avatars.githubusercontent.com/u/1?v=4
              followers: 24500
              followed_by: [octocat]
        Y
      { name: "kv", summary: "Compact facts grid (key → value).",
        schema: "mapping of key → value (text, markdown allowed)",
        example: <<~Y, },
          Branch: "`feat/checkout-v2`"
          Upstream: none
          Worktrees: 2
          Last deploy: 2025-02-20
        Y
    ].freeze

    module_function

    # markdown → [markdown with placeholders, {placeholder => html}]
    def extract(md, ctx)
      blocks = {}
      out = md.to_s.gsub(FENCE) do
        name = Regexp.last_match(1)
        body = Regexp.last_match(2)
        key = "TLBLOCK#{blocks.size}X"
        blocks[key] = render_block(name, body, ctx)
        "\n#{key}\n"
      end
      [out, blocks]
    end

    def inject(html, blocks)
      blocks.reduce(html) { |acc, (k, v)| acc.sub(%r{<p>#{k}</p>}, v) }
    end

    # a paragraph that is only a status pill ("nothing to show": `ok:0 cards in Human Check`) is a section's status line
    STATUS_P = %r{<p>(<span class="tl-pill t-[a-z]+">[^<]*</span>)</p>}

    def inline(html, ctx)
      html.gsub(INLINE) do
        kind = Regexp.last_match(1)
        val = CGI.unescapeHTML(Regexp.last_match(2))
        kind == "repo" ? repo_chip(val, ctx) : pill(kind, val)
      end.gsub(STATUS_P) { %(<p class="tl-status">#{Regexp.last_match(1)}</p>) }
    end

    BROKEN = [Invalid, Psych::Exception, ArgumentError, TypeError, NoMethodError].freeze

    def render_block(name, body, ctx)
      %(<div class="tl tl-#{name}">#{build(name, body, ctx)}</div>)
    rescue *BROKEN => e
      %(<div class="tl tl-error" role="alert"><b>tl:#{e(name)}</b> not rendered: #{e(e.message.lines.first.to_s.strip)}</div>)
    end

    # the component's inner HTML; raises on an unknown name, bad YAML or a schema break
    def build(name, body, ctx)
      unless CATALOG.any? { |c| c[:name] == name }
        raise Invalid, "unknown component (known: #{CATALOG.map { |c| c[:name] }.join(', ')})"
      end

      send("b_#{name}", YAML.safe_load(body, permitted_classes: [Date, Time]), ctx)
    end

    # What a report says at a glance, for the report list and cards: the first tl:stats figures, the first callout (or the
    # worst flag) as the headline, action counts by priority, repo / flag / needs counts, and how many blocks are broken.
    def digest(md, ctx)
      out = { figures: [], headline: nil, actions: { high: 0, med: 0, low: 0 }, repos: 0, flags: 0, needs: 0, broken: 0 }
      md.to_s.scan(FENCE) do |name, body|
        begin
          build(name, body, ctx)
        rescue *BROKEN
          out[:broken] += 1
          next
        end
        digest_block(out, name, YAML.safe_load(body, permitted_classes: [Date, Time]))
      end
      out
    end

    # ["tl:<name> #<n>: <reason>"] for every block that would render as an error box
    def problems(md, ctx)
      md.to_s.scan(FENCE).each_with_index.filter_map do |(name, body), i|
        build(name, body, ctx)
        nil
      rescue *BROKEN => e
        "tl:#{name} (block #{i + 1}): #{e.message.lines.first.to_s.strip}"
      end
    end

    def digest_block(out, name, d)
      case name
      when "stats"
        return unless out[:figures].empty?

        out[:figures] = d.first(6).map do |f|
          { label: f["label"].to_s, value: f["value"].to_s, tone: tone(f["tone"]),
            delta: f.key?("prev") ? fmt(f["value"] - f["prev"]) : nil, good: f["good"]&.to_s, }
        end
      when "callout" then out[:headline] ||= { tone: d["tone"].to_s, text: d["title"].to_s }
      when "flags"
        out[:flags] += d.size
        worst = d.min_by { |f| LEVELS.index(f["level"].to_s) }
        out[:headline] ||= { tone: worst["level"].to_s, text: "#{worst['kind']}: #{plain(worst['text'])}" }
      when "actions" then d.each { |a| out[:actions][a["priority"].to_sym] += 1 }
      when "repos", "cards" then out[:repos] += d.size
      when "needs" then out[:needs] += d.size
      end
    end

    # a markdown one-liner as plain text (for the digest)
    def plain(s) = s.to_s.gsub(/[*_`]/, "")[0, 160]

    # ── components ─────────────────────────────────────────────────────────────────────────────────

    def b_stats(d, _ctx)
      list!(d, "stats").map do |s|
        t = tone(s["tone"])
        sub = s["sub"] ? %(<small>#{wbr(e(s["sub"]))}</small>) : ""
        delta = if s.key?("prev")
                  delta_html(num!(s["value"], "value (with prev)"), num!(s["prev"], "prev"), good!(s["good"]))
                else
                  ""
                end
        %(<div class="tl-stat t-#{t}"><span class="tl-stat-fig"><b>#{e(req(s, 'value'))}</b>#{delta}</span>) +
          %(<span class="tl-stat-label">#{e(req(s, 'label'))}</span>#{sub}</div>)
      end.join
    end

    def b_cards(d, ctx)
      cards = list!(d, "cards").map { |c| card_html(c, ctx) }
      %(<div class="tl-cardgrid">#{cards.join}</div>)
    end

    def card_html(c, ctx)
      up = c["upstream"]
      raise Invalid, "upstream must be true or false" unless up.nil? || up == true || up == false

      branch = c["branch"] ? %(<code class="tl-branch" title="branch">#{e(c["branch"])}</code>) : ""
      shas = sha_chips(c["shas"], ctx)
      figs = card_figs(c)
      %(<article class="tl-card t-#{tone(c["status"])}"><header>) +
        %(<i class="tl-dot"></i>#{repo_chip(req(c, 'repo'), ctx, gh: true)}) +
        %(#{up == false ? pill('bad', 'no upstream') : ''}#{branch}</header>) +
        (figs.empty? ? "" : %(<div class="tl-figs">#{figs.join}</div>)) +
        lines_html(c["shipped"], "shipped", "tl-shipped", ctx, repo: c["repo"]) +
        lines_html(c["risks"], "risks", "tl-risks", ctx, repo: c["repo"]) +
        (shas.empty? ? "" : %(<footer class="tl-shas">#{shas}</footer>)) + "</article>"
    end

    def card_figs(c)
      figs = []
      if c.key?("commits")
        n = int!(c["commits"], "commits")
        chg = c.key?("prev") ? delta_html(n, int!(c["prev"], "prev"), nil, "vs #{c['prev']} the 24h before") : ""
        figs << fig(n, "commits", chg)
      end
      figs << fig(int!(c["mine"], "mine"), "mine") if c.key?("mine")
      %w[dirty unpushed].each do |k|
        next unless c.key?(k)

        v = c[k].nil? ? nil : int!(c[k], k)
        figs << fig(v.nil? ? "—" : v, k, "", v.to_i.positive?)
      end
      if %w[add del files].any? { |k| c.key?(k) }
        files = c.key?("files") ? %(<b>#{int!(c["files"], "files")}</b> files ) : ""
        figs << (%(<span class="tl-fig tl-lines">#{files}<b class="tl-add">+#{int!(c["add"], "add")}</b> ) +
                 %(<b class="tl-del">−#{int!(c["del"], "del")}</b></span>))
      end
      figs
    end

    def b_flags(d, ctx)
      rows = list!(d, "flags").sort_by { |f| LEVELS.index(level!(f["level"])) }.map do |f|
        kind = req(f, "kind").to_s
        raise Invalid, "kind must be ≤ 24 chars (a tag, not a sentence)" if kind.length > 24

        where = [f["repo"] && repo_chip(f["repo"], ctx), f["sha"] && sha_chips([f["sha"]], ctx, compact: true)].compact.join
        %(<li class="t-#{f["level"]}"><span class="tl-kind">#{e(kind)}</span>) +
          %(<span class="tl-flag-text">#{md_inline(req(f, 'text'), ctx, repo: f["repo"])}</span>) +
          %(<span class="tl-flag-where">#{where}</span></li>)
      end
      %(<ul class="tl-flags">#{rows.join}</ul>)
    end

    def b_needs(d, ctx)
      rows = list!(d, "needs").map do |n|
        slug = req(n, "repo").to_s
        title = e(req(n, "title"))
        card = n["card"].nil? ? nil : int!(n["card"], "card")
        head = if card && ctx[:slugs].include?(slug)
                 %(<a class="tl-need-title" href="#{project_href(slug)}?tab=board&amp;card=#{card}">#{title}</a>)
               else
                 %(<span class="tl-need-title">#{title}</span>)
               end
        meta = [card && %(<span class="tl-card-id">##{card}</span>), repo_chip(slug, ctx),
                n["column"] && %(<span class="tl-col">#{e(n["column"])}</span>),
                n["since"] && %(<span class="tl-since">since #{e(n["since"])}</span>),].compact.join
        ask = n["ask"] ? %(<div class="tl-ask">#{md_inline(n["ask"], ctx, repo: n["repo"])}</div>) : ""
        %(<li><i class="tl-need-mark"></i><div class="tl-need-main">) +
          %(<div class="tl-need-head">#{head}#{meta}</div>#{ask}</div></li>)
      end
      %(<ol class="tl-needs">#{rows.join}</ol>)
    end

    def b_churn(d, ctx)
      items = list!(d, "churn").map { |c| [c, int!(c["files"], "files"), int!(c["add"], "add"), int!(c["del"], "del")] }
      max = [items.map { |_, _, a, dl| a + dl }.max, 1].max.to_f
      rows = items.map do |c, files, add, del|
        top = Array(c["top"]).first(4).map { |t| %(<code>#{e(t)}</code>) }.join
        %(<li><span class="tl-churn-repo">#{repo_chip(req(c, 'repo'), ctx)}</span>) +
          %(<span class="tl-churn-bar" title="+#{add} −#{del}">) +
          %(<i class="a" style="width:#{(add / max * 100).round(1)}%"></i>) +
          %(<i class="d" style="width:#{(del / max * 100).round(1)}%"></i></span>) +
          %(<span class="tl-churn-n"><b>#{files}</b> files</span>) +
          %(<span class="tl-add">+#{add}</span><span class="tl-del">−#{del}</span>) +
          %(#{top.empty? ? '' : %(<span class="tl-churn-top">#{top}</span>)}</li>)
      end
      %(<ul class="tl-churn-list">#{rows.join}</ul>)
    end

    def b_repos(d, ctx)
      rows = list!(d, "repos").map do |r|
        t = tone(r["status"])
        nums = [["commits", r["commits"]], ["mine", r["mine"]], ["dirty", r["dirty"]], ["unpushed", r["unpushed"]]]
               .reject { |_, v| v.nil? }
               .map do |k, v|
                 %(<span class="tl-num#{' hot' if %w[dirty unpushed].include?(k) && v.to_i.positive?}">) +
                   %(<b>#{e(v)}</b> #{k}</span>)
               end.join
        shas = sha_chips(r["shas"], ctx)
        summary = r["summary"] ? %(<div class="tl-sum">#{md_inline(r["summary"], ctx, repo: r["repo"])}</div>) : ""
        %(<li class="t-#{t}"><i class="tl-dot"></i><div class="tl-repo-main">) +
          %(<div class="tl-repo-head">#{repo_chip(req(r, 'repo'), ctx, gh: true)}#{nums}</div>) +
          %(#{summary}#{shas.empty? ? '' : %(<div class="tl-shas">#{shas}</div>)}</div></li>)
      end
      %(<ul class="tl-repos">#{rows.join}</ul>)
    end

    def b_actions(d, ctx)
      items = list!(d, "actions").map do |a|
        pr = a["priority"].to_s
        raise Invalid, "priority must be high, med or low" unless %w[high med low].include?(pr)

        repo = a["repo"] ? repo_chip(a["repo"], ctx) : ""
        %(<li class="p-#{pr}"><span class="tl-prio">#{pr}</span>) +
          %(<span class="tl-act-text">#{md_inline(req(a, 'text'), ctx, repo: a["repo"])}</span>#{repo}</li>)
      end
      %(<ol class="tl-actions">#{items.join}</ol>)
    end

    def b_callout(d, ctx)
      raise Invalid, "callout must be a mapping {tone, title, body?}" unless d.is_a?(Hash)

      t = tone(d["tone"] || raise(Invalid, "tone is required"))
      body = d["body"] ? %(<div>#{md_inline(d["body"], ctx)}</div>) : ""
      %(<div class="tl-callout t-#{t}"><b>#{e(req(d, 'title'))}</b>#{body}</div>)
    end

    def b_bars(d, _ctx)
      raise Invalid, "bars must be a mapping with items" unless d.is_a?(Hash)

      items = list!(d["items"], "bars.items")
      vals = items.map { |i| num!(i["value"], "value") }
      max = [vals.max.to_f, 1].max
      rows = items.zip(vals).map do |i, v|
        %(<div class="tl-bar t-#{tone(i["tone"])}"><span class="tl-bar-label">#{e(req(i, 'label'))}</span>) +
          %(<span class="tl-bar-track"><i style="width:#{(v / max * 100).round(1)}%"></i></span>) +
          %(<b>#{e(fmt(v))}</b></div>)
      end
      return rows.join unless d["title"]

      unit = d["unit"] ? %( <span>· #{e(d["unit"])}</span>) : ""
      %(<header>#{e(d["title"])}#{unit}</header>) + rows.join
    end

    def b_progress(d, _ctx)
      list!(d, "progress").map do |p|
        done = num!(p["done"], "done")
        total = num!(p["total"], "total")
        raise Invalid, "need 0 ≤ done ≤ total, total > 0" unless total.positive? && done >= 0 && done <= total

        pct = (done / total * 100).round
        t = if p["tone"] then tone(p["tone"])
            elsif pct == 100 then "ok"
            else "accent"
            end
        %(<div class="tl-prog t-#{t}"><span class="tl-bar-label">#{e(req(p, 'label'))}</span>) +
          %(<span class="tl-bar-track"><i style="width:#{pct}%"></i></span>) +
          %(<b>#{e(fmt(done))}/#{e(fmt(total))}</b><span class="tl-pct">#{pct}%</span></div>)
      end.join
    end

    def b_diffstat(d, _ctx)
      rows = list!(d, "diffstat").map do |f|
        add = int!(f["add"], "add")
        del = int!(f["del"], "del")
        tot = add + del
        green = tot.zero? ? 0 : (add * 5.0 / tot).round
        boxes = (Array.new(green, "a") + Array.new(tot.zero? ? 0 : 5 - green, "d") + Array.new(tot.zero? ? 5 : 0, "z"))
                .map { |c| %(<i class="#{c}"></i>) }.join
        %(<li><code>#{e(req(f, 'path'))}</code><span class="tl-add">+#{add}</span><span class="tl-del">−#{del}</span>) +
          %(<span class="tl-boxes">#{boxes}</span></li>)
      end
      %(<ul class="tl-diff">#{rows.join}</ul>)
    end

    def b_timeline(d, ctx)
      rows = list!(d, "timeline").map do |t|
        extra = [t["repo"] && repo_chip(t["repo"], ctx),
                 t["sha"] && sha_chips([t["sha"]], ctx, compact: true),].compact.join(" ")
        %(<li class="t-#{tone(t["tone"])}"><time>#{e(req(t, 'time'))}</time><i class="tl-dot"></i>) +
          %(<div>#{md_inline(req(t, 'text'), ctx, repo: t["repo"])} #{extra}</div></li>)
      end
      %(<ol class="tl-timeline">#{rows.join}</ol>)
    end

    def b_spark(d, _ctx)
      list!(d, "spark").map do |s|
        vals = Array(s["values"]).map { |v| num!(v, "values[]") }
        raise Invalid, "values needs at least 2 numbers" if vals.size < 2

        lo, hi = vals.minmax
        span = (hi - lo).zero? ? 1 : hi - lo
        w = 120.0
        h = 28.0
        pts = vals.each_with_index.map do |v, i|
          [(i * w / (vals.size - 1)).round(1), (h - 3 - ((v - lo) / span * (h - 6))).round(1)]
        end
        line = pts.map { |x, y| "#{x},#{y}" }.join(" ")
        area = "0,#{h} #{line} #{w},#{h}"
        last = vals.last
        delta = last - vals.first
        %(<div class="tl-sparkrow t-#{tone(s["tone"])}"><span class="tl-bar-label">#{e(req(s, 'label'))}</span>) +
          %(<svg viewBox="0 0 #{w.to_i} #{h.to_i}" preserveAspectRatio="none" aria-hidden="true">) +
          %(<polygon points="#{area}"/><polyline points="#{line}"/>) +
          %(<circle cx="#{pts.last[0]}" cy="#{pts.last[1]}" r="2.6"/></svg>) +
          %(<b>#{e(fmt(last))}#{s["unit"] ? " #{e(s["unit"])}" : ''}</b>) +
          %(<span class="tl-delta#{delta_class(delta)}">#{delta.positive? ? '+' : ''}#{e(fmt(delta))}</span></div>)
      end.join
    end

    def b_kv(d, ctx)
      raise Invalid, "kv must be a mapping" unless d.is_a?(Hash) && d.any?

      %(<dl>#{d.map { |k, v| %(<dt>#{e(k)}</dt><dd>#{md_inline(v.to_s, ctx)}</dd>) }.join}</dl>)
    end

    # ── helpers ────────────────────────────────────────────────────────────────────────────────────

    def e(s) = ERB::Util.h(s.to_s)

    def delta_class(delta)
      if delta.positive? then " up"
      elsif delta.negative? then " down"
      else ""
      end
    end

    def tone(t)
      return "neutral" if t.nil?
      raise Invalid, "tone #{t.inspect} — use one of #{TONES.join(', ')}" unless TONES.include?(t.to_s)

      t.to_s
    end

    def list!(d, what)
      raise Invalid, "#{what} must be a non-empty list" unless d.is_a?(Array) && d.any? && d.all? { |x| x.is_a?(Hash) }

      d
    end

    def req(h, key)
      v = h[key]
      raise Invalid, "#{key} is required" if v.nil? || v.to_s.strip.empty?

      v
    end

    def num!(v, what)
      raise Invalid, "#{what} must be a number, got #{v.inspect}" unless v.is_a?(Numeric)

      v.to_f
    end

    def int!(v, what)
      raise Invalid, "#{what} must be a whole number ≥ 0, got #{v.inspect}" unless v.is_a?(Integer) && v >= 0

      v
    end

    LEVELS = %w[bad warn info].freeze

    def level!(l)
      LEVELS.include?(l.to_s) ? l.to_s : raise(Invalid, "level #{l.inspect} — use one of #{LEVELS.join(', ')}")
    end

    def good!(g)
      return nil if g.nil?
      raise Invalid, "good must be up or down, got #{g.inspect}" unless %w[up down].include?(g.to_s)

      g.to_s
    end

    # ▲/▼ change chip: green/red when `good` says which direction is good, grey otherwise.
    def delta_html(cur, prev, good, title = "vs #{fmt(prev)} yesterday")
      dv = cur - prev
      dir = if dv.positive? then "up" elsif dv.negative? then "down" else "flat" end
      feel = if good.nil? || dir == "flat" then ""
             elsif dir == good then " good"
             else " bad"
             end
      sign = { "up" => "▲", "down" => "▼", "flat" => "=" }[dir]
      %(<span class="tl-chg #{dir}#{feel}" title="#{e(title)}">) +
        %(<i aria-hidden="true">#{sign}</i>#{dir == 'flat' ? '' : e(fmt(dv.abs))}</span>)
    end

    def fig(v, label, extra = "", hot = false) = %(<span class="tl-fig#{' hot' if hot}"><b>#{e(v)}</b> #{label}#{extra}</span>)

    def lines_html(list, what, cls, ctx, repo: nil)
      return "" if list.nil?
      unless list.is_a?(Array) && list.all? { |x| x.is_a?(String) || x.is_a?(Numeric) }
        raise Invalid, "#{what} must be a list of short lines"
      end
      return "" if list.empty?

      %(<ul class="#{cls}">#{list.map { |x| %(<li>#{md_inline(x.to_s, ctx, repo: repo)}</li>) }.join}</ul>)
    end

    def project_href(slug) = "/projects/" + slug.split("/").map { |s| ERB::Util.url_encode(s) }.join("/")

    def fmt(v) = v.is_a?(Float) && v == v.round ? v.round.to_s : v.to_s

    def pill(kind, text) = %(<span class="tl-pill t-#{kind}">#{e(text)}</span>)

    # A chip that links only when the repo is tracked; an unknown name is shown struck, not linked. gh: the GitHub mark
    # after it — only where the chip heads the repo's own block (a card, a repo row), not on every mention.
    def repo_chip(slug, ctx, gh: false)
      slug = slug.to_s
      if ctx[:slugs].include?(slug)
        gh = gh && ctx[:repo_url]&.call(slug)
        %(<a class="tl-repo" href="#{project_href(slug)}">#{e(slug)}</a>) +
          (if gh
             %(<a class="gh-repo-link" href="#{e(gh)}" target="_blank" rel="noopener" title="#{e(slug)} on GitHub">) +
               %(#{AgentsKanban::CardLinks::ICONS['github']}</a>)
           else
             ""
           end)
      else
        %(<span class="tl-repo unknown" title="not a tracked repo">#{e(slug)}</span>)
      end
    end

    # markdown for a one-liner inside a component: rendered, outer <p> dropped, inline tokens applied.
    def md_inline(s, ctx, repo: nil)
      html = inline(ctx[:md].call(s.to_s.encode("UTF-8")).strip.sub(%r{\A<p>(.*)</p>\z}m, '\1'), ctx)
      repo && ctx[:refs] ? ctx[:refs].call(repo, html) : html
    end

    def sha_chips(shas, ctx, compact: false)
      Array(shas).map { |s| ctx[:sha_chip] ? ctx[:sha_chip].call(s.to_s, compact) : %(<code>#{e(s)}</code>) }.join(" ")
    end

    # escaped text with break opportunities after _ / · (long slugs in narrow tiles break there, not mid-word)
    def wbr(html) = html.gsub(%r{([_/·])}, '\\1<wbr>')

    def catalog_markdown
      head = <<~MD
        # Busyyaks report components
        Write these inside `post_report`'s body_markdown. A component is a fenced block with info string `tl:<name>` and a YAML body.
        Inline tokens (code spans): `repo:<slug>` repo chip · `ok:<text>` `warn:<text>` `bad:<text>` `info:<text>` status pills · commit SHAs link automatically.
        Tones: #{TONES.join(', ')}. A broken block renders as an error box — check the report page after posting.
        Data, not prose: numbers, tags and ≤ 12-word lines. No paragraphs, no "summary" sentences that repeat the numbers.
        Every number comes from a tool (daily_facts / list_projects), never from counting by hand; a number you could not get is left out, never estimated ("18+" is wrong).

        Suggested daily layout (one fixed order, so days compare):
        1. tl:stats — totals with prev (from daily_facts.previous): Commits 24h (good: up), Repos active, Uncommitted (good: down), Unpushed (good: down), No upstream (good: down), Human Check.
        2. tl:callout — only when something failed or is at risk today; one line title.
        3. "## Needs you" — tl:needs from daily_facts.human_input (agents' open questions, column Human input) then daily_facts.human_check (card ids link to the card) + decisions only the operator can take; none → `ok:0 cards waiting for you`.
        4. "## At risk" — tl:flags, worst first: no upstream, unpushed, breaking, security, secrets, failed scans; then one `info` flag per daily_facts.blocked_external card (kind `blocked externally`, text `card #<id>` + its reason: it waits for the world — another card, CI, a third party —, never under Needs you).
        5. "## Shipped" — tl:cards, one per active own repo: numbers + ≤ 4 shipped lines + risks + 1-2 shas.
        6. "## Changes" — tl:churn (files / +/− per repo).
        7. "## Upstream" — tl:flags for breaking/security upstream changes; none → `info:0 upstream flags`.
        8. "## GitHub network" — github_network(24)'s block_markdown pasted verbatim (one tl:github block: your github.com/feed — releases and new repos first, max 10 items, max 5 pushed repos, the rest counted — then new stars and follows of the people you follow, or "nothing new", or the collector's error).
        9. "## Act on" — tl:actions, max 5, each one command-sized.
        Every `repo` must be a real tracked slug (list_projects); for "nothing to show" write an inline pill, never a placeholder row.
      MD
      head + CATALOG.map do |c|
        "\n## tl:#{c[:name]}\n#{c[:summary]}\nSchema: #{c[:schema]}\n\n```tl:#{c[:name]}\n#{c[:example]}```\n"
      end.join
    end
  end
end

require_relative "github_block"
