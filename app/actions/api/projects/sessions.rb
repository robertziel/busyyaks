# frozen_string_literal: true

module Busyyaks
  module Actions
    module API
      module Projects
        # GET /api/projects/*slug/sessions — the project's live tmux sessions + the launches (types, who runs against the
        # caps) + launcher_error: the project page polls it (card 614), so a session started or ended anywhere else (the
        # lead's spawn, another tab, by hand) enters and leaves the session lanes without a reload. One launcher
        # `sessions` op; none of the page's commits / notes / year graph.
        class Sessions < Busyyaks::APIAction
          def handle(req, res)
            project = store.project(req.params[:slug].to_s)
            error!(res, 404, "no project #{req.params[:slug]}") unless project

            state = launch_state
            json(res, { sessions: Busyyaks::API.project(project, state[:sessions])[:sessions], **launch_json(state) })
          end
        end
      end
    end
  end
end
