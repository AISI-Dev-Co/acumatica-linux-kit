"""Guest RPC through the repository's SSH/SCP wrappers, with private admin requests."""

import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid


class Guest:
    def __init__(self, setup: Path, runtime: Path):
        self.setup = setup
        self.runtime = runtime

    def command(self, name: str, *args: str, capture: bool = False) -> str:
        result = subprocess.run([str(self.setup / name), *args], text=True,
                                stdout=subprocess.PIPE if capture else None, check=True)
        return result.stdout or ""

    def powershell(self, source: str) -> str:
        result = subprocess.run([str(self.setup / "vm-pwsh.sh")], input=source,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=1800)
        if result.returncode:
            raise RuntimeError(result.stdout.strip() or "guest command failed")
        return result.stdout

    def call(self, action: str, *, admin: bool = False, **payload):
        request = {"action": action, **payload}
        script = "C:\\Acumatica-ERP\\Automation\\Setup\\instances\\guest.ps1"
        if admin:
            result = self._private_call(script, request)
        else:
            encoded = base64.b64encode(json.dumps(request).encode()).decode()
            result = self.powershell(f"& '{script}' -RequestBase64 '{encoded}'")
        lines = result.splitlines()
        for line in lines:
            if line.startswith("ACU_RESULT:"):
                return json.loads(line.removeprefix("ACU_RESULT:"))
        raise RuntimeError(f"guest returned no result: {result[-2000:]}")

    def _private_call(self, script: str, request: dict) -> str:
        password = None
        for line in (self.runtime / "mssql.env").read_text().splitlines():
            if line.startswith("MSSQL_SA_PASSWORD="):
                password = line.partition("=")[2].strip().strip("\"'")
                break
        if not password:
            raise ValueError("MSSQL_SA_PASSWORD is missing from runtime mssql.env")
        request = {**request, "sqlPassword": password,
                   "sqlServer": os.environ.get("VM_SQL_BRIDGE_IP", "172.30.0.1")}
        # Credentials never enter process arguments or the shared repository.
        root = "C:\\ProgramData\\AcumaticaInstances"
        self.powershell(f"& '{script}' -Initialize")
        target = subprocess.run(
            ["bash", "-c", 'source "$1"; require_vm_credentials; printf "%s@%s" "$VM_USER" "$(resolve_vm_ip)"',
             "--", str(self.setup / "_vm_common.sh")], text=True, capture_output=True, check=True).stdout
        guest_file = root + "\\request-" + uuid.uuid4().hex + ".json"
        with tempfile.TemporaryDirectory(prefix=".instance-", dir=self.runtime) as temporary:
            local = Path(temporary) / "request.json"
            local.write_text(json.dumps(request))
            local.chmod(0o600)
            try:
                self.command("vm-scp.sh", str(local), f"{target}:{guest_file.replace(chr(92), '/')}", capture=True)
                return self.powershell(f"& '{script}' -RequestFile '{guest_file}'")
            finally:
                # The guest deletes the request immediately after reading it. This also
                # handles an SCP/SSH failure between transfer and execution.
                self.powershell(f"if (Test-Path -LiteralPath '{guest_file}') {{ Remove-Item -LiteralPath '{guest_file}' -Force }}")
