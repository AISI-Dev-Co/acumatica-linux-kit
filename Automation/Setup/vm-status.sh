#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_vm_common.sh"

require_host_bin docker
require_host_bin curl
require_host_bin timeout
healthy=true

printf 'Acumatica data:\n'
"$SCRIPT_DIR/acumatica-data-volume.sh" status || healthy=false
printf '\n'

printf '%-18s %-10s %s\n' CONTAINER STATUS IMAGE
for container in "$VM_CONTAINER" "$MSSQL_CONTAINER" "$N8N_CONTAINER"; do
	if docker inspect "$container" >/dev/null 2>&1; then
		docker inspect "$container" --format '{{printf "%-18s %-10s %s" .Name .State.Status .Config.Image}}'
		[[ "$(docker inspect "$container" --format '{{.State.Running}}')" == true ]] || healthy=false
	else
		printf '%-18s %-10s %s\n' "$container" missing '-'
		healthy=false
	fi
done

if [[ "$(docker inspect "$VM_CONTAINER" --format '{{.State.Running}}' 2>/dev/null)" == true ]]; then
	printf '\nWindows guest:\n'
	if ! timeout --foreground 20 "$SCRIPT_DIR/vm-ssh.sh" 'hostname && whoami'; then
		printf 'SSH probe failed\n' >&2
		healthy=false
	fi
	if ! timeout --foreground 30 "$SCRIPT_DIR/vm-pwsh.sh" '
$ErrorActionPreference="Stop"
Import-Module WebAdministration
function Test-Tcp($HostName, $Port) {
	$client=New-Object Net.Sockets.TcpClient
	try { $ar=$client.BeginConnect($HostName,$Port,$null,$null); $ok=$ar.AsyncWaitHandle.WaitOne(5000); if($ok){$client.EndConnect($ar)}; return $ok }
	finally { $client.Close() }
}
$was=(Get-Service WAS).Status
$w3svc=(Get-Service W3SVC).Status
$pool=(Get-WebAppPoolState AcumaticaERPAppPool).Value
$sql=Test-Tcp "172.30.0.1" 1433
$n8n=Test-Tcp "172.30.0.1" 5678
Write-Output ("WAS="+$was)
Write-Output ("W3SVC="+$w3svc)
Write-Output ("Pool="+$pool)
Write-Output ("SQLTcp="+$sql)
Write-Output ("N8nTcp="+$n8n)
if ($was -ne "Running" -or $w3svc -ne "Running" -or $pool -ne "Started" -or -not $sql -or -not $n8n) { throw "Windows runtime check failed" }
'; then
		printf 'Windows service/connectivity probe failed\n' >&2
		healthy=false
	fi
	printf '\nVM bridge listeners:\n'
	docker exec "$VM_CONTAINER" sh -lc 'ss -H -ltnp | grep -E ":(2222|1433|5678|8080)\\b" || true'
fi

printf '\nHost HTTP:\n'
if curl -fsS --max-time 10 http://127.0.0.1:38121/AcumaticaERP/Frames/BrowserWarning.aspx >/dev/null; then
	printf 'Acumatica=ready\n'
else
	printf 'Acumatica=unreachable\n'
	healthy=false
fi
if curl -fsS --max-time 10 http://127.0.0.1:5678/healthz | grep -Fq '"status":"ok"'; then
	printf 'n8n=ready\n'
else
	printf 'n8n=unreachable\n'
	healthy=false
fi

[[ "$healthy" == true ]]
