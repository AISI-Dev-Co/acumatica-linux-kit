#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_vm_common.sh"

require_host_bin docker
require_running_container "$VM_CONTAINER"
ensure_container_bins scp sshpass

if (($# != 2)); then
	fail "usage: vm-scp.sh <src> <dest>"
fi

src="$1"
dest="$2"
src_is_remote=0
dest_is_remote=0
scp_args=()

[[ "$src" == *:* ]] && src_is_remote=1
[[ "$dest" == *:* ]] && dest_is_remote=1

if ((src_is_remote == dest_is_remote)); then
	fail "exactly one side must be remote"
fi

cleanup() {
	if [[ -n "${container_tmp:-}" ]]; then
		docker exec "$VM_CONTAINER" rm -rf "$container_tmp" >/dev/null 2>&1 || true
	fi
}

trap cleanup EXIT

container_tmp="/tmp/vm-scp.$$.$RANDOM"

if ((src_is_remote == 0)); then
	[[ -e "$src" ]] || fail "local source not found: $src"
	if [[ -d "$src" ]]; then
		scp_args+=(-r)
	fi
	docker cp "$src" "$VM_CONTAINER:$container_tmp"
	docker_vm_scp "${scp_args[@]}" "$container_tmp" "$dest"
	exit 0
fi

docker_vm_scp "${scp_args[@]}" "$src" "$container_tmp"
docker cp "$VM_CONTAINER:$container_tmp" "$dest"
