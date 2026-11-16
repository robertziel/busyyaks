# frozen_string_literal: true

# gh_pollers: one row per batch of the github service's PR pollers (CiChecks + PrStates, one token, one loop):
# what the last tick cost (calls, 304s), the token's rate limit after it, and — when GitHub said the limit is used up —
# `paused_until` (x-ratelimit-reset / retry-after) with the reason. While paused the pollers send nothing and every
# wanted row says why; /github shows the row. down: the table goes (nothing else reads it).
ROM::SQL.migration do
  up do
    create_table(:gh_pollers) do
      String :name, primary_key: true
      Integer :ran_at, null: false
      Integer :calls, null: false
      Integer :not_modified, null: false
      Integer :rate_limit
      Integer :rate_remaining
      Integer :rate_reset
      Integer :paused_until
      String :error, text: true
    end
  end

  down do
    drop_table(:gh_pollers)
  end
end
