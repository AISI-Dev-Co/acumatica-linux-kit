---
name: environment
description: "Use for Acumatica runtime topology, VM, IIS, SQL, n8n, mounts, tunnels, or reachability."
---

For initial setup, load the applicable setup skill.

Load `references/instances.md` for client instance creation, swapping, parallel sites, dependency-set publishing, checkpoints, or reset. Keep each registered client's site, pool, and database isolated.

Run `Automation/Setup/acumatica-up.sh` for the complete runtime and `acumatica-down.sh` for complete shutdown. Use `acumatica-ready.sh` only with VM and SQL already running to warm and expose the canonical site. It neither selects clients nor starts n8n. Follow the failing startup stage and bounded diagnostics before recovery. Never persist a guest IP.

Keep runtime/connectivity diagnosis separate from source behavior and API contract design.

## VM, IIS, and data volume

The host workspace is shared to Windows as `C:\Acumatica-ERP`. IIS uses `C:\AcumaticaERP` → `D:\AcumaticaERP`. While Windows owns the NTFS volume, Linux sees `AcumaticaERP/` through the `AcumaticaData` CIFS share. With Windows stopped, Linux can mount the image directly. Never attach the image to both systems. An empty `AcumaticaERP/` → check `Automation/Setup/acumatica-data-volume.sh status` before treating source as missing. Registered clients use isolated trees on the same volume.

The Windows VM is `acumatica-windows` (`dockurr/windows`). SQL is `mssql` at `172.30.0.1:1433` from the guest. Acumatica is exposed at `http://127.0.0.1:38121/AcumaticaERP`. Optional n8n is at `http://127.0.0.1:5678`. The canonical frontend source is `AcumaticaERP/FrontendSources/`.

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

For IIS readiness failures, confirm in order: `WAS`, `W3SVC`, the `/AcumaticaERP` application under Default Web Site, `AcumaticaERPAppPool`, and `http://127.0.0.1/AcumaticaERP/Frames/Login.aspx` inside Windows. Probe the host tunnel only after the Windows-local request succeeds.

Required canonical IIS state: physical path `C:\AcumaticaERP`, symlink target `D:\AcumaticaERP`, `AcumaticaData` share target `D:\AcumaticaERP`, dedicated `AcumaticaERPAppPool`, and the expected resource and temp/cache directories. Never repair the site by creating another tree. For `Connection_Abandoned_By_ReqQueue` or `Timer_ConnectionIdle` in HTTPERR, verify the junction target, pool identity access, and worker state. For a `BeginRequest` stall after a disk move, stop the pool, force-stop an unresponsive `w3wp` only if needed, clear `C:\TemporaryAspFiles\AcumaticaERP`, then restart. A cold compile can take minutes and more than 1 GB.

## SQL and n8n

Use `Automation/Setup/n8n-up.sh` and `n8n-down.sh` for local n8n. Host networking lets n8n reach the existing Acumatica tunnel. n8n listens on `127.0.0.1:5678` only. There is no Windows-to-n8n callback route by default. If a workflow needs callbacks, design a private route for that workflow instead of widening the default listener.

Run `Automation/Setup/acumatica-up.sh` without `--core-only` for the full stack. For an already-ready canonical site, use `n8n-up.sh`. It creates or reuses `n8n_data` and verifies both n8n health and n8n-to-Acumatica HTTP. Complete first-time owner setup in the browser. Save the disposable owner login in `dev-logins.env` under the runtime directory. Don't reset an existing owner account. The owner account is not an Acumatica API credential. Configure workflow authentication and tenant separately, then verify a read-only request before enabling writes.

Use the container `n8n` CLI for workflow inspection, import, or export when the n8n API returns `401`. For Acumatica OAuth or API failures, load the applicable integration skill.

MSSQL runs in `mssql` with volume `acumatica-mssql-data`. Probe it with container `sqlcmd`; the guest endpoint is `172.30.0.1:1433`. When UI state is ambiguous, use read-only queries to verify integration results.

Trace connectivity in this order:

1. Windows guest → authenticated SQL query against `AcumaticaDB` via `Automation/Setup/vm-pwsh.sh < Automation/Setup/check-acumatica-sql.ps1`
2. Windows-local → IIS `127.0.0.1:80`
3. Host → Acumatica `127.0.0.1:38121`
4. n8n → Acumatica `127.0.0.1:38121`
5. Host → n8n `http://127.0.0.1:5678/healthz`
