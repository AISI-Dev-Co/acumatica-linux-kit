#!/usr/bin/env bash
set -euo pipefail

ACUMATICA_RUNTIME_DIR="${ACUMATICA_RUNTIME_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/acumatica-runtime}"
ACUMATICA_RUNTIME_COMPOSE="${ACUMATICA_RUNTIME_COMPOSE:-$ACUMATICA_RUNTIME_DIR/compose.yml}"

runtime_env_value() {
	local file="$1"
	local key="$2"
	local line value

	[[ -r "$file" ]] || return 0
	line="$(grep -m 1 -E "^${key}=" "$file" 2>/dev/null || true)"
	value="${line#*=}"
	value="${value%$'\r'}"
	if [[ "$value" == \"*\" && "$value" == *\" ]] || [[ "$value" == \'*\' && "$value" == *\' ]]; then
		value="${value:1:${#value}-2}"
	fi
	printf '%s\n' "$value"
}

VM_CONTAINER="${VM_CONTAINER:-omarchy-windows}"
MSSQL_CONTAINER="${MSSQL_CONTAINER:-mssql}"
N8N_CONTAINER="${N8N_CONTAINER:-n8n}"
VM_USER="${VM_USER:-$(runtime_env_value "$ACUMATICA_RUNTIME_DIR/windows.env" USERNAME)}"
VM_PASSWORD="${VM_PASSWORD:-$(runtime_env_value "$ACUMATICA_RUNTIME_DIR/windows.env" PASSWORD)}"
VM_IP="${VM_IP:-}"
VM_SQL_BRIDGE_IP="${VM_SQL_BRIDGE_IP:-172.30.0.1}"
VM_SQL_BRIDGE_PORT="${VM_SQL_BRIDGE_PORT:-1433}"
VM_SSH_PORT="${VM_SSH_PORT:-22}"
VM_WEB_BRIDGE_PORT="${VM_WEB_BRIDGE_PORT:-8080}"
ACUMATICA_ENV_LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/acumatica-environment-${UID}.lock"

VM_SSH_OPTS=(
	-o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null
	-o LogLevel=ERROR
	-o ConnectTimeout=10
	-o ConnectionAttempts=1
	-o ServerAliveInterval=15
	-o ServerAliveCountMax=2
)

fail() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

require_host_bin() {
	command -v "$1" >/dev/null 2>&1 || fail "missing required host binary: $1"
}

require_container() {
	docker inspect "$VM_CONTAINER" >/dev/null 2>&1 || fail "container not found: $VM_CONTAINER"
}

require_running_container() {
	local container="${1:-$VM_CONTAINER}"
	docker inspect "$container" >/dev/null 2>&1 || fail "container not found: $container"
	[[ "$(docker inspect "$container" --format '{{.State.Running}}')" == true ]] || fail "container is not running: $container"
}

require_vm_credentials() {
	[[ -n "$VM_USER" ]] || fail "VM_USER is unset and USERNAME is missing from $ACUMATICA_RUNTIME_DIR/windows.env"
	[[ -n "$VM_PASSWORD" ]] || fail "VM_PASSWORD is unset and PASSWORD is missing from $ACUMATICA_RUNTIME_DIR/windows.env"
}

acquire_environment_lock() {
	[[ "${ACUMATICA_ENV_LOCK_HELD:-}" == 1 ]] && return 0
	require_host_bin flock
	local wait_seconds="${ACUMATICA_LOCK_TIMEOUT_SECONDS:-30}"
	exec {ACUMATICA_ENV_LOCK_FD}>"$ACUMATICA_ENV_LOCK_FILE"
	flock -w "$wait_seconds" "$ACUMATICA_ENV_LOCK_FD" || fail "another Acumatica environment operation holds $ACUMATICA_ENV_LOCK_FILE"
	export ACUMATICA_ENV_LOCK_HELD=1 ACUMATICA_ENV_LOCK_FD
}

# Call only in children that must not extend the lifetime of the operation lock.
drop_environment_lock() {
	# Python subprocesses inherit the marker but may close or reuse the descriptor.
	if [[ -n "${ACUMATICA_ENV_LOCK_FD:-}" && "/proc/self/fd/$ACUMATICA_ENV_LOCK_FD" -ef "$ACUMATICA_ENV_LOCK_FILE" ]]; then
		exec {ACUMATICA_ENV_LOCK_FD}>&-
	fi
	unset ACUMATICA_ENV_LOCK_FD ACUMATICA_ENV_LOCK_HELD
}

wait_until() {
	local timeout_seconds="$1"
	local interval_seconds="$2"
	local label="$3"
	shift 3
	local started=$SECONDS
	local deadline=$((SECONDS + timeout_seconds))
	local attempt_limit="${WAIT_ATTEMPT_TIMEOUT_SECONDS:-30}"
	local remaining attempt_timeout probe_pid watchdog_pid rc
	command -v pkill >/dev/null 2>&1 || fail "missing required host binary: pkill"

	printf 'waiting: %s' "$label"
	while ((SECONDS < deadline)); do
		remaining=$((deadline - SECONDS))
		attempt_timeout=$((remaining < attempt_limit ? remaining : attempt_limit))
		( "$@" ) >/dev/null 2>&1 &
		probe_pid=$!
		(
			drop_environment_lock
			sleep "$attempt_timeout"
			if kill -0 "$probe_pid" >/dev/null 2>&1; then
				pkill -TERM -P "$probe_pid" >/dev/null 2>&1 || true
				kill -TERM "$probe_pid" >/dev/null 2>&1 || true
				sleep 2
				pkill -KILL -P "$probe_pid" >/dev/null 2>&1 || true
				kill -KILL "$probe_pid" >/dev/null 2>&1 || true
			fi
		) &
		watchdog_pid=$!
		if wait "$probe_pid"; then rc=0; else rc=$?; fi
		kill "$watchdog_pid" >/dev/null 2>&1 || true
		wait "$watchdog_pid" >/dev/null 2>&1 || true
		if ((rc == 0)); then
			printf ' (%ss)\n' "$((SECONDS - started))"
			return 0
		fi
		printf '.'
		sleep "$interval_seconds"
	done
	printf '\n' >&2
	fail "timed out after ${timeout_seconds}s waiting for $label"
}

resolve_vm_ip() {
	if [[ -n "${VM_IP:-}" ]]; then
		printf '%s\n' "$VM_IP"
		return 0
	fi

	local detected_ip
	detected_ip="$(docker exec "$VM_CONTAINER" sh -lc "awk '/socket address = / { print \$4; exit }' /etc/samba/smb.conf 2>/dev/null" | tr -d '\r')"
	if [[ -n "$detected_ip" ]]; then
		VM_IP="$detected_ip"
		printf '%s\n' "$VM_IP"
		return 0
	fi

	fail "unable to determine guest VM IP inside $VM_CONTAINER"
}

resolve_vm_container_bridge_ip() {
	local detected_ip
	detected_ip="$(docker inspect "$VM_CONTAINER" --format '{{range $name,$v := .NetworkSettings.Networks}}{{if eq $name "bridge"}}{{$v.IPAddress}}{{end}}{{end}}' | tr -d '\r')"
	[[ -n "$detected_ip" ]] || fail "unable to determine bridge IP for $VM_CONTAINER"
	printf '%s\n' "$detected_ip"
}

container_has_bin() {
	docker exec "$VM_CONTAINER" sh -lc "command -v $1 >/dev/null 2>&1"
}

ensure_container_bins() {
	local missing=()
	local name
	for name in "$@"; do
		if ! container_has_bin "$name"; then
			missing+=("$name")
		fi
	done

	((${#missing[@]} == 0)) || fail "container $VM_CONTAINER is missing: ${missing[*]}"
}

docker_vm_ssh() {
	local vm_ip
	require_vm_credentials
	vm_ip="$(resolve_vm_ip)"
	printf '%s\n' "$VM_PASSWORD" | docker exec -i "$VM_CONTAINER" \
		sh -c 'exec 3<&0; exec sshpass -d 3 "$@"' sh \
		ssh "${VM_SSH_OPTS[@]}" -p "$VM_SSH_PORT" "$VM_USER@$vm_ip" "$@"
}

docker_vm_scp() {
	require_vm_credentials
	printf '%s\n' "$VM_PASSWORD" | docker exec -i "$VM_CONTAINER" \
		sh -c 'exec 3<&0; exec sshpass -d 3 "$@"' sh \
		scp "${VM_SSH_OPTS[@]}" -P "$VM_SSH_PORT" "$@"
}

create_vm_password_file() {
	local password_file="/tmp/.vm-password.${BASHPID}.${RANDOM}"
	printf '%s\n' "$VM_PASSWORD" | docker exec -i "$VM_CONTAINER" sh -c 'umask 077; cat >"$1"' sh "$password_file"
	printf '%s\n' "$password_file"
}

mssql_ready() {
	docker exec "$MSSQL_CONTAINER" bash -lc '
		tool=""
		for candidate in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do
			if [ -x "$candidate" ]; then tool="$candidate"; break; fi
		done
		[ -n "$tool" ] || exit 1
		"$tool" -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -l 5 -b -Q "SET NOCOUNT ON; SELECT 1" >/dev/null
	' >/dev/null 2>&1
}

ensure_vm_socat_forward() {
	local listen_port="$1"
	local target="$2"
	local log_file="$3"
	require_host_bin timeout

	timeout --foreground --kill-after=2 "${VM_SOCAT_COMMAND_TIMEOUT_SECONDS:-30}" \
		docker exec -i "$VM_CONTAINER" sh -s -- "$listen_port" "$target" "$log_file" <<'SH'
set -eu
listen_port="$1"
target="$2"
log_file="$3"
expected="socat TCP-LISTEN:${listen_port},bind=0.0.0.0,fork,reuseaddr TCP:${target}"

exact_pids() {
	ps -eo pid=,args= | while read -r pid args; do
		[ "$args" = "$expected" ] && printf '%s\n' "$pid"
	done
}

managed_pids() {
	prefix="socat TCP-LISTEN:${listen_port},bind=0.0.0.0,fork,reuseaddr TCP:"
	ps -eo pid=,args= | while read -r pid args; do
		case "$args" in "$prefix"*) printf '%s\n' "$pid" ;; esac
	done
}

for pid in $(exact_pids); do
	if ss -H -ltnp "sport = :${listen_port}" 2>/dev/null | grep -Fq "pid=${pid},"; then
		exit 0
	fi
done

for pid in $(managed_pids); do kill "$pid" 2>/dev/null || true; done
i=0
while { [ -n "$(managed_pids)" ] || ss -H -ltn "sport = :${listen_port}" 2>/dev/null | grep -q .; } && [ "$i" -lt 30 ]; do
	i=$((i + 1))
	sleep 0.1
done
for pid in $(managed_pids); do kill -KILL "$pid" 2>/dev/null || true; done
rm -f "$log_file"
nohup socat "TCP-LISTEN:${listen_port},bind=0.0.0.0,fork,reuseaddr" "TCP:${target}" >"$log_file" 2>&1 &

i=0
while [ "$i" -lt 40 ]; do
	for pid in $(exact_pids); do
		if ss -H -ltnp "sport = :${listen_port}" 2>/dev/null | grep -Fq "pid=${pid},"; then
			exit 0
		fi
	done
	i=$((i + 1))
	sleep 0.1
done

cat "$log_file" >&2 2>/dev/null || true
exit 1
SH
}

remove_vm_socat_forward() {
	local listen_port="$1"
	require_host_bin timeout

	timeout --foreground --kill-after=2 "${VM_SOCAT_COMMAND_TIMEOUT_SECONDS:-30}" \
		docker exec -i "$VM_CONTAINER" sh -s -- "$listen_port" <<'SH'
listen_port="$1"
prefix="socat TCP-LISTEN:${listen_port},bind=0.0.0.0,fork,reuseaddr TCP:"
ps -eo pid=,args= | while read -r pid args; do
	case "$args" in "$prefix"*) kill "$pid" 2>/dev/null || true ;; esac
done
SH
}

is_managed_web_tunnel_pid() {
	local pid="$1"
	local port="$2"
	local args

	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	args="$(ps -p "$pid" -o args= 2>/dev/null)" || return 1
	[[ "$args" == ssh\ -N\ -g\ -L\ *":${port}:"* ]] &&
		[[ "$args" == *"-o ProxyCommand=docker exec -i ${VM_CONTAINER} nc "* ]] &&
		[[ "$args" == *" ${VM_USER}@windows-vm" ]]
}

managed_web_tunnel_pids() {
	local port="$1"
	local pid

	while read -r pid; do
		if is_managed_web_tunnel_pid "$pid" "$port"; then
			printf '%s\n' "$pid"
		fi
	done < <(pgrep -f '^ssh -N -g -L ' || true)
}
