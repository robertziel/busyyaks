# A disposable Linux machine for scripts/ci/install-test, as a container: systemd as PID 1, a lingering user `ci` with
# its own systemd user manager, a Docker daemon of its own, and the host tools README § Requirements names — what a
# reader's Ubuntu 24.04 box has, but for one thing: its dockerd runs the cgroupfs cgroup driver, where Ubuntu's runs
# systemd's (the reason: the RUN that writes /etc/docker/daemon.json below). scripts/ci/machine-run starts it privileged on the CI host's (rootless) Docker; its
# "root" is the CI user's subordinate uid, its daemon is nested inside it, nothing of the host's is mounted.
# ubuntu:24.04, pinned by digest (the image is cached by this file's hash: a floating tag would never refresh)
FROM ubuntu:24.04@sha256:9c7f200c07e3d4a03e7249d2c16bf66a51120fb876aa2242cf31451412543289
ARG CLAUDE_CODE_VERSION
# Chrome for Testing, pinned by version and one sha256 per architecture: the CI pool has amd64 and arm64 agents, and
# Google's apt package exists for amd64 only. Bump all three from
# googlechromelabs.github.io/chrome-for-testing (its archives are kept); an architecture not listed fails the build.
ARG CHROME_VERSION=158.0.8127.36
ARG CHROME_SHA256_AMD64=dba9cc838e1ce269c33ea68170881127bd15d078fc3ca5891c90802819a4d7c7
ARG CHROME_SHA256_ARM64=f811b64a50cbc73f94fda7b3f3b3bf62be5d9409b3207e6ead9b61e6706afffe
RUN test -n "$CLAUDE_CODE_VERSION"
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      systemd systemd-sysv dbus dbus-user-session libpam-systemd \
      docker.io docker-compose-v2 \
      ca-certificates curl git jq ruby tmux procps nodejs npm \
      desktop-file-utils xvfb xauth imagemagick unzip xdg-utils fonts-liberation \
      libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2 libcups2t64 libcurl4t64 libdbus-1-3 \
      libexpat1 libgbm1 libglib2.0-0t64 libgtk-3-0t64 libnspr4 libnss3 libpango-1.0-0 libudev1 libvulkan1 libx11-6 \
      libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2 \
 && case "$(dpkg --print-architecture)" in \
      amd64) platform=linux64 sum=$CHROME_SHA256_AMD64 ;; \
      arm64) platform=linux-arm64 sum=$CHROME_SHA256_ARM64 ;; \
      *) echo "no Chrome pinned for $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac \
 && curl -fsSLo /tmp/chrome.zip "https://storage.googleapis.com/chrome-for-testing-public/$CHROME_VERSION/$platform/chrome-$platform.zip" \
 && echo "$sum  /tmp/chrome.zip" | sha256sum -c - \
 && unzip -q /tmp/chrome.zip -d /opt && mv "/opt/chrome-$platform" /opt/chrome \
 && if [ -f /opt/chrome/chrome_sandbox ]; then mv /opt/chrome/chrome_sandbox /opt/chrome/chrome-sandbox; fi \
 && if [ -f /opt/chrome/chrome-sandbox ]; then chown root:root /opt/chrome/chrome-sandbox && chmod 4755 /opt/chrome/chrome-sandbox; fi \
 && ln -s /opt/chrome/chrome /usr/local/bin/google-chrome \
 && ! ldd /opt/chrome/chrome | grep 'not found' \
 && rm -rf /var/lib/apt/lists/* /tmp/chrome.zip \
 && npm install -g --silent "@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION" \
 && npm cache clean --force
# the reader's account: a login user in the docker group whose user manager runs from boot (loginctl enable-linger)
# Its XDG base dirs exist at 0700, as a desktop session leaves them (the XDG Base Directory spec's mode; this box's own
# ~/.local and ~/.config): otherwise the first program to make them under the login umask (Ubuntu: 002, user-private
# groups) — Chrome, for the dashboard screenshot — leaves ~/.local group-writable, which the collector rightly refuses.
# Chrome has been run once (its profile's `First Run` sentinel): a fresh profile opens its Terms dialog over the
# chooser's app window, which then never loads the chooser.
RUN useradd -m -s /bin/bash ci && usermod -aG docker ci \
 && install -d -m 0700 -o ci -g ci /home/ci/.local /home/ci/.local/share /home/ci/.local/state /home/ci/.config \
 && install -d -m 0700 -o ci -g ci /home/ci/.config/google-chrome-for-testing \
 && install -m 0600 -o ci -g ci /dev/null "/home/ci/.config/google-chrome-for-testing/First Run" \
 && mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/ci \
 && systemctl mask getty@tty1.service console-getty.service systemd-firstboot.service \
      proc-sys-fs-binfmt_misc.automount sys-kernel-config.mount sys-kernel-debug.mount sys-kernel-tracing.mount \
 && systemctl enable docker.service
# The machine's dockerd makes its containers' cgroups itself (cgroupfs), not as systemd scopes. Nested here (systemd
# PID 1 in a privileged container on a rootless daemon), the systemd driver lost a race now and then: the first
# memory-limited container's scope was started and deactivated in the same second, and runc's write of its memory.max
# failed "openat2 …/system.slice/docker-<id>.scope/memory.max: no such file or directory" (card #573; the machine's
# journal). What install-test checks — busyyaks' compose, units and limits — is the
# same under either driver; only who creates the container's cgroup changes.
RUN install -d -m 0755 /etc/docker \
 && printf '{\n  "exec-opts": ["native.cgroupdriver=cgroupfs"]\n}\n' > /etc/docker/daemon.json
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
