# frozen_string_literal: true

# daily_report_settings: config/busyyaks.yml `daily_report` as revisions — the newest row is the current
# one (Busyyaks::DailyReportSettings), edited on Settings → Daily report. Nothing is seeded: a gateway and a runner are
# this deployment's, there is no repo default; no row = no daily report configured (bin/daily-report posts NOT
# CONFIGURED). A deployment that had the YAML block imports it with bin/daily-report-settings import. down: the table
# goes, and with it every revision — put the block back into config/busyyaks.yml first (Settings shows the current one).
ROM::SQL.migration do
  up do
    create_table(:daily_report_settings) do
      primary_key :id
      String :doc, text: true, null: false # JSON, the daily_report mapping
      String :author, null: false
      Integer :created_at, null: false
    end
  end

  down do
    drop_table(:daily_report_settings)
  end
end
