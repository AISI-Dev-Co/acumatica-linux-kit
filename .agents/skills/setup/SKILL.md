---
name: setup
description: "Use when asked to set up this repository or provision the Linux host, Windows VM, SQL Server, Acumatica, or development tools."
---

Run setup from the clone. Do not hand the user the checklist. Inspect first, reuse a matching environment, and execute each stage until verified. Ask only for decisions, licenses, elevation, or guest actions you cannot perform. Do not reset an existing site, credential, VM disk, or SQL volume to get past a failed check.

Load `../environment/SKILL.md` for runtime operations. The environment uses a local Dockur Windows guest, Linux MSSQL container, and a dedicated NTFS data disk. The protected baseline is the build in `Automation/Setup/instances/profiles/default.json`. Use `acumatica-instance.sh` for additional sites after the baseline is ready.

## Host and runtime

- Check x86-64 hardware virtualization and `/dev/kvm`, Docker Engine and Compose v2, Bash, Python 3.10+, curl, OpenSSH, util-linux, `iproute2`, procps, CIFS tooling, and the kernel's `ntfs3` support. Check disk capacity and free host RAM against the guest and SQL caps. Use the host's package manager only where a dependency is missing.
- Check whether `omarchy-windows`, `mssql`, the local runtime paths, and the configured ports already belong to another stack. Reuse only a matching setup. Do not take over foreign resources.
- Create private `~/.config/acumatica-runtime` configuration, or honour `ACUMATICA_RUNTIME_DIR`. Use owner-only permission on env and CIFS credentials. Store separate generated Windows and SQL passwords there. Do not print them, pass them on a command line, or add them to Git.
- In `windows.env` set `VERSION=11`, `USERNAME`, `PASSWORD`, and resource sizes. The exercised configuration uses `CPU_CORES=6`, `RAM_SIZE=12G`, `DISK_SIZE=96G` and `DISK2_SIZE=32G`. Validate capacity rather than raising caps to recover failed startup.
- In `mssql.env` set `MSSQL_PID=Developer` for development, `ACCEPT_EULA=Y` only after acceptance, `MSSQL_SA_PASSWORD`, and an appropriate `MSSQL_MEMORY_LIMIT_MB` below the SQL container limit.
- Render `compose.yml` in that directory from this topology. Replace `<workspace>` with this clone's absolute path, and `<home>` with the operator's home. Create storage directories before Compose. Do not bind console, RDP, SQL, or SMB to a LAN address.

```yaml
services:
  windows:
    image: acumatica-windows-runtime:2026-08-18
    container_name: omarchy-windows
    env_file: windows.env
    devices:
      - /dev/kvm:/dev/kvm
    cap_add: [NET_ADMIN]
    ports:
      - "127.0.0.1:8006:8006"
      - "127.0.0.1:3389:3389/tcp"
      - "127.0.0.1:3389:3389/udp"
      - "127.0.0.1:38145:445"
    volumes:
      - "<home>/.windows:/storage"
      - "<home>/.windows-acumatica-data:/storage2"
      - "<workspace>:/shared"
    network_mode: bridge
    restart: "no"
  mssql:
    image: mcr.microsoft.com/mssql/server@sha256:b94071acd4612bfe60a73e265097c2b6388d14d9d493db8f37cf4479a4337480
    container_name: mssql
    env_file: mssql.env
    mem_limit: 10g
    memswap_limit: 10g
    ports:
      - "127.0.0.1:1433:1433"
    volumes:
      - mssql-data:/var/opt/mssql
    network_mode: bridge
    restart: "no"
volumes:
  mssql-data:
    name: acumatica-mssql-data
```

## First boot and baseline

