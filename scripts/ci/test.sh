#!/usr/bin/env bash
# busyyaks's CI gates — the same on Jenkins and on any machine with Docker.
#
#   scripts/ci/test.sh ruby       the Ruby suite on SQLite: the compose `test` service (docker compose run --rm --build test;
#                                 its test-postgres is up too: the SQLite → PostgreSQL copy test's target)
#                                 + SimpleCov line/branch coverage merged across the workers, fails below its floor
#                                 (test/support/coverage.rb)
#   scripts/ci/test.sh ruby-pg    the same suite on PostgreSQL: the test service's test-postgres (tmpfs) as its database,
#                                 DATABASE_ADAPTER=postgresql, one database per worker;
#                                 then a smoke over the compose `postgres` profile (socket volume, scram, HOST_UID)
#   scripts/ci/test.sh frontend   the SPA: npm ci → tsc --noEmit → eslint (0 warnings, src/vendor included) →
#                                 prettier --check (every TS/TSX/JS/CSS/JSON file in the repo, the vendored engine
#                                 included) → vitest run, in node:22-bookworm-slim
#   scripts/ci/test.sh lint       RuboCop over the whole tree (scripts/lint/rubocop; .rubocop.yml = Cookpad's guide), then
#                                 ShellCheck -S style over every shell script, found by shebang (scripts/lint/shellcheck)
#   scripts/ci/test.sh audit      dependency advisories: bundle-audit check --update (Gemfile.lock, in the
#                                 busyyaks:lint image) + the image's libgit2 (Dockerfile ARG) against libgit2's security
#                                 releases (scripts/ci/libgit2-audit.rb) + npm audit --audit-level=low (frontend/package-lock.json, which
#                                 also covers the vendored engine under frontend/src/vendor). Any finding fails it —
#                                 never ignored or baselined, fixed by upgrading. Needs network (advisory DBs)
#   scripts/ci/test.sh secrets    gitleaks over the full git history; any finding fails it, never allowlisted
#   scripts/ci/test.sh host       the host-side programs' tests (bin/yaks, bin/env, the launcher's rules, the
#                                 installers)
#                                 on the OLDEST host Ruby they support (HOST_RUBY_IMAGE = Busyyaks::CLI::MIN_RUBY):
#                                 a construct newer than that passes the suite's Ruby 3.4 and breaks on the host
#   scripts/ci/test.sh changelog  a pull request only: CHANGELOG_BASE (required: the ref it merges into, e.g.
#                                 origin/main) → scripts/ci/changelog — the PR adds a line under Unreleased and every
#                                 Unreleased entry is one line. Plain git on the checkout, no container; not in `all`
#                                 (a branch build has no base)
#   scripts/ci/test.sh all        lint, ruby, frontend, audit, secrets and host at once, each into its own log,
#                                 printed one after the other once all have finished; fails if any fails
#
# Where it runs: Jenkins (the maintainer's runner, Jenkinsfile) and GitHub Actions (.github/workflows/ci.yml, every
# pull request on the public repo, forks included) run this same script; so does any machine with Docker.
#
# Trust: every stage starts containers on the Docker daemon. On a rootful daemon, access to it is equivalent to root on
# that host; the Ruby suite goes further: compose() hands the daemon's socket INTO a container (docker:cli, for the
# compose plugin), and the suite builds the checkout's Dockerfile and runs its code as root with the checkout
# bind-mounted. Run it only on code you would run as root, on a host you can afford to give it — a disposable VM such
# as a GitHub-hosted runner, or a CI host that builds trusted branches only (never a stranger's fork on the
# maintainer's Jenkins). On a ROOTLESS daemon (DOCKER_HOST = that user's socket) container root is that unprivileged
# user, and the script hands it the rootless socket, never /var/run/docker.sock — the maintainer's Jenkins runs it so.
#
# Every CPU is used: the Ruby suite runs one worker process per CPU (Rakefile test:parallel), vitest
# --maxWorkers = the container's `nproc`; both read the count at run time, nothing is pinned here.
#
# Nothing here writes to the checkout except the Ruby suite's own bind mount (the compose file mounts `.:/app`);
# whatever it leaves root-owned is handed back to the caller's uid afterwards, so a Jenkins workspace stays deletable.
set -euo pipefail

