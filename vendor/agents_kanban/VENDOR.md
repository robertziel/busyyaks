# vendor/agents_kanban

A COPY of the shared kanban engine's RUBY port, its fixtures, SPEC.md and config.example.yml — the engine behind
every `/api/cards/*` route, the `kanban_*` MCP tools and the notifier. busyyaks keeps NO kanban logic of its own:
`lib/busyyaks/kanban.rb` only builds the engine from `config/kanban.yml` and this copy (`test/unit/no_kanban_code_test.rb`
fails when engine code reappears outside here).

Never edit anything here — edit the source repo and run `scripts/vendor-kanban-engine.sh`, which renders this file
and refuses to overwrite a drifted copy. `fixtures/` travels with the port because its own suite reads `../../fixtures`.

The REACT half of the same repo is vendored separately, for Vite, in `frontend/src/vendor/agents_kanban`
(see `frontend/src/vendor/VENDOR.md`); both halves are synced from ONE source commit by the one script, and both
files carry the same pin table.

License: Apache-2.0 — the module's [`LICENSE`](LICENSE), copied with every sync (busyyaks's root `NOTICE` lists it).

| package | source |
|---|---|
| `agents_kanban` | [robertziel/busyyaks_agents_kanban_module](https://github.com/robertziel/busyyaks_agents_kanban_module) (a local checkout of it, or of its private local repo, via `KANBAN_ENGINE`) |

The pin is git's content id of each vendored path — a tree id for a directory, a blob id for a file — not a commit
sha: the public repo is published from the private local repo as squashed commits, so commit shas differ between the two
while these ids do not. `scripts/vendor-kanban-engine.sh` compares each copy here with `git archive <tree id>` /
`git cat-file blob <blob id>` of the source checkout (either repo) and refuses to sync over a copy that differs.

| path in the source repo | pinned id (git tree / blob, same in the public repo and its private local repo) |
|---|---|
| `ruby` | `3f6b9c4830ceb46a3d46f6a81c350155034770af` |
| `fixtures` | `6db6760596e6803f52f6dd45d4bac6491c6bcb88` |
| `react/src` | `110cad564d4d6c31d63234c7b7d736f9b552b302` |
| `SPEC.md` | `573c244dfba8e0ed8910d85209ba72cba92e1eae` |
| `config.example.yml` | `518d45f60a44ac836cb1e4ccb9f7cc5335853480` |
| `LICENSE` | `9ef5b284fd11a7ce6383c5f2dbc91c0cf84bd40f` |

Synced from source commit `7964a49b40ddb8decb852c3cfee064d79d062ce8` (information only: a commit sha of the private local repo is not in the public repo and vice versa; the ids above are in both).
