#!/usr/bin/env bash
# Re-vendor the shared kanban engine (agents_kanban) into this repo.
#
#   KANBAN_ENGINE=/path/to/busyyaks_agents_kanban_module scripts/vendor-kanban-engine.sh   # sync to that checkout's HEAD
#
# KANBAN_ENGINE is required: where the source checkout lives is this machine's business, not the repo's (no default
# path). It may be a clone of the public repo (github.com/robertziel/busyyaks_agents_kanban_module) or of its private
# development repo (its private local repo): the pin works against either (below). VENDOR.md also states the module's license; a source whose
# LICENSE no longer matches it stops the sync.
#
# The source repo holds one directory per language (ruby/, react/) plus the fixtures and SPEC.md they share. This
# project embeds:
#
#   ruby/       -> vendor/agents_kanban/ruby          the engine the web, mcp and notifier containers run (lib/busyyaks/kanban.rb loads it)
#   fixtures/   -> vendor/agents_kanban/fixtures      so that port's own suite can run from the copy
#   react/src/  -> frontend/src/vendor/agents_kanban  the Board the project page mounts (Vite bundles it; its *.test.ts run in our vitest)
#   SPEC.md, config.example.yml, LICENSE -> vendor/agents_kanban/ (LICENSE also beside the react copy)
#
# THE PIN is git's own content id of each vendored path at the synced commit — the TREE id of ruby/, fixtures/ and
# react/src/, the BLOB id of SPEC.md, config.example.yml and LICENSE — not a commit sha. The public repo is published
# from the private local repo as squashed commits with the same content, so its commit shas differ from the local repo's but
# these ids are identical in both: the drift check below runs against a clone of either. The local-repo commit the sync
# was taken from is recorded beside the pin as information only; nothing reads it.
# Both VENDOR.md files are rendered whole by this script (the template is at the end) with the SAME pin table.
#
# A vendored copy is READ-ONLY by convention: an edit belongs in the source repo, which has its own suites. So this
# refuses to run while any copy differs from the content it was pinned at — syncing then would delete work nobody
# else has. Nothing is overwritten until that check and the source repo's own suites pass.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_REPO="robertziel/busyyaks_agents_kanban_module"
SRC="${KANBAN_ENGINE:?set KANBAN_ENGINE to your busyyaks_agents_kanban_module checkout (github.com/$SOURCE_REPO)}"
RB_DEST="$REPO/vendor/agents_kanban/ruby"
FIX_DEST="$REPO/vendor/agents_kanban/fixtures"
WEB_DEST="$REPO/frontend/src/vendor/agents_kanban"
RB_NOTE="$REPO/vendor/agents_kanban/VENDOR.md"
WEB_NOTE="$REPO/frontend/src/vendor/VENDOR.md"
TREES=(ruby fixtures react/src)                 # vendored directories: pinned by tree id
BLOBS=(SPEC.md config.example.yml LICENSE)      # vendored single files: pinned by blob id
IGNORE=(-x node_modules -x .bundle -x tmp -x '*.sqlite3' -x LICENSE)   # LICENSE: copied from the source root, checked as a blob

[[ -e "$SRC/.git" ]] || { echo "no git repo at $SRC" >&2; exit 1; }