cd "$(dirname "$0")/../.."
SRC=$PWD
COMPOSE_IMAGE=docker:28.5.2-cli      # carries the compose plugin (the Jenkins controller's docker CLI has none)
NODE_IMAGE=node:22-bookworm-slim     # the Dockerfile's frontend stage
GITLEAKS_IMAGE=zricethezav/gitleaks:v8.30.1
HOST_RUBY_IMAGE=ruby:3.2.3-slim      # Busyyaks::CLI::MIN_RUBY's version (test/unit/cli_test.rb asserts they agree)
# the standalone tests of what runs on the host (none requires test_helper: no app, no gems)
HOST_TESTS=(test/unit/cli_test.rb test/integration/yaks_test.rb test/unit/env_file_test.rb test/unit/launcher_rules_test.rb
            test/unit/deploy_template_test.rb test/unit/install_launcher_test.rb test/unit/deploy_units_test.rb)

# Bind mounts are resolved by the Docker DAEMON. Under Jenkins this script runs inside the controller's container,
# talking to the host's daemon, so it needs the checkout's path on the HOST: the source of the container mount that
# holds $SRC (or any other path given). Not in a container → the path itself. Inside one with no such mount → fail;
# never guess a path.
host_path() {
  local path=$1 dest source
  if [ ! -f /.dockerenv ]; then echo "$path"; return; fi
  while IFS='|' read -r dest source; do
    [ -n "$dest" ] || continue
    case "$path/" in "$dest"/*) echo "$source${path#"$dest"}"; return ;; esac
  done < <(docker inspect "$(hostname)" --format '{{range .Mounts}}{{.Destination}}|{{.Source}}{{"\n"}}{{end}}')
  echo "ci: $path is not on any mount of container $(hostname) — cannot hand it to the Docker daemon" >&2
  exit 1
}
HOST_SRC=$(host_path "$SRC")

# The daemon's socket, as the compose container gets it: DOCKER_HOST's unix:// path when set (a rootless daemon's
# /run/user/<uid>/docker.sock), else the default /var/run/docker.sock. Any other DOCKER_HOST (tcp://, ssh://) cannot be
# handed into a container as a socket → fail, never guess.
docker_socket() {
  case "${DOCKER_HOST:-}" in
    '') echo /var/run/docker.sock ;;
    unix://*) echo "${DOCKER_HOST#unix://}" ;;
    *) echo "ci: DOCKER_HOST=$DOCKER_HOST is not a unix:// socket — the compose container needs one to mount" >&2; exit 1 ;;
  esac
}
DOCKER_SOCKET=$(docker_socket)

# Rootful daemon: container root is host root, so whatever a run writes into the bind-mounted checkout as root is
# handed back to the caller (id -u/-g) afterwards. Rootless daemon: container root IS the caller on the host, so root-
# written files already belong to the caller; only files written as a NON-root uid inside a container (the caller's
# uid in there maps to a subordinate uid on the host) need handing back, as 0:0. No answer from the daemon → fail here,
# never assume rootful.
DOCKER_SECURITY=$(docker info --format '{{json .SecurityOptions}}') || {
  echo "ci: docker info failed — no Docker daemon to run the gates on (DOCKER_HOST=${DOCKER_HOST:-unset})" >&2; exit 1
}
case "$DOCKER_SECURITY" in
  *name=rootless*) ROOTLESS=1 ;;
  *) ROOTLESS= ;;
esac

# Root-written files under the given checkout paths (default: all of it) back to the caller. Rootless: a no-op (they are
# the caller's already). Every suite runs this at its end, while the others may still run: on a rootless daemon it must
# not touch another suite's files, so there it never runs over the whole tree.
chown_back() {
  [ -z "$ROOTLESS" ] || return 0
  docker run --rm -v "$HOST_SRC:/w" "$COMPOSE_IMAGE" chown -R "$(id -u):$(id -g)" /w
}

# One name per run: concurrent builds of different branches must not share a compose project or an image tag.
RUN_ID=$(printf '%s' "${BUILD_TAG:-local-$$}" | tr -c 'a-zA-Z0-9_-' '-' | tr '[:upper:]' '[:lower:]')
PROJECT="busyyaks-ci-${RUN_ID}"

# the daemon's socket goes into this container: root-equivalent on the host when the daemon is rootful (see Trust above)
# $1 = the run's compose project + tmp dir name; the rest = compose args
compose() {
  local name=$1; shift
  docker run --rm -v "$DOCKER_SOCKET:/var/run/docker.sock" -v "$HOST_SRC:$HOST_SRC" -w "$HOST_SRC" \
    "$COMPOSE_IMAGE" docker compose -p "$name" --env-file "tmp/ci/$name/compose.env" \
    -f docker-compose.yml -f "tmp/ci/$name/compose.ci.yml" "$@"
}

# The compose `test` service (with its test-postgres) on SQLite (no argument) or on PostgreSQL (`pg`).
ruby_compose() {
  local pg=${1:-} name
  name="$PROJECT-$([ -n "$pg" ] && echo pg || echo sqlite)"
  # Compose interpolates the whole file, and the live services' `${VAR:?}` refuse an empty value. The test service
  # sets its own environment, so the live wiring only has to be present: .env.example's keys (every one must be
  # listed there), the empty secrets filled with a marker no service run here reads.
  mkdir -p "tmp/ci/$name"
  sed -E 's/^([A-Z0-9_]+)=$/\1=ci-unused/' .env.example > "tmp/ci/$name/compose.env"
  # This run's own image tag instead of busyyaks:test (two branches building at once would swap each other's image).
  {
    printf 'services:\n  test:\n    image: busyyaks:%s\n' "$name"
    [ -z "$pg" ] || printf '    environment:\n      DATABASE_ADAPTER: postgresql\n'
  } > "tmp/ci/$name/compose.ci.yml"

  local status=0
  compose "$name" --profile test run --rm --build test || status=$?
  compose "$name" --profile test down --volumes --remove-orphans >/dev/null 2>&1 || true
  docker image rm "busyyaks:$name" >/dev/null 2>&1 || true
  # the suite ran as root on the bind-mounted checkout
  chown_back
  rm -rf "tmp/ci/$name"
  return $status
}

ruby_suite() {
  ruby_compose
}

ruby-pg_suite() {
  local status=0
  ruby_compose pg || status=$?
  [ "$status" -ne 0 ] || pg_compose_smoke || status=$?
  return $status
}

# The compose `postgres` service as a deployment runs it: as HOST_UID (this user), its cluster and socket in the data
# dir (here this run's own tmp/ci/<name>/data, never ./data: the override below replaces both mounts), no network,
# scram auth; the app as HOST_UID through bin/entrypoint reaching the socket through its /data mount — migrate, write a
# card + comment (test/support/compose_smoke.rb), and a wrong password refused.
pg_compose_smoke() {
  local name="$PROJECT-pgsmoke" status=0 out
  mkdir -p "tmp/ci/$name/data/postgres" "tmp/ci/$name/data/postgres-run" "tmp/ci/$name/log"
  sed -E -e 's/^([A-Z0-9_]+)=$/\1=ci-unused/' -e 's/^DATABASE_ADAPTER=.*/DATABASE_ADAPTER=postgresql/' \
    -e 's#^POSTGRES_HOST=.*#POSTGRES_HOST=/data/postgres-run#' -e 's/^POSTGRES_PORT=.*/POSTGRES_PORT=5432/' \
    -e 's/^POSTGRES_DB=.*/POSTGRES_DB=smoke/' -e 's/^POSTGRES_USER=.*/POSTGRES_USER=smoke/' \
    -e 's/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=smoke-pw/' -e 's/^POSTGRES_LOCK_TIMEOUT_MS=.*/POSTGRES_LOCK_TIMEOUT_MS=15000/' \
    -e "s/^HOST_UID=.*/HOST_UID=$(id -u)/" -e "s/^HOST_GID=.*/HOST_GID=$(id -g)/" .env.example > "tmp/ci/$name/compose.env"
  # the test service as a live service: the host user, /data checked (the socket inside it), the live services' DB keys
  cat > "tmp/ci/$name/compose.ci.yml" <<YML
services:
  postgres:
    volumes: ["./tmp/ci/$name/data/postgres:/var/lib/postgresql/data", "./tmp/ci/$name/data/postgres-run:/var/run/postgresql"]
  test:
    image: busyyaks:$name
    user: "$(id -u):$(id -g)"
    volumes: [".:/app", "/app/public/app", "./tmp/ci/$name/data:/data", "./tmp/ci/$name/log:/app/log"]
    environment:
      HOME: /tmp
      DATA_DIR: /data
      DATABASE_ADAPTER: postgresql
      POSTGRES_HOST: /data/postgres-run
      POSTGRES_PORT: "5432"
      POSTGRES_DB: smoke
      POSTGRES_USER: smoke
      POSTGRES_PASSWORD: smoke-pw
      POSTGRES_LOCK_TIMEOUT_MS: "15000"
YML
  # postgres and the app run as HOST_UID = this user's uid. On a rootless daemon that uid inside a container maps to a
  # subordinate uid on the host, so this run's own dir (data + the app's log, mounted over /app/log above) is handed to
  # it first and back to the caller (0:0 inside) at the end — never anything outside it: other suites run meanwhile
  [ -z "$ROOTLESS" ] || docker run --rm -v "$HOST_SRC/tmp/ci/$name:/d" "$COMPOSE_IMAGE" chown -R "$(id -u):$(id -g)" /d
  compose "$name" --profile postgres up -d --wait postgres || status=$?
  if [ "$status" -eq 0 ]; then
    compose "$name" --profile test run --rm --build test sh -c \
      'bundle exec hanami db migrate --no-dump && bundle exec ruby test/support/compose_smoke.rb' || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    if out=$(compose "$name" --profile test run --rm -e POSTGRES_PASSWORD=wrong test bundle exec ruby test/support/compose_smoke.rb 2>&1); then
      echo "smoke: a wrong password connected" >&2; status=1
    elif ! grep -q "password authentication failed" <<<"$out"; then
      echo "smoke: a wrong password failed for another reason:" >&2; echo "$out" >&2; status=1
    else
      echo "smoke: a wrong password is refused (password authentication failed)"
    fi
  fi
  compose "$name" --profile postgres --profile test down --volumes --remove-orphans >/dev/null 2>&1 || true
  docker image rm "busyyaks:$name" >/dev/null 2>&1 || true
  if [ -n "$ROOTLESS" ]; then
    docker run --rm -v "$HOST_SRC/tmp/ci/$name:/d" "$COMPOSE_IMAGE" chown -R 0:0 /d
  else
    chown_back
  fi
  rm -rf "tmp/ci/$name"
  return $status
}

