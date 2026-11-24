#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_vm_common.sh"

require_host_bin ssh
require_host_bin ss
require_host_bin ps
require_host_bin pgrep
require_host_bin curl
require_host_bin docker
require_host_bin setsid
require_running_container "$VM_CONTAINER"
require_vm_credentials
acquire_environment_lock

PORT="${1:-38121}"
TARGET_HOST="${VM_WEB_TARGET_HOST:-127.0.0.1}"
TARGET_PORT="${VM_WEB_TARGET_PORT:-80}"
LISTEN_HOST="${VM_WEB_LISTEN_HOST:-127.0.0.1}"
[[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || fail "invalid web tunnel port: $PORT"
[[ "$TARGET_PORT" =~ ^[0-9]+$ ]] && ((TARGET_PORT >= 1 && TARGET_PORT <= 65535)) || fail "invalid web target port: $TARGET_PORT"
PID_FILE="${TMPDIR:-/tmp}/acumatica-vm-web-${PORT}.pid"
LOG_FILE="${TMPDIR:-/tmp}/acumatica-vm-web-${PORT}.log"
tunnel_pattern="ssh -N -g -L ${LISTEN_HOST}:${PORT}:${TARGET_HOST}:${TARGET_PORT}"

"$SCRIPT_DIR/vm-ensure-bridge.sh" >/dev/null

VM_IP="$(resolve_vm_ip)"

rm -f "$PID_FILE"
while read -r existing_pid; do
	existing_args="$(ps -p "$existing_pid" -o args= 2>/dev/null || true)"
	if [[ "$existing_args" == *"$tunnel_pattern"* ]] &&
		ss -H -ltnp "sport = :${PORT}" | grep -Fq "pid=${existing_pid},"; then
		printf '%s\n' "$existing_pid" >"$PID_FILE"
		printf 'web bridge already running on %s:%s (pid %s)\n' "$LISTEN_HOST" "$PORT" "$existing_pid"
		exit 0
	fi
	kill "$existing_pid" >/dev/null 2>&1 || true
done < <(managed_web_tunnel_pids "$PORT")

for _ in {1..40}; do
	[[ -z "$(managed_web_tunnel_pids "$PORT")" ]] && break
	sleep 0.1
done

if ss -H -ltn "sport = :${PORT}" | grep -q .; then
	fail "host port $PORT is already in use"
fi

ASKPASS_FILE="$(mktemp "${TMPDIR:-/tmp}/acumatica-vm-askpass.XXXXXX")"
trap 'rm -f "$ASKPASS_FILE"' EXIT
printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$VM_PASSWORD" >"$ASKPASS_FILE"
chmod 700 "$ASKPASS_FILE"

(
	drop_environment_lock
	exec setsid -f env \
		-u VM_PASSWORD \
		-u SSHPASS \
		SSH_ASKPASS="$ASKPASS_FILE" \
		SSH_ASKPASS_REQUIRE=force \
		DISPLAY=:0 \
		ssh \
		-N -g \
		-L "${LISTEN_HOST}:${PORT}:${TARGET_HOST}:${TARGET_PORT}" \
		-o ExitOnForwardFailure=yes \
		-o ServerAliveInterval=30 \
		-o ServerAliveCountMax=3 \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		-o LogLevel=ERROR \
		-o GatewayPorts=yes \
		-o ProxyCommand="docker exec -i ${VM_CONTAINER} nc ${VM_IP} 22" \
		"${VM_USER}@windows-vm"
) >"$LOG_FILE" 2>&1

for _ in {1..40}; do
	while read -r candidate_pid; do
		candidate_args="$(ps -p "$candidate_pid" -o args= 2>/dev/null || true)"
		if [[ "$candidate_args" == *"$tunnel_pattern"* ]] &&
			ss -H -ltnp "sport = :${PORT}" | grep -Fq "pid=${candidate_pid},"; then
			printf '%s\n' "$candidate_pid" >"$PID_FILE"
			break 2
		fi
	done < <(managed_web_tunnel_pids "$PORT")
	sleep 0.25
done

rm -f "$ASKPASS_FILE"
trap - EXIT

if [[ ! -s "$PID_FILE" ]] || ! kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
	while read -r failed_pid; do
		failed_args="$(ps -p "$failed_pid" -o args= 2>/dev/null || true)"
		if [[ "$failed_args" == *"$tunnel_pattern"* ]]; then
			kill "$failed_pid" >/dev/null 2>&1 || true
		fi
	done < <(managed_web_tunnel_pids "$PORT")
	rm -f "$PID_FILE"
	printf 'error: web bridge failed to start, see %s\n' "$LOG_FILE" >&2
	exit 1
fi

printf 'web bridge listening on %s:%s -> %s:%s via ssh tunnel to %s\n' "$LISTEN_HOST" "$PORT" "$TARGET_HOST" "$TARGET_PORT" "$VM_IP"
