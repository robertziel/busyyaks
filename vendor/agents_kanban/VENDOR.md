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
| `ruby` | `e51c76e6e94205a01d59a92b8b07147f21b00c7a` |
| `fixtures` | `e9c4db2b2dabab85978916972c8630eae6f083c0` |
| `react/src` | `6cf856a95c80145d3261d1bcde378876e5410e7c` |
| `SPEC.md` | `8d7631b31d3386b2a6b4d52e5402733185159a83` |
| `config.example.yml` | `a13eaf97d1869ac02f1d96fa9f191779df74e686` |
| `LICENSE` | `9ef5b284fd11a7ce6383c5f2dbc91c0cf84bd40f` |

Synced from source commit `67a03e5befed242383a0e04ce1d6f8c1d657e0a8` (information only: a commit sha of the private local repo is not in the public repo and vice versa; the ids above are in both).
