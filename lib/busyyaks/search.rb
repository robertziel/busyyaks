# frozen_string_literal: true

require_relative "api"

module Busyyaks
  # Spotlight for the whole app: one query across projects, kanban cards (+ their comments), commits, reports,
  # notes and live agent sessions. Each group is ranked (exact > prefix > word-start > substring, then recency)
  # and capped; every item carries the path the SPA opens. A source that cannot be read (the launcher for
  # agents) is an error on its group, never an empty group pretending nothing matched.
  class Search
    PER = 8
    Item = ->(**kw) { kw }

    # columns: {key => label} of the board config; tables: the engine's table names (Kanban.default.tables) — the
    # palette reads card rows directly for speed, through the names the engine owns.
    def initialize(db, kanban_columns:, tables:)
      @db = db
      @columns = kanban_columns
      @t = tables
    end

    def run(query, agents: nil, agents_error: nil)
      q = query.to_s.strip
      return { q: q, groups: [] } if q.empty?

      groups = [
        group("projects", "Projects") { projects(q) },
        group("cards", "Board cards") { cards(q) },
        group("commits", "Commits") { commits(q) },
        group("reports", "Reports") { reports(q) },
        group("notes", "Notes") { notes(q) },
        if agents_error
          { key: "agents", label: "Agents", items: [], error: agents_error }
        else
          group("agents", "Agents") { agent_items(q, agents || []) }
        end,
      ]
      { q: q, groups: groups.reject { |g| g[:items].empty? && !g[:error] } }
    end

    private

    def group(key, label)
      items = yield
      { key: key, label: label, items: items.first(PER), total: items.size }
    end

    def like(q) = "%#{q.gsub(/[\\%_]/) { |c| "\\#{c}" }}%"
    def where_like(ds, *cols, q) = ds.where(Sequel.|(*cols.map { |c| Sequel.ilike(c, like(q)) }))

    def score(text, q)
      t = text.to_s.downcase
      s = q.downcase
      return 0 if t == s
      return 1 if t.start_with?(s)
      return 2 if t.match?(/(?:\A|[\s\/_.\-:])#{Regexp.escape(s)}/)

      3
    end

    def snippet(text, q, width: 70)
      t = text.to_s.gsub(/\s+/, " ").strip
      i = t.downcase.index(q.downcase)
      return t[0, width * 2] if i.nil?

      from = [i - width, 0].max
      (from.positive? ? "…" : "") + t[from, (width * 2) + q.length] + (from + (width * 2) + q.length < t.length ? "…" : "")
    end

    def path(slug) = "/projects/" + slug.split("/").map { |s| ERB::Util.url_encode(s) }.join("/")

    def projects(q)
      where_like(@db[:projects].where(present: true), :slug, :branch, :remote, q).limit(200).all
        .sort_by { |p| [score(p[:slug].split("/").last, q), score(p[:slug], q), -p[:last_commit_at].to_i] }
        .map do |p|
          via = if p[:slug].downcase.include?(q.downcase) then nil
                elsif p[:branch].to_s.downcase.include?(q.downcase) then "branch #{p[:branch]}"
                else p[:remote]
                end
          subtitle = [p[:own] ? "own" : "upstream", p[:branch], via].compact.uniq.join(" · ")
          Item.call(kind: "project", title: p[:slug], icon: API.icon_url(p), subtitle: subtitle,
                    href: path(p[:slug]), at: p[:last_commit_at],
                    meta: { commits_7d: p[:commits_window], dirty: p[:dirty], unpushed: p[:unpushed], remote: p[:remote] })
        end
    end

    def cards(q)
      hits = where_like(@db[@t[:cards]].where(archived_at: nil), :title, :notes, :assignee, :labels, q).limit(200).all
      by_comment = @db[@t[:card_activity]].where(kind: "comment").where(Sequel.ilike(:body, like(q))).limit(200).all
      extra = by_comment.map { |a| a[:card_id] }.uniq - hits.map { |c| c[:id] }
      hits += @db[@t[:cards]].where(id: extra, archived_at: nil).all unless extra.empty?
      comment_of = by_comment.group_by { |a| a[:card_id] }
      hits.sort_by { |c| [score(c[:title], q), -c[:updated_at].to_i] }.map do |c|
        body = c[:title].downcase.include?(q.downcase) ? c[:notes] : (comment_of[c[:id]]&.first&.dig(:body) || c[:notes])
        Item.call(kind: "card", title: c[:title], subtitle: "#{c[:project_slug]} · #{@columns.fetch(c[:column], c[:column])}",
                  snippet: snippet(body, q), href: "#{path(c[:project_slug])}?tab=board&card=#{c[:id]}", at: c[:updated_at],
                  meta: { id: c[:id], column: c[:column], assignee: c[:assignee], priority: c[:priority] })
      end
    end

    def commits(q)
      ds = @db[:commits]
      ds = if q.match?(/\A[0-9a-f]{4,40}\z/i)
             ds.where(Sequel.|(Sequel.like(:sha, "#{q.downcase}%"), Sequel.ilike(:subject, like(q))))
           else
             where_like(ds, :subject, :author, q)
           end
      ds.order(Sequel.desc(:committed_at)).limit(200).all
        .sort_by { |c| [c[:sha].start_with?(q.downcase) ? 0 : 1, -c[:committed_at]] }
        .map do |c|
          Item.call(kind: "commit", title: c[:subject], subtitle: "#{c[:project_slug]} · #{c[:sha][0, 7]} · #{c[:author]}",
                    href: "/commit/#{c[:sha]}", at: c[:committed_at],
                    meta: { sha: c[:sha], project: c[:project_slug], mine: c[:mine] })
        end
    end

    def reports(q)
      where_like(@db[:reports], :title, :body_md, :author, q).order(Sequel.desc(:created_at)).limit(100).all
        .sort_by { |r| [score(r[:title], q), -r[:created_at]] }
        .map do |r|
          Item.call(kind: "report", title: r[:title], subtitle: "#{r[:date]} · #{r[:author]}",
                    snippet: snippet(r[:body_md], q), href: "/reports/#{r[:id]}", at: r[:created_at], meta: { id: r[:id] })
        end
    end

    def notes(q)
      where_like(@db[:notes], :body, :author, q).order(Sequel.desc(:created_at)).limit(100).all.map do |n|
        Item.call(kind: "note", title: snippet(n[:body], q, width: 40),
                  subtitle: [n[:project_slug] || "general", n[:author]].join(" · "), snippet: snippet(n[:body], q),
                  href: n[:project_slug] ? path(n[:project_slug]) : "/", at: n[:created_at], meta: { id: n[:id] })
      end
    end

    def agent_items(q, sessions)
      s = q.downcase
      sessions.select { |x| [x.name, x.title, x.cwd, x.project].compact.any? { |v| v.to_s.downcase.include?(s) } }
              .sort_by { |x| [score(x.name, q), -x.activity] }
              .map do |x|
                Item.call(kind: "agent", title: x.name, subtitle: [x.state, x.engines.join("·"), x.title].compact.join(" · "),
                          href: x.project ? path(x.project) : "/", at: x.activity,
                          meta: { state: x.state, subagents: x.subagents, attach: "tmux attach -t #{x.name}",
                                  project: x.project, })
              end
    end
  end
end
