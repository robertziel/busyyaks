# frozen_string_literal: true

module Busyyaks
  module Actions
    module API
      module Agents
        # GET /api/agents/reap — agent sessions that are not working (what "Clear idle" would stop).
        class ReapPreview < Busyyaks::APIAction
          def handle(_req, res)
            r = LauncherClient.reap_preview
            by_path = store.projects.sort_by { |p| -p[:path].length }
            cands = r["candidates"].map do |c|
              pp = c["project_path"]
              proj = pp && by_path.find { |p| pp == p[:path] || pp.start_with?("#{p[:path]}/") }
              owned = Hanami.app["db.gateway"].connection[:cards]
                            .where(owner_session: c["name"], archived_at: nil)
                            .select(:id, :title, :project_slug).all
              cards = owned.map { |o| { id: o[:id], title: o[:title], project: o[:project_slug] } }
              c.merge("project" => proj && proj[:slug], "cards" => cards)
            end
            json(res, { quiet_min: r["quiet_min"], candidates: cands })
          end
        end
      end
    end
  end
end
