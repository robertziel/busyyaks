# frozen_string_literal: true

# git_host_connections: which git host busyyaks reads, as revisions — once .env GITHUB_LOGIN (+ the token,
# GITHUB_TOKEN, which never comes here: it is a file only the github service mounts; Busyyaks::GitHosts). The newest
# row is the current one; provider null = disconnected. Nothing is seeded: a fresh install has no host connected, and
# a deployment that had the .env keys imports them once (bin/git-hosts import-env < .env, in the github container).
# down: the table goes, and with it the connection — put GITHUB_LOGIN / GITHUB_TOKEN back into .env and compose first.
ROM::SQL.migration do
  up do
    create_table(:git_host_connections) do
      primary_key :id
      String :provider # github · null = none connected
      String :login
      String :token_hint # "…abcd": the token's last four, to tell two tokens apart on the page
      String :author, null: false
      Integer :created_at, null: false
    end
  end

  down do
    drop_table(:git_host_connections)
  end
end
