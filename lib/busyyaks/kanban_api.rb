# frozen_string_literal: true

require "json"
require_relative "kanban"
require_relative "agents"
require_relative "api"
require_relative "github"
require_relative "pr_states"
require_relative "auth"

module Busyyaks
  # Mixed into the /api kanban actions (app/actions/api): the Hanami side of the vendored engine's operator API
  # (AgentsKanban::Api → [status, body]). Session-cookie auth like every page, a JSON 401 instead of a redirect;
  # mutations need X-CSRF-Token. Bodies: JSON or form-encoded. See docs/API-kanban.md. The web user is the operator.
  #
  # What busyyaks adds to the engine's answers (its ports): the links a card names in its repo (CardLinks over the
  # projects table + git), the owner-session candidates and live sessions (the launcher), assignee suggestions.
  module KanbanAPI
    private

    def kanban = Kanban.default

    # Per request: the engine's Api over this request's store; the extras close over the signed-in operator
    # (Hanami freezes action instances, so nothing is kept in an ivar).
    def api(req)
      email = req.session[:email]
      store = Kanban.default
      Kanban.api(store, card_extras: ->(c, b) { card_extras(c, b) }, board_extras: ->(p) { board_extras(p, email) })
    end

    # The card's links. The checkout's branches / files come from the scanner's last read and a GitRead child
    # (Kanban.git_port, no git in this process); a repo it cannot read gets the links that need no checkout plus a
    # row saying why (and the PR flags then look for no branch of it) — never a guessed branch or file. A repo whose
    # last scan failed keeps its last read, with the same row. → [links, the row the PR flags read]
    def checkout_links(card, comments, project, row)
      commits = ->(shas) { store.commits_by_sha(shas) }
      links = AgentsKanban::CardLinks.build(card, comments, project, commits: commits, git: Kanban.git_port)
      links += [GitPort.warning(row, "last scan: #{row[:git_error]}")] if row && row[:git_error]
      [links, row]
    rescue GitPort::Unavailable => e
      links = AgentsKanban::CardLinks.build(card, comments, project.merge(path: nil), commits: commits, git: Kanban.git_port)
      [links + [GitPort.warning(row, e.message)], row.merge(path: nil)]
    end

    # Links (repo, branches, sites, commits, the handoff PR / CI) and #N chips resolved against this card, plus the
    # launcher's live sessions for the owner picker.
    def card_extras(card, body)
      comments = body[:activity].select { |a| a[:kind] == "comment" }.map { |a| a[:body] }
      row = store.project(card[:project_slug])
      project = Github.work_project(row)
      links, row = checkout_links(card, comments, project, row)
      refs = AgentsKanban::CardLinks::Refs.new(repo: project && Github.repo_url(project[:remote]), pr_url: card[:pr_url],
                                               slug: card[:project_slug],
                                               activity_ids: body[:activity].map { |a| a[:id] }.to_set,
                                               card_slugs: ->(ids) { kanban.card_slugs(ids) },
                                               card_path: ->(slug, id) { Busyyaks::API.card_path(slug, id) })
      linkify = ->(html) { AgentsKanban::CardLinks.linkify(html, links, refs: refs) }
      out = { links: Kanban.pr_flags.apply(links, card, row) } # local · public, open · merged …
      if body[:card][:description_html]
        out[:card] = body[:card].merge(description_html: linkify.(body[:card][:description_html]))
      end
      out[:activity] = body[:activity].map { |a| a[:body_html] ? a.merge(body_html: linkify.(a[:body_html])) : a }
      out.merge(owner_sessions(project))
    end

    def board_extras(project, email) = assignee_suggestions(project, email).merge(owner_sessions(project))

    def require_login(req, res)
      return if Auth.identify(res.session)

      halt_json(res, 401, "not signed in")
    end

    def handle_invalid_csrf_token(_req, res) = halt_json(res, 403, "invalid or missing X-CSRF-Token")

    def halt_json(res, status, msg)
      res.headers["Content-Type"] = "application/json"
      halt status, JSON.generate(error: msg)
    end

    def json(res, body, status: 200)
      res.status = status
      res.headers["Content-Type"] = "application/json"
      res.body = JSON.generate(body)
    end

    # One engine call → the JSON answer with its status.
    def answer(res, (status, body)) = json(res, body, status: status)

    # JSON body (Content-Type application/json) or the form params, as a string-keyed Hash. A malformed body raises
    # Invalid, which `refusing` answers as 422.
    def body(req)
      unless req.content_type.to_s.include?("application/json")
        return req.params.raw.reject { |k, _| %w[_csrf_token id slug].include?(k) }
      end

      input = req.env["rack.input"]
      input.rewind if input.respond_to?(:rewind)
      raw = input.read.to_s
      parsed = raw.empty? ? {} : JSON.parse(raw)
      raise AgentsKanban::Invalid, "body must be a JSON object" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError => e
      raise AgentsKanban::Invalid, "invalid JSON: #{e.message}"
    end

    # The engine never raises for a client's input; the body parser above may. Wrap each action.
    def refusing(res)
      yield
    rescue AgentsKanban::Invalid => e
      json(res, { error: e.message }, status: 422)
    end

    def slug(req) = req.params[:slug].to_s
    def id(req) = req.params[:id].to_s

    # Live agent sessions (for "owner gone" on card faces) and this project's own (the owner picker). The
    # launcher being down is said (sessions_error), never read as "every owner is gone".
    def owner_sessions(project)
      snap = LauncherClient.agents
      groups = Busyyaks::Agents.groups(snap, store.projects)
      mine = groups.find { |_, s, _| project && s == project[:slug] }&.last || []
      # model: what the pane runs now (the collector's reading), nil when it does not report one — shown on the card,
      # never guessed
      models = groups.flat_map { |_, _, ss| ss }.to_h { |s| [s.name, s.model] }
      links = snap["sessions"].to_h do |s|
        link = { claude_url: s["claude_url"], ssh_attach: Busyyaks::API.ssh_attach(s["name"]),
                 terminal_url: Busyyaks::API.terminal_url(s["name"], s["socket"]), model: models[s["name"]], }
        [s["name"], link]
      end
      { live_sessions: snap["sessions"].map { |s| s["name"] },
        project_sessions: mine.map { |s| { name: s.name, socket: s.socket, state: s.state, engines: s.engines } },
        session_links: links, sessions_error: nil, }
    rescue LauncherClient::Unavailable, LauncherClient::Refused => e
      { live_sessions: nil, project_sessions: [], session_links: {}, sessions_error: e.message }
    end

    # Assignee / member candidates: the operator, this project's live tmux sessions, the configured agent types' labels,
    # and every agent / session name seen in the board's activity. The launcher being down is reported (launcher_error),
    # never papered over.
    def assignee_suggestions(project, email)
      launchers = Kanban.config.agent_types
      sessions = []
      error = nil
      begin
        sessions = LauncherClient.sessions.select { |s| s["project_path"] == project[:path] }.map { |s| s["name"] }
      rescue LauncherClient::Unavailable, LauncherClient::Refused => e
        error = e.message
      end
      { assignees: ([email].compact + sessions + launchers.map(&:label) + kanban.members(project[:slug])).uniq,
        launcher_error: error, }
    end
  end
end
