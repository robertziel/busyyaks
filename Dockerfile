# syntax=docker/dockerfile:1.7
# Stage 1: the SPA (frontend/ → public/app). `npm run build` type-checks (tsc --noEmit) then bundles;
# the lockfile is required (npm ci) — generate it in a node container, never on the host.
FROM node:22-bookworm-slim AS frontend
WORKDIR /src/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
COPY frontend/ ./
RUN npm run build

# Stage 2: libgit2, the only code that reads a scanned repo (bin/git-read through the rugged gem). Built here, not
# rugged's bundled copy: the version is ours to follow upstream security releases (CI `audit` compares it with the
# newest libgit2 release: scripts/ci/libgit2-audit.rb), the tarball is checksum-pinned, and the build has no network
# transport (no SSH / HTTPS: a read never fetches), the system zlib (Debian's security updates) and POSIX regcomp, no
# bundled PCRE. test/unit/git_read_test.rb asserts the version and that Rugged.features is [:threads] only.
FROM ruby:3.4-slim AS libgit2
ARG LIBGIT2_VERSION=1.9.7
ARG LIBGIT2_SHA256=1a4fbe7589e814777ae76b64734ad80f4ecad22cd33a22682a2aaea4ae5375e7
RUN apt-get update && apt-get install -y --no-install-recommends build-essential cmake zlib1g-dev pkg-config \
 && rm -rf /var/lib/apt/lists/*
ADD --checksum=sha256:${LIBGIT2_SHA256} https://github.com/libgit2/libgit2/archive/refs/tags/v${LIBGIT2_VERSION}.tar.gz /src/libgit2.tar.gz
RUN mkdir /src/libgit2 && tar xzf /src/libgit2.tar.gz -C /src/libgit2 --strip-components=1 \
 && cmake -S /src/libgit2 -B /src/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/libgit2 \
      -DBUILD_SHARED_LIBS=ON -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DBUILD_EXAMPLES=OFF -DUSE_THREADS=ON \
      -DUSE_SSH=OFF -DUSE_HTTPS=OFF -DUSE_NTLMCLIENT=OFF -DUSE_GSSAPI=OFF -DUSE_BUNDLED_ZLIB=OFF \
      -DREGEX_BACKEND=regcomp -DUSE_SHA1=CollisionDetection -DUSE_SHA256=Builtin \
 && cmake --build /src/build -j"$(nproc)" && cmake --install /src/build \
 && echo "${LIBGIT2_VERSION}" > /opt/libgit2/VERSION

# Stage 3: the app
FROM ruby:3.4-slim

# jq: test/unit/daily_report_tick_test.rb runs the host script bin/daily-report (which needs it) in a sandbox
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential libyaml-dev git sqlite3 pkg-config zlib1g-dev jq \
 && rm -rf /var/lib/apt/lists/*
COPY --from=libgit2 /opt/libgit2 /opt/libgit2
RUN echo /opt/libgit2/lib > /etc/ld.so.conf.d/libgit2.conf && ldconfig
# rugged compiles against /opt/libgit2 (pkg-config), never its own vendored libgit2
ENV PKG_CONFIG_PATH=/opt/libgit2/lib/pkgconfig BUNDLE_BUILD__RUGGED=--use-system-libraries
# No system-wide safe.directory: git trusts a repo owned by another uid only under the projects mount (PROJECTS_MOUNT,
# compose's GIT_CONFIG_* — the scanned repos are bind-mounted read-only and owned by the host user).

WORKDIR /app
COPY Gemfile Gemfile.lock ./
# the :lint group (RuboCop) runs in its own image, busyyaks:lint (scripts/lint/rubocop)
ENV BUNDLE_WITHOUT=lint
RUN bundle install
COPY . .
COPY --from=frontend /src/public/app ./public/app
# the /data ownership check every service runs first (bin/entrypoint), then its command
ENTRYPOINT ["/app/bin/entrypoint"]
CMD ["bin/web"]
