#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_vm_common.sh"

require_host_bin docker
require_host_bin timeout
require_running_container "$VM_CONTAINER"
require_running_container "$MSSQL_CONTAINER"
acquire_environment_lock

if ! docker inspect -f '{{if .NetworkSettings.Networks.bridge}}yes{{end}}' "$VM_CONTAINER" | grep -qx yes; then
	docker network connect bridge "$VM_CONTAINER"
fi

VM_IP="$(resolve_vm_ip)"
MSSQL_IP="$(docker inspect "$MSSQL_CONTAINER" --format '{{range $name,$v := .NetworkSettings.Networks}}{{if eq $name "bridge"}}{{$v.IPAddress}}{{end}}{{end}}' | tr -d '\r')"
[[ -n "$MSSQL_IP" ]] || fail "unable to determine bridge IP for $MSSQL_CONTAINER"

timeout --foreground --kill-after=5 "${VM_BRIDGE_SETUP_TIMEOUT_SECONDS:-300}" docker exec "$VM_CONTAINER" sh -lc '
	set -eu
	missing=""
	for name in socat ssh sshpass nc ss iptables; do
		command -v "$name" >/dev/null 2>&1 || missing="$missing $name"
	done
	if [ -n "$missing" ]; then
		export DEBIAN_FRONTEND=noninteractive
		apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=20 update
		apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=20 install -y \
			socat openssh-client sshpass netcat-openbsd iproute2 iptables
	fi

	default_if="$(ip route show default | awk '"'"'NR == 1 { print $5 }'"'"')"
	if [ -n "${default_if:-}" ] && ! iptables -t nat -C POSTROUTING -o "$default_if" -j MASQUERADE >/dev/null 2>&1; then
		iptables -t nat -A POSTROUTING -o "$default_if" -j MASQUERADE
	fi
'

ensure_vm_socat_forward 2222 "${VM_IP}:22" /tmp/socat-ssh.log
ensure_vm_socat_forward "$VM_SQL_BRIDGE_PORT" "${MSSQL_IP}:1433" /tmp/socat-mssql.log
ensure_vm_socat_forward "$VM_WEB_BRIDGE_PORT" "${VM_IP}:80" /tmp/socat-web.log

printf 'VM bridges configured: ssh :2222, SQL :%s, web :%s\n' "$VM_SQL_BRIDGE_PORT" "$VM_WEB_BRIDGE_PORT"