frontend_suite() {
  # read-only source, frontend/ copied in without node_modules: npm ci never touches the checkout. public/static beside
  # it, as in the checkout: a test runs public/static/skin.js (the skin choice, outside the bundle). Prettier reads the
  # whole repo in place (read-only; it never writes with --check) with the copy's node_modules: the same files and glob
  # as `npm run format:check`, .gitignore + .prettierignore applied (Prettier's default ignore files, read from /repo)
  docker run --rm -v "$HOST_SRC:/repo:ro" "$NODE_IMAGE" sh -euc '
    mkdir -p /w/frontend /w/public && cd /repo/frontend && tar cf - --exclude=./node_modules . | tar xf - -C /w/frontend
    cp -r /repo/public/static /w/public/static && cd /w/frontend
    npm ci --no-audit --no-fund
    npx tsc --noEmit
    npm run lint
    (cd /repo && /w/frontend/node_modules/.bin/prettier --check "**/*.{ts,tsx,js,css,json}")
    npx vitest run --maxWorkers="$(nproc)"'
}

lint_suite() {
  local status=0
  LINT_SRC=$HOST_SRC scripts/lint/rubocop --format simple || status=1
  LINT_SRC=$HOST_SRC scripts/lint/shellcheck || status=1
  return $status
}

audit_suite() {
  local status=0 tag
  tag=$(scripts/lint/image)
  docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$HOST_SRC:/src:ro" --entrypoint bundle "$tag" \
    exec bundle-audit check --update /src || status=1
  # the image's libgit2 (Dockerfile ARG) against libgit2's security releases: not in any advisory db
  docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$HOST_SRC:/src:ro" --entrypoint ruby "$tag" \
    /src/scripts/ci/libgit2-audit.rb /src/Dockerfile || status=1
  # the lockfile alone is audited: nothing installed, nothing written to the checkout
  docker run --rm -v "$HOST_SRC/frontend:/src:ro" "$NODE_IMAGE" sh -euc '
    mkdir /w && cp /src/package.json /src/package-lock.json /w && cd /w
    npm audit --audit-level=low' || status=1
  return $status
}

