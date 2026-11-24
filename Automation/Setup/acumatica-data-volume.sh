#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_vm_common.sh"

REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
MOUNT_POINT="${ACUMATICA_DATA_MOUNT_POINT:-$REPO_ROOT/AcumaticaERP}"
DISK_IMAGE="${ACUMATICA_DATA_DISK_IMAGE:-$HOME/.windows-acumatica-data/data2.img}"
CIFS_SOURCE="${ACUMATICA_DATA_CIFS_SOURCE:-//127.0.0.1/AcumaticaData}"
VOLUME_ROOT="${ACUMATICA_DATA_VOLUME_ROOT:-$HOME/.local/share/acumatica-data-volume}"
DATA_ROOT="$VOLUME_ROOT/AcumaticaERP"

exact_mount() {
	findmnt -rn -M "$1" -o FSTYPE,SOURCE 2>/dev/null || true
}

mount_status() {
	local current
	current="$(exact_mount "$1")"
	printf '%s\n' "${current:-unmounted}"
}

require_mount_point() {
	[[ -d "$MOUNT_POINT" ]] || fail "Acumatica data mount point is missing: $MOUNT_POINT"
	[[ -d "$DATA_ROOT" ]] || fail "Acumatica data root is missing: $DATA_ROOT"
}

verify_tree() {
	[[ -f "$MOUNT_POINT/Bin/PX.Data.dll" ]] || fail "Acumatica repository mount does not contain the website tree"
}

mount_from_fstab() {
	if ! mount "$1"; then
		sudo -n /usr/bin/mount "$1" ||
			fail "cannot mount $1; check fstab and obtain approved elevation if the mount helper requires it"
	fi
}

unmount_data() {
	local path
	for path in "$MOUNT_POINT" "$DATA_ROOT" "$VOLUME_ROOT"; do
		[[ -n "$(exact_mount "$path")" ]] || continue
		# The operator normally owns these fstab mounts. Root-owned mounts
		# require separately authorised elevation, never an unattended prompt.
		if ! umount "$path" 2>/dev/null; then
			sudo -n /usr/bin/umount "$path" ||
				fail "cannot unmount $path; resolve the mount or unmount it with approved elevation"
		fi
	done
	[[ -z "$(exact_mount "$MOUNT_POINT")$(exact_mount "$DATA_ROOT")$(exact_mount "$VOLUME_ROOT")" ]] ||
		fail "Acumatica data volume is still mounted"
}

mount_running() {
	local current
	require_host_bin mount
	require_host_bin findmnt
	require_host_bin timeout
	require_mount_point
	current="$(exact_mount "$DATA_ROOT")"
	if [[ "$current" == cifs\ "$CIFS_SOURCE" ]]; then
		[[ -n "$(exact_mount "$MOUNT_POINT")" ]] || mount_from_fstab "$MOUNT_POINT"
		verify_tree
		return 0
	fi
	[[ -z "$current" ]] || fail "refusing to replace active Acumatica data backing mount: $current"
	[[ -z "$(exact_mount "$VOLUME_ROOT")" ]] || fail "refusing to mount the Windows share over the local NTFS view"
	timeout --foreground 10 bash -c 'exec 3<>/dev/tcp/127.0.0.1/38145' 2>/dev/null ||
		fail "Windows Acumatica data share is unreachable on 127.0.0.1:38145"
	mount_from_fstab "$CIFS_SOURCE"
	mount_from_fstab "$MOUNT_POINT"
	current="$(exact_mount "$DATA_ROOT")"
	[[ "$current" == cifs\ "$CIFS_SOURCE" ]] || fail "unexpected running Acumatica data backing mount: $current"
	[[ -n "$(exact_mount "$MOUNT_POINT")" ]] || fail "Acumatica repository bind mount is missing"
	verify_tree
}

mount_stopped() {
	local current vm_state
	require_host_bin docker
	require_host_bin mount
	require_host_bin findmnt
	require_mount_point
	# A failed Docker query does not prove that the guest stopped.
	vm_state="$(docker ps -a --filter "name=^/${VM_CONTAINER}$" --format '{{.State}}')" ||
		fail "cannot confirm Windows is stopped; refusing a raw NTFS mount"
	case "$vm_state" in
		""|created|exited) ;;
		*) fail "refusing to mount the data disk while Windows container is $vm_state" ;;
	esac
	current="$(exact_mount "$VOLUME_ROOT")"
	if [[ "$current" == ntfs3\ * ]]; then
		[[ -n "$(exact_mount "$MOUNT_POINT")" ]] || mount_from_fstab "$MOUNT_POINT"
		verify_tree
		return 0
	fi
	[[ -z "$current" ]] || fail "refusing to replace active Acumatica data backing mount: $current"
	[[ -z "$(exact_mount "$DATA_ROOT")" ]] || fail "refusing to mount NTFS while the Windows share is active"
	[[ -f "$DISK_IMAGE" ]] || fail "Acumatica data disk image is missing: $DISK_IMAGE"
	mount_from_fstab "$DISK_IMAGE"
	[[ -d "$DATA_ROOT/Bin" ]] || fail "mounted NTFS volume does not contain AcumaticaERP"
	mount_from_fstab "$MOUNT_POINT"
	current="$(exact_mount "$VOLUME_ROOT")"
	[[ "$current" == ntfs3\ * ]] || fail "unexpected stopped Acumatica data backing mount: $current"
	[[ -n "$(exact_mount "$MOUNT_POINT")" ]] || fail "Acumatica repository bind mount is missing"
	verify_tree
}

case "${1:-status}" in
	mount-running)
		acquire_environment_lock
		mount_running
		;;
	mount-stopped)
		acquire_environment_lock
		mount_stopped
		;;
	unmount)
		acquire_environment_lock
		unmount_data
		;;
	status)
		printf 'repository: %s\n' "$(mount_status "$MOUNT_POINT")"
		printf 'share:      %s\n' "$(mount_status "$DATA_ROOT")"
		printf 'volume:     %s\n' "$(mount_status "$VOLUME_ROOT")"
		;;
	*)
		printf 'usage: %s {mount-running|mount-stopped|unmount|status}\n' "${0##*/}" >&2
		exit 2
		;;
esac
