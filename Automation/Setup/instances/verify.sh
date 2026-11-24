#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$(cd -- "$HERE/.." && pwd)"
if (($# == 0)); then set -- default clean25; fi
for file in acumatica-instance.sh acumatica-ready.sh acumatica-up.sh n8n-down.sh; do
	bash -n "$SETUP/$file"
done
python -m unittest discover -s "$HERE" -p 'test_*.py' -q
docker compose -f "$SETUP/n8n-compose.yml" config -q
"$SETUP/vm-pwsh.sh" <<'PS'
$ErrorActionPreference = 'Stop'
@(
    Get-ChildItem C:\Acumatica-ERP\Automation\Setup\instances\*.ps1
    Get-Item C:\Acumatica-ERP\Automation\Setup\build-extension-package.ps1
    Get-Item C:\Acumatica-ERP\Automation\Setup\test-build-extension-package.ps1
) | ForEach-Object {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    if ($errors) { throw ($errors.Message -join [Environment]::NewLine) }
    Write-Output ('Parsed ' + $_.Name)
}
& C:\Acumatica-ERP\Automation\Setup\instances\test_guest.ps1
& C:\Acumatica-ERP\Automation\Setup\instances\test_publication.ps1
& C:\Acumatica-ERP\Automation\Setup\test-build-extension-package.ps1 -Builder C:\Acumatica-ERP\Automation\Setup\build-extension-package.ps1
PS
"$SETUP/acumatica-instance.sh" status | python -c '
import json,sys
rows=json.load(sys.stdin)
by_id={r["id"]:r for r in rows}
selected=[by_id[name] for name in sys.argv[1:]]
assert all(r["state"] == "Started" for r in selected), selected
assert len({r["database"] for r in selected}) == len(selected), selected
for row in selected:
    if row["id"] in ("clean", "clean25"):
        assert row["published"] == [], row
print("Verified independent running instances: " + ", ".join(r["id"] for r in selected))
' "$@"
(
	cd "$HERE"
	python - "$@" <<'PY'
import sys
from pathlib import Path
from catalog import load_catalog
from control import wait_for_login
profiles = load_catalog(Path('profiles'))
for name in sys.argv[1:]:
    wait_for_login(profiles[name], 38121)
PY
)
