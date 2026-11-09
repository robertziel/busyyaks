# frozen_string_literal: true

module Busyyaks
  module Actions
    module API
      module Agents
        # POST /api/agents/reap {sessions: [{name, socket}]} — stop the confirmed sessions; the host re-checks each.
        class Reap < Busyyaks::APIAction
          def handle(req, res)
            list = Array(req.params[:sessions]).map { |s| s.to_h.transform_keys(&:to_s).slice("name", "socket") }
            error!(res, 400, "sessions: pick at least one") if list.empty? || list.any? { |s| s["name"].to_s.empty? }

            json(res, { results: LauncherClient.reap(list)["results"] })
          end
        end
      end
    end
  end
end