# gitleaks over the WHOLE git history: every commit on every ref the checkout has, not just the
# tree. Any finding fails it — a leaked secret is rotated and removed, never allowlisted: an in-repo .gitleaks.toml /
# .gitleaksignore (gitleaks would read either from the scanned repo) is refused, and `gitleaks:allow` comments are
# ignored. A shallow checkout cannot show the history, so it fails rather than scan part of it.
secrets_suite() {
  if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    echo "secrets: shallow checkout ($(git rev-list --count HEAD) commits) — the full history is not here to scan" >&2
    return 1
  fi
  local own common
  own=$(git ls-files | grep -E '(^|/)\.gitleaks(\.toml|ignore)$' || true)
  if [ -n "$own" ]; then
    echo "secrets: refused — $own in the tree; findings are fixed, never allowlisted" >&2
    return 1
  fi
  # a git worktree's .git is a file pointing at the main checkout's git dir: mount that too, at its own path
  local mounts=(-v "$HOST_SRC:/repo:ro")
  common=$(git rev-parse --path-format=absolute --git-common-dir)
  case "$common/" in "$SRC"/*) ;; *) mounts+=(-v "$(host_path "$common"):$common:ro") ;; esac
  echo "secrets: $GITLEAKS_IMAGE over $(git rev-list --all --no-merges --count) commits (merges carry no diff of their own)"
  # -w /tmp: no .gitleaksignore is read from the working dir; safe.directory: the checkout belongs to another uid
  docker run --rm -u "$(id -u):$(id -g)" -w /tmp "${mounts[@]}" \
    -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
    "$GITLEAKS_IMAGE" git --redact --verbose --no-banner --exit-code 1 --ignore-gitleaks-allow /repo
}

# The host-side programs' tests on the oldest host Ruby (read-only source; each test writes under its own tmpdir)
host_suite() {
  docker run --rm -v "$HOST_SRC:/src:ro" -w /src "$HOST_RUBY_IMAGE" sh -euc '
    ruby -v
    for f in "$@"; do echo "== $f"; ruby -Ilib -Itest "$f"; done' host "${HOST_TESTS[@]}"
}

# The given suites at once. Each one's output goes to its own log (interleaved lines would be unreadable), printed
# whole once every suite has finished, with its exit status.
all_suites() {
  local logs name failed=0 status
  local -A pid
  logs=$(mktemp -d)
  for name in "$@"; do "${name}_suite" > "$logs/$name.log" 2>&1 & pid[$name]=$!; done
  for name in "$@"; do
    status=0; wait "${pid[$name]}" || status=$?
    echo "════ $name (exit $status) ════"; cat "$logs/$name.log"
    [ "$status" -eq 0 ] || failed=1
    echo "$name exit $status" >> "$logs/summary"
  done
  echo "ci: $(paste -sd ',' "$logs/summary" | sed 's/,/ · /g')"
  rm -rf "$logs"
  return $failed
}

case "${1:-}" in
  lint) lint_suite ;;
  ruby) ruby_suite ;;
  ruby-pg) ruby-pg_suite ;;
  frontend) frontend_suite ;;
  audit) audit_suite ;;
  secrets) secrets_suite ;;
  host) host_suite ;;
  changelog) scripts/ci/changelog "${CHANGELOG_BASE:?CHANGELOG_BASE is not set — the ref the pull request merges into, e.g. origin/main}" ;;
  all) all_suites lint ruby ruby-pg frontend audit secrets host ;;
  *) echo "usage: $0 lint|ruby|ruby-pg|frontend|audit|secrets|host|changelog|all" >&2; exit 2 ;;
esac
