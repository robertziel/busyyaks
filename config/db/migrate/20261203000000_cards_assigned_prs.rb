# frozen_string_literal: true

require "json"
require_relative "../../../lib/busyyaks/pr_states"

# A card's PRs are the ones its agents assigned to it (kanban_pr_assign → metadata prs.<role>) — the board
# no longer derives them from the card's pr_url, its handoff text or branch names. This carries the cards already in
# flight over, once, from what the old lookup read, so none of them is stuck at its next approval:
#   - an enrolled project (projects.local_mode): `local` = the pr_url when it is a PR on the local repo, else the newest
#     handoff naming one; `public` = the pr_url when it is a PR on the public repo;
#   - any other project: `pr` = the pr_url when it is a GitHub PR (its URL names the repo, as the code reads it).
# A role the card already has is kept. Cards of every column, archived too. The github pollers' rows for the refs no
# longer asked (`head:` / `branch:`) are deleted. Prints the number of cards carried over.
#
# down: nothing — the assignments stay; the code before this change does not read prs.local / prs.pr.
ROM::SQL.migration do
  up do
    pr = %r{https://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)}
    # the first PR on `repo` the text names, as its URL; nil when none (or no repo on github.com)
    on = lambda do |text, repo|
      r, n = repo && text.to_s.scan(pr).find { |owner_name, _| owner_name.casecmp?(repo) }
      r && "https://github.com/#{r}/pull/#{n}"
    end
    projects = self[:projects].select_hash(:slug, %i[local_mode local_repo public_repo])
    n = 0
    self[:cards].select(:id, :project_slug, :pr_url, :metadata).all.each do |c|
      mode, local_remote, public_remote = projects[c[:project_slug]]
      meta = c[:metadata] ? JSON.parse(c[:metadata]) : {}
      next unless meta.is_a?(Hash)

      prs = meta["prs"].is_a?(Hash) ? meta["prs"].dup : {}
      found = {}
      if mode
        local = Busyyaks::PrStates.slug(local_remote)
        handoffs = self[:card_activity].where(card_id: c[:id], kind: "handoff").order(Sequel.desc(:id)).select_map(:body)
        found["local"] = on.call(c[:pr_url], local) || handoffs.lazy.filter_map { |b| on.call(b, local) }.first
        found["public"] = on.call(c[:pr_url], Busyyaks::PrStates.slug(public_remote))
      else
        found["pr"] = c[:pr_url].to_s[/\A#{pr}\z/]
      end
      add = found.compact.reject { |role, _| prs.key?(role) }
      next if add.empty?

      meta["prs"] = prs.merge(add)
      self[:cards].where(id: c[:id]).update(metadata: JSON.generate(meta))
      n += 1
    end
    %i[gh_pr_states gh_pr_checks].each do |t|
      self[t].where(Sequel.like(:ref, "head:%") | Sequel.like(:ref, "branch:%")).delete
    end
    puts "cards_assigned_prs: #{n} card(s) carried over"
  end

  down do
    # nothing: see the header
  end
end
