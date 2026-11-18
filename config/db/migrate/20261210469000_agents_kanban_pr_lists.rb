# frozen_string_literal: true

require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"
require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/errors"
require_relative "../../../lib/busyyaks/pr_states"

# agents_kanban Schema v14: a card's PRs are a LIST — metadata prs {role => url} (one PR per role) becomes
# [{url, repo, number, role, by, at}] (by / at read off the card's own "PR <role>: <url>" activity line, null when none
# says), so a card holds every PR of every repo it changes. A data step: no DDL. A value naming several PRs in text
# ("…/pull/1 + /pull/2 (merged: …)") becomes one entry per PR; an old role key the host does not read (`engine`,
# `mirror`, …) becomes the one role whose repos hold the PR's repo (PrStates::Roles: the scanner's enrolment rows, as
# the Store reads them). Anything else stops the migration naming the card and the value — nothing is guessed.
ROM::SQL.migration do
  up do
    db = self
    roles = Busyyaks::PrStates::Roles.new(projects: ->(slug) { db[:projects].where(slug: slug.to_s).first },
                                          enrolled: -> { db[:projects].exclude(local_mode: nil).order(:slug).all })
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 14, prs: roles)
  end

  # Back to {role => url}, exactly: an entry up mapped (an old `engine` / `mirror` key, `local` on a plain project that
  # reads only `pr`) carries `from_roles` and goes back under those keys. Refused (nothing written, the cards
  # named) while a card holds two PRs of one role or has PRs unassigned — v12 cannot hold either; restore the backup
  # taken before the deploy instead.
  down do
    AgentsKanban::Schema.prs_to_roles!(self, prefix: "")
  end
end
