#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_vm_common.sh"

require_host_bin ps
require_host_bin pgrep
acquire_environment_lock

PORT="${1:-38121}"
[[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || fail "invalid web tunnel port: $PORT"
PID_FILE="${TMPDIR:-/tmp}/acumatica-vm-web-${PORT}.pid"
stopped=false

while read -r pid; do
	kill "$pid" >/dev/null 2>&1 || true
	stopped=true
done < <(managed_web_tunnel_pids "$PORT")

if pgrep -f "socat TCP-LISTEN:${PORT},bind=0.0.0.0,fork,reuseaddr TCP:" >/dev/null 2>&1; then
	pkill -f "socat TCP-LISTEN:${PORT},bind=0.0.0.0,fork,reuseaddr TCP:" >/dev/null 2>&1 || true
	stopped=true
fi

rm -f "$PID_FILE"

if [[ "$stopped" == true ]]; then
	printf 'stopped web bridge on port %s\n' "$PORT"
else
	printf 'no tracked web bridge running on port %s\n' "$PORT"
fi
