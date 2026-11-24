#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_vm_common.sh"

CORE_ONLY=false
if [[ "${1:-}" == --core-only && $# == 1 ]]; then
	CORE_ONLY=true
elif (($# != 0)); then
	fail "usage: ${0##*/} [--core-only]"
fi

require_host_bin docker
require_host_bin curl
require_host_bin timeout
require_host_bin flock
require_host_bin ss
require_vm_credentials
acquire_environment_lock

WINDOWS_SERVICE="${ACUMATICA_WINDOWS_SERVICE:-windows}"
MSSQL_SERVICE="${ACUMATICA_MSSQL_SERVICE:-mssql}"
MSSQL_TIMEOUT_SECONDS="${MSSQL_READY_TIMEOUT_SECONDS:-180}"
VM_TIMEOUT_SECONDS="${VM_READY_TIMEOUT_SECONDS:-360}"
GUEST_SQL_TIMEOUT_SECONDS="${GUEST_SQL_READY_TIMEOUT_SECONDS:-90}"
ACUMATICA_READY_TIMEOUT_SECONDS="${ACUMATICA_READY_TIMEOUT_SECONDS:-420}"
N8N_READY_TIMEOUT_SECONDS="${N8N_READY_TIMEOUT_SECONDS:-120}"
CORE_START_TIMEOUT_SECONDS="${CORE_START_TIMEOUT_SECONDS:-600}"
WINDOWS_RUNTIME_IMAGE="${ACUMATICA_WINDOWS_RUNTIME_IMAGE:-acumatica-windows-runtime:2026-08-18}"
WINDOWS_RUNTIME_DOCKERFILE="$SCRIPT_DIR/windows-runtime.Dockerfile"
DATA_VOLUME_SCRIPT="$SCRIPT_DIR/acumatica-data-volume.sh"
stage="preflight"
started=$SECONDS

export ACUMATICA_RUNTIME_DIR ACUMATICA_RUNTIME_COMPOSE
export VM_CONTAINER MSSQL_CONTAINER N8N_CONTAINER VM_USER
export ACUMATICA_READY_TIMEOUT_SECONDS N8N_READY_TIMEOUT_SECONDS
export -n VM_PASSWORD SSHPASS 2>/dev/null || true

diagnose() {
	local rc=$?
	((rc == 0)) && return
	trap - EXIT
	set +e
	diag_run() { timeout --foreground --kill-after=2 10 "$@" >&2 || true; }
	printf '\nAcumatica environment startup failed during: %s\n' "$stage" >&2
	printf '\nContainer state:\n' >&2
	diag_run docker compose -f "$ACUMATICA_RUNTIME_COMPOSE" ps
	for container in "$MSSQL_CONTAINER" "$VM_CONTAINER" "$N8N_CONTAINER"; do
		diag_run docker inspect "$container" --format '{{.Name}} status={{.State.Status}} exit={{.State.ExitCode}} started={{.State.StartedAt}}'
	done
	printf '\nRecent core logs:\n' >&2
	diag_run docker logs --tail 15 "$MSSQL_CONTAINER"
	diag_run docker logs --tail 15 "$VM_CONTAINER"
	if [[ "$(timeout --foreground --kill-after=2 5 docker inspect "$VM_CONTAINER" --format '{{.State.Running}}' 2>/dev/null || true)" == true ]]; then
		diag_run docker exec "$VM_CONTAINER" sh -c 'for bridge in ssh mssql web n8n; do f="/tmp/socat-$bridge.log"; if [ -s "$f" ]; then printf "%s\n" "--- $f"; tail -n 15 "$f"; fi; done'
		diag_run "$SCRIPT_DIR/vm-pwsh.sh" 'Import-Module WebAdministration; Write-Output ("WAS="+(Get-Service WAS).Status); Write-Output ("W3SVC="+(Get-Service W3SVC).Status); Write-Output ("Pool="+(Get-WebAppPoolState AcumaticaERPAppPool).Value)'
	fi
	printf '\nHost listeners:\n' >&2
	ss -H -ltn 2>/dev/null | grep -E ':(1433|5678|38121)\b' >&2 || true
	exit "$rc"
}
trap diagnose EXIT

required_env() {
	local file="$1" key="$2"
	[[ -n "$(runtime_env_value "$file" "$key")" ]] || fail "missing $key in $file"
}

container_running() {
	local container="$1"
	[[ "$(docker inspect "$container" --format '{{.State.Running}}' 2>/dev/null)" == true ]]
}

windows_owns_data() {
	container_running "$VM_CONTAINER" &&
		docker exec "$VM_CONTAINER" pgrep -f '[q]emu-system' >/dev/null 2>&1
}

guest_ssh_ready() {
	docker_vm_ssh "exit 0"
}

guest_sql_ready() {
	"$SCRIPT_DIR/vm-pwsh.sh" "\$client=New-Object Net.Sockets.TcpClient; try { \$ar=\$client.BeginConnect(\"$VM_SQL_BRIDGE_IP\",$VM_SQL_BRIDGE_PORT,\$null,\$null); \$ok=\$ar.AsyncWaitHandle.WaitOne(5000); if(\$ok){\$client.EndConnect(\$ar)}; if(-not \$ok){exit 1} } finally {\$client.Close()}"
}

stage="preflight"
[[ -r "$ACUMATICA_RUNTIME_COMPOSE" ]] || fail "runtime compose file not found: $ACUMATICA_RUNTIME_COMPOSE"
required_env "$ACUMATICA_RUNTIME_DIR/windows.env" USERNAME
required_env "$ACUMATICA_RUNTIME_DIR/windows.env" PASSWORD
required_env "$ACUMATICA_RUNTIME_DIR/mssql.env" ACCEPT_EULA
required_env "$ACUMATICA_RUNTIME_DIR/mssql.env" MSSQL_SA_PASSWORD
[[ "$VM_SQL_BRIDGE_IP" =~ ^[A-Za-z0-9.:-]+$ ]] || fail "invalid VM_SQL_BRIDGE_IP: $VM_SQL_BRIDGE_IP"
[[ "$VM_SQL_BRIDGE_PORT" =~ ^[0-9]+$ ]] && ((VM_SQL_BRIDGE_PORT >= 1 && VM_SQL_BRIDGE_PORT <= 65535)) || fail "invalid VM_SQL_BRIDGE_PORT: $VM_SQL_BRIDGE_PORT"
docker info >/dev/null
docker compose -f "$ACUMATICA_RUNTIME_COMPOSE" config -q
if docker compose -f "$ACUMATICA_RUNTIME_COMPOSE" config --images | grep -Fxq "$WINDOWS_RUNTIME_IMAGE" &&
	! docker image inspect "$WINDOWS_RUNTIME_IMAGE" >/dev/null 2>&1; then
	[[ -r "$WINDOWS_RUNTIME_DOCKERFILE" ]] || fail "Windows runtime Dockerfile is missing: $WINDOWS_RUNTIME_DOCKERFILE"
	docker build -f "$WINDOWS_RUNTIME_DOCKERFILE" -t "$WINDOWS_RUNTIME_IMAGE" "$SCRIPT_DIR/../.."
fi
docker volume inspect acumatica-mssql-data >/dev/null 2>&1 || fail "required Docker volume is missing: acumatica-mssql-data"

if ! windows_owns_data; then
	stage="Acumatica data volume handoff to Windows"
	"$DATA_VOLUME_SCRIPT" unmount
fi

stage="core container startup"
printf '[1/6] Starting Windows VM and SQL Server\n'
timeout --foreground "$CORE_START_TIMEOUT_SECONDS" docker compose -f "$ACUMATICA_RUNTIME_COMPOSE" up -d "$MSSQL_SERVICE" "$WINDOWS_SERVICE"
wait_until 60 2 "SQL container running" container_running "$MSSQL_CONTAINER"
wait_until 60 2 "Windows VM container running" container_running "$VM_CONTAINER"

stage="SQL readiness"
printf '[2/6] Waiting for SQL Server\n'
wait_until "$MSSQL_TIMEOUT_SECONDS" 3 "authenticated SQL query" mssql_ready

stage="VM bridge setup"
printf '[3/6] Configuring VM bridges\n'
"$SCRIPT_DIR/vm-ensure-bridge.sh"

stage="Windows guest readiness"
printf '[4/6] Waiting for Windows guest and SQL route\n'
wait_until "$VM_TIMEOUT_SECONDS" 5 "Windows SSH" guest_ssh_ready
wait_until "$GUEST_SQL_TIMEOUT_SECONDS" 3 "Windows-to-SQL TCP" guest_sql_ready
stage="Windows data share"
"$SCRIPT_DIR/vm-pwsh.sh" '$ErrorActionPreference="Stop"; $root="D:\AcumaticaERP"; if(-not (Test-Path $root -PathType Container)){throw "Acumatica data volume is unavailable: $root"}; $link=Get-Item C:\AcumaticaERP -Force; if([string]($link.Target -join ";") -ne $root){throw "C:\AcumaticaERP does not target $root"}; $share=Get-SmbShare -Name AcumaticaData -ErrorAction Stop; if($share.Path -ne $root){throw "AcumaticaData share targets $($share.Path) instead of $root"}'
"$DATA_VOLUME_SCRIPT" mount-running

if [[ "$CORE_ONLY" == true ]]; then
	trap - EXIT
	printf '\nCore ready in %ss; application pools and n8n were not warmed\n' "$((SECONDS - started))"
	exit 0
fi

stage="Acumatica readiness"
printf '[5/6] Starting IIS and warming Acumatica\n'
"$SCRIPT_DIR/acumatica-ready.sh" 38121

stage="n8n readiness"
printf '[6/6] Starting n8n\n'
"$SCRIPT_DIR/n8n-up.sh"

trap - EXIT
printf '\nEnvironment ready in %ss\n' "$((SECONDS - started))"
printf 'Acumatica: http://127.0.0.1:38121/AcumaticaERP/Frames/Login.aspx?ReturnUrl=%%2fAcumaticaERP%%2fMain\n'
printf 'n8n:       http://127.0.0.1:5678\n'
