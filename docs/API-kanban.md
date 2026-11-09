# Kanban JSON API

Per-project Trello-like board. The engine is the vendored `agents_kanban` (`vendor/agents_kanban`; its `SPEC.md` is the
contract, `config/kanban.yml` this board's shape); every route below is one `AgentsKanban::Api` call (`lib/busyyaks/kanban_api.rb`).
Same data as the MCP `kanban_*` tools (`AgentsKanban::Tools`, worded from the config); the JSON card shape is shared
(`Store#card_json`). A card also carries `parent` / `children` / `blocked_by` / `metadata` (the engine's
dependency fields — busyyaks's config has `dependencies: null`, so they are recorded and shown, never enforced) and the
board JSON carries `config` (the board config the React side renders with).

## Conventions

| | |
|---|---|
| Auth | session cookie (same as every page). Not signed in / not allowlisted → `401 {"error":"not signed in"}` |
| CSRF | every POST/PATCH/DELETE sends `X-CSRF-Token: <meta name="csrf-token">`. Missing/wrong → `403 {"error":"invalid or missing X-CSRF-Token"}` |
| Bodies | `Content-Type: application/json` (form-encoded also accepted). Unknown keys → `422 unknown fields: …` |
| Errors | every refusal is `{"error": "<reason>"}`: `404` unknown project/card/comment/checklist/item/label, `422` invalid input or refused. Never a silent substitute |
| Role | the web user is the operator: may move cards anywhere, including Human Check → Merged. Agents (MCP) cannot; a card FLAGGED `needs_operator` (`kanban_ask`) or `blocked_external` (`kanban_block`) refuses agent moves until the operator's comment / `kanban_unblock` |
| Authorship | a comment is edited / deleted only by its author (`422 only <author> edits or deletes comment <id>`) |
| Times | ISO 8601 with offset, `null` when unset. `due` input: `YYYY-MM-DDTHH:MM[:SS][Z\|±HH:MM]` (no offset = the server's `TZ`); the SPA always sends the browser's offset |
| Markdown | descriptions, comments and checklist items are markdown, rendered **only** by the server (`Busyyaks::Markdown.card`, commonmarker `unsafe: false` — raw HTML dropped; `@name` wrapped in `<span class="mention">`, not inside code/links). Clients inject `*_html`; they never render markdown |
| Slugs | may contain `/` (`acme/shop`): `/api/projects/acme/shop/board` |

## Columns (the template board — workflow v3, card #233; a project's board may differ: `GET /api/projects/*slug/workflow`)

| key | label | type | `operator_only` |
|---|---|---|---|
| `backlog` | Backlog | parked | false |
| `todo` | To do | queued | false |
| `doing` | In progress | working | false |
| `qa` | QA | review | false |
| `human_check` | Human Check | gate | true — agents enter only with `kanban_handoff`; the operator's Approve (→ `ready`) is the approval step |
| `ready` | Ready to merge | gate | true — entered by the operator's approval; its agent then takes "Merge" → `merged` (refused unapproved) |
| `merged` | Merged | done | true — only from `ready` (agents, approved) or by the operator; terminal |

Types (the fixed set): `parked queued working review gate done cancelled` (engine SPEC § 2a). **Human input is no column**:
a question for the operator is the card's `needs_operator` flag (`kanban_ask`; `asked*`, `question*` on the card JSON) and
an external blocker its `blocked_external` flag (`kanban_block`; `blocked: {reason, url, by, at}`) — the card keeps its
column, shows a badge, refuses agent moves, and counts as waiting. The private local-repo boards run the engine's
`local_v3` board (14 states: Backlog · To do · In progress · Local: Agent review · Local: Author response · Local:
Human review · Local: Merged · Local: Deploy check · Public: Agent review · Public: Author response · Public: Human review
· Awaiting merge · Done · Cancelled; `review_round` per agent-review column, limit 3 → the handoff carries `unresolved`).

`waiting_columns` = the gate columns (`human_check`, `ready`): "N waiting for you" = their cards + the flagged cards
elsewhere (`waiting`, `flagged` on the board / boards JSON). `listened_columns` = `todo`, `doing`, `qa`, `human_check`,
`ready`: a card there with an `assignee` but no `owner_session` shows **no listener** on its face.

Priorities: `high` · `medium` · `low` · `null`.
Colours (labels, covers; config `label_colors`, the Glass vivid tokens): `green` · `yellow` · `orange` · `red` · `purple` · `blue` · `teal` · `pink` · `gray` (= no colour).

## Card

```json
{
  "id": 12, "project": "g/r", "column": "todo", "position": 0,
  "title": "Fix login", "labels": ["auth"], "assignee": "claude-shop_teamlead", "priority": "high",
  "comments": 2, "due": "2025-03-05T18:00:00+01:00", "due_done": false, "cover": "blue",
  "has_description": true, "checklist_done": 1, "checklist_total": 3, "attachments": 2,
  "question": "Auth or **imgproc** first?", "question_options": ["Auth first", "Imgproc first"],
  "asked": "2025-03-02T16:40:00+01:00", "asked_by": "claude-shop_teamlead",
  "created_by": "operator@example.com",
  "created": "2025-03-02T10:00:00+01:00", "updated": "2025-03-02T11:30:00+01:00", "archived": null
}
```

`dialog`: `null`, or the open session dialog posted on this card (`{id, session, keys, escape, free_text, options: [{key, label, free}], posted}`;
only `keys` — non-free digits + `esc` — can be pressed). `question*` / `asked*`: the last `kanban_ask` or session dialog (`null` when never asked; `question_options` `null` = a free answer). Single-card
responses also carry `question_html`.

Single-card responses (`{card, activity}`) add `description` (markdown), `description_html` and `checklists`, and
`attachments` becomes the list (board faces: the count; see [Attachments](#attachments)):

```json
"checklists": [ { "id": 3, "title": "Ship", "position": 0,
  "items": [ { "id": 9, "body": "write **tests**", "body_html": "write <strong>tests</strong>", "done": true, "position": 0,
               "done_by": "claude-shop_teamlead", "done_at": "2025-03-02T11:00:00+01:00" } ] } ]
```

- `labels`: names from the board's label set (unknown names → 422 listing the set). `position` is 0-based within the column, contiguous, renumbered on every move/archive.
- Card face (SPA): due badge red = overdue, orange = due within 24 h, green = `due_done`; `checklist_done/checklist_total`; `has_description`; `comments`.
- Checklist item `body_html` is inline HTML (one paragraph unwrapped).

## Activity entry

```json
{ "id": 40, "at": "2025-03-02T11:30:00+01:00", "kind": "comment", "author": "claude-shop_teamlead", "body": "markdown",
  "body_html": "<p>…</p>", "edited": null }
```

`kind`: `create` · `update` (body lists changed fields) · `move` (`From → To`, column labels) · `comment` (markdown + `body_html`
+ `edited` time or `null`) · `question` (an agent's `kanban_ask`: markdown + `body_html`, ends with `**Options:** \`A\` · \`B\`` when
it has choices; author `busyyaks` for a session dialog) · `answer` (the operator pressed a session-dialog key: "pressed 2. No in &lt;session&gt;") · `owner` · `ping` (sent / failed) · `handoff` · `approve` · `watchdog` · `delete` (a comment deleted by its author) · `checklist` (added / renamed / removed a checklist,
completed / unchecked an item, converted an item to a card) · `archive` (`archived`/`restored`) · `attachment`
(`attached <name> (<size>)` / `deleted attachment <name>`). Oldest first.

## Endpoints

### `GET /api/boards`

Projects with live cards or a Backlog.md `backlog/` dir.

```json
{ "columns_order": ["backlog","todo","doing","qa","human_check","ready","merged"],
  "waiting_columns": ["human_check","ready"], "waiting": 2,
  "boards": [ { "project": "g/r", "counts": {"backlog":1,"todo":0,"doing":3,"qa":0,"human_check":1,"ready":0,"merged":4}, "total": 9,
                "waiting": 2, "flagged": 1, "backlog_md": false } ] }
```

### `GET /api/projects/*slug/board[?column=<key>][&archived=1]`

```json
{
  "project": "g/r",
  "labels": [ { "id": 1, "name": "bug", "color": "red" } ],
  "columns": [ { "column": "backlog", "label": "Backlog", "operator_only": false, "cards": [Card, ...] }, ... ],
  "archived": [Card, ...],
  "backlog_md": null,
  "columns_order": ["backlog", ...], "waiting_columns": ["human_check", "ready"], "waiting": 2, "flagged": 1, "listened_columns": ["todo", "doing", "qa", "human_check", "ready"], "priorities": ["high","medium","low"], "label_colors": ["green", ...],
  "assignees": ["operator@example.com", "claude-shop_teamlead", "claude"],
  "launcher_error": null
}
```

- `columns`: all eight in order (only `column` when `?column=` is given; unknown key → 422). Cards ordered by `position`.
- `archived`: only with `?archived=1`, newest archived first.
- `assignees` (members): the operator, this project's live tmux sessions, configured launcher labels, and every author /
  assignee / creator seen on this board's cards. `launcher_error` is the reason when the launcher is down (sessions then
  missing from the list); show it.
- `backlog_md`: `null`, or the repo's Backlog.md tasks, **read-only** (edit with the `backlog` CLI in the repo):

```json
{ "read_only": "edit with the backlog CLI in the repo",
  "errors": ["task-5 - x.md: no front matter", "status \"Parked\" (1 task) has no column — see BacklogMd::STATUS_MAP"],
  "tasks": [ { "id": "TASK-2", "title": "B", "status": "In Progress", "column": "doing", "labels": [], "assignee": ["@claude"],
               "priority": "high", "file": "task-2 - B.md" } ] }
```

`column` is `null` for a status with no mapping (also listed in `errors`). `"draft": true` only on `backlog/drafts/` tasks (always Backlog). Absent front-matter keys are absent.

### Cards

| route | body | → |
|---|---|---|
| `POST /api/projects/*slug/board` | `title`, `column` (required), `description?`, `labels?`, `assignee?`, `priority?`, `due?` — appended at the bottom | `201 {card, activity}` |
| `GET /api/cards/:id` | | `{card, activity}` |
| `PATCH /api/cards/:id` (or `POST`) | any of `title`, `description`, `labels` (array or comma string), `assignee` (`""`/`null` unassigns), `priority` (`""`/`null` clears), `due` (`""`/`null` clears), `due_done` (bool), `cover` (colour, `""`/`null` clears). Use `/move` for the column | `{card, activity}` |
| `POST /api/cards/:id/move` | `column` or `transition` (a workflow transition name out of the card's column; with `column` for a `*` fan-out), `position?` (0 = top; omitted / past the end = bottom). Archived → 422; no transition for the operator → 422 listing the transitions there are | `{card, counts, delivered}` (this board's live cards per column; `delivered` as for comments, `null` when the column did not change) |
| `POST /api/cards/:id/assign` | `assignee` (key required; `""`/`null` unassigns) | `{card, activity}` |
| `POST /api/cards/:id/archive` | `archived`: `true` / `false` (restore → bottom of its column) | `{card, activity}` |
| `POST /api/cards/:id/approve` | `approved`: `true` (default) approves the card at its approval step — a step = the board's `rules.gates.approvals` entry whose `from` is the card's column (the handoff check, e.g. Local: Human review → Local: Merged; the final one, e.g. Public: Human review → Awaiting merge): the card moves to the step's `to`, `approved`/`approved_by` set, the owner pinged; `false` withdraws (back to `from`) while it still sits approved in `to` — the operator only (no MCP tool; engine SPEC § 4) | `{card, activity}` · `422` not at a step |

### Session dialogs

| route | body | → |
|---|---|---|
| `POST /api/cards/:id/dialog-answer` | `key`: one of `card.dialog.keys` (a digit or `esc`; free text never) — the operator only (web session + CSRF; no MCP tool). The host launcher's `answer` op re-captures the session's screen and presses the key only if the dialog's hash still matches | `{card, activity}` (card → `doing`, `answer` entry by the operator) · `422` changed / vanished dialog or bad key (nothing typed, nothing recorded) · `503` launcher down |

### Comments

| route | body | → |
|---|---|---|
| `POST /api/cards/:id/comment` | `body` (markdown). On a card flagged `needs_operator` (not a session dialog) it is the operator's **answer**: the flag clears, the card keeps its column (activity `answer` by the operator) and the owner gets one `ANSWERED` ping carrying it. The dialog's option buttons post the option text here | `201 {card, activity, delivered}` — `delivered`: `"queued: <session>"`, `"none: no owner session"` or `"none: <author> is the card's owner"`; never silent |
| `PATCH /api/comments/:id` (or `POST`) | `body` — author only; sets `edited` | `{card, activity}` |
| `DELETE /api/comments/:id` | — author only; logs a `delete` entry | `{card, activity}` |

### Checklists

| route | body | → |
|---|---|---|
| `POST /api/cards/:id/checklists` | `title`, `items?` (array of markdown strings) | `201 {card, activity}` |
| `PATCH /api/checklists/:id` (or `POST`) | `title` | `{card, activity}` |
| `DELETE /api/checklists/:id` | | `{card, activity}` |
| `POST /api/checklists/:id/items` | `body` (markdown, ≤ 1000 chars) | `201 {card, activity}` |
| `PATCH /api/checklist-items/:id` (or `POST`) | `body?`, `done?` (bool; one required) | `{card, activity}` |
| `DELETE /api/checklist-items/:id` | | `{card, activity}` |
| `POST /api/checklist-items/:id/convert` | — the item becomes a card at the bottom of the parent's list (title = item, or its first 200 chars with the whole item as description); the item is removed | `201 {card, activity, created: Card}` (card/activity = the parent's) |

### Labels (the board's set)

| route | body | → |
|---|---|---|
| `GET /api/projects/*slug/workflow` | — the project's BOARD SHAPE: its columns with their types and order (no graph position: the editor lays the graph out itself, schema v9), and its workflow (the engine's `boards` / `board_columns` / `board_transitions` rows; the template's copy until edited) | `{columns: [{key, label, type, hide_after_hours}], transitions: [{name, from, to, by}], rules: {default_column, waiting, listened, operator_only, agent_no_create, gates, dependencies, idle_column, spawn_columns}, types: [{key, label, summary, …}], updated_by, updated}` |
| `POST /api/projects/*slug/workflow` | `columns` + `transitions` (the whole shape): `type` one of `parked queued working review gate done cancelled` (the type decides the column's rules — engine SPEC § 2a); `from` a column, a list or `"*"`; `to` a column or `"*"`; `by` `operator` \| `agent` \| `any`. Validated as a whole; a column that still holds cards (live or archived) cannot be dropped | the saved shape (as GET) · `422` the reason (the card ids when a column holds cards) |
| `DELETE /api/projects/*slug/workflow` | — the template board again for this project | the shape (as GET) · `422` when cards sit in a column the template lacks |
| `POST /api/projects/*slug/labels` | `name` (≤ 40, no comma, unique per board), `color` | `201 {label, labels}` |
| `POST /api/launch` | `slug`, `type` (an `agent_types` key), `launcher?` (one of the type's; default its first) — the cap is checked on a fresh live list, the session registered (a lead adopts), then started by bin/launcher | `201 {session, type, launcher, agent, adopted: [card], result: {remote_control, remote_control_name, reason, trust, trust_reason, prompt}, concurrency}` · `400` no type · `422` cap / unknown type or launcher (who runs in `error`) · `503` launcher down |
| `PATCH /api/labels/:id` (or `POST`) | `name?`, `color?` — a rename rewrites every card of the board carrying it | `{label, labels}` |
| `DELETE /api/labels/:id` | — removed from the set and from every card | `{labels}` |

### Attachments

Files on a card (table `card_attachments`), optionally belonging to one of its comments. Bytes live under
`ATTACHMENTS_DIR/<card_id>/<random hex>` (compose: `./data/attachments`) — never under the uploaded name. Limits are env,
required, no defaults: `ATTACHMENT_MAX_BYTES` (one file) and `ATTACHMENT_TYPES` (allowlist: MIME types and/or extensions,
see `.env.example`; an unknown entry fails the boot).

```json
{ "id": 7, "card_id": 12, "comment_id": 40, "filename": "login-bug.png", "content_type": "image/png", "size": 48213,
  "sha256": "9f2c…", "image": true, "uploaded_by": "claude-shop_teamlead", "created": "2025-03-02T11:40:00+01:00",
  "url": "/api/attachments/7", "download_url": "/api/attachments/7/download", "markdown": "![login-bug.png](/api/attachments/7)" }
```

| route | body | → |
|---|---|---|
| `POST /api/cards/:id/attachments` | multipart: `file`, `comment_id?` (a comment of this card). CSRF header required | `201 {attachment}` · `413` over the cap · `422` refused (reason) |
| `GET /api/attachments/:id` | — `png/jpeg/gif/webp`: inline. Anything else (SVG, HTML included): `Content-Disposition: attachment`, served as `application/octet-stream` for SVG/HTML | the bytes |
| `GET /api/attachments/:id/download` | — always `Content-Disposition: attachment` | the bytes |
| `DELETE /api/attachments/:id` | — soft delete (row kept, file no longer served), logged as `attachment`. Web = the operator: any; MCP agents: their own | `{card, activity}` |

- Type: from the **bytes** (magic numbers; text = UTF-8 without NUL, then SVG / HTML / plain). It must match the name's
  extension and the allowlist: `x.png` holding JPEG bytes, a `.txt` holding HTML, a `.json` that does not parse → `422` with
  the reason. The client's `Content-Type` and path are ignored; the display name is the sanitized last path segment (≤ 200).
- Serving: sign-in required (`401`), `X-Content-Type-Options: nosniff`, `Content-Security-Policy: default-src 'none'; sandbox`,
  `filename` + RFC 6266 `filename*`, `ETag` = sha256, `Cache-Control: private, max-age=31536000, immutable` (`304` on
  `If-None-Match`). The stored path must resolve (realpath) inside `ATTACHMENTS_DIR`; deleted / missing → `404`.
- Markdown: `![name](/api/attachments/ID)` renders as the picture (a link the card dialog opens as a lightbox);
  `[name](/api/attachments/ID/download)` as a file chip with `download`. Any other image URL renders as a plain link — no
  remote image is ever loaded. A comment whose body references the author's unlinked attachments of the card claims them
  (`comment_id`); deleting the comment unlinks them (the files stay on the card).
- Live updates: an add / delete touches the card and changes the board face count and the single-card list, so
  `/board/rev` and `/api/cards/:id/rev` change.

### Markdown preview

`POST /api/markdown {body, inline?}` → `{html}` — the editor's Preview tab: the same server render as saved descriptions and
comments (`inline: true` = a checklist item). Never a client-side markdown library.

## MCP (agents)

Every tool takes `author` (the agent or tmux session name) for writes; refusals are `isError` results with the reason.

| tool | does |
|---|---|
| `kanban_board(project, column?, archived?)` | same JSON as `GET /api/projects/*slug/board` minus `assignees`/`launcher_error`/`columns_order`/`priorities`/`label_colors`; every card + `url` (below) |
| `kanban_card(id)` | `{card, activity}` as **markdown** (no `*_html`): description, checklists with items (done/by), labels, due, comments with ids and `edited`; `card.url` = the absolute URL that opens it on its board (`https://$PUBLIC_HOST/projects/<slug>?tab=board&card=<id>`, `http://127.0.0.1:$WEB_HOST_PORT/…` while `PUBLIC_HOST` is empty; `lib/busyyaks/dashboard_url.rb`) — every card row a tool returns carries it, the agents' link to a card (MCP instructions: Links) |
| `kanban_create(project, title, author, tmux_session?, column?, description?, labels?, priority?, due?)` | Card **owned by the agent's session** (assignee = author, owner = `tmux_session` — verified live — or the session whose registered agent name is `author`); neither → refused. `column` omitted = `backlog`; `merged` / a gate refused; `assignee` refused |
| `kanban_register(project, type, tmux_session, author, launcher?)` | `{session, type, launcher, agent, adopted: [{id,title,column,column_label}], concurrency}`: the session registers as an agent type of `config/kanban.yml`; `launcher` = the launcher key it was started with — required when the type lists several (never guessed, `spawn_launcher` does not apply to a session started by hand); refused beyond `concurrency.max_sessions` / the type's `max` / `max_per_project` (with who runs), twice for one session, or for an unknown type. A `lead` adopts the board's ownerless cards in its `takes` columns |
| `kanban_move(id, column?, transition?, author, position?)` | Card; refused into a gate (use `kanban_handoff`), along an approval step (the operator's), out of a gate unless approved and along a named agent transition, while the card is flagged (`needs_operator` / `blocked_external`), and past the review loop's round limit |
| `kanban_update(id, author, title?, description?, labels?, priority?, due?, due_done?, cover?)` | Card; `assignee` refused: "use kanban_claim(id, assignee, tmux_session)" |
| `kanban_claim(id, assignee, tmux_session)` | Card with `assignee` + `owner_session` set; gaining an owner queues ONE ping with the operator's comments that reached nobody. `tmux_session` required and must be live (launcher `sessions` op); unknown → refused with the live list, launcher down → refused. The owner is the lead's session: subagents comment under their own names, replies route to the lead |
| `kanban_ask(id, question, author, options?, tmux_session?)` | Card FLAGGED `needs_operator` in its own column (`tmux_session` given + no owner → claimed first) with `question` / `question_options` / `asked*`; a `comment` "**Question for the operator:**" + a `flag` entry. Requires an owner session; refused in a terminal column; a new ask replaces the question; the operator's comment clears it (`answer` entry, one `ANSWERED` ping). One reminder comment after `flags.reminder_hours` (24). `options`: ≤ 8 distinct strings ≤ 200 chars |
| `kanban_block(id, reason, url, author)` · `kanban_unblock(id, author, note?)` | Card FLAGGED `blocked_external` (reason + http(s) url required; a `comment` "**Blocked (external):**" + a `flag` entry) / cleared. Counts as waiting; reminded after 24 h |
| `kanban_handoff(id, qa, pr_url, ci_url, ui_change, author, transition?, column?)` | Card in a gate: the one its column has a named agent transition into (several → `transition` or `column`); screenshots attached first when `ui_change`. At the review loop's round limit the card gets the `unresolved` label |
| `kanban_comment(id, body, author)` | `{id, delivered}` (comment id; who it pings); markdown, rendered for the operator exactly like the web's |
| `kanban_comment_edit(comment_id, body, author)` | the entry (author must match) |
| `kanban_comment_delete(comment_id, author)` | `{deleted, card}` (author must match) |
| `kanban_labels(project)` | `[{id, name, color}]` |
| `kanban_label_save(project, name, author, color?, new_name?)` | create (color required) or recolour / rename → the set |
| `kanban_label_delete(project, name, author)` | the set |
| `kanban_labels_set(id, labels, author)` | Card (`[]` clears) |
| `kanban_due_set(id, due, author, done?)` | Card (`due: ""` clears) |
| `kanban_checklist_add(id, title, author, items?)` | `{id, title, checklist_done, checklist_total, checklists}` |
| `kanban_checklist_rename(checklist_id, title, author)` · `kanban_checklist_delete(checklist_id, author)` | same |
| `kanban_checklist_item_add(checklist_id, body, author)` · `kanban_checklist_item_edit(item_id, body, author)` | same |
| `kanban_checklist_toggle(item_id, done, author)` · `kanban_checklist_item_delete(item_id, author)` | same |
| `kanban_checklist_item_convert(item_id, author)` | the new Card (agents cannot convert inside Merged) |
| `kanban_attach(id, author, filename, comment?, content_base64 \| project_path)` | `{attachment, comment_id}`. Exactly one source: `content_base64` (≤ `ATTACHMENT_MAX_BYTES` decoded; the encoded length is capped before decoding) or `project_path` (a file in **this card's** repo on the read-only projects mount: relative to the repo root, or absolute under it; realpath'd, refused outside the repo / not a regular file). With `comment`: posts it with the snippet appended — through `Kanban#comment`, so it pings the owner like any comment |
| `kanban_attachments(id)` | the card's live attachments (JSON above) |
| `kanban_attachment_get(attachment_id)` | the attachment; text types (`txt log md csv json yml diff`) add `text` (first 100 000 chars) and `truncated`; pictures / other files: metadata + `url` |

## Web (SPA, `frontend/src/components/Board.tsx`, `CardDialog.tsx`)

| | |
|---|---|
| Board | lists with drag-and-drop (correct under a filter / due order), list menu (cards · overdue · due 24 h · unassigned, add, collapse — collapse kept per browser), filter: text · labels (any) · member (me / unassigned / name) · due (overdue / 24 h / none / complete), view order: list / due date |
| Card face | `? question` / `? N choices` (flagged `needs_operator`, any column), `⛔ blocked: <reason>` (`blocked_external`), `round n/3` (a review column), **no listener** (assignee without owner session in a listened column), cover, label strips (click: names), due badge, description, comments, attachments (paperclip + count), checklist x/y, priority, #id, assignee avatar |
| Card modal | `?card=<id>[&panel=labels\|due\|members\|checklist\|cover]`: title, members/labels/due, "Question for you" box (flagged `needs_operator`: question, option buttons → the answer comment; the card stays in its column), "Blocked (external)" box (reason, link, by), "Nobody is listening" warning + owner picker above the comment box when no owner session, `delivered` under it after a comment, owner panel with the latest ping (status · reason · tries · times), description, checklists, activity (comments edit/delete by author, "edited"); sidebar: members, labels (create/rename/recolour/delete), checklist, due (+complete), cover, move, priority, copy link, archive |
| Editor | Write / Preview (`/api/markdown`), toolbar bold · italic · code · link · list · task list · attach; `Ctrl+B/I/E/K`, `Ctrl+Enter` save, `Esc` cancel. Description and comment editors: paste an image / drop a file / the paperclip → upload, a placeholder at the caret becomes the snippet; progress chip; a failure stays visible with the server's reason |
| Attachments | "Attachments · N": picture thumbnails (click → lightbox, `Esc` closes it first), file rows (name, size, uploader, time, download, delete); sidebar **Attach** (file picker, multiple); drop files anywhere on the open card |
| Keys (board) | arrows focus · `Enter`/`e` open · `n` new card in focused list · `c` archive · `l` labels · `d` due · `m` members · `Space` assign to me · `Alt+←/→` list · `Alt+↑/↓` order · `q` my cards · `f`/`/` filter · `Esc` · `?` overlay |
