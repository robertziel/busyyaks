# frozen_string_literal: true

require_relative "git_read"
require_relative "launcher_client"

module Busyyaks
  # The idle watch's view of an owner session's checkout (CiChecks::Port's `launcher:`): which branch it is on and
  # when its last commit was. The host launcher only says WHERE the session works (its `git` op: the pane's dir,
  # relative to PROJECTS_ROOT) and runs no git; the read is a GitRead child here, in the container, on the listed
  # project that holds that dir — never a path the launcher or the session chose outside the scanner's list.
  module SessionGit
    Unavailable = AgentsKanban::Delivery::Unavailable

    module_function

    # → {"ok" => true, "branch" => …, "last_commit_at" => epoch | nil}; Unavailable with the reason otherwise.
    def git(session:, socket:, store: Store.default, launcher: LauncherClient)
      rel = launcher.git(session: session, socket: socket)["path"].to_s
      raise Unavailable, "the launcher named no dir for #{session}" if rel.empty? || rel.split("/").include?("..")

      dir = rel == "." ? GitRead.mount : File.join(GitRead.mount, rel)
      project = store.project_at(dir) or raise Unavailable, "#{session} works in #{dir}, which is no listed project"
      head = GitRead.call("head", path: project[:path], root: GitRead.mount)
      { "ok" => true, "branch" => head["branch"], "last_commit_at" => head["last_commit_at"] }
    rescue GitRead::Failed => e
      raise Unavailable, e.message
    end
  end
end
