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
#   scripts/ci/test.sh host       the host-side programs' tests (bin/yaks, bin/env, bin/setup, the launcher's rules,
#                                 the installers), then the README Quickstart replayed without Ruby
#                                 (scripts/ci/quickstart-test, in the docker CLI image)
#                                 on the OLDEST host Ruby they support (HOST_RUBY_IMAGE = Busyyaks::CLI::MIN_RUBY):
#                                 a construct newer than that passes the suite's Ruby 3.4 and breaks on the host
#   scripts/ci/test.sh flake      the flake gate: every test file the change touches (vs CI_BASE_REF), plus
#                                 the tests that name a lib/bin/cli file it touches, each run CI_FLAKE_REPEATS times,
#                                 CI_RUNNER_CPUS runs at a time (rake test:repeat); any other changed or deleted path
#                                 repeats the whole suite; one red run of a file fails it:
#                                 "flaky: <file> failed k/N". CI_BASE_REF (env, required: a commit this checkout has) =
#                                 what the change is measured against — the PR's base, or the previous commit of a push
#   scripts/ci/test.sh all        lint, ruby, ruby-pg, frontend, flake, audit, secrets and host at once, each into its own
#                                 log, printed one after the other once all have finished; fails if any fails
#   scripts/ci/test.sh A B …      each named stage, one after the other in that order (every one runs, a red one too),
#                                 then `ci: A exit 0 · B exit 1`; fails naming each red stage. An unknown name, or `all`
#                                 beside another, is refused (exit 2) before anything runs
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
# The runner's shape: the ruby, ruby-pg, frontend and flake containers each get the public runner's CPU
# time (scripts/ci/runner.env CI_RUNNER_CPUS → docker --cpus N, a CFS quota on no fixed cores: concurrent Jenkins builds
# spread over the host, never all on the same N), and every CPU-sized count is N (vitest --maxWorkers, the flake waves),
# never the host's `nproc`. That matches CONTENTION, not the runner's slower cores or a shared VM's stalls; the guard
# against those is the clock rule (test/unit/no_real_clock_test.rb). The Ruby suite runs one worker process per test file
# (Rakefile test:parallel: I/O-bound), inside that quota.
#
# Nothing here writes to the checkout except the Ruby suite's own bind mount (the compose file mounts `.:/app`);
# whatever it leaves root-owned is handed back to the caller's uid afterwards, so a Jenkins workspace stays deletable.
set -euo pipefail

cd "$(dirname "$0")/../.."
SRC=$PWD

# The stages, in `all`'s order. The arguments are checked here, before any Docker call: every one must be a stage
# (`all` only alone) — a name that is not one never runs a subset quietly.
STAGES=(lint ruby ruby-pg frontend flake audit secrets host)
usage() { echo "usage: $0 all | STAGE... (stages: ${STAGES[*]}; several run one after the other)" >&2; exit 2; }
[ "$#" -gt 0 ] || usage
for arg in "$@"; do
  if [ "$arg" = all ]; then
    [ "$#" -eq 1 ] || { echo "ci: 'all' runs every stage: name it alone" >&2; usage; }
  else
    case " ${STAGES[*]} " in *" $arg "*) ;; *) echo "ci: unknown stage '$arg'" >&2; usage ;; esac
  fi
done

# scripts/ci/runner.env: the public runner's shape, the one place it is written. Only its two keys, each a positive
# integer; a missing file, key or value fails here — never a default.
RUNNER_ENV=scripts/ci/runner.env
[ -f "$RUNNER_ENV" ] || { echo "ci: $RUNNER_ENV is missing — the runner's shape (CI_RUNNER_CPUS, CI_FLAKE_REPEATS)" >&2; exit 1; }
CI_RUNNER_CPUS='' CI_FLAKE_REPEATS=''
while IFS= read -r line; do
  case "$line" in
    '' | '#'*) ;;
    CI_RUNNER_CPUS=* | CI_FLAKE_REPEATS=*) printf -v "${line%%=*}" '%s' "${line#*=}" ;;
    *) echo "ci: $RUNNER_ENV: unknown line: $line" >&2; exit 1 ;;
  esac
