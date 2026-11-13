# Image for one project's runtime (PLAN 4.1, D-008, D-015, D-110). Status: verify.
# Bob is pinned to an exact version (FR-32). Runs as an unprivileged user (uid 10001).
# Toolset (D-110): bash, git, C toolchain, Python 3 with venv and pip, Node 22 with npm, corepack, Go, Rust.
# The gateway mounts the project folder and a per-project home at their host paths and sets HOME to the
# home, so every toolchain is installed system-wide and on PATH; nothing here depends on /home/bob.
# Build (Apple container, Mac): container build -t localhost/acpcode-bob:2.0.9-tools1 -f deploy/bob-project.Containerfile deploy
# Build (Podman, Linux):        podman build -t acpcode-bob:2.0.9-tools1 -f deploy/bob-project.Containerfile deploy
# Check the image: deploy/verify-project-image.sh localhost/acpcode-bob:2.0.9-tools1
FROM docker.io/library/node:22-bookworm-slim

# Pinned toolchain versions. Sources (fetched 2026-11-10):
#   Go 1.27.3: https://go.dev/dl/?mode=json (newest stable; sha256 of go1.27.3.linux-{amd64,arm64}.tar.gz).
#   Rust 1.99.1: https://static.rust-lang.org/dist/channel-rust-stable.toml (rustc 1.99.1, manifest date 2026-10-15).
#   rustup 1.29.3: https://static.rust-lang.org/rustup/archive/1.29.3/<triple>/rustup-init (+ .sha256 beside it).
ARG GO_VERSION=1.27.3
ARG GO_SHA256_AMD64=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40
ARG GO_SHA256_ARM64=a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49
ARG RUST_VERSION=1.99.1
ARG RUSTUP_VERSION=1.29.3

# Shell, git, the usual agent tools, the C toolchain (Python, cgo and Rust builds), Python 3.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash git ca-certificates curl wget jq ripgrep less unzip zip xz-utils openssh-client \
      procps findutils sed gawk make patch file tree \
      build-essential pkg-config libssl-dev \
      python3 python3-pip python3-venv python-is-python3 \
 && rm -rf /var/lib/apt/lists/*

# Go, to /usr/local/go. GOPATH stays the default ($HOME/go), so each project's home keeps its own.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) sha="$GO_SHA256_AMD64" ;; \
      arm64) sha="$GO_SHA256_ARM64" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/go.tar.gz "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz"; \
    echo "${sha}  /tmp/go.tar.gz" | sha256sum -c -; \
    tar -C /usr/local -xzf /tmp/go.tar.gz; \
    rm /tmp/go.tar.gz

# Rust, system-wide: rustup-init is checked against its published .sha256. The toolchain is installed with
# RUSTUP_HOME and CARGO_HOME set for this step only, so every user can read and run it. At run time
# CARGO_HOME is left unset (the image cannot write /usr/local/cargo as uid 10001), so cargo uses $HOME/.cargo.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) triple=x86_64-unknown-linux-gnu ;; \
      arm64) triple=aarch64-unknown-linux-gnu ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    mkdir /tmp/rustup-init; \
    cd /tmp/rustup-init; \
    curl -fsSLO "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${triple}/rustup-init"; \
    curl -fsSLO "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${triple}/rustup-init.sha256"; \
    sha256sum -c rustup-init.sha256; \
    chmod +x rustup-init; \
    RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo \
      ./rustup-init -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_VERSION}" -c clippy -c rustfmt; \
    cd /; \
    rm -rf /tmp/rustup-init

# Node 22 and npm come from the base image. corepack provides pnpm and yarn.
RUN corepack enable

# Bob, pinned to an exact version (FR-32).
RUN npm install -g --save-exact @ibm/bob@2.0.9 && npm cache clean --force

# The gateway runs this image with --user 10001:10001 (D-051, D-079), so this uid owns the project home and
# folders. If you change it, set runner.containerUid/containerGid.
RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin bob

# Debian marks the system Python as externally managed (PEP 668), which blocks `pip install --user`.
# The agent's own installs go to $HOME, which is per project and writable, so the marker is relaxed for pip
# only. System packages stay root-owned and read-only for uid 10001. Venvs are unaffected.
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV HOME=/home/bob
ENV RUSTUP_HOME=/usr/local/rustup
ENV PATH=/usr/local/go/bin:/usr/local/cargo/bin:${PATH}

USER bob
WORKDIR /work
ENTRYPOINT ["bob"]
