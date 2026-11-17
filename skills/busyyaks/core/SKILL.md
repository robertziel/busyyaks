---
name: core
description: How busyyaks sessions work with the kanban MCP — identity, ownership, kanban_ask / kanban_block, never polling, comment headers, gates and approval, conflicts and red CI never parking a card, links. Every session busyyaks starts loads it.
---
# busyyaks core: the board and its kanban MCP

The board (columns, transitions, gates) is the operator's: read it with `kanban_workflow(project)` and a card's way
forward with `kanban_card(id).transitions` — never assume a column name. A board whose columns start with `Local:` /
`Public:` (a board with a separate publish stage): load the skill the entry's "Load when needed" list names for it, when
this deployment provides one.

## Identity and ownership

| | |
|---|---|
| who you are | your tmux session (`tmux display -p '#S'`); the launch prompt names your agent name |
| own a card | cards you create (`kanban_create` with `tmux_session`, or `author` = your agent name) are yours; a card you start that you do not own → `kanban_claim(id, assignee, tmux_session)` first |
| new card | only with the operator's go-ahead (`kanban_ask` on the card you work); findings go as comments on that card, never as new cards |
| scope | work ONLY on the cards you were started for / own |

## Talking to the operator

- A question, a choice or a go-ahead about a card → `kanban_ask(id, question, author, options?)` on that card, then
  END the turn. The card keeps its column, is flagged needs_operator and refuses agent moves until the answer.
  Never ask only in chat (nobody reads it); never move a card to ask.
- Waiting on CI, an API or anyone outside the board → `kanban_block(id, reason, url)`; `kanban_unblock` when it clears.
- Never poll the board or a card (no sleep / re-read loops): comments, moves and answers arrive as pings. End the
  turn and wait.
- Work runs concurrently, never idle-waiting: the only serial points are push → CI → merge and the operator's
  gates (your agent type's section below: lead = Orchestration, worker = Concurrency).
- Never end a turn "waiting for X" unless a watcher for X is armed (a `Monitor` until-loop, e.g. on
  `gh pr view N --json statusCheckRollup` every 60 s). If the watched event already happened, act on it now.

## Comments

Every comment starts with a header:

```
[<Role>] · <STATUS> · round <n> · severity: <blocker|major|minor|nit> · category: <correctness|security|perf|tests|style|design>
```

Role = `Team Lead`, `Author Agent`, `Reviewer Agent`, `QA Agent`. STATUS = OPEN · FIXED · DISAGREE · RESOLVED ·
NEEDS_HUMAN · SUMMARY. A reply to a review thread carries no severity / category:
`[Author Agent] · FIXED · <sha> — <one line>` or `[Author Agent] · DISAGREE — <evidence: file:line, spec, docs>`.
Only the Reviewer writes RESOLVED.

Severity: blocker / major block the handoff; **minor / nit never block** — note them, file them for after the
release when the operator agrees, move on.

## Approval and merging

- **Never merge before the operator approves** — no `gh pr merge`, no merge button, no `--admin`, no push to a
  default branch — until the operator's approval moved the card on. Open the PR, hand off, stop.
- After the approval the owner merges along the transitions the card lists and takes the next one.
- An agent leaves a gate only along a named agent transition once the operator approved; a flagged card is never
  moved by an agent. Gates are entered only with `kanban_handoff`.

## Conflicts and red CI never park a card

- A PR's base moved, a merge refused ("Base branch was modified"), a rebase conflicts → rebase / merge onto the
  CURRENT base at once, resolve every conflict keeping both sides' intent, re-vendor if needed, re-run the full CI
  (and a reviewer on the resolution), proceed. Never wait for another card's PR to land first; if it lands later, rebase again.
- Check each merge / push result before the next step; never chain a follow-up (a re-vendor, a push) after a failed one.
- A red check (PR, merged commit, default branch) → read the failing stage's log, name the cause. In the change →
  fix the code (never skip, exclude or loosen a check), push, CI again. Outside it (network, rate limit, runner
  outage) → re-run once and note it; red again → fix the cause or `kanban_block` with the build URL. Post the cause
  and what you did on the card. Never stop, wait or hand off on red.

## Links

For every reference decide what it IS and link to where it lives, read from data: a card → its `url`
(`kanban_card`); a comment → the card's `url` + "comment N"; a PR → that PR on ITS repo (`pr_url`, the card's Links,
`gh pr view` — different repos reuse the same numbers); a commit → its repo + sha; a CI build → `ci_url`.
Can't tell → look it up, never guess. **In chat, never `#` before a number** ("card 236", "<repo> PR 99"); on the
board write `card #N`, `PR #N`, `comment #N` as they are.
