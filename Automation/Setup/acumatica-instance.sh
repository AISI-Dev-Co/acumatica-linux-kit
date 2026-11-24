#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_vm_common.sh"
require_host_bin python3
acquire_environment_lock
export ACUMATICA_RUNTIME_DIR VM_SQL_BRIDGE_IP VM_CONTAINER MSSQL_CONTAINER N8N_CONTAINER
python3 "$SCRIPT_DIR/instances/control.py" "$@"
