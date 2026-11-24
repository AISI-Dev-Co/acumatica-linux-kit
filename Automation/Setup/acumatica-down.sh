#!/usr/bin/env bash
set -Eeuo pipefail

# Full local stack shutdown: n8n -> Windows VM -> MSSQL.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_vm_common.sh"

require_host_bin docker
require_host_bin timeout
require_host_bin flock
acquire_environment_lock

WINDOWS_SERVICE="${ACUMATICA_WINDOWS_SERVICE:-windows}"
MSSQL_SERVICE="${ACUMATICA_MSSQL_SERVICE:-mssql}"
GUEST_SHUTDOWN_TIMEOUT_SECONDS="${GUEST_SHUTDOWN_TIMEOUT_SECONDS:-120}"
CORE_STOP_TIMEOUT_SECONDS="${CORE_STOP_TIMEOUT_SECONDS:-120}"

container_running() {
	local container="$1"
	[[ "$(docker inspect "$container" --format '{{.State.Running}}' 2>/dev/null || true)" == true ]]
}

guest_running() {
	container_running "$VM_CONTAINER" &&
		docker exec "$VM_CONTAINER" pgrep -f '[q]emu-system' >/dev/null 2>&1
}

printf '[1/3] Stopping n8n\n'
if ! "$SCRIPT_DIR/n8n-down.sh"; then
	printf 'warning: normal n8n shutdown failed; removing its container\n' >&2
	docker rm -f "$N8N_CONTAINER" >/dev/null 2>&1 || true
fi

printf '[2/3] Stopping Windows VM\n'
"$SCRIPT_DIR/vm-web-stop.sh" 38121 || true
"$SCRIPT_DIR/acumatica-data-volume.sh" unmount
if guest_running; then
	shutdown_requested=false
	if container_has_bin ssh && container_has_bin sshpass; then
		if timeout --foreground 30 "$SCRIPT_DIR/vm-pwsh.sh" 'Stop-Computer -Force'; then
			shutdown_requested=true
		else
			printf 'warning: Windows rejected the shutdown request; container stop will be used\n' >&2
		fi
	else
		printf 'warning: VM bridge tools are unavailable; container stop will be used\n' >&2
	fi

	if [[ "$shutdown_requested" == true ]]; then
		printf 'waiting: Windows guest shutdown'
		deadline=$((SECONDS + GUEST_SHUTDOWN_TIMEOUT_SECONDS))
		while guest_running && ((SECONDS < deadline)); do
			printf '.'
			sleep 2
		done
		if guest_running; then
			printf '\nwarning: graceful shutdown timed out; container stop will be used\n' >&2
		else
			printf '\n'
		fi
	fi
fi

printf '[3/3] Stopping Windows container and MSSQL\n'
if container_running "$VM_CONTAINER" || container_running "$MSSQL_CONTAINER"; then
	if ! timeout --foreground "$CORE_STOP_TIMEOUT_SECONDS" \
		docker compose -f "$ACUMATICA_RUNTIME_COMPOSE" stop -t 30 "$WINDOWS_SERVICE" "$MSSQL_SERVICE"; then
		printf 'warning: Compose stop failed; stopping named containers directly\n' >&2
		for container in "$VM_CONTAINER" "$MSSQL_CONTAINER"; do
			container_running "$container" && docker stop -t 30 "$container" >/dev/null || true
		done
	fi
else
	printf 'Windows container and MSSQL already stopped\n'
fi

running=()
for container in "$VM_CONTAINER" "$MSSQL_CONTAINER" "$N8N_CONTAINER"; do
	container_running "$container" && running+=("$container")
done
((${#running[@]} == 0)) || fail "stack containers still running: ${running[*]}"

"$SCRIPT_DIR/acumatica-data-volume.sh" mount-stopped

printf 'Acumatica stack stopped: Windows VM, MSSQL, n8n; data volume mounted locally\n'
