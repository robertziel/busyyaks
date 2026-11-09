# frozen_string_literal: true

module Busyyaks
  module Actions
    module API
      module Commits
        # GET /api/commits/:sha — the commit (any unique prefix ≥ 7) and its GitHub URL when the origin is there.
        class Show < Busyyaks::APIAction
          def handle(req, res)
            sha = req.params[:sha].to_s
            error!(res, 400, "sha must be 7–40 hex chars") unless sha.match?(/\A[0-9a-f]{7,40}\z/)
            commit = store.find_commit(sha)
            error!(res, 404, "no commit #{sha}") unless commit

            project = store.project(commit[:project_slug])
            json(res, { commit: Busyyaks::API.commit(commit, project && project[:remote]),
                        project: project && Busyyaks::API.project(project), })
          end
        end
      end
    end
  end
end
