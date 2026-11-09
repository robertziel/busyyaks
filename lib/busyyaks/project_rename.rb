# frozen_string_literal: true

module Busyyaks
  # Moves one project's rows to a new slug after its directory was renamed:
  # projects.slug + its path's last segment, and every table's project_slug column (commits, daily, cards, boards,
  # board columns / transitions / labels, agent sessions, notes, …), found from the schema so a new table is never
  # missed. One transaction. Refused — nothing written — when the old slug is unknown, its path does not end in it, or
  # the new slug already has any row. Run it with every service stopped (a request for the new slug creates its board).
  #
  # author: [old, new] re-signs the engine's own entries after system_author changed (the idle watch tells the engine's
  #   pings from the owner's activity by that name): AUTHOR_COLUMNS.
  # repo: ["owner/old", "owner/new"] after a GitHub repo rename: gh_merged_prs.repo (+ url), cards.pr_url and the
  #   projects' remote / pr_remote — GitHub answers the old name with a 301 the collector reports as an error, and the
  #   merged-PR search returns the new name, so unmigrated rows would be counted twice.
  module ProjectRename
    module_function

    Refused = Class.new(StandardError)

    AUTHOR_COLUMNS = [%i[card_activity author], %i[cards asked_by], %i[session_dialogs answered_by],
                      %i[agent_sessions launched_by], %i[boards updated_by],].freeze
    REPO_URL_COLUMNS = [%i[cards pr_url], %i[gh_merged_prs url], %i[projects remote], %i[projects pr_remote]].freeze

    # → {"table.column" => rows changed}
    def run(db, from:, to:, author: nil, repo: nil)
      raise Refused, "refused: same slug #{from.inspect}" if from == to
      if [from, to, *author, *repo].any? { |v| v.to_s.strip.empty? }
        raise Refused, "refused: empty value in #{[from, to, author, repo].inspect}"
      end
      if repo && !repo.all? { |r| r.match?(%r{\A[\w.-]+/[\w.-]+\z}) }
        raise Refused, "refused: repo must be owner/name, got #{repo.inspect}"
      end

      cols = slug_columns(db)
      taken = cols.select { |t, c| db[t].where(c => to).count.positive? }
      raise Refused, "refused: #{to.inspect} already has rows in #{taken.map { |t, c| "#{t}.#{c}" }.join(', ')}" if taken.any?
      row = db[:projects].where(slug: from).first or raise Refused, "refused: no project #{from.inspect}"
      tail = "/#{from.split('/').last}"
      raise Refused, "refused: path #{row[:path]} does not end in #{tail}" unless row[:path].end_with?(tail)

      db.transaction do
        out = cols.to_h { |t, c| ["#{t}.#{c}", db[t].where(c => from).update(c => to)] }
        new_path = row[:path].delete_suffix(tail) + "/#{to.split('/').last}"
        out["projects.path"] = db[:projects].where(slug: to).update(path: new_path)
        if author
          present(db, AUTHOR_COLUMNS).each { |t, c| out["#{t}.#{c}"] = db[t].where(c => author[0]).update(c => author[1]) }
        end
        rename_repo(db, *repo, out) if repo
        out
      end
    end

    def rename_repo(db, old, new, out)
      out["gh_merged_prs.repo"] = db[:gh_merged_prs].where(repo: old).update(repo: new) if db.table_exists?(:gh_merged_prs)
      re = %r{(github\.com[/:])#{Regexp.escape(old)}(?=\.git\z|/|\z)}i
      present(db, REPO_URL_COLUMNS).each do |t, c|
        # by value, not by row id (portable: SQLite and PostgreSQL); every row holding a value gets the same rewrite
        values = db[t].exclude(c => nil).where(Sequel.ilike(c, "%#{old}%")).distinct.select_map(c)
        out["#{t}.#{c}"] = values.sum do |was|
          v = was.sub(re) { "#{Regexp.last_match(1)}#{new}" }
          v == was ? 0 : db[t].where(c => was).update(c => v)
        end
      end
    end

    def slug_columns(db)
      with_slug = db.tables.sort.select { |t| db.schema(t).any? { |c, _| c == :project_slug } }
      [[:projects, :slug]] + with_slug.map { |t| [t, :project_slug] }
    end

    def present(db, list) = list.select { |t, c| db.table_exists?(t) && db.schema(t).any? { |n, _| n == c } }
  end
end
