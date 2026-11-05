#!/usr/bin/env bash
# One gate for all offline checks. Run from anywhere: scripts/check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

step() { printf '\n== %s\n' "$1"; }

step "Node version (>= 22.12)"
node -e '
  const [maj, min] = process.versions.node.split(".").map(Number);
  if (maj < 22 || (maj === 22 && min < 12)) { console.error("Node >= 22.12 required, found " + process.version); process.exit(1); }
  console.log(process.version);
'

step "JSON files parse"
for f in .claude/settings.json gateway/package.json gateway/config.example.json gateway/test/fixtures/*.json; do
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$f"
  echo "ok  $f"
done

step "Gateway dependencies installed"
if [ ! -f gateway/node_modules/ws/package.json ]; then
  echo "Missing gateway/node_modules. Run: npm ci --prefix gateway" >&2
  exit 1
fi
echo "ok  ws $(node -p 'require("./gateway/node_modules/ws/package.json").version')"

step "Syntax check"
while IFS= read -r -d '' f; do
  node --check "$f"
done < <(find gateway/src gateway/test gateway/scripts scripts -type f \( -name '*.js' -o -name '*.mjs' \) -print0)
echo "ok"

step "Gateway tests"
npm test --prefix gateway --silent

step "Gateway dry run with the example config"
node gateway/src/main.js --config gateway/config.example.json --dry-run > /dev/null
echo "ok"

step "No secrets in the overlay"
if grep -rInE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' --exclude-dir=node_modules --exclude-dir=.git gateway docs deploy scripts .claude CLAUDE.md FORK.md 2>/dev/null; then
  echo "Private key material found" >&2
  exit 1
fi
if grep -nE '"(token|secret|password)"[[:space:]]*:' gateway/config.example.json; then
  echo "A raw secret key name is in gateway/config.example.json" >&2
  exit 1
fi
echo "ok"

step "Docs cross-check"
node scripts/check-docs.mjs

step "Swift package tests (macOS only)"
if [ "$(uname -s)" = "Darwin" ] && command -v swift > /dev/null 2>&1; then
  for pkg in AgmenteTransport ACPClient AppServerClient; do
    if [ -d "$pkg" ]; then
      swift test --package-path "$pkg"
    fi
  done
else
  echo "SKIP: Swift package tests need macOS (ACPClient uses Network.framework)"
fi

printf '\nAll checks passed.\n'
