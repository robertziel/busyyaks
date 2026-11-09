# frozen_string_literal: true

module Busyyaks
  module Actions
    module API
      module Projects
        # GET /api/projects/*slug — one repo: state, live tmux sessions, year graph counts, commits, notes.
        class Show < Busyyaks::APIAction
          def handle(req, res)
            project = store.project(req.params[:slug].to_s)
            error!(res, 404, "no project #{req.params[:slug]}") unless project

            state = launch_state
            json(res, {
                   project: Busyyaks::API.project(project, state[:sessions]),
                   year: store.daily(slug: project[:slug]),
                   commits: store.commits(slug: project[:slug], limit: 200)
                                 .map { |c| Busyyaks::API.commit(c, project[:remote]) },
                   notes: store.notes(project_slug: project[:slug]).map { |n| Busyyaks::API.note(n) },
                   **launch_json(state),
                 })
          end
        end
      end
    end
  end
end
