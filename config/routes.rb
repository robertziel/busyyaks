# frozen_string_literal: true

module Busyyaks
  class Routes < Hanami::Routes
    get "/up", to: "health.show"

    # sign-in: the auth provider's page, its own endpoints under /auth/ (config/busyyaks.yml `auth`)
    get "/login", to: "sessions.new"
    get "/auth/*path", to: "sessions.provider"
    post "/auth/*path", to: "sessions.provider"
    post "/logout", to: "sessions.destroy"

    # JSON API for the SPA (session cookie, the auth provider asked every request; mutations carry X-CSRF-Token)
    get "/api/today/rev", to: "api.today_rev"   # the home page: poll, re-read /api/today on change
    get "/api/today", to: "api.today"
    get "/api/search", to: "api.search"
    get "/api/icons/*slug", to: "api.icons"
    get "/api/projects", to: "api.projects.index"
    get "/api/projects/*slug/board/rev", to: "api.board.rev"   # live updates: poll, refetch on change
    get "/api/projects/*slug/board", to: "api.board.show"      # kanban JSON API (docs/API-kanban.md)
    post "/api/projects/*slug/board", to: "api.board.create"
    post "/api/projects/*slug/labels", to: "api.labels.create"
    # the project's workflow (DB), the operator edits it
    get "/api/projects/*slug/workflow", to: "api.workflow.show"
    post "/api/projects/*slug/workflow", to: "api.workflow.save"
    delete "/api/projects/*slug/workflow", to: "api.workflow.reset"
    post "/api/projects/*slug/stop", to: "api.projects.stop"   # operator: Stop / Stop all of a project's tmux sessions
    get "/api/projects/*slug", to: "api.projects.show"          # slugs of nested roots carry a "/" (acme/x)
    post "/api/notes", to: "api.projects.note"
    post "/api/launch", to: "api.projects.launch"
    post "/api/create", to: "api.projects.create"
    get "/api/reports", to: "api.reports.index"
    get "/api/reports/components", to: "api.reports.components"
    get "/api/reports/:id", to: "api.reports.show"
    get "/api/commits/:sha", to: "api.commits.show"
    get "/api/github", to: "api.github.show"                     # GitHub network feed (lib/busyyaks/github_network.rb)
    get "/api/agents", to: "api.agents.index"
    get "/api/agents/team", to: "api.agents.team"
    get "/api/agents/reap", to: "api.agents.reap_preview"
    post "/api/agents/reap", to: "api.agents.reap"
    post "/api/agents/seen", to: "api.agents.seen"
    post "/api/agents/answer", to: "api.agents.answer"     # operator only: press a dialog option on a session's screen
    get "/api/boards", to: "api.board.index"
    get "/api/waiting/rev", to: "api.waiting.rev"                # the "waiting for you" widget: poll, refetch on change
    get "/api/waiting", to: "api.waiting.index"
    get "/api/cards/:id/rev", to: "api.cards.rev"
    get "/api/cards/:id", to: "api.cards.show"
    post "/api/cards/:id", to: "api.cards.update"
    patch "/api/cards/:id", to: "api.cards.update"
    post "/api/cards/:id/move", to: "api.cards.move"
    post "/api/cards/:id/comment", to: "api.cards.comment"
    post "/api/cards/:id/assign", to: "api.cards.assign"
    post "/api/cards/:id/archive", to: "api.cards.archive"
    post "/api/cards/:id/owner", to: "api.cards.owner"
    post "/api/cards/:id/dialog-answer", to: "api.cards.dialog_answer"   # operator only: press a session dialog option
    post "/api/cards/:id/approve", to: "api.cards.approve"
    post "/api/cards/:id/checklists", to: "api.cards.checklist"
    post "/api/cards/:id/attachments", to: "api.cards.attach"   # multipart: file, comment_id?
    get "/api/attachments/:id/download", to: "api.attachments.download"
    get "/api/attachments/:id", to: "api.attachments.show"
    delete "/api/attachments/:id", to: "api.attachments.destroy"
    post "/api/comments/:id", to: "api.comments.update"
    patch "/api/comments/:id", to: "api.comments.update"
    delete "/api/comments/:id", to: "api.comments.destroy"
    post "/api/checklists/:id", to: "api.checklists.update"
    patch "/api/checklists/:id", to: "api.checklists.update"
    delete "/api/checklists/:id", to: "api.checklists.destroy"
    post "/api/checklists/:id/items", to: "api.checklists.item"
    post "/api/checklist-items/:id", to: "api.checklist_items.update"
    patch "/api/checklist-items/:id", to: "api.checklist_items.update"
    delete "/api/checklist-items/:id", to: "api.checklist_items.destroy"
    post "/api/checklist-items/:id/convert", to: "api.checklist_items.convert"
    post "/api/labels/:id", to: "api.labels.update"
    patch "/api/labels/:id", to: "api.labels.update"
    delete "/api/labels/:id", to: "api.labels.destroy"
    get "/api/settings/agents", to: "api.agent_settings.show"   # Settings → Agents & launchers
    post "/api/settings/agents", to: "api.agent_settings.save"
    get "/api/settings/daily-report", to: "api.daily_report_settings.show"   # Settings → Daily report
    post "/api/settings/daily-report", to: "api.daily_report_settings.save"
    get "/api/setup", to: "api.setup.show"                      # the first-run hello screen (/hello)
    post "/api/setup/complete", to: "api.setup.complete"
    post "/api/markdown", to: "api.markdown.preview"           # editor Preview: the server's render, never a JS markdown lib

    # the SPA shell: every other signed-in GET (the client router owns the path)
    get "/commit/:sha", to: "commits.show"   # → GitHub when the origin is there, else the shell
    root to: "spa.show"
    get "/*path", to: "spa.show"
  end
end