done < "$RUNNER_ENV"
for key in CI_RUNNER_CPUS CI_FLAKE_REPEATS; do
  [[ "${!key}" =~ ^[1-9][0-9]*$ ]] || { echo "ci: $RUNNER_ENV: $key must be a positive integer (is '${!key}')" >&2; exit 1; }
done
CPU_QUOTA="$((CI_RUNNER_CPUS * 100000)) 100000"   # what cgroup v2 cpu.max reads in a container given --cpus N
COMPOSE_IMAGE=docker:28.5.2-cli      # carries the compose plugin (the Jenkins controller's docker CLI has none)
NODE_IMAGE=node:22-bookworm-slim     # the Dockerfile's frontend stage
GITLEAKS_IMAGE=zricethezav/gitleaks:v8.30.1
HOST_RUBY_IMAGE=ruby:3.2.3-slim      # Busyyaks::CLI::MIN_RUBY's version (test/unit/cli_test.rb asserts they agree)
# the standalone tests of what runs on the host (none requires test_helper: no app, no gems)
HOST_TESTS=(test/unit/cli_test.rb test/unit/cli_remote_test.rb test/unit/cli_chooser_test.rb test/integration/yaks_test.rb test/unit/env_file_test.rb
            test/unit/launcher_rules_test.rb test/unit/deploy_template_test.rb test/unit/install_launcher_test.rb test/unit/deploy_units_test.rb
            test/unit/collector_test.rb test/unit/install_collector_test.rb test/integration/collector_test.rb
            test/unit/setup_test.rb test/unit/ci_stages_test.rb test/unit/ci_settings_test.rb
            test/unit/skills_test.rb test/unit/no_global_skill_test.rb)

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

