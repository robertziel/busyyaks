# Tests

Docker only; nothing is installed on the host.

```bash
scripts/ci/test.sh all                 # lint · ruby · ruby-pg · frontend · audit · secrets, at once, logs kept apart
scripts/ci/test.sh ruby                # one stage: lint | ruby | ruby-pg | frontend | audit | secrets
docker compose run --rm --build test; s=$?; docker compose --profile test rm -sfv test-postgres; (exit $s)   # the Ruby suite only (its exit status kept), then its test-postgres (never `down`: it would stop the stack)
```

| Stage | Runs |
|---|---|
| `lint` | RuboCop (Cookpad's style guide, [`LINT.md`](LINT.md)) and ShellCheck over every shell script |
| `ruby` | the minitest suite in the compose `test` service, on SQLite (the public default); its `test-postgres` is up too, as the SQLite → PostgreSQL copy test's target |
| `ruby-pg` | the same suite on PostgreSQL: the `test` service's `test-postgres` (`postgres:16.10-alpine`, data on tmpfs; the test service runs in its network namespace), `DATABASE_ADAPTER=postgresql`; the coverage floor holds on both. Then a smoke over the compose `postgres` service as a deployment runs it (HOST_UID, Unix socket, scram, a wrong password refused) |
| `frontend` | `tsc`, ESLint, Prettier and vitest in `frontend/` |
| `audit` | `bundle-audit check --update` + `npm audit --audit-level=low`; any advisory fails, fixed by upgrading |
| `secrets` | gitleaks over the history |
| `changelog` | pull requests only, `CHANGELOG_BASE=<target ref>`: the PR adds a `- ` line under `## [Unreleased]` in CHANGELOG.md and every Unreleased entry is one line (`scripts/ci/changelog`; Jenkins fetches the target first, GitHub Actions runs it on `pull_request`) |

- The `test` service builds its own image (`busyyaks:test`), never the live `busyyaks:local`, so running the tests
  never restarts or migrates a running deployment.
- **Every CPU**: the Ruby suite runs `rake test:parallel`, one worker process per test file (the suite mostly waits on
  I/O, so the OS shares the CPUs), each on its own copy of a once-migrated database (SQLite: a file copy; PostgreSQL: `CREATE DATABASE <db>_w<i> TEMPLATE <db>_template`, dropped after; `test/support/test_databases.rb`), attachments dir and launcher
  socket, all in a RAM `/tmp` (on disk every table wipe waits on fsync). `rake test` = the same files serially,
  unmeasured (`TEST=<file>` for one). vitest runs with `--maxWorkers=$(nproc)`.
- **Coverage**: every `rake test:parallel` worker records SimpleCov line + branch coverage of `app/ config/ lib/ auth/`
  (tests and `vendor/` left out); the merged result is printed (`coverage: line … · branch …`) and the run fails below
  the floor in `test/support/coverage.rb` (line 95 % / branch 84 %, raised as the suite covers more, never lowered) or
  when nothing was measured.
- **CI**: two runners, one script. [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs
  `scripts/ci/test.sh all` on `ubuntu-latest` for every pull request (forks included) and every push to `main` —
  the public check, `gates` (workflow `ci`). It runs on public repositories only: a private copy (the maintainer's private local repo, a
  private fork) skips the job, so it spends no Actions minutes, unless the repository variable `CI_ON_PRIVATE` is
  `true`; while a repository is private the check shows as skipped, and a skipped check satisfies a required one,
  so there `gates` is required only with `CI_ON_PRIVATE` set. The [`Jenkinsfile`](../Jenkinsfile) is the maintainer's runner: a Jenkins multibranch job reporting the
  status `jenkins/ci` to GitHub, and the only one that updates the badges. Any CI that can run Docker can run the
  script.
- **Trust**: the script needs the Docker daemon, and access to it is root on that host. The `ruby` stage also mounts
  the daemon's socket (`/var/run/docker.sock`) into a container (compose, `docker:*-cli`) that builds the checkout's
  `Dockerfile` and runs its code as root with the checkout bind-mounted. Run it only on code you would run as root, on
  a disposable machine (a GitHub-hosted runner) or a CI host that builds trusted branches only — never a stranger's
  fork on a host you care about.
- **Gate scripts' tests**: `test/unit/ci_gates_test.rb` drives `scripts/ci/test.sh` and `scripts/hooks/run` against
  throwaway git repos with a stub `docker`, and checks every refusal: a shallow clone, an in-tree `.gitleaks.toml` /
  `.gitleaksignore`, a checkout on no mount of the container, no `docker`, `extensions.worktreeConfig` off — each fails
  before any container starts —, the argv a passing run hands to Docker, and that a failing container fails its stage
  (`audit`: either half) and `all`.
- **Badges**: the README's tests / coverage / branch-coverage badges show the last green build of the default branch.
  After the gates pass there (never on another branch), `scripts/ci/badges` reads the Ruby suite's `TOTAL … runs` and
  `coverage: …` lines and vitest's `Tests … passed` from that build's logs and writes shields.io endpoint JSON into a
  public gist (`Jenkinsfile` `BADGE_GIST_ID`, with the Secret Text credential `BADGE_CREDENTIAL`, a token with `gist`
  scope). A missing line or a refused update fails the build. A fork points both at its own gist, or the badges stay
  upstream's.

## README images

The screenshots and SVGs in both READMEs (this repo's `docs/images/` and the kanban module's) are generated, never
taken from a real deployment:

```sh
# a throwaway stack built from this checkout: acme/* repos with a year of commits by dev@example.com and a teammate,
# auth none on 127.0.0.1, stand-in tmux sessions and agent-session collector (scripts/readme-images/collector)
README_DEMO_WEB_PORT=18241 README_DEMO_MCP_PORT=18242 scripts/readme-images/demo-stack up /tmp/rd
# seed it (the board through the MCP tools + operator API, the merged PRs into the demo DB), capture every screenshot in
# the light skin — the module's with its part outlined and the host dimmed — and check every captured word against the
# term lists; writes docs/images/*.webp here and <module checkout>/docs/images/*.webp
PRIVATE_TERMS=.private-terms:<module checkout>/.private-terms scripts/readme-images/build /tmp/rd <module checkout>
scripts/readme-images/demo-stack down /tmp/rd && rm -rf /tmp/rd
# the SVGs: How it works on its light plate, the module's logo-{light,dark}.svg pair; with the article's saved HTML
# also the agency figure — the page is
# not committed: save it first, curl does not run its analytics:
#   curl -sS -o /tmp/article.html https://robertz.co/feeds/architecture/how-i-reached-100-prs-a-day/)
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/w -v <module checkout>:/module -w /w python:3.13-slim \
  python scripts/readme-images/svgs.py /module [<article page.html>]
```

The workdir path must stay under 80 bytes (the collector's unix socket lives in it). `build` refuses to write any image
when a term is in the captured text, in the scripts, in the SVGs or in the READMEs, or when an image is over 400 KB.
