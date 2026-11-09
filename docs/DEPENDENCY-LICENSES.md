# Dependency licenses

busyyaks publishes source only. Its dependencies are not in this repository: Docker downloads them when you build an
image (`Dockerfile`, `scripts/lint/Dockerfile`, `scripts/hooks/Dockerfile`). Material that IS in the repository —
ported code, copied rules, fonts, the vendored kanban module — is listed in [`NOTICE`](../NOTICE).

Read from the lockfiles at 1.0.0 (unreleased); re-check after a dependency change with the commands at the end.

## Ruby gems (`Gemfile.lock`, 90 gems)

| License | Gems |
|---|---|
| MIT | 70 |
| Ruby, or Ruby / BSD-2-Clause (dual) | 14 |
| BSD-2-Clause, BSD-3-Clause, MIT / BSD-2-Clause | 4 |
| Ruby / GPL-2.0-only (dual) | 1: `rdoc` |
| GPL-3.0-or-later | 1: `bundler-audit` |

| Gem | License | Where it runs | Obligation |
|---|---|---|---|
| `rdoc` 8.1.0 (via `irb`, groups `cli` · `development` · `test`) | Ruby or GPL-2.0-only, at the user's choice | the app image | none beyond keeping its notices: used under the Ruby license |
| `bundler-audit` 0.9.3 (group `lint`) | GPL-3.0-or-later | only the lint and hooks images (`BUNDLE_WITHOUT=lint` keeps it out of the app image) | none: a development tool run as a separate program, not linked into or shipped with busyyaks; GPL obligations would apply only to someone who distributes that tool or an image containing it |

## npm packages (`frontend/package-lock.json`, 258 packages)

Shipped in the browser bundle (`public/app`, built by Vite in the image): only the 11 runtime packages — `react`,
`react-dom`, `react-router`, `react-router-dom`, `scheduler`, `cookie`, `set-cookie-parser`, `js-tokens`,
`loose-envify`, and `@dagrejs/dagre` 3.1.3 with its `@dagrejs/graphlib` 4.0.6 (the layered layout of the vendored
engine's workflow graph; the engine's one runtime dependency, pinned here at the same version) — all MIT.

The other 247 are build and test tools (`devDependencies` and theirs): 207 MIT, 16 Apache-2.0, 12 ISC, 8 BSD, and:

| Package | License | Used for | Obligation |
|---|---|---|---|
| `minimatch` 11.0.5, `@isaacs/nonrecursive-glob-match` 1.1.0 | BlueOak-1.0.0 | glob matching inside the build and lint tools | none: permissive (keep the notice when redistributing the package); nothing of it reaches the bundle |
| `argparse` 2.0.1 | Python-2.0 (PSF) | a dependency of ESLint's config loading | none: permissive; build-time only |
| `caniuse-lite` 1.0.30001820 | CC-BY-4.0 | browser-support data read by the build tools | none for busyyaks: data consulted at build time, not redistributed in the bundle |

No dependency is under a copyleft license whose terms reach busyyaks's own code or its built bundle.

## Re-check

```bash
# npm: every package that is not MIT / ISC / Apache-2.0 / BSD (dev = build/test only)
jq -r '.packages | to_entries[] | select(.key != "") |
  "\(.value.license // "NONE")\t\(.key | sub(".*node_modules/"; ""))\t\(if .value.dev then "dev" else "runtime" end)"' \
  frontend/package-lock.json | grep -vE '^(MIT|ISC|Apache-2.0|BSD-2-Clause|BSD-3-Clause)\s'

# gems: the license each installed gem declares, in the test image (built by `docker compose run --rm --build test`;
# the lint group is installed only in busyyaks:lint-<hash>, built by scripts/lint/rubocop: run the same there)
docker run --rm -v "$PWD":/w -w /w --entrypoint ruby busyyaks:test -rbundler -e '
  Bundler::LockfileParser.new(File.read("Gemfile.lock")).specs.map(&:name).uniq.sort.each { |n|
    s = Gem::Specification.find_all_by_name(n).first
    puts [s ? s.licenses.join("|") : "not installed here", n].join("\t") }'
```
