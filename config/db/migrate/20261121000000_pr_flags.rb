# frozen_string_literal: true

# PR flags on a card's links: which repo a PR is in (mirror · public) and its state (open · draft · merged
# · closed).
# projects: the private-mirror enrolment the scanner reads from the repo's git config (its guard config,
#   `guard.*`): mirror_mode (own | upstream | nil = not enrolled), mirror_repo (guard.mirrorRemote's URL), public_repo
#   (guard.upstreamRemote's fetch URL — the public PR is opened there), public_head (guard.publicRemote's URL — the
#   repo `pub/card-<id>` is pushed to: upstream itself in own mode, the fork in upstream mode), mirror_error (an
#   enrolment the scanner could not read: a guard remote with no URL — shown on the card, never guessed around).
# gh_pr_states: the web (no GitHub token) writes which PRs' state it wants (repo + ref "pr:N" | "head:owner:branch");
#   the github service answers them every GITHUB_CI_INTERVAL_SECONDS (same split as gh_pr_checks).
ROM::SQL.migration do
  up do
    alter_table(:projects) do
      add_column :mirror_mode, String
      add_column :mirror_repo, String
      add_column :public_repo, String
      add_column :public_head, String
      add_column :mirror_error, String, text: true
    end
    create_table :gh_pr_states do
      primary_key :id
      String :repo, null: false           # owner/name
      String :ref, null: false            # "pr:5" | "head:owner:branch"
      Integer :requested_at, null: false
      Integer :checked_at
      Integer :number                     # the PR's number once known
      String :url                         # its html_url
      String :state                       # open | draft | merged | closed | none (no PR for that head)
      String :error, text: true           # why the last poll failed
      unique %i[repo ref]
    end
  end

  down do
    drop_table :gh_pr_states
    alter_table(:projects) do
      %i[mirror_mode mirror_repo public_repo public_head mirror_error].each { |c| drop_column c }
    end
  end
end
