#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT="$REPO_ROOT/development/acuminator-vm/acuminator_agent.py"

if [[ ! -f "$AGENT" ]]; then
	echo "error: Acuminator agent wrapper not found: $AGENT" >&2
	exit 1
fi

cmd="analyze"
if [[ $# -gt 0 && ( "$1" == "describe" || "$1" == "analyze" ) ]]; then
	cmd="$1"
	shift
fi

if [[ "$cmd" == "describe" ]]; then
	exec python3 "$AGENT" describe "$@"
fi

has_runner_output=0
for arg in "$@"; do
	if [[ "$arg" == "--include-runner-output" ]]; then
		has_runner_output=1
		break
	fi
done

if [[ $has_runner_output -eq 1 ]]; then
	agent_args=(analyze "$@")
else
	agent_args=(analyze "$@" --include-runner-output)
fi

if [[ "$(uname -s)" == Linux* && "${ACUMINATOR_FORCE_LOCAL:-0}" != "1" ]]; then
	VM_PWSH="$SCRIPT_DIR/vm-pwsh.sh"
	WINDOWS_REPO_ROOT='C:\Acumatica-ERP'
	WINDOWS_AGENT="$WINDOWS_REPO_ROOT\development\acuminator-vm\acuminator_agent.py"

	if [[ ! -x "$VM_PWSH" ]]; then
		echo "error: Windows VM bridge not found: $VM_PWSH" >&2
		exit 1
	fi

	encoded_args="$(python3 - "$REPO_ROOT" "$WINDOWS_REPO_ROOT" "${agent_args[@]}" <<'PY'
import base64
import json
import sys

repo_root, windows_repo_root, *args = sys.argv[1:]
repo_prefix = repo_root.rstrip("/") + "/"

def map_arg(arg: str) -> str:
	if arg == repo_root:
		return windows_repo_root
	if arg.startswith(repo_prefix):
		relative = arg[len(repo_prefix):].replace("/", "\\")
		return windows_repo_root + "\\" + relative
	if arg.startswith("/"):
		raise SystemExit(
			f"error: Linux path is not visible in the Windows VM: {arg}. "
			"Use a path under the repository or set ACUMINATOR_FORCE_LOCAL=1."
		)
	return arg

payload = json.dumps([map_arg(arg) for arg in args]).encode("utf-8")
print(base64.b64encode(payload).decode("ascii"))
PY
)"

	exec "$VM_PWSH" "\$payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encoded_args')); \$agentArgs = @(ConvertFrom-Json \$payload); Set-Location '$WINDOWS_REPO_ROOT'; & python '$WINDOWS_AGENT' @agentArgs; exit \$LASTEXITCODE"
fi

exec python3 "$AGENT" "${agent_args[@]}"
