---
name: environment
description: "Use for Acumatica runtime topology, VM, IIS, SQL, n8n, mounts, tunnels, or reachability."
---

For initial setup, load the setup skill. Load `references/environment.md` for topology, paths, VM, IIS, or tunnels. Load `references/docker-sidecars.md` for n8n or MSSQL. Load only the branch needed for the fault.

Load `references/instances.md` for client instance creation, swapping, parallel sites, dependency-set publishing, checkpoints, or reset. Keep each registered client's site, pool, and database isolated.

Run `Automation/Setup/acumatica-up.sh` for the complete runtime and `acumatica-down.sh` for complete shutdown. Use `acumatica-ready.sh` only with VM and SQL already running to warm and expose the canonical site. It neither selects clients nor starts n8n. Follow the failing startup stage and bounded diagnostics before recovery. Never persist a guest IP.

Keep runtime/connectivity diagnosis separate from source behavior and API contract design.
