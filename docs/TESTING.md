# Tests

Docker only; nothing is installed on the host.

```bash
# every stage at once, logs kept apart; the env: below the table
CI_BASE_REF=origin/main CI_GITHUB_READ_TOKEN=$(gh auth token) CI_GITHUB_CACHE_DIR=~/.cache/busyyaks-ci scripts/ci/test.sh all
scripts/ci/test.sh ruby                # one stage: lint | ruby | ruby-pg | frontend | flake | audit | secrets | host
scripts/ci/test.sh lint frontend       # several: one after the other, each runs; fails naming the red ones (a typo: exit 2)
docker compose run --rm --build test; s=$?; docker compose --profile test rm -sfv test-postgres; (exit $s)   # the Ruby suite only (its exit status kept), then its test-postgres (never `down`: it would stop the stack)
```

| Stage | Runs |
|---|---|
| `lint` | RuboCop (Cookpad's style guide, [`LINT.md`](LINT.md)) and ShellCheck over every shell script |
| `ruby` | the minitest suite in the compose `test` service, on SQLite (the public default); its `test-postgres` is up too, as the SQLite → PostgreSQL copy test's target |
| `ruby-pg` | the same suite on PostgreSQL: the `test` service's `test-postgres` (`postgres:16.10-alpine`, data on tmpfs; the test service runs in its network namespace), `DATABASE_ADAPTER=postgresql`; the coverage floor holds on both. Then a smoke over the compose `postgres` service as a deployment runs it (HOST_UID, Unix socket, scram, a wrong password refused) |
| `frontend` | `tsc`, ESLint, Prettier and vitest in `frontend/` |
| `flake` | each test file the change touches (vs `CI_BASE_REF`) run `CI_FLAKE_REPEATS` (5) times, in batches of `CI_RUNNER_CPUS` runs: a changed test file, and the tests that name a changed `lib/`, `bin/` or `cli/` file. Any other changed path (docs, `CHANGELOG.md`, config, the SPA, `test/support/`) or a deleted one repeats the whole suite. A heuristic, not coverage: an integration test that reaches a lib file only through the app is repeated only with the whole suite (`ruby` runs it once either way) |
| `audit` | `bundle-audit check --update` + the image's libgit2 against its security releases + `npm audit --audit-level=low`; any advisory fails, fixed by upgrading |
| `secrets` | gitleaks over the history |
| `host` | the host-side programs' tests (`bin/yaks`, the launcher's rules, the installers; the list: `scripts/ci/host-tests`) on the oldest host Ruby they support |
| `distros` | the host-side tests (`scripts/ci/host-tests`) on Ubuntu 24.04, Debian 13, Fedora 42 and Alpine 3.22, each with its own packaged Ruby and `/bin/sh` and no locale (`scripts/ci/host-distros`) |
| `install` · `install-pg` | busyyaks installed for real on SQLite / PostgreSQL (`scripts/ci/install-test install`): the README Quickstart as written, the image built, the stack up, `/up` + MCP, the collector / launcher / daily-timer installers against the real `systemctl --user`, `yaks doctor` + `server status`, the XDG desktop entry validated and the chooser opened in Chrome under Xvfb |
| `update` · `update-pg` | the change's base (merge-base of HEAD and `CI_BASE_REF`) installed the same way, a note + a report written, `yaks update` refused on a dirty checkout and on a release that does not build, then that code's own `yaks update` to HEAD: migrations, a backup, the data kept (`scripts/ci/install-test update`) |

