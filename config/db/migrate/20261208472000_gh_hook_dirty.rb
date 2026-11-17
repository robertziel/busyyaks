# frozen_string_literal: true

# gh_pr_states.dirty / gh_pr_checks.dirty (card #472): a GitHub webhook (POST /api/github/hook, Busyyaks::GithubHook)
# names the rows it changed by bumping this counter; the github service polls the wanted dirty rows at once instead of
# at its next GITHUB_CI_INTERVAL_SECONDS tick, then clears the mark it read (unless a newer hook bumped it again).
# NULL = clean. The poll's answer stays the only state: a hook never writes one.
ROM::SQL.migration do
  up do
    %i[gh_pr_states gh_pr_checks].each { |t| alter_table(t) { add_column :dirty, Integer } }
  end

  down do
    %i[gh_pr_states gh_pr_checks].each { |t| alter_table(t) { drop_column :dirty } }
  end
end
