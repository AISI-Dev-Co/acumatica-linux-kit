#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_vm_common.sh"

require_host_bin docker
require_running_container "$VM_CONTAINER"
require_vm_credentials
ensure_container_bins ssh sshpass

if (($# == 0)); then
	VM_IP="$(resolve_vm_ip)"
	password_file="$(create_vm_password_file)"
	trap 'docker exec "$VM_CONTAINER" rm -f "$password_file" >/dev/null 2>&1 || true' EXIT
	docker exec -it "$VM_CONTAINER" sshpass -f "$password_file" ssh "${VM_SSH_OPTS[@]}" -p "$VM_SSH_PORT" "$VM_USER@$VM_IP"
	exit $?
fi

remote_cmd="$*"
docker_vm_ssh "$remote_cmd"
