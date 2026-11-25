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
| `ruby` | `41357277180806240b3d53993df10a09ee2d3589` |
| `fixtures` | `e6eafdf63b4d867c4337ff1e6632fc66e1c6b65d` |
| `react/src` | `40fd1f6546dc74cc5e3940fd0755a369d06141b4` |
| `SPEC.md` | `bbc4fee56defcea372b5d0adbc0b52023e951a86` |
| `config.example.yml` | `f197e9d52ad905791c3a0141f51c6ed8b8277399` |
| `LICENSE` | `9ef5b284fd11a7ce6383c5f2dbc91c0cf84bd40f` |

Synced from source commit `8ca82b4820292490288b229570a6dd022d0d4a1c` (information only: a commit sha of the private local repo is not in the public repo and vice versa; the ids above are in both).