# pin_of <VENDOR.md> <path>: the id the pin table records for <path>; nothing when the file or the row is missing.
pin_of() {
    [[ -f "$1" ]] || return 0
    local line prefix="| \`$2\` | \`"
    while IFS= read -r line; do
        if [[ "$line" == "$prefix"* && "${line#"$prefix"}" =~ ^([0-9a-f]{40})\`\ \|$ ]]; then
            echo "${BASH_REMATCH[1]}"; return 0
        fi
    done <"$1"
}

# need_pin <VENDOR.md> <path> <destination>: the pin of a copy that exists; a copy with no pin cannot be checked → stop.
need_pin() {
    local id
    id=$(pin_of "$1" "$2")
    if [[ -z "$id" ]]; then
        echo "${3#"$REPO"/} exists but ${1#"$REPO"/} has no pin row for \`$2\` — cannot check it for local edits." >&2
        exit 1
    fi
    git -C "$SRC" cat-file -e "$id" 2>/dev/null || {
        echo "the pinned \`$2\` ($id) is not in $SRC — fetch the commit it was vendored from first." >&2; exit 1; }
    echo "$id"
}

drift() {   # drift <copy> <pinned id>: report and stop
    echo "$1 differs from its pinned content $2:" >&2
    cat >&2
    echo "move that change into $SRC first — this script will not overwrite it." >&2
    exit 1
}

# A copy that drifted from its pin: say which files, and stop.
check_tree() {      # check_tree <note> <path> <destination>
    local note="$1" sub="$2" dest="$3" id tmp out
    [[ -d "$dest" ]] || return 0
    id=$(need_pin "$note" "$sub" "$dest")
    tmp=$(mktemp -d)
    git -C "$SRC" archive --format=tar "$id" | tar -x -C "$tmp"
    out=$(diff -r -q "${IGNORE[@]}" "$tmp" "$dest" 2>&1) || { rm -rf "$tmp"; drift "${dest#"$REPO"/}" "$id" <<<"$out"; }
    rm -rf "$tmp"
}

check_blob() {      # check_blob <note> <path> <destination file>
    local note="$1" path="$2" dest="$3" id
    [[ -f "$dest" ]] || return 0
    id=$(need_pin "$note" "$path" "$dest")
    git -C "$SRC" cat-file blob "$id" | cmp -s - "$dest" || drift "${dest#"$REPO"/}" "$id" <<<"(file content)"
}

check_tree "$RB_NOTE"  ruby               "$RB_DEST"
check_tree "$RB_NOTE"  fixtures           "$FIX_DEST"
check_tree "$WEB_NOTE" react/src          "$WEB_DEST"
check_blob "$RB_NOTE"  SPEC.md            "$REPO/vendor/agents_kanban/SPEC.md"
check_blob "$RB_NOTE"  config.example.yml "$REPO/vendor/agents_kanban/config.example.yml"
check_blob "$RB_NOTE"  LICENSE            "$REPO/vendor/agents_kanban/LICENSE"
check_blob "$WEB_NOTE" LICENSE            "$WEB_DEST/LICENSE"

# Both VENDOR.md state the module's license ("License: Apache-2.0", also in NOTICE; rendered by the template below),
# so a source whose LICENSE is not that one stops the sync here: update NOTICE, the template and both notes first.
license_head=$(head -3 "$SRC/LICENSE")
if [[ "$license_head" != *"Apache License"* || "$license_head" != *"Version 2.0"* ]]; then
    echo "$SRC/LICENSE is not the Apache License 2.0 — update NOTICE and both VENDOR.md first" >&2; exit 1
fi
for note in "$RB_NOTE" "$WEB_NOTE"; do
    grep -q "^License: Apache-2.0" "$note" || { echo "${note#"$REPO"/} has no 'License: Apache-2.0' line" >&2; exit 1; }
done

# The source repo's own suites gate the sync (ruby on SQLite — the Postgres run is the source repo's own gate — and react),
# both on every CPU: the engine's `rake test:parallel` (a worker process per CPU, each on its own SQLite file) and its
# vitest config's maxWorkers = availableParallelism().
docker build -q -t agents-kanban-ruby:dev "$SRC/ruby" >/dev/null
docker run --rm -v "$SRC":/app -w /app/ruby agents-kanban-ruby:dev bundle exec rake test:parallel
docker build -q -t agents-kanban-react:dev "$SRC/react" >/dev/null
docker run --rm -v "$SRC":/repo -w /repo/react agents-kanban-react:dev sh -c 'npx tsc --noEmit && npx vitest run'

COMMIT=$(git -C "$SRC" rev-parse HEAD)
rm -rf "$RB_DEST" "$FIX_DEST" "$WEB_DEST"
mkdir -p "$RB_DEST" "$FIX_DEST" "$WEB_DEST"
git -C "$SRC" archive --format=tar "HEAD:ruby"      | tar -x -C "$RB_DEST"
git -C "$SRC" archive --format=tar "HEAD:fixtures"  | tar -x -C "$FIX_DEST"
git -C "$SRC" archive --format=tar "HEAD:react/src" | tar -x -C "$WEB_DEST"
git -C "$SRC" cat-file blob HEAD:SPEC.md            > "$REPO/vendor/agents_kanban/SPEC.md"
git -C "$SRC" cat-file blob HEAD:config.example.yml > "$REPO/vendor/agents_kanban/config.example.yml"
git -C "$SRC" cat-file blob HEAD:LICENSE            > "$REPO/vendor/agents_kanban/LICENSE"
cp "$REPO/vendor/agents_kanban/LICENSE" "$WEB_DEST/LICENSE"

# --- VENDOR.md template -------------------------------------------------------------------------------------------
pin_table() {
    local p
    echo "| path in the source repo | pinned id (git tree / blob, same in the public repo and its private local repo) |"
    echo "|---|---|"
    for p in "${TREES[@]}" "${BLOBS[@]}"; do echo "| \`$p\` | \`$(git -C "$SRC" rev-parse "HEAD:$p")\` |"; done
    echo
    echo "Synced from source commit \`$COMMIT\` (information only: a commit sha of the private local repo is not in the public repo and vice versa; the ids above are in both)."
}

pin_text() {
    cat <<EOF
| package | source |
|---|---|
| \`agents_kanban\` | [$SOURCE_REPO](https://github.com/$SOURCE_REPO) (a local checkout of it, or of its private local repo, via \`KANBAN_ENGINE\`) |

The pin is git's content id of each vendored path — a tree id for a directory, a blob id for a file — not a commit
sha: the public repo is published from the private local repo as squashed commits, so commit shas differ between the two
while these ids do not. \`scripts/vendor-kanban-engine.sh\` compares each copy here with \`git archive <tree id>\` /
\`git cat-file blob <blob id>\` of the source checkout (either repo) and refuses to sync over a copy that differs.

$(pin_table)
EOF
}

cat >"$RB_NOTE" <<EOF
# vendor/agents_kanban

A COPY of the shared kanban engine's RUBY port, its fixtures, SPEC.md and config.example.yml — the engine behind
every \`/api/cards/*\` route, the \`kanban_*\` MCP tools and the notifier. busyyaks keeps NO kanban logic of its own:
\`lib/busyyaks/kanban.rb\` only builds the engine from \`config/kanban.yml\` and this copy (\`test/unit/no_kanban_code_test.rb\`
fails when engine code reappears outside here).

Never edit anything here — edit the source repo and run \`scripts/vendor-kanban-engine.sh\`, which renders this file
and refuses to overwrite a drifted copy. \`fixtures/\` travels with the port because its own suite reads \`../../fixtures\`.

The REACT half of the same repo is vendored separately, for Vite, in \`frontend/src/vendor/agents_kanban\`
(see \`frontend/src/vendor/VENDOR.md\`); both halves are synced from ONE source commit by the one script, and both
files carry the same pin table.

License: Apache-2.0 — the module's [\`LICENSE\`](LICENSE), copied with every sync (busyyaks's root \`NOTICE\` lists it).

$(pin_text)
EOF

cat >"$WEB_NOTE" <<EOF
# frontend/src/vendor

A COPY of the shared kanban engine's REACT port (\`agents_kanban/react/src\`): the Board, the card dialog, the markdown
editor and \`kanban.css\`, mounted by \`components/Board.tsx\` (a ~70-line adapter that binds the \`KanbanApi\` port to
\`api.ts\` and the view to \`?card=&panel=&archived=\`). Its \`lib/*.test.ts\` run in this project's vitest too.

Never edit anything here — edit the source repo and run \`scripts/vendor-kanban-engine.sh\`, which renders this file
and refuses to overwrite a drifted copy. The RUBY half is vendored under \`vendor/agents_kanban\`; both are synced
from ONE source commit and carry the same pin table.

License: Apache-2.0 — the module's [\`agents_kanban/LICENSE\`](agents_kanban/LICENSE), copied with every sync (busyyaks's root \`NOTICE\` lists it).

$(pin_text)
EOF

echo "vendored $SRC @ $COMMIT -> vendor/agents_kanban/{ruby,fixtures,SPEC.md,config.example.yml,LICENSE} + frontend/src/vendor/agents_kanban"