1. If the baseline does not exist, do not use `acumatica-up.sh` yet. Validate Compose, build `Automation/Setup/windows-runtime.Dockerfile` with the image tag above, then start `mssql` and `windows` through the local Compose file. Do not boot if Linux still has the data image mounted. Poll the guest console at `http://127.0.0.1:8006` until Windows setup is complete. See [Dockur's setup and OEM options](https://github.com/dockur/windows).
2. From the guest console or OEM first-boot hook, enable Windows OpenSSH using `Automation/Setup/install_ssh.ps1` on the Dockur share. Verify `sshd` actually runs. Set up the workspace link with `Automation/Setup/setup_links.bat`. Verify `C:\Acumatica-ERP\Automation\Setup` resolves to this clone. Run `vm-ensure-bridge.sh` on Linux. Verify `vm-pwsh.sh` can read the Windows hostname and the guest can reach SQL at `172.30.0.1:1433` before opening the wizard.
3. Identify the dedicated secondary disk by identity and capacity. Initialize GPT and format NTFS only if the disk is new and uninitialised. Assign `D:` without reassigning a live volume. Create `D:\AcumaticaERP` and link `C:\AcumaticaERP` to it. Export `D:\AcumaticaERP` as the `AcumaticaData` SMB share for the local development account. Do not share the root of `D:` or grant anonymous access.
4. Install the authorized, signed Acumatica MSI for the exact default profile build. Follow the [Acumatica instance creation guide](https://beacon.acumatica.com/r/Installation-Guide/Deploying-Acumatica-ERP-Instances/Instance-Deployment-Creation-of-an-Instance). Configure application, IIS pool, physical path and database to match the default profile, with SQL server `172.30.0.1`. Use a database-scoped runtime login. Complete first-login and licensing requirements. Confirm `Bin\PX.Data.dll` file version and a Windows-local HTTP login response. Do not use a client or production database as the baseline.
5. On Linux, prepare `AcumaticaERP/` and `~/.local/share/acumatica-data-volume/AcumaticaERP`. Configure operator-mountable `noauto,user,nosuid,nodev` fstab entries: CIFS `//127.0.0.1/AcumaticaData` on the backing `AcumaticaERP` directory with `port=38145` and a private credential file; `ntfs3` loop mount of `~/.windows-acumatica-data/data2.img` on the backing parent with the actual NTFS partition byte offset; bind of the backing `AcumaticaERP` directory to the clone's `AcumaticaERP/`. Use the operator UID/GID and owner-only file modes for the dev share. Derive offset from the GPT start sector times logical sector size. Never use an offset copied from another disk. Use the same Linux account for both lifecycle directions. Use approved elevation to install the fstab entries. Normal lifecycle tries operator mounts first. If the distribution's mount helper requires root, authenticate sudo interactively in the same terminal before using the wrapper's noninteractive fallback. Do not grant broad passwordless sudo. Validate the entries before invoking `acumatica-data-volume.sh mount-running`.
6. Create the external `n8n_data` Docker volume if absent. The core wrapper checks its existence even when the sidecar is stopped. Start `acumatica-up.sh --core-only` and `acumatica-ready.sh`. Only launch the full n8n stack if needed and port `5678` is restricted to the host and VM. Create the n8n owner locally and keep the account persistent in the volume.

## Development and proof

- Prepare .NET SDK, the project's target framework developer pack, and compatible MSBuild in Windows. Install Python 3.10+ in Windows for the Acuminator adapter. Use the official [Acuminator runner release](https://github.com/Acumatica/Acuminator/releases), extract the full archive in the guest, and pass `--runner <guest-path>` to `run-acuminator.sh`. Install Node and dependencies only for Modern UI work, using the selected site's requirements.
- Confirm the canonical URL, installed build and IIS path. Run `acumatica-instance.sh status` and distinguish absent sites from unreachable SQL or IIS. Confirm `AcumaticaERP/App_Data/CodeRepository/` is present when source inspection is needed. Use the selected site's frontend checks, package builder, and Acuminator against a real requested project. Do not publish an invented package to prove setup.
- For customization work, create a named disposable instance with a supported build and checkpoint before publishing. Do not apply product upgrades or migrate customer data during setup.
- Report the site URL, exact build, SSH and mount checks, which development tools were verified, and any user-only blocker. For later startup and shutdown, use the environment skill. A successful Compose start alone is not readiness.
