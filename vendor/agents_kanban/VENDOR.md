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
| `ruby` | `a9985109ee75c88fbc007f2a56bb2c8dc527be7b` |
| `fixtures` | `dc999b32e2ae5ca3f0f28471a6dc7a9f3b424992` |
| `react/src` | `c657fd4acfd94067a7494cb087cb6142cdef857a` |
| `SPEC.md` | `6345afb9e9eb7fd455c871ed6fcd4d4bd8aaa650` |
| `config.example.yml` | `31c189d579951cbbf5b0e63072c6a9941261c97b` |
| `LICENSE` | `9ef5b284fd11a7ce6383c5f2dbc91c0cf84bd40f` |

Synced from source commit `823bfeecce11962b072ee638e8ef65bbe105842e` (information only: a commit sha of the private local repo is not in the public repo and vice versa; the ids above are in both).
