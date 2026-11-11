# frozen_string_literal: true

require "json"
require "set"
require "date"
require "time"
require "rack/utils"
require_relative "config"
require_relative "scanner"
require_relative "git_read"
require_relative "store"
require_relative "report_blocks"
require_relative "markdown"
require_relative "kanban"
require_relative "github_network"
require_relative "scan_freshness"

module Busyyaks
  # MCP over Streamable HTTP (JSON responses, no SSE stream), at POST /mcp.
  # Bearer MCP_TOKEN required; any Origin header is refused (no browser should ever call this).
  # A second bearer, MCP_REPORT_TOKEN, is the daily report's (bin/daily-report and its runner — a model that reads
  # untrusted text: commit subjects, the GitHub feed): it lists and calls only REPORT_TOOLS — reads + check/post_report,
  # nothing that writes a card, a note or anything typed into a session.
  class McpServer
    PROTOCOLS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze
    INFO = { name: "busyyaks", version: "0.1.0" }.freeze

    TOOLS = [
      { name: "whats_new",
        description: "Everything new on a day: that day's reports, commits per repo since local midnight, " \
                     "repos with uncommitted or unpushed work.",
        inputSchema: { type: "object", properties: {
          date: { type: "string", description: "YYYY-MM-DD; today when omitted" },
        }, }, },
      { name: "list_projects",
        description: "Tracked git repos with branch, last commit, commits/mine in the scan window, dirty files, " \
                     "unpushed commits.",
        inputSchema: { type: "object", properties: {
          own: { type: "boolean", description: "true = own repos, false = upstream clones; all when omitted" },
          active_days: { type: "integer", description: "only repos with a commit in the last N days" },
        }, }, },
      { name: "project",
        description: "One repo: state, recent commits, notes.",
        inputSchema: { type: "object", properties: { slug: { type: "string" }, limit: { type: "integer" } },
                       required: ["slug"], }, },
      { name: "daily_facts",
        description: "The numbers for a daily report, computed here (never count or estimate them yourself): " \
                     "commits in the last `hours` vs the `hours` before, each active repo (commits, prev, mine, " \
                     "branch, upstream, dirty, dirty_paths, unpushed, subjects, churn with per-commit paths), " \
                     "pending work over every repo (dirty / unpushed / " \
                     "own repos with no upstream), kanban cards waiting for the operator on every board " \
                     "(human_input: an agent's open question; human_check: work to check that can be approved now; " \
                     "waiting_for_ci: gate cards whose CI is not green yet, not counted; blocked_external: cards " \
                     "waiting for another card, CI or a third party, not counted) and per-column card " \
                     "counts, the previous report of `series` with its headline figures, the last scan.",
        inputSchema: { type: "object", properties: {
          hours: { type: "integer", description: "window length, 1-168 (24 for a daily report)" },
          series: { type: "string",
                    description: "title prefix of the previous report to compare with, e.g. \"Daily report\"", },
        }, required: %w[hours series], }, },
      { name: "report_components",
        description: "The report UI component library: tl:stats, tl:cards, tl:flags, tl:needs, tl:churn, tl:repos, " \
                     "tl:actions, tl:callout, tl:bars, tl:progress, tl:diffstat, tl:timeline, tl:spark, tl:kv, " \
                     "tl:github blocks and inline repo/status tokens, with schema and an example each, and the " \
                     "daily report layout. Read before writing a report.",
        inputSchema: { type: "object", properties: {} }, },
      { name: "check_report",
        description: "Check a report's markdown before posting: lists every tl:* block that would render as an " \
                     "error box (with the reason) and every repo chip that names an untracked repo. Posts nothing.",
        inputSchema: { type: "object", properties: { body_markdown: { type: "string" } },
                       required: ["body_markdown"], }, },
      { name: "post_report",
        description: "Publish a report (markdown) to the dashboard. The daily report goes here. Build it from the " \
                     "components in report_components (fenced ```tl:<name> YAML blocks) — rich UI instead of plain " \
                     "tables.",
        inputSchema: { type: "object", properties: {
          title: { type: "string" }, body_markdown: { type: "string" },
          author: { type: "string", description: "who wrote it, e.g. the agent/model name" },
          date: { type: "string", description: "YYYY-MM-DD; today when omitted" },
        }, required: %w[title body_markdown author], }, },
      { name: "list_reports",
        description: "Recent reports (id, date, title, author).",
        inputSchema: { type: "object", properties: { limit: { type: "integer" }, date: { type: "string" } } }, },
      { name: "get_report",
        description: "Full markdown of one report.",
        inputSchema: { type: "object", properties: { id: { type: "integer" } }, required: ["id"] }, },
      { name: "add_note",
        description: "Attach a note to a repo (or a general note when project is omitted).",
        inputSchema: { type: "object", properties: {
          body: { type: "string" }, author: { type: "string" }, project: { type: "string" },
        }, required: %w[body author], }, },
      { name: "list_notes",
        description: "Notes, newest first; one repo's when project is given.",
        inputSchema: { type: "object", properties: { project: { type: "string" }, limit: { type: "integer" } } }, },
      { name: "github_network",
        description: "The operator's GitHub network in the last `hours`, from the collector's snapshots: repos the " \
                     "people they follow starred (grouped per repo, starred by most followees first, with " \
                     "description / language / stars / topics), accounts those people started following (with who " \
                     "followed them), the operator's dashboard feed (github.com/feed: releases, new repos, repos " \
                     "made public, forks, members, tags, stars not already under repos — releases and new repos " \
                     "first; pushes summarised per repo; every event grouped by repo then type with actors; " \
                     "comments / issues / PRs / reviews counted) and the collector's status (last run, error, rate " \
                     "limit left, feed coverage). block_markdown is the ready tl:github block: paste it verbatim " \
                     "into a report.",
        inputSchema: { type: "object", properties: {
          hours: { type: "integer", description: "window length, 1-#{GithubNetwork::MAX_HOURS} (24 for a daily report)" },
        }, required: %w[hours], }, },
      { name: "scan_now",
        description: "Rescan every repo now (git log/status/upstream); returns repo count and duration.",
        inputSchema: { type: "object", properties: {} }, },
      { name: "daily_report_config",
        description: "How the daily report runs on this deployment (config/busyyaks.yml daily_report, validated): schedule, " \
                     "cutoff, timeouts, gateway, models, runner (type + its keys). bin/daily-report and the timer installer " \
                     "read it here. Error when the deployment has no daily_report.",
        inputSchema: { type: "object", properties: {} }, },
    ].freeze

    class ToolError < StandardError; end

    # What MCP_REPORT_TOKEN may call: the reads the daily report makes, check_report and post_report. Never scan_now: a
    # scan runs git on repos busyyaks does not control inside this process, which holds the launcher socket.
    REPORT_TOOLS = %w[whats_new list_projects project daily_facts report_components check_report post_report list_reports
                      get_report list_notes github_network daily_report_config
                      kanban_board kanban_card kanban_workflow].freeze

    # bin/daily-report's placeholders ("<series> FAILED", "<series> NOT RUN — …"): never a previous report.
    NOT_A_REPORT = /\b(FAILED|NOT RUN)\b/
    CHURN_PATHS_MAX = 15

    # sessions: -> live tmux session names for kanban_claim (nil = the host launcher's `sessions` op).
    # scan_interval: .env SCAN_INTERVAL_SECONDS (the scanner's value): last_scan is `stale` when it finished longer ago
    # than 3 × the interval + min(its duration, one interval), more than 60 s in the future, or a row with no start /
    # a negative duration (ScanFreshness)
    def initialize(token:, report_token:, scan_interval:, store: nil, config: nil, clock: -> { Time.now }, sessions: nil)
      raise KeyError, "MCP_TOKEN is empty" if token.to_s.length < 32
      raise KeyError, "MCP_REPORT_TOKEN must be at least 32 characters" if report_token.to_s.length < 32
      raise KeyError, "MCP_REPORT_TOKEN must differ from MCP_TOKEN" if report_token == token

      unless scan_interval.is_a?(Integer) && scan_interval.positive?
        raise KeyError, "SCAN_INTERVAL_SECONDS must be a positive integer"
      end

      @token = token
      @report_token = report_token
      @scan_interval = scan_interval
      @store = store
      @config = config
      @clock = clock
      @sessions = sessions
    end

    def call(env)
      return plain(404, "not found") unless env["PATH_INFO"] == "/mcp"
      return plain(403, "browser origins are refused") if env["HTTP_ORIGIN"]
      scope = scope_of(env["HTTP_AUTHORIZATION"].to_s)
      unless scope
        log_refused(env)
        return plain(401, "bearer token required")
      end
      return [405, { "allow" => "POST" }, []] unless env["REQUEST_METHOD"] == "POST"

      msg = JSON.parse(env["rack.input"].read)
      return json(200, rpc_error(nil, -32_600, "batches are not supported")) unless msg.is_a?(Hash)
      return [202, {}, []] unless msg.key?("id") # notification / response

      json(200, dispatch(msg, scope: scope))
    rescue JSON::ParserError
      json(400, rpc_error(nil, -32_700, "parse error"))
    end

    # scope: :full (MCP_TOKEN) or :report (MCP_REPORT_TOKEN: REPORT_TOOLS only)
    def dispatch(msg, scope: :full)
      id = msg["id"]
      case msg["method"]
      when "initialize"
        asked = msg.dig("params", "protocolVersion")
        result(id, protocolVersion: PROTOCOLS.include?(asked) ? asked : PROTOCOLS.first,
                   capabilities: { tools: { listChanged: false } }, serverInfo: INFO,
                   instructions: instructions(scope))
      when "ping" then result(id, {})
      when "tools/list" then result(id, tools: tools_for(scope))
      when "tools/call"
        name = msg.dig("params", "name")
        args = msg.dig("params", "arguments") || {}
        begin
          if scope == :report && !REPORT_TOOLS.include?(name)
            raise ToolError, "#{name} is not open to the daily report's token (MCP_REPORT_TOKEN: #{REPORT_TOOLS.join(', ')})"
          end

          text = call_tool(name, args)
          result(id, content: [{ type: "text", text: text }], isError: false)
        rescue ToolError, ArgumentError, KeyError, Date::Error, Config::Invalid => e
          result(id, content: [{ type: "text", text: "error: #{e.message}" }], isError: true)
        end
      else rpc_error(id, -32_601, "method not found: #{msg['method']}")
      end
    end

    def call_tool(name, a)
      case name
      when "whats_new" then whats_new(day(a["date"]))
      when "daily_facts" then daily_facts(Integer(a.fetch("hours")), str!(a, "series"))
      when "list_projects"
        rows = store.projects(own: a["own"])
        if a["active_days"]
          cut = now.to_i - (Integer(a["active_days"]) * 86_400)
          rows = rows.select { |p| p[:last_commit_at].to_i >= cut }
        end
        dump(rows.map { |p| project_row(p) })
      when "project"
        p = store.project(a.fetch("slug")) or raise ToolError, "no project #{a['slug']}"
        dump(project: project_row(p),
             commits: store.commits(slug: p[:slug], limit: Integer(a["limit"] || 50)).map { |c| commit_row(c) },
             notes: store.notes(project_slug: p[:slug], limit: 20).map { |n| note_row(n) })
      when "report_components" then ReportBlocks.catalog_markdown
      when "check_report"
        md = str!(a, "body_markdown")
        html = Markdown.report(md, store)
        unknown = html.scan(%r{<span class="tl-repo unknown"[^>]*>([^<]+)</span>}).flatten.uniq.map { |s| CGI.unescapeHTML(s) }
        dump(broken: ReportBlocks.problems(md, Markdown.report_ctx(store)), untracked_repos: unknown,
             github_unverified: ReportBlocks.github_unverified(md, gh_data.db, login: github_login))
      when "github_network"
        feed = GithubNetwork::Feed.call(gh_data, login: github_login, hours: Integer(a.fetch("hours")), now: now.to_i)
        dump(github_json(feed).merge(block_markdown: GithubNetwork::Block.markdown(feed)))
      when "post_report"
        id = store.add_report(date: day(a["date"]).iso8601, title: str!(a, "title"),
                              body_md: str!(a, "body_markdown"), author: str!(a, "author"))
        dump(id: id)
      when "list_reports"
        reports = store.reports(limit: Integer(a["limit"] || 20), date: a["date"])
        dump(reports.map { |r| r.slice(:id, :date, :title, :author).merge(created_at: iso(r[:created_at])) })
      when "get_report"
        r = store.report(Integer(a.fetch("id"))) or raise ToolError, "no report #{a['id']}"
        "# #{r[:title]}\n_#{r[:date]} · #{r[:author]}_\n\n#{r[:body_md]}"
      when "add_note"
        slug = a["project"]
        raise ToolError, "no project #{slug}" if slug && !store.project(slug)

        dump(id: store.add_note(body: str!(a, "body"), author: str!(a, "author"), project_slug: slug))
      when "list_notes"
        notes = store.notes(project_slug: a.key?("project") ? a["project"] : :any, limit: Integer(a["limit"] || 50))
        dump(notes.map { |n| note_row(n) })
      when "scan_now"
        t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        n = Scanner.new(config, store).run
        dump(repos: n, seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t).round(1))
      when "daily_report_config"
        # read fresh on every call (unless injected): an edit to daily_report applies at the next tick, no restart
        dr = (@config || Config.load).daily_report or
          raise ToolError, "no daily report on this deployment: config/busyyaks.yml has no daily_report key"
        dump(dr.to_h)
      else
        raise ToolError, "unknown tool: #{name}" unless kanban_tools.handles?(name)

        kanban_tools.call(name, a)
      end
    end

    def whats_new(date)
      from = Time.new(date.year, date.month, date.day).to_i
      to = from + 86_400
      commits = store.commits(since: from, limit: 2000).select { |c| c[:committed_at] < to }
      by_repo = commits.group_by { |c| c[:project_slug] }.map do |slug, cs|
        { repo: slug, commits: cs.size, mine: cs.count { |c| c[:mine] },
          subjects: cs.first(15).map { |c| "#{c[:sha][0, 9]} #{c[:subject]}" }, }
      end.sort_by { |r| -r[:commits] }
      pending = store.projects.select { |p| p[:dirty].positive? || p[:unpushed].to_i.positive? }
                     .map { |p| { repo: p[:slug], dirty: p[:dirty], unpushed: p[:unpushed] } }
      scan = store.last_scan
      dump(date: date.iso8601,
           reports: store.reports(date: date.iso8601).map do |r|
             { id: r[:id], title: r[:title], author: r[:author], body_markdown: r[:body_md] }
           end,
           commits_by_repo: by_repo,
           pending_work: pending,
           last_scan: ScanFreshness.json(scan, interval: @scan_interval, now: now))
    end

    def daily_facts(hours, series)
      raise ToolError, "hours must be 1..168, got #{hours}" unless (1..168).cover?(hours)

      to = now.to_i
      from = to - (hours * 3600)
      commits = store.commits(since: from - (hours * 3600), limit: 1_000_000).select { |c| c[:committed_at] <= to }
      cur, prev = commits.partition { |c| c[:committed_at] >= from }
      prev_by = prev.group_by { |c| c[:project_slug] }
      repos = cur.group_by { |c| c[:project_slug] }.map do |slug, cs|
        # one order for subjects and churn.commits, stable on every database (same-second commits by sha)
        cs = cs.sort_by { |c| [c[:committed_at], c[:sha]] }
        p = store.project(slug)
        { repo: slug, own: p && p[:own], branch: p && p[:branch], upstream: p && !p[:unpushed].nil?, commits: cs.size,
          prev: (prev_by[slug] || []).size, mine: cs.count { |c| c[:mine] }, dirty: p && p[:dirty], unpushed: p && p[:unpushed],
          dirty_paths: p && p[:dirty_paths] && JSON.parse(p[:dirty_paths]),
          subjects: cs.map { |c| "#{c[:sha][0, 9]} #{c[:subject]}" },
          churn: p ? churn(p[:path], cs.map { |c| c[:sha] }) : { error: "project #{slug} not in the store" }, }
      end.sort_by { |r| -r[:commits] }
      projects = store.projects
      dirty = projects.select { |p| p[:dirty].positive? }
      unpushed = projects.select { |p| p[:unpushed].to_i.positive? }
      week = to - (7 * 86_400)
      no_up = projects.select { |p| p[:own] && p[:unpushed].nil? && p[:last_commit_at].to_i >= week }
      kanban = Kanban.default
      slugs = projects.map { |p| p[:slug] }
      # the daily report's two "needs you" lists: the cards flagged needs_operator (an agent's open question, in whatever
      # column) and the cards in the boards' gate columns (a check); a card only blocked_external waits for the world,
      # not for the operator: its own list, never "needs you"
      w = kanban.waiting_cards(slugs)
      by_slug = w.by_slug
      boards = w.boards
      asks = []
      checks = []
      by_slug.each do |slug, cs|
        cs.each do |c|
          if kanban.needs_operator?(c) then asks << c
          elsif boards[slug].gate?(c[:column]) then checks << c
          end
        end
      end
      questions = asks.map do |c|
        { card: c[:id], repo: c[:project_slug], title: c[:title], column: c[:column_label], since: iso(c[:since]),
          assignee: c[:assignee], owner_session: c[:owner_session],
          needs_operator: !c[:asked_at].nil?, question: c[:question],
          options: c[:question_options] && JSON.parse(c[:question_options]), asked_by: c[:asked_by],
          asked: iso(c[:asked_at]),
          blocked: c[:blocked_at] && { reason: c[:blocked_reason], url: c[:blocked_url], by: c[:blocked_author],
                                       at: iso(c[:blocked_at]), }, }
      end
      human_check = checks.map do |c|
        { card: c[:id], repo: c[:project_slug], title: c[:title], since: iso(c[:since]), assignee: c[:assignee],
          priority: c[:priority], comments: c[:comments], }
      end
      # gate cards whose Approve would not pass now: waiting for CI, not for the operator
      waiting_for_ci = w.held.values.flatten.map do |c|
        { card: c[:id], repo: c[:project_slug], title: c[:title], column: c[:column_label], hold: c[:gate_hold],
          owner_session: c[:owner_session], }
      end
      blocked_external = w.external.values.flatten.map do |c|
        { card: c[:id], repo: c[:project_slug], title: c[:title], column: c[:column_label], since: iso(c[:since]),
          reason: c[:blocked_reason], url: c[:blocked_url], by: c[:blocked_author], owner_session: c[:owner_session], }
      end
      columns = kanban.counts(slugs: slugs).each_with_object(Hash.new(0)) do |(slug, cols), acc|
        b = kanban.board_of(slug)
        cols.each { |k, n| acc[b.label(k)] += n }
      end
      before = store.reports(limit: 50).find do |r|
        r[:created_at] <= to && r[:title].start_with?(series) && !r[:title].match?(NOT_A_REPORT)
      end
      scan = store.last_scan
      dump(window: { from: iso(from), to: iso(to), hours: hours },
           totals: { commits: cur.size, mine: cur.count { |c| c[:mine] }, repos_active: repos.size },
           previous_window: { commits: prev.size, mine: prev.count { |c| c[:mine] }, repos_active: prev_by.size },
           repos: repos,
           pending: { dirty_files: dirty.sum { |p| p[:dirty] }, dirty_repos: dirty.size,
                      unpushed_commits: unpushed.sum { |p| p[:unpushed] }, unpushed_repos: unpushed.size,
                      no_upstream_active_own: no_up.map { |p| p[:slug] },
                      top: (dirty | unpushed).sort_by { |p| -(p[:dirty] + p[:unpushed].to_i) }.first(10)
                                             .map { |p| { repo: p[:slug], dirty: p[:dirty], unpushed: p[:unpushed] } }, },
           human_input: questions,
           human_check: human_check,
           waiting_for_ci: waiting_for_ci,
           blocked_external: blocked_external,
           kanban_columns: columns,
           previous_report: before && { id: before[:id], title: before[:title], created_at: iso(before[:created_at]),
                                        figures: ReportBlocks.digest(before[:body_md], Markdown.report_ctx(store))[:figures], },
           last_scan: ScanFreshness.json(scan, interval: @scan_interval, now: now))
    end

    private

    # Lines changed by exactly these commits, computed here so the report model never adds numbers up:
    # {files, add, del, top, binary, commits} (top = the 4 busiest top-level dirs by lines; commits = per commit its
    # short sha and the first CHURN_PATHS_MAX paths it touched + how many more — what the daily report's children read to
    # flag migrations, removed routes, secrets, instead of running git on the host). A binary file counts as a file with
    # 0 lines; so does one larger than GIT_READ_MAX_BLOB_BYTES (never loaded) — `binary` says how many files that is.
    # Read by a GitRead child (libgit2, its limits; no git CLI). A read that fails (repo gone, sha missing, a limit) →
    # {error}, never a partial or guessed figure.
    def churn(path, shas, root: GitRead.mount)
      read = GitRead.call("churn", path: path, root: root, shas: shas)
      files = {}
      binary = Set.new
      add = del = 0
      read["files"].each do |f, a, d, bin, _big|
        files[f] = (files[f] || 0) + a + d
        add += a
        del += d
        binary << f if bin
      end
      dirs = files.each_with_object(Hash.new(0)) { |(f, n), acc| acc[f.include?("/") ? "#{f.split('/').first}/" : f] += n }
      { files: files.size, add: add, del: del, top: dirs.sort_by { |_, n| -n }.first(4).map(&:first), binary: binary.size,
        commits: read["commits"].map { |c| { sha: c["sha"][0, 9], paths: c["paths"].first(CHURN_PATHS_MAX),
                                              more: [c["paths"].size - CHURN_PATHS_MAX, 0].max, } }, }
    rescue GitRead::Failed => e
      { error: e.message[0, 300] }
    end

    def store = (@store ||= Store.default)
    # The vendored engine's MCP tools, worded for config/kanban.yml; `sessions` = the launcher's live tmux names.
    def kanban_tools = Kanban.tools(sessions: @sessions)
    def config = (@config ||= Config.load)
    def now = @clock.call
    def day(s) = s.nil? || s.empty? ? now.to_date : Date.iso8601(s)
    def iso(ts) = ts && Time.at(ts).iso8601
    def dump(obj) = JSON.pretty_generate(obj)

    def str!(a, key)
      v = a[key]
      raise ToolError, "#{key} is required" unless v.is_a?(String) && !v.strip.empty?

      v
    end

    def project_row(p)
      { slug: p[:slug], path: p[:path], own: p[:own], branch: p[:branch], remote: p[:remote],
        last_commit: iso(p[:last_commit_at]), commits_window: p[:commits_window], mine_window: p[:mine_window],
        dirty: p[:dirty], unpushed: p[:unpushed], }
    end

    def gh_data = (@gh_data ||= GithubNetwork::Data.default)
    def github_login = (@github_login ||= ENV.fetch("GITHUB_LOGIN"))

    # the feed with every timestamp as ISO 8601 (the model reads it)
    def github_json(feed)
      st = feed[:status]
      { window: { hours: feed[:window][:hours], from: iso(feed[:window][:from]), to: iso(feed[:window][:to]) },
        login: feed[:login],
        status: st.merge(%i[last_run_at last_ok_at running_since rate_reset follows_since].to_h { |k| [k, iso(st[k])] }),
        followees: feed[:followees].size,
        repos: feed[:repos].map do |r|
          r.slice(:repo, :url, :description, :language, :stars, :topics, :starred_by)
           .merge(starred_at: r[:starred_at].map { |t| iso(t) }, stars_as_of: iso(r[:fetched_at]))
        end,
        people: feed[:people].map do |p|
          p.slice(:login, :name, :bio, :followers, :followed_by, :you_follow)
           .merge(first_seen_at: iso(p[:first_seen_at]))
        end,
        feed: feed_json(feed[:feed]), }
    end

    def feed_json(f)
      st = f[:status]
      { status: st.merge(%i[last_run_at last_ok_at since gap_at].to_h { |k| [k, iso(st[k])] }),
        total: f[:total], counts: f[:counts],
        items: f[:items].map do |i|
          i.except(:avatar, :type).merge(at: iso(i[:at])).tap { |h| h[:card] = h[:card].except(:avatar) if h[:card] }
        end,
        pushes: f[:pushes].map { |x| x.except(:avatars).merge(last_at: iso(x[:last_at])) },
        by_repo: f[:by_repo].map { |r| r.merge(last_at: iso(r[:last_at])) },
        activity: f[:activity], stars_covered: f[:stars_covered], }
    end

    def commit_row(c)
      { sha: c[:sha][0, 9], at: iso(c[:committed_at]), author: c[:author], mine: c[:mine], subject: c[:subject] }
    end

    def note_row(n) = { id: n[:id], project: n[:project_slug], at: iso(n[:created_at]), author: n[:author], body: n[:body] }

    # the report token's client is told only about what it may call (the board's agent rules are not its business)
    def instructions(scope)
      head = "Busyyaks: the operator's projects, daily reports and notes. Start with whats_new."
      return "#{head} This token reaches the daily report's tools only: #{REPORT_TOOLS.join(', ')}." if scope == :report

      "#{head} #{kanban_tools.instructions}"
    end

    def tools_for(scope)
      all = TOOLS + kanban_tools.definitions
      scope == :report ? all.select { |t| REPORT_TOOLS.include?(t[:name].to_s) } : all
    end

    # the bearer's scope: :full, :report, or nil (refused). Both tokens are compared, always, in constant time.
    def scope_of(header)
      given = header.delete_prefix("Bearer ")
      return nil if given.empty? || given == header

      full = Rack::Utils.secure_compare(given, @token)
      report = Rack::Utils.secure_compare(given, @report_token)
      if full then :full
      elsif report then :report
      end
    end

    # One line per refused request on the Rack error stream (puma → the container log): when, from where, why — never
    # the header's value, so neither a wrong token nor a near-miss of the real one is ever written down.
    def log_refused(env)
      header = env["HTTP_AUTHORIZATION"].to_s
      why = if header.empty? then "no Authorization header"
            elsif !header.start_with?("Bearer ") then "not a Bearer Authorization header"
            else "wrong bearer token"
            end
      env["rack.errors"].puts("#{@clock.call.utc.iso8601} mcp 401 #{why} from #{env['REMOTE_ADDR']} " \
                              "#{env['REQUEST_METHOD']} #{env['PATH_INFO']}")
    end

    def result(id, res) = { jsonrpc: "2.0", id: id, result: res }
    def rpc_error(id, code, message) = { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
    def json(status, body) = [status, { "content-type" => "application/json" }, [JSON.generate(body)]]
    def plain(status, text) = [status, { "content-type" => "text/plain" }, [text]]
  end
end
