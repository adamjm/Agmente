# Draft image for one project's runtime (PLAN 4.1, D-008, D-015). Status: verify.
# Bob is pinned to an exact version (FR-32). Runs as an unprivileged user.
# Build: podman build -t acpcode-bob:2.0.9 -f deploy/bob-project.Containerfile deploy
FROM docker.io/library/node:22-bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN npm install -g --save-exact @ibm/bob@2.0.9 && npm cache clean --force
# The gateway runs this image with --userns=keep-id:uid=10001,gid=10001 --user 10001:10001 (D-051), so
# this uid owns the project home and folders. If you change it, set runner.containerUid/containerGid.
RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin bob
USER bob
ENV HOME=/home/bob
WORKDIR /work
ENTRYPOINT ["bob"]
