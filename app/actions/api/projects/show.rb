# frozen_string_literal: true

module Busyyaks
  module Actions
    module API
      module Projects
        # GET /api/projects/*slug — one repo: state, year graph counts, commits, notes. Its live tmux sessions + the
        # launches are GET /api/projects/*slug/sessions, which the page polls (card 614): not here, so a page load asks
        # the launcher once and no read carries a session list that is never refreshed.
        class Show < Busyyaks::APIAction
          def handle(req, res)
            project = store.project(req.params[:slug].to_s)
            error!(res, 404, "no project #{req.params[:slug]}") unless project

            json(res, {
                   project: Busyyaks::API.project(project).except(:sessions),
                   year: store.daily(slug: project[:slug]),
                   commits: store.commits(slug: project[:slug], limit: 200)
                                 .map { |c| Busyyaks::API.commit(c, project[:remote]) },
                   notes: store.notes(project_slug: project[:slug]).map { |n| Busyyaks::API.note(n) },
                 })
          end
        end
      end
    end
  end
end
