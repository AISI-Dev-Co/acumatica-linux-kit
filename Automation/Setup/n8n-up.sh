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
	docker logs --tail 40 "$N8N_CONTAINER" >&2 || true
}
trap diagnose EXIT

docker volume create n8n_data >/dev/null
# Retire the forward from older kit releases. Windows callbacks are opt-in.
remove_vm_socat_forward 5678

docker compose -f "$COMPOSE_FILE" config -q
timeout --foreground "$START_TIMEOUT_SECONDS" env -u N8N_PUBLIC_URL docker compose -f "$COMPOSE_FILE" up -d n8n

n8n_healthy() {
	[[ "$(docker inspect "$N8N_CONTAINER" --format '{{.State.Running}}' 2>/dev/null)" == true ]] &&
		curl -fsS --max-time 5 http://127.0.0.1:5678/healthz | grep -Fq '"status":"ok"'
}
wait_until "$TIMEOUT_SECONDS" 2 "n8n HTTP health" n8n_healthy

n8n_reaches_acumatica() {
	docker exec "$N8N_CONTAINER" node -e '
		const url = new URL(process.env.ACUMATICA_BASE_URL + "/Frames/BrowserWarning.aspx");
		const req = require("http").get(url, res => {
			res.resume();
			res.on("end", () => process.exit(res.statusCode === 200 ? 0 : 1));
		});
		req.setTimeout(5000, () => req.destroy(new Error("timeout")));
		req.on("error", () => process.exit(1));
	'
}
wait_until 60 3 "n8n-to-Acumatica HTTP" n8n_reaches_acumatica

trap - EXIT
printf 'n8n ready: http://127.0.0.1:5678\n'
