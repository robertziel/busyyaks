# frozen_string_literal: true

module Busyyaks
  # Coding-agent sessions (agent_engines collector snapshot, via bin/launcher) shaped for the sidebar:
  # grouped by the tracked project their pane's cwd is in, working sessions first.
  module Agents
    # herdr's states + the board's, worst first: blocked = the job is stopped until a person acts (a dialog /
    # permission prompt on its screen, the collector's waiting_for, a card of its in the board's ask column) · review = a
    # card of its waits in the handoff column (its PR to review) · working · finished = idle and every card it owns (≥ 1)
    # sits in its board's done column (the cards say so, never the screen) · idle · unknown = no source can
    # tell. Each source is a reading of its own; the state is the worst any of them reports, `state_by` names which one.
    # `unread` is not a state: its turn ended after the operator last opened the row (was "done": it said
    # nothing about the work being done).
    STATES = %w[blocked review working finished idle unknown].freeze

    Session = Struct.new(:name, :socket, :attached, :activity, :panes, :project, :cwd, :claude_url, :asks, :reviews, :cards,
                         :seen_at, keyword_init: true) do
      def key = "#{socket}/#{name}"
      def screens = panes.map { |p| p["screen"] || {} }
      def dialogs = screens.filter_map { |sc| sc["dialog"] }
      def screen_rule(state) = screens.find { |sc| sc["state"] == state }&.dig("rule")
      def waiting_for = panes.filter_map { |p| p["waiting_for"]&.to_s&.[](0, 160) }
      def subagents = panes.sum { |p| p["subagents_running"].to_i }
      def subagents_known? = panes.any? { |p| !p["subagents_running"].nil? }
      def screen_errors = screens.filter_map { |sc| sc["error"] }

      def blocked? = !blocker_source.nil?
      def blocker_source
        return "screen: #{screen_rule('blocked')}" if screen_rule("blocked")
        return "collector: waiting_for" if waiting_for.any?

        "card ##{asks.first[:id]}" if asks.any?
      end

      def busy? = !working_source.nil?
      def working_source
        return "screen: #{screen_rule('working')}" if screen_rule("working")
        return "collector: busy" if panes.any? { |p| p["status"] == "busy" }

        "subagents running" if subagents.positive?
      end

      def idle_source
        return "screen: #{screen_rule('idle')}" if screen_rule("idle")

        "collector: idle" if panes.any? { |p| p["status"] == "idle" }
      end

      # when the turn ended: the collector's status change time of an idle pane (nil = not known → never unread)
      def turn_ended_at = panes.select { |p| p["status"] == "idle" }.filter_map { |p| p["status_at"]&.to_f }.max
      def unread? = !attached && !seen_at.nil? && !turn_ended_at.nil? && turn_ended_at > seen_at

      # the cards it came to own since it registered (Store#owned_cards); nil = no open registration → its cards are
      # unknown, never finished. open = not in a done column (a column the board no longer has counts as open: unknown ≠ done)
      def cards_known? = !cards.nil?
      def open_cards = Array(cards).reject { |c| c[:finishes] == true }
      def finished_cards = Array(cards).select { |c| c[:finishes] == true }
      def finished? = cards_known? && cards.any? && open_cards.empty?

      def state
        return "blocked" if blocked?
        return "review" if reviews.any?
        return "working" if busy?
        return "unknown" unless idle_source

        finished? ? "finished" : "idle"
      end

      def finished_source = "cards: #{finished_cards.size} in #{finished_cards.map { |c| c[:column_label] }.uniq.join(' · ')}"

      def state_by
        blocker_source || (reviews.any? ? "card ##{reviews.first[:id]} in review" : nil) || working_source ||
          (state == "finished" ? finished_source : idle_source)
      end
      def pane = panes.first
      # the label bin/launcher gave the pane from config/busyyaks.yml engines; a pane without one runs an
      # engine that is not configured — said so, its screen error names the fix
      def engines = panes.map { |p| p["engine_label"] || "#{p['engine']} (not configured)" }.uniq
      def title = panes.map { |p| p["title"] }.compact.first
      def model = panes.map { |p| p["model"] }.compact.first
    end

    module_function

    # snap: the launcher's `agents` answer; projects: store.projects; asks: {session name => [cards of it in an ask
    # column]}; reviews: {session name => [cards of it in a handoff column]}; cards: {session name => [every live card it
    # came to own since its open registration — keyed [name, socket], Store#owned_cards; absent = unknown]}; seen: {key =>
    # when the operator last saw it}. → [[group_label, slug|nil, [Session]]]
    def groups(snap, projects, asks: {}, reviews: {}, cards: {}, seen: {})
      by_path = projects.sort_by { |p| -p[:path].length }
      sessions = snap.fetch("sessions").map do |s|
        pane = s["panes"].first || {}
        pp = pane["project_path"]
        proj = pp && by_path.find { |p| pp == p[:path] || pp.start_with?("#{p[:path]}/") }
        Session.new(name: s["name"], socket: s["socket"], attached: s["attached"].to_i.positive?, activity: s["activity"].to_i,
                    panes: s["panes"], project: proj && proj[:slug], cwd: pane["cwd"], claude_url: s["claude_url"],
                    asks: asks.fetch(s["name"], []), reviews: reviews.fetch(s["name"], []),
                    cards: cards[[s["name"], s["socket"]]]&.fetch(:cards), seen_at: seen["#{s['socket']}/#{s['name']}"])
      end
      sessions.group_by { |s| s.project || "other" }.map do |key, ss|
        ss = ss.sort_by { |s| [rank(s), -s.activity] }
        [key == "other" ? "outside tracked repos" : key, key == "other" ? nil : key, ss]
      end.sort_by { |_, slug, ss| [ss.map { |s| rank(s) }.min, slug.nil? ? 1 : 0, -ss.map(&:activity).max] }
    end

    def rank(s) = STATES.index(s.state)

    # The collector's tasks answer (Claude or Hermes shape) → uniform rows.
    def team(res)
      agents = Array(res["agents"]).map do |a|
        { label: a["description"] || a["title"] || a["id"], type: a["agentType"] || a["subagent_type"] || a["type"],
          state: a["state"] || (a["active"] ? "running" : "done"), mtime: a["mtime"], model: a["model"], }
      end.sort_by { |a| [a[:state] == "running" ? 0 : 1, -a[:mtime].to_f] }
      workflows = Array(res["workflows"]).map do |w|
        { label: w["name"] || w["id"], state: w["status"], agents: w["agents_n"], summary: w["summary"], started: w["started"] }
      end
      tasks = Array(res["tasks"]).map do |t|
        { label: t["description"] || t["command"] || t["id"], state: t["status"], mtime: t["mtime"] }
      end
      { agents: agents, workflows: workflows, tasks: tasks }
    end
  end
end
