# frozen_string_literal: true

module Busyyaks
  module Actions
    module Commits
      # GET /commit/:sha — to the commit on GitHub when the repo's origin is there (works from any link, no JS);
      # otherwise the SPA shell, whose Commit view shows the detail from /api/commits/:sha.
      class Show < Spa::Show
        def handle(req, res)
          sha = req.params[:sha].to_s
          commit = sha.match?(/\A[0-9a-f]{7,40}\z/) && store.find_commit(sha)
          if commit
            project = store.project(commit[:project_slug])
            url = Github.commit_url(project && project[:remote], commit[:sha])
            return res.redirect_to(url) if url
          end
          super
        end
      end
    end
  end
end
