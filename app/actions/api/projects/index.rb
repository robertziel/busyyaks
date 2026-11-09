# frozen_string_literal: true

module Busyyaks
  module Actions
    module API
      module Projects
        # GET /api/projects — every tracked repo as a folder tree, the configured roots, launch state, clone jobs.
        class Index < Busyyaks::APIAction
          def handle(_req, res)
            state = launch_state
            projects = store.projects
            jobs = state[:launcher_error] ? [] : LauncherClient.jobs
            json(res, {
                   tree: Busyyaks::API.tree(Busyyaks::Tree.build(projects), state[:sessions]),
                   total: projects.size,
                   roots: Config.load.roots,
                   jobs: jobs.map do |j|
                     { url: j["url"], path: j["path"], status: j["status"], exit: j["exit"], tail: Array(j["tail"]).last }
                   end,
                   **launch_json(state),
                 })
          end
        end
      end
    end
  end
end