# The stages that run on the runner's CPU quota (ruby, ruby-pg, frontend, flake) ask this before they start anything;
# the others (lint, audit, secrets, host) use no quota and run on any host. The runner's CPUs must exist on the daemon's
# host: fewer → refused, never a smaller pin. And the daemon must APPLY the quota: a rootless dockerd whose user manager was not delegated the cpu controller drops
# --cpus with only a warning and runs unlimited. Asked once per stage that limits, before it starts anything. The probe's
# image is pulled first (a fresh image cache printed its pull progress where cpu.max was read), and
# only the run's STDOUT is the measurement: exactly `<quota> <period>` (or `max <period>`), else "could not read".
require_pin() {
  local got err cpus
  cpus=$(docker info --format '{{.NCPU}}')
  if [ "$cpus" -lt "$CI_RUNNER_CPUS" ]; then
    echo "ci: the Docker host has $cpus CPUs, the runner's shape needs $CI_RUNNER_CPUS ($RUNNER_ENV)" >&2
    return 1
  fi
  err=$(mktemp)
  if ! docker pull -q "$COMPOSE_IMAGE" > /dev/null 2> "$err"; then
    echo "ci: could not pull $COMPOSE_IMAGE for the CPU-quota probe: $(cat "$err")" >&2
    rm -f "$err"; return 1
  fi
  if ! got=$(docker run --rm --cpus "$CI_RUNNER_CPUS" "$COMPOSE_IMAGE" cat /sys/fs/cgroup/cpu.max 2> "$err"); then
    echo "ci: the CPU-quota probe did not run: $(cat "$err")" >&2
    rm -f "$err"; return 1
  fi
  if ! [[ "$got" =~ ^(max|[0-9]+)\ [0-9]+$ ]]; then
    echo "ci: could not read cpu.max from the CPU-quota probe: '$got'" >&2
    rm -f "$err"; return 1
  fi
  if [ "$got" != "$CPU_QUOTA" ]; then
    echo "ci: the Docker daemon did not limit a container to $CI_RUNNER_CPUS CPUs (cpu.max in it: '$got', want" \
      "'$CPU_QUOTA'; docker said: '$(tr '\n' ' ' < "$err")') — a rootless dockerd needs the cpu controller delegated to" \
      "its user manager" >&2
    rm -f "$err"; return 1
  fi
  rm -f "$err"
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

# The compose `test` service (with its test-postgres) on SQLite (no argument), on PostgreSQL (`pg`), or running the
# flake gate's repeats (`flake <files>`), both containers given the runner's CPUs (a quota).
ruby_compose() {
  local mode=${1:-sqlite} name
  [ "$#" -eq 0 ] || shift
  require_pin || return 1
  name="$PROJECT-$mode"
  # Compose interpolates the whole file, and the live services' `${VAR:?}` refuse an empty value. The test service
  # sets its own environment, so the live wiring only has to be present: .env.example's keys (every one must be
  # listed there), the empty values filled with a marker no service run here reads — an absolute path, since some are
  # bind-mount sources (PROJECTS_ROOT, LAUNCHER_RUN_DIR: empty in .env.example) and a bare word there is a
  # named volume compose refuses.
  mkdir -p "tmp/ci/$name"
  sed -E 's#^([A-Z0-9_]+)=$#\1=/ci-unused#' .env.example > "tmp/ci/$name/compose.env"
  # This run's own image tag instead of busyyaks:test (two branches building at once would swap each other's image).
  {
    # MT_CPU: minitest's thread pool per test process is the runner's CPUs, never the host's nproc (a quota leaves nproc
    # at the host's 32: 83 workers × 32 threads ran out of the Jenkins agent's tasks)
    # TEST_WORKERS: test:parallel's test processes at a time = the runner's CPUs
    printf 'services:\n  test:\n    image: busyyaks:%s\n    cpus: %s\n    environment:\n      MT_CPU: "%s"\n      TEST_WORKERS: "%s"\n' \
      "$name" "$CI_RUNNER_CPUS" "$CI_RUNNER_CPUS" "$CI_RUNNER_CPUS"
    case "$mode" in
      pg) printf '      DATABASE_ADAPTER: postgresql\n' ;;
      flake) printf '      TEST_REPEAT_TIMES: "%s"\n      TEST_REPEAT_WORKERS: "%s"\n      TEST_REPEAT_FILES: "%s"\n' \
               "$CI_FLAKE_REPEATS" "$CI_RUNNER_CPUS" "$*"   # at most one test process per runner CPU
             printf '    command: ["bundle", "exec", "rake", "test:repeat"]\n' ;;
    esac
    printf '  test-postgres:\n    cpus: %s\n' "$CI_RUNNER_CPUS"
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
  sed -E -e 's#^([A-Z0-9_]+)=$#\1=/ci-unused#' -e 's/^DATABASE_ADAPTER=.*/DATABASE_ADAPTER=postgresql/' \
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
  require_pin || return 1
  # read-only source, frontend/ copied in without node_modules: npm ci never touches the checkout. public/static beside
  # it, as in the checkout: a test runs public/static/skin.js (the skin choice, outside the bundle); skins/ too: the
  # waiting widget's contrast test reads the skin tokens. Prettier reads the
  # whole repo in place (read-only; it never writes with --check) with the copy's node_modules: the same files and glob
  # as `npm run format:check`, .gitignore + .prettierignore applied (Prettier's default ignore files, read from /repo)
  docker run --rm --cpus "$CI_RUNNER_CPUS" -e "CI_RUNNER_CPUS=$CI_RUNNER_CPUS" -v "$HOST_SRC:/repo:ro" "$NODE_IMAGE" sh -euc '
    mkdir -p /w/frontend /w/public && cd /repo/frontend && tar cf - --exclude=./node_modules . | tar xf - -C /w/frontend
    cp -r /repo/public/static /w/public/static && cp -r /repo/skins /w/skins && cd /w/frontend
    mkdir -p /w/scripts && cp -r /repo/scripts/readme-images /w/scripts/readme-images   # rename.js: readmeImages.test.ts
    npm ci --no-audit --no-fund
    npx tsc --noEmit
    npm run lint
    (cd /repo && /w/frontend/node_modules/.bin/prettier --check "**/*.{ts,tsx,js,css,json}")
    npx vitest run --maxWorkers="$CI_RUNNER_CPUS"'
}

