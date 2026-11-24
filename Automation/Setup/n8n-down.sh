#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_vm_common.sh"

require_host_bin docker
require_host_bin timeout
acquire_environment_lock

cleanup() {
	if [[ "$(docker inspect "$VM_CONTAINER" --format '{{.State.Running}}' 2>/dev/null || true)" == true ]]; then
		remove_vm_socat_forward 5678 || true
	fi
}

finish() {
	local rc=$?
	trap - EXIT
	cleanup
	exit "$rc"
}
trap finish EXIT

if docker inspect "$N8N_CONTAINER" >/dev/null 2>&1; then
	timeout --foreground "${N8N_STOP_TIMEOUT_SECONDS:-150}" docker compose -f "$SCRIPT_DIR/n8n-compose.yml" down --timeout 120
fi

trap - EXIT
cleanup
printf 'n8n stopped\n'
