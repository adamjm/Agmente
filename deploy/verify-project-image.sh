#!/usr/bin/env bash
# Checks a project container image the way the gateway runs it (D-079 Apple runner, D-051 Podman
# runner): uid 10001, an empty writable HOME bind-mounted at its own path, the project folder
# bind-mounted and used as the working directory, and --entrypoint overridden to bash. Prints one
# ok or FAIL line per check and exits non-zero if any check fails. `bob --version` is recorded, not
# counted, because it may need a licence or the network.
#
# Usage: deploy/verify-project-image.sh [--runtime podman|container] <image>
#   --runtime container   Apple container CLI (default, the Mac).
#   --runtime podman      Podman (the Linux host). Untested on the Mac unless noted in D-110.
#   --dns <ip>            The container's nameserver, as runner.dns in the gateway config (D-081).
#                         The network checks need it on a Mac whose vmnet resolver does not answer.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: deploy/verify-project-image.sh [--runtime podman|container] [--dns <ip>] <image>
  --runtime container   Apple container CLI (default).
  --runtime podman      Podman, with the gateway's --userns=keep-id mapping.
  --dns <ip>            Nameserver for the containers (runner.dns, D-081).
USAGE
}

runtime=container
dns=""
image=""
while [ $# -gt 0 ]; do
  case "$1" in
    --runtime) runtime="${2:?--runtime needs podman or container}"; shift 2 ;;
    --runtime=*) runtime="${1#--runtime=}"; shift ;;
    --dns) dns="${2:?--dns needs an IP address}"; shift 2 ;;
    --dns=*) dns="${1#--dns=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      [ -z "$image" ] || { echo "give one image name" >&2; exit 2; }
      image="$1"; shift ;;
  esac
done
[ -n "$image" ] || { usage >&2; exit 2; }
case "$runtime" in
  container|podman) ;;
  *) echo "--runtime must be podman or container" >&2; exit 2 ;;
esac
command -v "$runtime" >/dev/null 2>&1 || { echo "$runtime is not on PATH" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/acpcode-verify.XXXXXX")"
trap 'rm -rf "$work" 2>/dev/null || echo "warning: could not remove $work" >&2' EXIT
home="$work/home"
project="$work/project"
mkdir -p "$home" "$project"

# run_in_image <script>: one container, as the gateway starts it, running the script under bash.
run_in_image() {
  local dns_flag=()
  if [ -n "$dns" ]; then dns_flag=(--dns "$dns"); fi
  if [ "$runtime" = podman ]; then
    podman run --rm --init --userns=keep-id:uid=10001,gid=10001 --user 10001:10001 \
      ${dns_flag[@]+"${dns_flag[@]}"} \
      -e "HOME=$home" -v "$home:$home" -v "$project:$project" -w "$project" \
      --entrypoint bash "$image" -c "$1" </dev/null
  else
    container run --rm --progress none --init -u 10001:10001 \
      ${dns_flag[@]+"${dns_flag[@]}"} \
      -e "HOME=$home" -v "$home:$home" -v "$project:$project" -w "$project" \
      --entrypoint bash "$image" -c "$1" </dev/null
  fi
}

passed=0
failed=0

# check <label> <script>: ok when the script exits 0. The ok line shows the last non-empty output line.
check() {
  local out rc last
  if out="$(run_in_image "$2" 2>&1)"; then rc=0; else rc=$?; fi
  if [ "$rc" -eq 0 ]; then
    passed=$((passed + 1))
    last="$(printf '%s\n' "$out" | awk 'NF { line = $0 } END { print line }')"
    printf 'ok    %s: %s\n' "$1" "$last"
  else
    failed=$((failed + 1))
    printf 'FAIL  %s (exit %s)\n' "$1" "$rc"
    printf '%s\n' "$out" | tail -n 8 | sed 's/^/        /'
  fi
}

echo "image: $image"
echo "runtime: $runtime"
echo

echo "== versions and identity"
check "bash --version" 'bash --version'
check "git --version" 'git --version'
check "python3 --version" 'python3 --version'
check "python --version" 'python --version'
check "pip --version" 'pip --version'
check "node --version" 'node --version'
check "npm --version" 'npm --version'
check "go version" 'go version'
check "rustc --version" 'rustc --version'
check "cargo --version" 'cargo --version'
check "id -u is 10001" 'test "$(id -u)" = 10001 && id -u'
check "rust env: RUSTUP_HOME set, CARGO_HOME unset" \
  'test "$RUSTUP_HOME" = /usr/local/rustup && test -z "${CARGO_HOME:-}" && echo "RUSTUP_HOME=$RUSTUP_HOME"'
check "pnpm and yarn resolve (corepack)" 'command -v pnpm && command -v yarn'

echo
echo "== work in each language (offline)"
check "bash script runs" '
  mkdir -p bash-check && cd bash-check
  printf "%s\n" "echo script-ok" > check.sh
  bash check.sh'
check "python3 -m venv and run" '
  mkdir -p py-check && cd py-check
  python3 -m venv .venv
  .venv/bin/python -c "print(1)"'
check "node -e" 'node -e "console.log(1)"'
check "go run hello" '
  mkdir -p go-check && cd go-check
  go mod init x >/dev/null
  printf "%s\n" "package main" "" "import \"fmt\"" "" "func main() { fmt.Println(\"hello\") }" > main.go
  go run .'
check "cargo run hello (no dependencies)" '
  mkdir -p rust-check && cd rust-check
  cargo new hello >/dev/null
  cd hello && cargo run -q'
check "cc compiles and runs a C file" '
  mkdir -p c-check && cd c-check
  printf "%s\n" "#include <stdio.h>" "int main(void) { puts(\"c-ok\"); return 0; }" > c.c
  cc -o c c.c && ./c'

echo
echo "== network (these fetch from the internet; a failure here may be the network, not the image)"
check "pip install --user six (PyPI)" '
  pip install --user --quiet --disable-pip-version-check six
  python3 -c "import six; print(\"six\", six.__version__)"'
check "pnpm --version (corepack downloads pnpm)" 'COREPACK_ENABLE_DOWNLOAD_PROMPT=0 pnpm --version'

echo
echo "== recorded, not counted"
bob_out="$(run_in_image 'timeout 60 bob --version' 2>&1)" && bob_rc=0 || bob_rc=$?
printf 'info  bob --version (exit %s): %s\n' "$bob_rc" "$(printf '%s' "$bob_out" | tail -n 3 | tr '\n' ' ')"

echo
printf '%s passed, %s FAILED\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
