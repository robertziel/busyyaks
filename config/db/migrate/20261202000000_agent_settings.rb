# frozen_string_literal: true

require "json"
require "yaml"

# agent_settings: the host config's launchers + agent types as revisions — the newest row is the current
# one (Busyyaks::AgentSettings), edited on Settings → Agents & launchers. The first revision is the repo default,
# config/agents.template.yml, read here as it is at migrate time (the template is plain data; a deployment that ran
# its own launchers imports them with bin/agent-settings import). down: the table goes, and with it every revision —
# put the launchers + agent_types back into config/kanban.yml first (Settings shows the current ones).
ROM::SQL.migration do
  up do
    create_table(:agent_settings) do
      primary_key :id
      String :doc, text: true, null: false # JSON {launchers, agent_types}
      String :author, null: false
      Integer :created_at, null: false
    end
    template = YAML.safe_load_file(File.expand_path("../../agents.template.yml", __dir__))
    self[:agent_settings].insert(doc: JSON.generate(template), author: "migration 20261202000000",
                                 created_at: Time.now.to_i)
  end

  down do
    drop_table(:agent_settings)
  end
end
