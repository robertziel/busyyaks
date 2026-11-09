# frozen_string_literal: true

module Busyyaks
  module Actions
    module API
      module Agents
        # GET /api/agents — the sidebar's data, polled every 10 s: coding-agent sessions grouped by project, each in
        # herdr's states: its screen's verdict (host side), the collector's reading, the cards it FLAGGED (needs_operator:
        # a question; blocked_external: waiting for the world — the job is stopped either way) and handed over (a gate
        # column: work to check — only while its Approve would pass now; a held one waits for CI, card #248), every
        # card it owns (finished = all in a done column), and when the operator last saw it
        # (agent_seen; attached = seen now).
        # Launcher or snapshot down → 503 {error} (ApiAction); the sidebar shows that state.
        class Index < Busyyaks::APIAction
          def handle(_req, res)
            snap = LauncherClient.agents
            projects = store.projects
            kb = Busyyaks::Kanban.default
            w = kb.waiting_cards(projects.map { |p| p[:slug] })
            owned = lambda do |pick|
              w.by_slug
               .flat_map { |slug, cs| cs.select { |c| pick.call(c, w.boards[slug]) && c[:owner_session] } }
               .group_by { |c| c[:owner_session] }
            end
            asks = owned.(->(c, _b) { kb.flagged?(c) })                              # flagged: the job is stopped
            reviews = owned.(->(c, b) { !kb.flagged?(c) && b.gate?(c[:column]) })    # handed over: waits for the check
            keys = snap["sessions"].map { |s| "#{s['socket']}/#{s['name']}" }
            attached = snap["sessions"].select { |s| s["attached"].to_i.positive? }.map { |s| "#{s['socket']}/#{s['name']}" }
            seen = store.agent_seen(keys, attached: attached)
            # per open registration, the cards it came to own since: finished = all in a done column
            cards = kb.owned_cards(projects.map { |p| p[:slug] })
            # a gate card whose Approve would not pass now (card #248) is no review: it waits for CI — said on its row
            holds = w.held.values.flatten.to_h { |c| [c[:id], c[:gate_hold]] }
            cards.each_value { |reg| reg[:cards].each { |c| c[:gate_hold] = holds[c[:id]] } }
            groups = Busyyaks::Agents.groups(snap, projects, asks: asks, reviews: reviews, cards: cards, seen: seen)
            json(res, Busyyaks::API.agents(snap, groups, projects.to_h { |p| [p[:slug], Busyyaks::API.icon_url(p)] }))
          end
        end
      end
    end
  end
end