The four machine stages run only by name (never in `all`); Jenkins runs `install` and `install-pg`, and `update` · `update-pg` join it in a follow-up (they install the change's base, which needs this card's fixes first). Each makes a disposable Linux machine for itself
(`scripts/ci/machine-run`, image `scripts/ci/machine/Dockerfile`): a container with systemd as PID 1, a lingering user
`ci` with its own systemd user manager and its own Docker daemon (on the **cgroupfs** cgroup driver, where a reader's
Ubuntu runs systemd's: nested, the systemd driver lost a scope race now and then — card #573), started `--privileged` on a **rootless** Docker
daemon (the Jenkins agents'), so its root is the CI user's subordinate uid. A rootful daemon is refused. The change goes
in as a git bundle; the screenshots and, on a failure, the stack's logs come out into `CI_ARTIFACTS/<stage>`; the
machine and its volumes are removed. No credential goes in (the stack's `.env` GitHub token is one GitHub refuses); they need
only `CI_ARTIFACTS` and `CI_REGISTRY_MIRROR` (the CI host's Docker Hub pull-through cache URL — each machine's own
dockerd pulls through it, and the daemon running the machine must use the same one — or `none`; required, no default;
a Jenkins agent gets it from its own environment). `machine-image` builds the machines' image once, before they run side by side.

macOS: `yaks desktop` is covered only by `cli_test` with Darwin faked on Linux, never on a real Mac (no macOS CI node).

What a run needs (CI passes the same; `.env.example` § CI):

- Docker. The stages `ruby`, `ruby-pg`, `frontend` and `flake` run on the public runner's CPU count
  (`scripts/ci/runner.env` `CI_RUNNER_CPUS`, 4) as a Docker CPU quota: the Docker host needs at least that many CPUs
  and a daemon that applies `--cpus` (a rootless dockerd needs the cpu controller delegated to its user manager);
  either missing → that stage is refused. `lint`, `audit`, `secrets` and `host` run on any host.
- `CI_BASE_REF` for `flake` (and so `all`): the commit your change is measured against, e.g. `origin/main`.
- `CI_GITHUB_READ_TOKEN` (a read-only GitHub token, e.g. `$(gh auth token)`) and `CI_GITHUB_CACHE_DIR` (any dir you
  own) for `audit`.

- **Time**: the code reads the clock only through `Busyyaks::Clock`, and a test never sleeps or waits with a timeout
  itself — every wait is a `Wait` helper (`test/support/wait.rb`), an absence is asserted after the event that decides
  it, a duration only from below (`Elapsed.at_least`); `test/unit/no_real_clock_test.rb` holds the rule.
- The `test` service builds its own image (`busyyaks:test`), never the live `busyyaks:local`, so running the tests
  never restarts or migrates a running deployment.
- **Every CPU**: the Ruby suite runs `rake test:parallel`, one worker process per test file (the suite mostly waits on
  I/O, so the OS shares the CPUs), each on its own copy of a once-migrated database (SQLite: a file copy; PostgreSQL: `CREATE DATABASE <db>_w<i> TEMPLATE <db>_template`, dropped after; `test/support/test_databases.rb`), attachments dir and launcher
  socket, all in a RAM `/tmp` (on disk every table wipe waits on fsync). `rake test` = the same files serially,
  unmeasured (`TEST=<file>` for one). At most `TEST_WORKERS` files run at a time (`.env`; CI: `CI_RUNNER_CPUS`), and
  vitest runs with `--maxWorkers=$CI_RUNNER_CPUS`.
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
# the dark skin — the module's with its part outlined and the host dimmed — and check every captured word against the
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

**busyyaks' own five shots** (`today`, `board`, `card`, `today-mobile`, `workflow`) come from the same stage made from
a **dump** of busyyaks' own board — reused for every capture, dumped again only to refresh its content:

```sh
# once: busyyaks' board on your live dashboard (cards, comments, checklists, labels, PRs + their last GitHub state, the
# cards' pictures), its commit subjects of the last year and its merged PRs — renamed by the rule
# (scripts/readme-images/rename.js) and gated (dump.js: every word; every picture read by tesseract, a card keeping
# its newest clean one, each skip named in report.json) into a private dir outside the repo. Reads only.
PRIVATE_TERMS=.private-terms:<the kanban module's private terms> scripts/readme-images/dump <live checkout> ~/.local/state/readme-dump
# every capture: the stage with the dump's busyyaks repo + engine repo (enrolled, the dump's commits) beside acme/*;
# build loads the dump (load-dump.rb), seeds what a quiet day lacks (seed-busyyaks.js: lead + workers + sub team,
# labels, a question with options, a session dialog, a checklist, due dates, a sub-card, a cover, a review thread on
# the README card, a daily report), captures, gates and writes docs/images/{today,board,card,today-mobile,workflow}.webp
README_DEMO_WEB_PORT=18241 README_DEMO_MCP_PORT=18242 scripts/readme-images/demo-stack up ~/.local/state/rd --from ~/.local/state/readme-dump
PRIVATE_TERMS=.private-terms:<module checkout>/.private-terms scripts/readme-images/build ~/.local/state/rd <module checkout>
```

The picture gate reads a picture's **words** only (tesseract): a face, a logo or an icon with no text passes it, so
look at the kept pictures once before the first build — `dump` prints their paths, `<dumpdir>/report.json` lists kept
and skipped (card, picture, kinds); `DROP=<file>` (outside the dump dir, one picture id per line) rules one out by
hand. Real pictures are kept only where a README shot shows one: the README card's, and the covers of the board's first
`COVER_COLUMNS` (default 5) columns. `CARD` (required) is the card the README opens, `PICTURES` (default 10) how many
of its pictures it keeps, `CANDIDATES` (default 8) how many of each other card's newest are tried.

`scripts/readme-images/live` (the shots straight off the live dashboard, renamed in the page) stays for a one-off.

The workdir path must stay under 80 bytes (the collector's unix socket lives in it). `build` refuses to write any image
when a term is in the captured text, in the scripts, in the SVGs or in the READMEs, or when an image is over 400 KB.
