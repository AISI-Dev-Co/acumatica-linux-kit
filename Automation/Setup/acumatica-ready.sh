#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if (($# > 1)); then
	printf 'usage: %s [port]\n' "${0##*/}" >&2
	exit 2
fi
exec "$SCRIPT_DIR/acumatica-instance.sh" ready default --port "${1:-38121}"