# The flake gate: what the change touches, run CI_FLAKE_REPEATS times, CI_RUNNER_CPUS runs at a time. Fails
# CLOSED: every changed path must be one this maps — a changed test file (test/**/*_test.rb) selects itself; a lib/**/*.rb,
# bin/<x> or cli/**/<x>.rb selects the test files that name it (its path `busyyaks/<x>` or its constant; "bin/<x>";
# "<x>.rb"), and naming none selects the whole suite. Any other path (app/, config/, test/support/, docs, the SPA,
# Rakefile, Gemfile, Dockerfile …) selects the whole suite: Ruby tests read docs, fixtures and the SPA's files too, so no
# path is assumed test-free. A DELETED path other than a test file selects the whole suite too (no test names it any
# more: the tests that used it are the ones to repeat, and nothing says which). Only an empty diff repeats nothing.
# A heuristic, not coverage: a lib file exercised only through the app (an integration test that never names it) does
# not select that test — the ruby / ruby-pg stages still run every test once.
flake_suite() {
  [ -n "${CI_BASE_REF:-}" ] || { echo "flake: CI_BASE_REF is not set — the commit the change is measured against" >&2; return 1; }
  local base changed=() deleted=() picked=() named=() f stem const all=
  base=$(git rev-parse --verify --quiet "$CI_BASE_REF^{commit}") || {
    echo "flake: CI_BASE_REF=$CI_BASE_REF is not a commit this checkout has" >&2; return 1
  }
  base=$(git merge-base "$base" HEAD)
  mapfile -t changed < <(git diff --name-only --diff-filter=d "$base" HEAD)
  mapfile -t deleted < <(git diff --name-only --diff-filter=D "$base" HEAD)
  for f in "${deleted[@]}"; do
    case "$f" in
      test/*_test.rb) ;;
      *) echo "flake: $f was deleted — the whole suite is repeated"; all=1 ;;
    esac
  done
  for f in "${changed[@]}"; do
    named=()
    case "$f" in
      test/*_test.rb) picked+=("$f"); continue ;;
      lib/*.rb)
        stem=${f#lib/}; stem=${stem%.rb}
        const=$(basename "$stem" | sed -E 's/(^|_)([a-z0-9])/\U\2/g')
        mapfile -t named < <(git grep -l -E "(^|[^A-Za-z0-9_])($const([^A-Za-z0-9_]|$)|$stem([^A-Za-z0-9_]|$))" HEAD -- 'test/*_test.rb' | sed 's/^HEAD://') ;;
      bin/*)
        mapfile -t named < <(git grep -l -F "$f" HEAD -- 'test/*_test.rb' | sed 's/^HEAD://') ;;
      cli/*.rb)
        mapfile -t named < <(git grep -l -F "$(basename "$f")" HEAD -- 'test/*_test.rb' | sed 's/^HEAD://') ;;
      *)
        echo "flake: $f maps to no test file — the whole suite is repeated"; all=1; continue ;;
    esac
    if [ "${#named[@]}" -eq 0 ]; then echo "flake: no test file names $f — the whole suite is repeated"; all=1; fi
    picked+=("${named[@]}")
  done
  [ -z "$all" ] || mapfile -t picked < <(git ls-files 'test/*_test.rb' 'auth/*/test/*_test.rb')
  mapfile -t picked < <(printf '%s\n' "${picked[@]}" | sed '/^$/d' | sort -u)
  echo "flake: $((${#changed[@]} + ${#deleted[@]})) files changed since $(git rev-parse --short "$base") ($CI_BASE_REF); ${#picked[@]} test files × $CI_FLAKE_REPEATS, $CI_RUNNER_CPUS at a time on $CI_RUNNER_CPUS CPUs"
  if [ $((${#changed[@]} + ${#deleted[@]})) -eq 0 ]; then echo "flake: nothing changed — nothing to repeat"; return 0; fi
  if [ "${#changed[@]}" -eq 0 ] && [ -z "$all" ]; then echo "flake: only test files were deleted — nothing to repeat"; return 0; fi
  [ "${#picked[@]}" -gt 0 ] || { echo "flake: $((${#changed[@]} + ${#deleted[@]})) files changed and no test file was found to repeat" >&2; return 1; }
  printf '  %s\n' "${picked[@]}"
  ruby_compose flake "${picked[@]}"
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
  # the image's libgit2 (Dockerfile ARG) against libgit2's security releases: not in any advisory db. GitHub's API with
  # CI_GITHUB_READ_TOKEN (required: never anonymous — one IP's 60/h is shared by every build on the host), handed in by
  # NAME (`-e VAR`: the value never on a command line), pages asked with their kept ETag (a 304 costs nothing) from
  # CI_GITHUB_CACHE_DIR (required, the caller's: Jenkins the agent user's home, GitHub the job's temp dir — wiped per
  # job, so a full read each run —, a local run its own; .env.example). The container writes it: as the caller (rootful) or as container root = the caller (rootless)
  if [ -z "${CI_GITHUB_READ_TOKEN:-}" ]; then
    echo "audit: CI_GITHUB_READ_TOKEN is not set — a read-only GitHub token for the libgit2 release list (.env.example)" >&2
    status=1
  elif [ -z "${CI_GITHUB_CACHE_DIR:-}" ]; then
    echo "audit: CI_GITHUB_CACHE_DIR is not set — the dir that keeps the release list's ETags (.env.example)" >&2
    status=1
  else
    local user
    mkdir -p "$CI_GITHUB_CACHE_DIR"
    if [ -n "$ROOTLESS" ]; then user=0:0; else user="$(id -u):$(id -g)"; fi
    docker run --rm -u "$user" -e HOME=/tmp -e CI_GITHUB_READ_TOKEN -v "$HOST_SRC:/src:ro" \
      -v "$(host_path "$(cd "$CI_GITHUB_CACHE_DIR" && pwd)"):/cache" \
      --entrypoint ruby "$tag" /src/scripts/ci/libgit2-audit.rb /src/Dockerfile /cache || status=1
  fi
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
    for f in "$@"; do echo "== $f"; ruby -Ilib -Itest "$f"; done' host "${HOST_TESTS[@]}" || return
  # the README Quickstart's steps before the browser, replayed where there is NO Ruby: the docker
  # CLI image (busybox sh, git, compose — it reads .env for real; no daemon asked), as a non-root user like a reader
  echo "== scripts/ci/quickstart-test (no Ruby: $COMPOSE_IMAGE)"
  # HOME: a dir of that user's whose ancestors no one else can write (LAUNCHER_RUN_DIR goes under it; /tmp is refused)
  docker run --rm -u 1000:1000 --tmpfs /home/you:exec,uid=1000,gid=1000,mode=0755 -e HOME=/home/you -v "$HOST_SRC:/src:ro" \
    "$COMPOSE_IMAGE" sh /src/scripts/ci/quickstart-test /src
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

# The named stages one after the other, each on the terminal as it runs; every one runs, then the summary line. Each in
# its own process (as in all_suites): a function called in an `||` list would run with `set -e` switched off.
run_stages() {
  local name status failed=() summary=()
  for name in "$@"; do
    echo "════ $name ════"
    status=0; "${name}_suite" & wait $! || status=$?
    summary+=("$name exit $status")
    [ "$status" -eq 0 ] || failed+=("$name")
  done
  echo "ci: $(printf '%s\n' "${summary[@]}" | paste -sd ',' | sed 's/,/ · /g')"
  [ "${#failed[@]}" -eq 0 ] || { echo "ci: failed: ${failed[*]}" >&2; return 1; }
}

if [ "$1" = all ]; then
  all_suites "${STAGES[@]}"
elif [ "$#" -eq 1 ]; then
  "${1}_suite"
else
  run_stages "$@"
fi
