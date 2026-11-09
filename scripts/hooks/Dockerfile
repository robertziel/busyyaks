# busyyaks:hooks — every git hook runs in here, never on the host: overcommit 0.75.0 + RuboCop and its plugins
# (the Gemfile's :lint group, pinned by Gemfile.lock — the same gems CI's busyyaks:lint image runs), ESLint + Prettier with
# frontend/'s node_modules (npm ci of frontend/package-lock.json — the same packages CI's frontend stage installs),
# gitleaks (the version CI's secrets stage runs) and ShellCheck (the version CI's lint stage runs). scripts/hooks/image tags it by the hash of every input and rebuilds on
# change; the build context is those inputs alone.
FROM node:22-bookworm-slim AS node
WORKDIR /deps
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund

FROM zricethezav/gitleaks:v8.30.1 AS gitleaks

FROM koalaman/shellcheck:v0.10.0 AS shellcheck

FROM ruby:3.4-slim
# git: overcommit, the staged snapshot and gitleaks; procps: overcommit reads its parent command (`ps`)
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git procps \
 && rm -rf /var/lib/apt/lists/*
COPY --from=node /usr/local/bin/node /usr/local/bin/node
# node_modules at /deps: the staged tree is checked out at /deps/snap, so Node's lookup from /deps/snap/frontend finds it
COPY --from=node /deps/node_modules /deps/node_modules
COPY --from=gitleaks /usr/bin/gitleaks /usr/local/bin/gitleaks
COPY --from=shellcheck /bin/shellcheck /usr/local/bin/shellcheck
WORKDIR /lint
COPY Gemfile Gemfile.lock ./
ENV BUNDLE_ONLY=lint BUNDLE_GEMFILE=/lint/Gemfile
RUN bundle install && bundle exec overcommit --version && bundle exec rubocop --version \
 && node --version && /deps/node_modules/.bin/eslint --version \
 && /deps/node_modules/.bin/prettier --version && gitleaks version && shellcheck --version
COPY scripts/hooks/entry scripts/hooks/overcommit.rb scripts/hooks/eslint scripts/hooks/gitleaks scripts/hooks/shellcheck \
     scripts/hooks/prettier scripts/lint/shell-files /hooks/
WORKDIR /deps/snap
ENTRYPOINT ["/hooks/entry"]
