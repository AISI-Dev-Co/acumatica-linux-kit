The host workspace is shared to Windows as `C:\Acumatica-ERP`. IIS uses `C:\AcumaticaERP` → `D:\AcumaticaERP`. While Windows owns the NTFS volume, Linux sees `AcumaticaERP/` through the `AcumaticaData` CIFS share. With Windows stopped, Linux can mount the image directly. Never attach the image to both systems. An empty `AcumaticaERP/` → check `Automation/Setup/acumatica-data-volume.sh status` before treating source as missing. Registered clients use isolated trees on the same volume. Follow `instances.md`.

The Windows VM is `omarchy-windows` (`dockurr/windows`). SQL is `mssql` at `172.30.0.1:1433` from the guest. Acumatica is exposed at `http://127.0.0.1:38121/AcumaticaERP`. Optional n8n is at `http://127.0.0.1:5678`. The canonical frontend source is `AcumaticaERP/FrontendSources/`.

Use these wrappers rather than fixed guest addresses:

| Need | Command |
|---|---|
| full start / stop | `Automation/Setup/acumatica-up.sh` / `acumatica-down.sh` |
| volume handoff | `Automation/Setup/acumatica-data-volume.sh status` |
| guest shell, PowerShell, or copy | `Automation/Setup/vm-ssh.sh` / `vm-pwsh.sh` / `vm-scp.sh` |
| bridge | `Automation/Setup/vm-ensure-bridge.sh` |
| web tunnel | `Automation/Setup/vm-web-expose.sh <port>` / `vm-web-stop.sh <port>` |
| warm and expose canonical site with VM/SQL already up | `Automation/Setup/acumatica-ready.sh` |
| VM status | `Automation/Setup/vm-status.sh` |
| n8n lifecycle | `Automation/Setup/n8n-up.sh` / `n8n-down.sh` |

For readiness failure, start with `acumatica-up.sh`. When core services are already running, use `acumatica-ready.sh`. Then confirm, in order: `WAS`, `W3SVC`, the `/AcumaticaERP` application under Default Web Site, `AcumaticaERPAppPool`, and `http://127.0.0.1/AcumaticaERP/Frames/Login.aspx` inside Windows. Probe the host tunnel only after the Windows-local request succeeds.

Required canonical IIS state: physical path `C:\AcumaticaERP`, symlink target `D:\AcumaticaERP`, `AcumaticaData` share target `D:\AcumaticaERP`, dedicated `AcumaticaERPAppPool`, and the expected resource and temp/cache directories. Never repair the site by creating another tree. For `Connection_Abandoned_By_ReqQueue` or `Timer_ConnectionIdle` in HTTPERR, verify the junction target, pool identity access, and worker state. For a `BeginRequest` stall after a disk move, stop the pool, force-stop an unresponsive `w3wp` only if needed, clear `C:\TemporaryAspFiles\AcumaticaERP`, then restart. A cold compile can take minutes and more than 1 GB.
