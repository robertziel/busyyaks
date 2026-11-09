# frontend/src/vendor

A COPY of the shared kanban engine's REACT port (`agents_kanban/react/src`): the Board, the card dialog, the markdown
editor and `kanban.css`, mounted by `components/Board.tsx` (a ~70-line adapter that binds the `KanbanApi` port to
`api.ts` and the view to `?card=&panel=&archived=`). Its `lib/*.test.ts` run in this project's vitest too.

Never edit anything here — edit the source repo and run `scripts/vendor-kanban-engine.sh`, which renders this file
and refuses to overwrite a drifted copy. The RUBY half is vendored under `vendor/agents_kanban`; both are synced
from ONE source commit and carry the same pin table.

License: Apache-2.0 — the module's [`agents_kanban/LICENSE`](agents_kanban/LICENSE), copied with every sync (busyyaks's root `NOTICE` lists it).

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
