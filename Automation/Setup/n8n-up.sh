#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_vm_common.sh"

require_host_bin docker
require_host_bin curl
require_host_bin timeout
require_running_container "$VM_CONTAINER"
acquire_environment_lock

COMPOSE_FILE="$SCRIPT_DIR/n8n-compose.yml"
TIMEOUT_SECONDS="${N8N_READY_TIMEOUT_SECONDS:-120}"
START_TIMEOUT_SECONDS="${N8N_START_COMMAND_TIMEOUT_SECONDS:-300}"

diagnose() {
	local rc=$?
	((rc == 0)) && return
	printf 'n8n startup failed; recent container log:\n' >&2
	docker logs --tail 40 "$N8N_CONTAINER" >&2 2>/dev/null || true
}
trap diagnose EXIT

docker volume inspect n8n_data >/dev/null 2>&1 || fail "required Docker volume is missing: n8n_data"
"$SCRIPT_DIR/vm-ensure-bridge.sh" >/dev/null

docker compose -f "$COMPOSE_FILE" config -q
timeout --foreground "$START_TIMEOUT_SECONDS" env -u N8N_PUBLIC_URL docker compose -f "$COMPOSE_FILE" up -d n8n

n8n_healthy() {
	[[ "$(docker inspect "$N8N_CONTAINER" --format '{{.State.Running}}' 2>/dev/null)" == true ]] &&
		curl -fsS --max-time 5 http://127.0.0.1:5678/healthz | grep -Fq '"status":"ok"'
}
wait_until "$TIMEOUT_SECONDS" 2 "n8n HTTP health" n8n_healthy

HOST_BRIDGE_IP="$(docker inspect "$VM_CONTAINER" --format '{{range $name,$v := .NetworkSettings.Networks}}{{if eq $name "bridge"}}{{$v.Gateway}}{{end}}{{end}}' | tr -d '\r')"
[[ -n "$HOST_BRIDGE_IP" ]] || fail "unable to determine host bridge gateway for $VM_CONTAINER"
ensure_vm_socat_forward 5678 "${HOST_BRIDGE_IP}:5678" /tmp/socat-n8n.log

windows_n8n_ready() {
	"$SCRIPT_DIR/vm-pwsh.sh" "\$client=New-Object Net.Sockets.TcpClient; try { \$ar=\$client.BeginConnect(\"$VM_SQL_BRIDGE_IP\",5678,\$null,\$null); \$ok=\$ar.AsyncWaitHandle.WaitOne(5000); if(\$ok){\$client.EndConnect(\$ar)}; if(-not \$ok){exit 1} } finally {\$client.Close()}"
}
wait_until 90 3 "Windows-to-n8n TCP" windows_n8n_ready

trap - EXIT
printf 'n8n ready: http://127.0.0.1:5678 (Windows bridge %s:5678)' "$VM_SQL_BRIDGE_IP"
printf '\n'
