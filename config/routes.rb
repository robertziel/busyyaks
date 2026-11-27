# frozen_string_literal: true

require_relative "../lib/busyyaks/terminal_endpoint"
require_relative "../lib/busyyaks/host_guard"
require_relative "../lib/busyyaks/config"
require_relative "../lib/busyyaks/github_hook"
require_relative "../lib/busyyaks/ci_checks"
require_relative "../lib/busyyaks/kanban"

module Busyyaks
  class Routes < Hanami::Routes
    get "/up", to: "health.show"
    get "/manifest.webmanifest", to: "manifest.show"   # the SPA installable as a desktop app

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
    get "/api/projects/*slug/board/live", to: "api.board.live" # the working glow: what its agent sessions do
    get "/api/projects/*slug/board/presence", to: "api.board.presence" # who works on each card now: the faces
    get "/api/projects/*slug/board", to: "api.board.show"      # kanban JSON API (docs/API-kanban.md)
    post "/api/projects/*slug/board", to: "api.board.create"
    post "/api/projects/*slug/labels", to: "api.labels.create"
    # the project's workflow: <repo>/.busyyaks/workflow.yml, applied to the engine's boards tables by the writer
    # service; the editor's Save / Reset go through the writer (card #429)
    get "/api/projects/*slug/workflow-file", to: "api.workflow_file.show"
    get "/api/projects/*slug/workflow", to: "api.workflow.show"
    post "/api/projects/*slug/workflow", to: "api.workflow.save"
    delete "/api/projects/*slug/workflow", to: "api.workflow.reset"
    get "/api/projects/*slug/agent-rules", to: "api.project_agent_rules.show" # the project's Settings tab: rules per agent type
    post "/api/projects/*slug/agent-rules", to: "api.project_agent_rules.save"
    get "/api/projects/*slug/agents", to: "api.project_agents.show" # the Settings tab: the repo's .busyyaks/agents.yml
    post "/api/projects/*slug/agents", to: "api.project_agents.save"
    get "/api/projects/*slug/sessions", to: "api.projects.sessions" # the page polls it (card 614)
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
    # an agent session's live terminal, a WebSocket (its checks: lib/busyyaks/terminal_endpoint.rb)
    get Busyyaks::TerminalEndpoint::PATH, to: Busyyaks::TerminalEndpoint.new(
      # per request: the Hosts HostGuard answers under the provider of now (Auth.use swaps it in tests)
      origins: -> { Busyyaks::HostGuard.origins(ENV, provider: Busyyaks::Auth.provider) },
      settings: Busyyaks::Config.load.terminal, public_host: ENV.fetch("PUBLIC_HOST")
    )
    # GitHub webhooks wake the PR / CI pollers (card #472): only when config/busyyaks.yml github_hook is on (else no
    # route: 404); the HMAC signature is its only auth (no session, no CSRF), HostGuard still in front
    hook = Busyyaks::Config.load.github_hook
    if hook
      post Busyyaks::GithubHook::PATH, to: Busyyaks::GithubHook::Endpoint.new(
        secret: Busyyaks::GithubHook.boot!(hook, ENV), settings: hook,
        wanted_for: -> { Busyyaks::Kanban.ci_window } # Settings → Runtime github_ci_interval_seconds, per delivery
      )
    end
    get "/api/boards", to: "api.board.index"
    get "/api/waiting/rev", to: "api.waiting.rev"                # the "waiting for you" widget: poll, refetch on change
    get "/api/waiting", to: "api.waiting.index"
    get "/api/session-boards", to: "api.session_boards.index"   # every agent session's own board, read-only
    get "/api/cards/:id/rev", to: "api.cards.rev"
    get "/api/cards/:id/live", to: "api.cards.live"   # the card dialog's live agent line: poll
    get "/api/cards/:id/terminals", to: "api.cards.terminals"   # the card's agent sessions, for its Terminals section
    get "/api/cards/:id", to: "api.cards.show"
    post "/api/cards/:id", to: "api.cards.update"
    patch "/api/cards/:id", to: "api.cards.update"
    post "/api/cards/:id/move", to: "api.cards.move"
    post "/api/cards/:id/comment", to: "api.cards.comment"
    post "/api/cards/:id/assign", to: "api.cards.assign"
    post "/api/cards/:id/archive", to: "api.cards.archive"
    post "/api/cards/:id/hold", to: "api.cards.hold"   # operator: put on hold / release
    post "/api/cards/:id/owner", to: "api.cards.owner"
    post "/api/cards/:id/dialog-answer", to: "api.cards.dialog_answer"   # operator only: press a session dialog option
    post "/api/cards/:id/approve", to: "api.cards.approve"
    post "/api/cards/:id/pr-unassign", to: "api.cards.pr_unassign"   # operator: take one PR off the card
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
    get "/api/settings/agent-rules", to: "api.agent_rules.show"   # Settings → Agent rules: busyyaks's own skills layers
    post "/api/settings/agent-rules", to: "api.agent_rules.save"
    get "/api/settings/daily-report", to: "api.daily_report_settings.show"   # Settings → Daily report
    post "/api/settings/daily-report", to: "api.daily_report_settings.save"
    get "/api/settings/runtime", to: "api.runtime_settings.show"   # Settings → Runtime: the services' timing
    post "/api/settings/runtime", to: "api.runtime_settings.save"
    get "/api/settings/dictation", to: "api.dictation_settings.show"   # Settings → Dictation: what the mic runs (card 634)
    post "/api/settings/dictation", to: "api.dictation_settings.save"
    post "/api/settings/dictation/test", to: "api.dictation_settings.test"
    post "/api/settings/dictation/models", to: "api.dictation_settings.models"
    get "/api/settings/git-hosts", to: "api.git_hosts.show"         # Settings → Git hosts: GitHub / GitLab
    post "/api/settings/git-hosts", to: "api.git_hosts.connect"
    delete "/api/settings/git-hosts", to: "api.git_hosts.disconnect"
    post "/api/settings/git-hosts/test", to: "api.git_hosts.test"   # Test connection: the stored token, asked again
    get "/api/settings/update", to: "api.update_settings.show"     # Settings → Updates: this checkout's updates (card 536)
    post "/api/settings/update", to: "api.update_settings.save"
    get "/api/setup", to: "api.setup.show"                      # the first-run hello screen (/hello)
    get "/api/setup/harnesses", to: "api.setup.harnesses"     # the agent CLIs on the host
    post "/api/setup/complete", to: "api.setup.complete"
    get "/api/setup/browse", to: "api.setup.browse"            # the projects dir picker: a host dir's subdirs (card 532)
    get "/api/setup/projects-root", to: "api.setup.projects_root"
    post "/api/setup/projects-root", to: "api.setup.projects_root_change"
    post "/api/dictation", to: "api.dictation.transcribe"     # the card dialog's mic → the speech server
    post "/api/markdown", to: "api.markdown.preview"           # editor Preview: the server's render, never a JS markdown lib

    # the SPA shell: every other signed-in GET (the client router owns the path)
    get "/commit/:sha", to: "commits.show"   # → GitHub when the origin is there, else the shell
    root to: "spa.show"
    get "/*path", to: "spa.show"
  end
end
