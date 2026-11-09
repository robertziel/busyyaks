# frozen_string_literal: true

module Busyyaks
  # Web URLs for repos whose origin is on github.com. Any other host gets no link (nil), not a guess.
  module Github
    module_function

    def repo_url(remote)
      m = remote.to_s.match(%r{\A(?:git@github\.com:|https://github\.com/|ssh://git@github\.com/)([\w.-]+)/([\w.-]+?)(?:\.git)?/?\z})
      m && "https://github.com/#{m[1]}/#{m[2]}"
    end

    # The project as the card links see it: its repo is the one the work is pushed to (`pr_remote`, the
    # branch's push remote), so branches, files, commits and PR #N open where they exist — not origin.
    def work_project(project) = project && project.merge(remote: project[:pr_remote])

    def commit_url(remote, sha)
      base = repo_url(remote)
      base && "#{base}/commit/#{sha}"
    end
  end
end
