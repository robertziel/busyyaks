# The real agent CLIs, pinned, for the harness contract tests: each runs against the scripted mock model in
# this same container, with no network at run time (docker run --network none).
FROM node:22-bookworm-slim@sha256:e9f565d32859f0cbfb52125eafe8be39390f24dac302dc3cdf566e8ba3ab21ee AS node

FROM ruby:3.4.13-slim
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm
ARG CLAUDE_CODE_VERSION=2.1.330
ARG CODEX_VERSION=0.166.0
ARG HERMES_COMMIT=baef00bf4c6d9f009f19a7ecb3251849f4f7d54c
ARG AIMOCK_VERSION=1.48.1
ARG AIMOCK_SHA256=4443a32462d37cd76518df83777e8ce036088fec0b9bd5df7df24848b1dc52c9
ARG UV_VERSION=0.13.9
ARG UV_SHA256=a7fbaff2b9a271d85c1bdb540941090fd1ce011797b4abeb48e4dcd39c2471d5
RUN apt-get update && apt-get install -y --no-install-recommends tmux git ca-certificates curl procps \
 && rm -rf /var/lib/apt/lists/*
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "@openai/codex@${CODEX_VERSION}"
RUN cd /tmp && npm pack "@copilotkit/aimock@${AIMOCK_VERSION}" --silent \
 && echo "${AIMOCK_SHA256}  /tmp/copilotkit-aimock-${AIMOCK_VERSION}.tgz" | sha256sum -c - \
 && npm install -g --ignore-scripts "/tmp/copilotkit-aimock-${AIMOCK_VERSION}.tgz" \
 && rm "/tmp/copilotkit-aimock-${AIMOCK_VERSION}.tgz"
RUN curl -fsSL -o /tmp/uv.tgz "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" \
 && echo "${UV_SHA256}  /tmp/uv.tgz" | sha256sum -c - \
 && tar -xzf /tmp/uv.tgz --strip-components=1 -C /usr/local/bin && rm /tmp/uv.tgz \
 && git clone --filter=blob:none https://github.com/NousResearch/hermes-agent /opt/hermes \
 && git -C /opt/hermes checkout --detach "${HERMES_COMMIT}" \
 && UV_PYTHON_INSTALL_DIR=/opt/python uv sync --project /opt/hermes --frozen --extra mcp --python 3.14 \
 && chmod -R a+rX /opt/hermes /opt/python \
 && ln -s /opt/hermes/.venv/bin/hermes /usr/local/bin/hermes
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
WORKDIR /tmp
