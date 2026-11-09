# Security policy

## Reporting a vulnerability

Report it **privately**, through GitHub's private vulnerability reporting:
[Security → Report a vulnerability](https://github.com/robertziel/busyyaks/security/advisories/new). Never in a public
issue, pull request or discussion.

Include what you can of: the affected version or commit, the component (web, MCP server, scanner, GitHub collector,
notifier, launcher, the kanban module), the configuration it needs (`auth` provider, how the web port is exposed),
steps to reproduce, and the impact you expect.

What happens next:

| | |
|---|---|
| Acknowledgement | within 7 days |
| Assessment | confirmed or declined with the reason, in the advisory |
| Fix | developed in the advisory's temporary private fork; released with the advisory published and a CHANGELOG entry |
| Credit | in the advisory and the CHANGELOG, unless you ask not to be named |

A vulnerability in the vendored kanban module (`vendor/agents_kanban`, `frontend/src/vendor/agents_kanban`) can be
reported here or to [busyyaks_agents_kanban_module](https://github.com/robertziel/busyyaks_agents_kanban_module/security/advisories/new);
it is fixed there first and busyyaks re-vendors it.

## Supported versions

| Version | Supported |
|---|---|
| `1.0.0-beta.x` (the latest beta) and `main` | yes: fixes land on `main` and ship in the next beta |
| anything older than the latest release | no: upgrade to the latest release |

## Scope

In scope: what busyyaks itself does with the secrets and access it is given.

- the web app and its JSON API: authentication through the configured `auth` provider, sessions and CSRF, the Host
  allowlist and `Origin` check against DNS rebinding ([docs/DEPLOY.md](docs/DEPLOY.md#hosts-the-web-app-answers-dns-rebinding)
  — a page on another site reaching a `provider: none` instance on localhost **is** in scope), the content security policy, server-side Markdown rendering, attachment upload and download;
- the MCP server: the bearer token, the `Origin` check, every tool;
- the host-side launcher (`bin/launcher`): its socket, the ops it accepts, what it types into tmux panes;
- the collectors: handling of `GITHUB_TOKEN`, `MCP_TOKEN`, `SESSION_SECRET`, credentials inside git remote URLs;
- the daily-report runner: the agent CLI it starts with the busyyaks MCP as its only tools (no terminal);
- the open risks documented in [docs/DEPLOY.md → Remaining risks](docs/DEPLOY.md#remaining-risks) — the shared
  database, git on untrusted repos — are known;
  a way across a boundary that is not listed there is in scope;
- the CI and hook scripts in this repo (`scripts/`), and the Docker images they build.

Not ours to close: Claude Code keeps its own per-path folder-trust list in `~/.claude.json`; a path it trusts stays
trusted whatever busyyaks decides ([docs/DEPLOY.md → Folder trust](docs/DEPLOY.md#folder-trust-the-launcher)).

Out of scope:

- **`auth: { provider: none }` exposed beyond localhost.** `none` means every request is the operator; it is the
  documented choice for a deployment reachable only from the machine itself. Publishing that port (a public bind, a
  reverse proxy, a tunnel) without a real provider gives everyone operator access by design, not by a bug. A
  provider that can be bypassed **is** in scope.
- **The MCP port tunnelled or published.** It is for local agent sessions only, never tunnelled
  ([README → When not to use it](README.md#when-not-to-use-it)).
- What an agent session does with the access you gave it: Claude Code's permission mode, the launchers and prompts in
  your `config/kanban.yml`, the repos you mount.
- Anyone who can already run commands as the host user or reach the Docker daemon (`scripts/ci/test.sh` mounts the
  Docker socket; that is host-root-equivalent by design).
- Vulnerabilities in third-party dependencies with no busyyaks-specific impact: report them upstream. CI fails on any
  published advisory (`scripts/ci/test.sh audit`), and the fix is an upgrade.
- Denial of service by a signed-in operator against their own instance.
