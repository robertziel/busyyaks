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
| `ruby` | `26e564f2b5874038f51aa06f7037d8288391b38b` |
| `fixtures` | `dc999b32e2ae5ca3f0f28471a6dc7a9f3b424992` |
| `react/src` | `3e3fba85c1dc58e351d99f8656eb8049c0a10b9d` |
| `SPEC.md` | `ed6db6d26ec7fd451527c0f66bfd31a66a9d9134` |
| `config.example.yml` | `fd0ff050b5177a586b0ceddf3be85417028337f0` |
| `LICENSE` | `9ef5b284fd11a7ce6383c5f2dbc91c0cf84bd40f` |

Synced from source commit `e7784967c7d585dc4c5cf0d17d974af9613fc3e6` (information only: a commit sha of the private local repo is not in the public repo and vice versa; the ids above are in both).
