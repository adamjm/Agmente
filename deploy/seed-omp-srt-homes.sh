#!/bin/sh
# Copy the omp agent files (omp-config/models.yml and config.yml) into each project home, for the srt runner.
# Under srt there is no image to carry them (the container image bakes them in at /opt/omp-agent), and omp
# reads $HOME/.omp/agent. baseUrl is rewritten from the container address to localhost. That needs
# runner.allowLocalBinding true in the gateway config; the gateway then adds localhost to the agent's hosts.
# Run it again after adding a project that will use the omp runner, or after editing the omp-config files.
# Usage: seed-omp-srt-homes.sh [STATE_DIR]     (default ~/acpcode/state)
set -eu
SRC=$(cd "$(dirname "$0")/omp-config" && pwd)
STATE=${1:-$HOME/acpcode/state}
[ -d "$STATE/homes" ] || { echo "no $STATE/homes" >&2; exit 1; }
for h in "$STATE"/homes/*/; do
  d="${h}.omp/agent"
  mkdir -p "$d"
  sed 's#http://192.168.64.1:18000#http://localhost:18000#' "$SRC/models.yml" > "$d/models.yml"
  cp "$SRC/config.yml" "$d/config.yml"
  chmod 600 "$d/models.yml"
  echo "seeded $d"
done
