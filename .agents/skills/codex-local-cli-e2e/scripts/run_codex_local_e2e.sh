#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  run_codex_local_e2e.sh --endpoint <ws://host:port> --udid <SIM_UDID> [options]

Required:
  --endpoint <value>         Codex app-server endpoint (ws://host:port or host:port)
  --udid <value>             iOS Simulator UDID

Optional:
  --start-codex-cmd <value>  Command to start codex app-server for this run
  --project <value>          Xcode project path (default: <repo-root>/ACPCode.xcodeproj)
  --scheme <value>           Xcode scheme (default: ACPCode)
  --test-id <value>          Test identifier (default: ACPCodeUITests/ACPCodeUITests/testCodexDirectWebSocketConnectInitializeAndSessionFlow)
  --bundle-id <value>        App bundle id for uninstall (default: com.example.ACPCode)
  --workdir <value>          Working directory for xcodebuild (default: <repo-root>)
  --xcodebuild-log <value>   xcodebuild log path (default: ${TMPDIR:-/tmp}/acpcode_codex_e2e_xcodebuild.log)
  --codex-log <value>        Codex server log path (default: ${TMPDIR:-/tmp}/codex-local-app-server-e2e.log)
  --skip-uninstall           Skip simulator app uninstall during cleanup
  --shutdown-sim             Shutdown simulator during cleanup
  --help                     Show this help

Examples:
  run_codex_local_e2e.sh --endpoint ws://127.0.0.1:8788 --udid <UDID>
  run_codex_local_e2e.sh --endpoint ws://127.0.0.1:8788 --udid <UDID> \
    --start-codex-cmd "codex app-server --listen ws://127.0.0.1:8788"
EOF
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/../../../.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"

PROJECT="${REPO_ROOT}/ACPCode.xcodeproj"
SCHEME="ACPCode"
TEST_ID="ACPCodeUITests/ACPCodeUITests/testCodexDirectWebSocketConnectInitializeAndSessionFlow"
BUNDLE_ID="com.example.ACPCode"
WORKDIR="${REPO_ROOT}"
XCODEBUILD_LOG="${TMP_BASE}/acpcode_codex_e2e_xcodebuild.log"
CODEX_LOG="${TMP_BASE}/codex-local-app-server-e2e.log"
E2E_CONFIG_FILE="${TMP_BASE}/acpcode_codex_e2e_config.env"

ENDPOINT=""
UDID=""
START_CODEX_CMD=""
SKIP_UNINSTALL=0
SHUTDOWN_SIM=0
SERVER_PID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint)
      ENDPOINT="${2:-}"
      shift 2
      ;;
    --udid)
      UDID="${2:-}"
      shift 2
      ;;
    --start-codex-cmd)
      START_CODEX_CMD="${2:-}"
      shift 2
      ;;
    --project)
      PROJECT="${2:-}"
      shift 2
      ;;
    --scheme)
      SCHEME="${2:-}"
      shift 2
      ;;
    --test-id)
      TEST_ID="${2:-}"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      shift 2
      ;;
    --workdir)
      WORKDIR="${2:-}"
      shift 2
      ;;
    --xcodebuild-log)
      XCODEBUILD_LOG="${2:-}"
      shift 2
      ;;
    --codex-log)
      CODEX_LOG="${2:-}"
      shift 2
      ;;
    --skip-uninstall)
      SKIP_UNINSTALL=1
      shift
      ;;
    --shutdown-sim)
      SHUTDOWN_SIM=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$ENDPOINT" || -z "$UDID" ]]; then
  echo "Error: --endpoint and --udid are required." >&2
  usage
  exit 2
fi

if [[ "$ENDPOINT" != *"://"* ]]; then
  ENDPOINT="ws://${ENDPOINT}"
fi

HOSTPORT="${ENDPOINT#*://}"
HOSTPORT="${HOSTPORT%%/*}"
if [[ "$HOSTPORT" != *:* ]]; then
  echo "Error: endpoint must include host and port: $ENDPOINT" >&2
  exit 2
fi

HOST="${HOSTPORT%:*}"
PORT="${HOSTPORT##*:}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
  echo "Error: invalid port in endpoint: $ENDPOINT" >&2
  exit 2
fi

cleanup() {
  local ec=$?

  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi

  if (( SKIP_UNINSTALL == 0 )); then
    xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi

  if (( SHUTDOWN_SIM == 1 )); then
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  fi

  rm -f "$E2E_CONFIG_FILE" >/dev/null 2>&1 || true

  exit "$ec"
}
trap cleanup EXIT INT TERM

wait_for_port() {
  local attempts="${1:-60}"
  local i=1
  while (( i <= attempts )); do
    if nc -z "$HOST" "$PORT" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    ((i++))
  done
  return 1
}

echo "Endpoint: $ENDPOINT"
echo "Simulator: $UDID"

if [[ -n "$START_CODEX_CMD" ]]; then
  echo "Starting codex app-server..."
  nohup bash -lc "$START_CODEX_CMD" >"$CODEX_LOG" 2>&1 &
  SERVER_PID=$!
  if ! wait_for_port 90; then
    echo "Error: server did not become reachable at $ENDPOINT" >&2
    if [[ -f "$CODEX_LOG" ]]; then
      echo "--- codex log tail ---" >&2
      tail -n 80 "$CODEX_LOG" >&2 || true
    fi
    exit 1
  fi
else
  if ! wait_for_port 3; then
    echo "Error: no reachable server at $ENDPOINT. Start it first or pass --start-codex-cmd." >&2
    exit 1
  fi
fi

xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

if (( SKIP_UNINSTALL == 0 )); then
  # Ensure deterministic first-run state for the UI test.
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

cat > "$E2E_CONFIG_FILE" <<EOF
ACPCODE_E2E_CODEX_ENABLED=1
ACPCODE_E2E_CODEX_ENDPOINT=$ENDPOINT
EOF

echo "Running Codex UI E2E test..."
set +e
(
  cd "$WORKDIR"
  ACPCODE_E2E_CODEX_ENABLED=1 \
  ACPCODE_E2E_CODEX_ENDPOINT="$ENDPOINT" \
  ACPCODE_E2E_CODEX_CONFIG_PATH="$E2E_CONFIG_FILE" \
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$UDID" \
    -only-testing:"$TEST_ID" \
    test
) | tee "$XCODEBUILD_LOG"
status=${PIPESTATUS[0]}
set -e

echo "xcodebuild log: $XCODEBUILD_LOG"
if [[ -f "$CODEX_LOG" ]]; then
  echo "codex server log: $CODEX_LOG"
fi
echo "e2e config file: $E2E_CONFIG_FILE"

if (( status != 0 )); then
  echo "Codex E2E failed. Last matching failure lines:" >&2
  rg -n "(Test case '.*' failed|XCTAssert|Assertion|error:|\\*\\* TEST FAILED \\*\\*)" "$XCODEBUILD_LOG" | tail -n 20 >&2 || true
  exit "$status"
fi

if rg -q "testCodexDirectWebSocketConnectInitializeAndSessionFlow\\(\\)' skipped" "$XCODEBUILD_LOG"; then
  echo "Codex E2E failed: test was skipped unexpectedly." >&2
  rg -n "(skipped on|Test skipped -)" "$XCODEBUILD_LOG" | tail -n 20 >&2 || true
  exit 1
fi

echo "Codex E2E passed."
