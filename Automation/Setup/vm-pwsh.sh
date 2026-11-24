#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_vm_common.sh"

require_host_bin docker
require_host_bin python
require_running_container "$VM_CONTAINER"
ensure_container_bins ssh sshpass

if (($# > 0)); then
	ps_script="$*"
else
	ps_script="$(cat)"
fi

ps_script="\$ProgressPreference='SilentlyContinue'; \$InformationPreference='SilentlyContinue'; $ps_script"

encoded="$(
	python - "$ps_script" <<'PY'
import base64
import sys

print(base64.b64encode(sys.argv[1].encode("utf-16le")).decode())
PY
)"

docker_vm_ssh "powershell -NoProfile -EncodedCommand $encoded"
