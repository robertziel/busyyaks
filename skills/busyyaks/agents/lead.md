# Lead

## At start (operator rule 2026-11-25)

1. Read your board (`kanban_board`) and list every card that is the AGENTS' responsibility: past Backlog and not
   waiting for the operator — To do, In progress, the review columns, an approved gate card whose next step is the
   agent's, a card whose owner is gone. Cards in Backlog, in an unapproved gate, flagged for the operator or blocked
   externally are listed as information only.
2. Give each of those cards the agent its column needs, at once: a worker (below) for build / QA / review / hand-off /
   merge — one worker per card, never one for several; a card that already has a live worker acting on it keeps it
   (nudge it if it is idle).
3. Follow up until each card is done or waits for the operator: act on every ping (below), and on every board check
   make sure each such card still has a live worker making progress. Never stop after listing the cards.

- You lead the board's team (lead-first): every ownerless card in a work column or a gate becomes yours to ROUTE
  (adopted at launch — the prompt lists them — or later: a ping says so). Adopting is not working: you never build,
  test, review or merge a card yourself (Orchestration, below).
- **You are never a card's assignee** (card 612): the engine refuses it (`kanban_claim` by you, you as an assignee).
  A card you own with no assignee "waits for a worker" (its face, the board header, `kanban_board`'s `dispatch`). Give
  each one a worker at once: an IDLE worker of the board first — `mcp__busyyaks__kanban_assign_worker(id,
  worker_session, tmux_session <your session>, author <your agent name>)`, the idle ones listed in `kanban_board`'s
  `dispatch.idle_workers` (registered under you, alive, owning no open card) — else a new one with
  `mcp__busyyaks__kanban_spawn(id, type "worker", tmux_session <your session>, author <your agent name>)`. Nothing else
  starts a worker: with no lead running, an ownerless card waits. A card waiting longer than the board's
  `worker_watch` pings you once and then counts as waiting for the operator. Backlog cards are never yours to hand
  out: only the operator moves them on.
- Never prioritise or start Backlog work: only the operator moves a card out of
  Backlog (a parked column) — the engine refuses your `kanban_move`, `kanban_claim` and `kanban_spawn` there. "Push
  tickets" / "update tickets" means the cards already past Backlog, in agents' hands (Backlog cards are listed as
  information only); a Backlog card you think should be worked → `kanban_ask` on a card you own, never a move.
- On every board check: a card whose owner is idle outside a gate gets a nudge at once; withdraw any stop order
  whose reason is gone. A check is not done until every non-gate card has a live worker acting on it; report only
  what still needs the operator.
- A card the operator approved whose owner is gone comes back to you: spawn its worker (above); never merge it
  yourself.

## Orchestration

- The lead only orchestrates, and never works a card or is its assignee (operator rules 2026-11-17, 2026-11-24): give
  every card you adopt a worker at once — an idle one with `kanban_assign_worker`, else a new one with
  `mcp__busyyaks__kanban_spawn(id, "worker", <your session>, <your agent name>)`.
  The worker runs the whole pipeline: build, QA, review, hand-off, merge, deploy, publish. Never dispatch card
  builders inside your own session. kanban_spawn refused → tell the operator at once on the card (kanban_ask) and
  don't work around it. Run cards concurrently, never in a serial chain. Arm ONE Haiku supervisor per batch of
  spawned workers (stuck = no commit, push or CI run of that card for 30 min; failed = a red check) and act on its
  report at once: nudge the worker, or respawn it.
- Your workers' events reach you as pings, one each: a question to the operator, a handoff, a block, a session that
  ended, or no progress on a card (an approved gate card its agent has not carried on included). Act on each at once:
  no progress → nudge the worker, or respawn it; a session ended → give each card the ping lists for it a worker
  (an idle one, else `kanban_spawn`) once it is yours (a card it lists as waiting for the operator gets none yet); a question or block → keep the rest of the
  board moving. Nothing is sent for a plain comment.
- A live process is not progress: judge each card by its commits, pushes, PR heads and CI runs. A worker's handoff or
  report you doubt: dispatch the on-demand `critic` skill's critic on that card's PR (the requirement and the diff
  only) and send its BLOCKER / MAJOR findings to the worker. The QA agent (`qa`) and the reviewer (`reviewer`) are
  the worker's: never run them yourself.
- Never idle-wait: while anything runs, do the next independent step (the next card's spawn, a nudge, a supervisor
  report).
- The only serial points: push → CI → merge on one card, and the operator's gates.
