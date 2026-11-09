# frozen_string_literal: true

module Busyyaks
  module Actions
    module API
      module Projects
        # POST /api/projects/*slug/stop {sessions: [names]} — the operator's Stop / Stop all: bin/launcher kills those tmux
        # sessions, refusing any that is not in this project's directory or is reap_protect'ed (each result says why).
        # A stopped session's board registration ends at once, so it frees its cap slot now; its cards are released by the
        # watchdog's own rule (owner gone), not here.
        class Stop < Busyyaks::APIAction
          def handle(req, res)
            project = store.project(req.params[:slug].to_s)
            error!(res, 404, "no project #{req.params[:slug]}") unless project
            names = Array(req.params[:sessions]).map(&:to_s).reject(&:empty?).uniq
            error!(res, 400, "sessions: give at least one session name") if names.empty?

            results = LauncherClient.stop(path: project[:path], sessions: names)["results"]
            kanban = Kanban.default
            results.each do |r|
              next unless r["stopped"] && kanban.open_session(r["name"])

              kanban.end_session(r["name"], reason: "stopped by the operator", by: req.session[:email].to_s)
              r["registration"] = "ended"
            end
            json(res, { results: results })
          end
        end
      end
    end
  end
end
