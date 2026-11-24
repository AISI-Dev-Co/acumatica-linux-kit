---
name: setup
description: "Use when asked to set up this repository or provision the Linux host, Windows VM, SQL Server, Acumatica, or development tools."
---

Run setup from the clone. Do not hand the user the checklist. Inspect first, reuse a matching environment, and execute each stage until verified. Ask only for decisions, licenses, elevation, or guest actions you cannot perform. Do not reset an existing site, credential, VM disk, or SQL volume to get past a failed check.

Load `../environment/SKILL.md` for runtime operations. The environment uses a local Dockur Windows guest, Linux MSSQL container, and a dedicated NTFS data disk. The protected baseline is the build in `Automation/Setup/instances/profiles/default.json`. Use `acumatica-instance.sh` for additional sites after the baseline is ready.

## Adapt and report

Treat the supplied files as a starting point. If a command or default doesn't fit the host, inspect the failure and the relevant upstream documentation. Make the smallest local change that fixes it, then rerun the live check that failed. Preserve instance isolation and the NTFS ownership handoff. Don't work around a failure by wiping data or disabling safeguards.

For a reproducible kit defect or portability gap, prefer updating an existing issue or filing one at [AISI-Dev-Co/acumatica-linux-kit](https://github.com/AISI-Dev-Co/acumatica-linux-kit/issues). Include the kit revision, Linux distro, failed setup stage, sanitised error, and what you changed or verified. Don't post credentials, customer data, or unreviewed logs. If you can't post, leave an issue-ready summary for the user. Don't pitch a one-off local override as a kit bug.

## Host and runtime

On a bare Linux host, install Docker Engine and Compose v2 using the [instructions for the detected distribution](https://docs.docker.com/engine/install/). Use the local daemon with KVM device access. Run the setup below to create the guest from the pinned Dockur image, including when no VM exists yet. Preserve Dockur's NAT networking; the wrappers depend on its `172.30.0.1` guest gateway. If the Docker bridge already occupies `172.30.0.0/16`, stop and resolve the conflict before deploying Acumatica. This path targets x86-64 Linux. If KVM is unavailable, check firmware virtualization or nested virtualization before proceeding. Do not silently fall back to emulation.

- Check x86-64 hardware virtualization with `/dev/kvm` and `/dev/net/tun`, a local Docker Engine and Compose v2, Bash, Python 3.10+, curl, OpenSSH, util-linux, `iproute2`, procps, CIFS tooling, and the kernel's `ntfs3` support. Check disk capacity and free host RAM against the guest and SQL caps. Use the host's package manager only where a dependency is missing.
- Check whether `acumatica-windows`, `mssql`, the local runtime paths, and the configured ports already belong to another stack. Reuse only a matching setup. Do not take over foreign resources. For a preexisting compatible Dockur stack with a different container name, set `VM_CONTAINER` in the environment for all wrappers and use its actual Compose project and disk paths.
- Use `ACUMATICA_RUNTIME_DIR` if set. Otherwise use `${XDG_CONFIG_HOME:-$HOME/.config}/acumatica-runtime`. This is a disposable local dev box. Keep credentials in plain, owner-readable local files outside Git. No secret store. Read existing files before asking for a login or attempting a reset. Do not print passwords or pass them on command lines. Business deployments supply their own environment and secret management.
- Windows and SQL credentials live in `windows.env` and `mssql.env`. Keep Acumatica and n8n credentials in `dev-logins.env`: `ACUMATICA_USERNAME`, `ACUMATICA_PASSWORD`, `ACUMATICA_TENANT`, `N8N_EMAIL` and `N8N_PASSWORD`. Add the n8n fields when enabling it. Keep the file mode `0600` and read it as data, not shell code. Update it after a password change. Do not duplicate the SQL administrator password there.
- In `windows.env` set `VERSION=11`, `DISK_FMT=raw`, `USERNAME`, `PASSWORD`, and resource sizes. The exercised configuration uses `CPU_CORES=6`, `RAM_SIZE=12G`, `DISK_SIZE=96G` and `DISK2_SIZE=32G`. Validate capacity rather than raising caps to recover failed startup.
- In `mssql.env` set `MSSQL_PID=Developer` for development, `ACCEPT_EULA=Y` only after acceptance, `MSSQL_SA_PASSWORD`, and an appropriate `MSSQL_MEMORY_LIMIT_MB` below the SQL container limit.
- Render `compose.yml` in that directory from this topology. Replace `<workspace>` with this clone's absolute path, `<home>` with the operator's home, and `<runtime>` with the local runtime directory. Create storage directories before Compose. Do not bind console, RDP, SQL, or SMB to a LAN address.

```yaml
services:
  windows:
    image: acumatica-windows-runtime:2026-08-18
    container_name: acumatica-windows
    env_file: windows.env
    devices:
      - /dev/kvm:/dev/kvm
      - /dev/net/tun:/dev/net/tun
    cap_add: [NET_ADMIN]
    stop_grace_period: 2m
    ports:
      - "127.0.0.1:8006:8006"
      - "127.0.0.1:3389:3389/tcp"
      - "127.0.0.1:3389:3389/udp"
      - "127.0.0.1:38145:445"
    volumes:
      - "<home>/.windows:/storage"
      - "<home>/.windows-acumatica-data:/storage2"
      - "<workspace>:/shared"
      - "<runtime>/oem:/oem:ro"
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

## First boot

If the baseline does not exist, bootstrap Windows and SQL before invoking `acumatica-up.sh`. Stage the OEM hook below before starting Compose. Validate the local Compose file, build `Automation/Setup/windows-runtime.Dockerfile` with the tag above, then start `mssql` and `windows` directly. Confirm Linux has not attached or mounted `data2.img` before boot. Use the guest console at `http://127.0.0.1:8006` to monitor first boot. Verify an authenticated SQL query too. A Docker container in Running state is not proof that Windows or SQL is ready.

### Get PowerShell before doing guest work

Before first boot, stage the existing SSH installer outside the clone: copy `Automation/Setup/install_ssh.ps1` to `<runtime>/oem/install_ssh.ps1` and add this `<runtime>/oem/install.bat`. Keep it credential-free.

```bat
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_ssh.ps1"
exit /b %errorlevel%
```

Bind `<runtime>/oem:/oem:ro` under the Windows service. [The pinned Dockur release](https://github.com/dockur/windows/tree/c7aac1edcf37a69ff730d0b4f073d16580a27763) copies it to `C:\OEM` and runs it at the end of unattended installation. It does not rerun on an already-installed guest. Do not put credentials in the OEM hook or recreate an existing disk to run it.

Once Windows finishes, use the Linux shell:

```sh
Automation/Setup/vm-ensure-bridge.sh
Automation/Setup/vm-pwsh.sh '$ErrorActionPreference="Stop"; hostname; whoami; (Get-Service sshd).Status'
```

Treat those command results as the gate, not the VM console showing a desktop. If SSH never comes up, inspect `C:\ProgramData\AcumaticaLinuxKit\openssh-bootstrap.log` in the console. On an existing guest or after a failed OEM run, use one elevated console or RDP session to launch the copy at `C:\OEM\install_ssh.ps1`, or the copy on the Dockur workspace share. If console input is unreliable, don't type a provisioning script into it. Get an RDP session with clipboard or ask for the single bootstrap action and resume over SSH. Do not claim automated setup if that was required.

After SSH works, use `vm-pwsh.sh` and `vm-scp.sh` for commands and files. Establish `C:\Acumatica-ERP` using the mapping in `Automation/Setup/setup_links.bat`, without its console pause. Verify that it resolves to the clone, and probe SQL from Windows before opening the wizard.

### Enable IIS in the guest

Use an elevated Windows PowerShell session through `vm-pwsh.sh`. For the Windows 11 development guest, enable IIS with these feature IDs. Use the target release's [system environment requirements](https://beacon.acumatica.com/r/Installation-Guide/Preparing-for-Installing-Acumatica-ERP/Preparation-for-the-Acumatica-ERP-Installation-System-Environment) when changing builds. The `45` suffix is the Windows feature identifier, including on systems with ASP.NET 4.8.

```sh
Automation/Setup/vm-pwsh.sh <<'PS'
$ErrorActionPreference = 'Stop'
$user = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$user.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'The SSH session is not elevated. Use the elevated guest session for this step.'
}
$features = @(
    'IIS-WebServerRole', 'IIS-WebServer', 'IIS-ManagementConsole',
    'IIS-ManagementScriptingTools', 'IIS-NetFxExtensibility45', 'IIS-ASPNET45',
    'IIS-ISAPIExtensions', 'IIS-ISAPIFilter', 'IIS-WebSockets',
    'IIS-DefaultDocument', 'IIS-StaticContent', 'IIS-HttpCompressionDynamic',
    'IIS-HttpCompressionStatic', 'IIS-RequestFiltering'
)
$result = Enable-WindowsOptionalFeature -Online -FeatureName $features -All -NoRestart
if ($result.RestartNeeded) { throw 'IIS requires a guest reboot before proceeding.' }
foreach ($feature in $features) {
    if ((Get-WindowsOptionalFeature -Online -FeatureName $feature).State -ne 'Enabled') {
        throw "IIS feature not enabled: $feature"
    }
}
Import-Module WebAdministration
Get-Service WAS, W3SVC
PS
```

If servicing requires a reboot, use a controlled guest restart, recheck SSH, and rerun the feature check before installing Acumatica. Verify the installed .NET Framework is at least 4.8. Windows 11 is for development and testing only.

## Put the website on the data disk

1. Use `DISK2_SIZE` and the `/storage2` bind in the Compose topology to make a separate raw `~/.windows-acumatica-data/data2.img`. In Windows use `Get-Disk` and `Get-Partition` to match that dedicated disk by identity and capacity. Reject the boot or system disk. Only initialise and format a verified new RAW disk: GPT → one usable NTFS data partition → drive `D:`. A GPT Microsoft Reserved partition is normal. For an existing disk, verify NTFS and its drive letter without formatting or reassigning a live volume.
2. Create `D:\AcumaticaERP`. Create a directory junction `C:\AcumaticaERP` → `D:\AcumaticaERP` with `New-Item -ItemType Junction` only if the C path is absent. Do not move files across an existing conflicting path. `C:\Acumatica-ERP` is the separate link to the Linux workspace and is **not** an IIS website. Verify the junction target from Windows before deploying.
3. Obtain the [official MSI for the default build](https://acumatica-builds.s3.amazonaws.com/builds/26.1/26.101.0225/AcumaticaERP/AcumaticaERPInstall.msi) from Acumatica's build archive. In Windows, verify that `Get-AuthenticodeSignature` reports a valid Acumatica signature, then install as administrator. The MSI installs the Configuration Wizard; it does not deploy the website. Launch the Configuration Wizard. Ask once whether the user would rather drive it with your guidance because that's usually faster. If they decline and you have guest UI access, operate it yourself. Use Acumatica's [official deployment guide](https://beacon.acumatica.com/r/Installation-Guide/Deploying-Acumatica-ERP-Instances/Instance-Deployment-Creation-of-an-Instance) and the settings below. Never deploy into Program Files or the Dockur workspace share.

   | Setting | Value |
   |---|---|
   | SQL Server | `172.30.0.1`, SQL Server authentication |
   | Database | Create `AcumaticaDB`, empty `Company` tenant |
   | Website database login | Dedicated SQL login for `AcumaticaDB`, not the installer administrator |
   | Instance and IIS application | `AcumaticaERP` under `Default Web Site` |
   | Local instance path and IIS physical path | `C:\AcumaticaERP`, resolving to `D:\AcumaticaERP` |
   | Application pool | Dedicated `AcumaticaERPAppPool`, Integrated, 64-bit |
   | Node.js | Install the Windows runtime for this build or select an existing compatible installation |

   After deployment verify `D:\AcumaticaERP\Bin\PX.Data.dll` exists and its file version matches the profile. Verify IIS physical path. Run `Automation/Setup/vm-pwsh.sh < Automation/Setup/check-acumatica-sql.ps1` from Linux to prove Windows can query `AcumaticaDB` using the deployed site login. Also read `NodeJs:NodeJsPath` from the canonical `web.config` and run that directory's `node.exe --version` in Windows. Named sites borrow this runtime even if they use the Classic UI. Stop if the installer puts files on C independently or refuses the junction; do not copy a second site or silently retarget IIS.
4. From Linux, run the share helper with the elevated Windows dev account you'll use for CIFS. It creates the share only for `D:\AcumaticaERP`, grants that account access, and adds an SMB firewall rule scoped to the Dockur and Docker bridge gateways. Do not enable the general File and Printer Sharing firewall group.

   ```sh
   vm_container="${VM_CONTAINER:-acumatica-windows}"
   gateway="$(docker inspect --format '{{(index .NetworkSettings.Networks "bridge").Gateway}}' "$vm_container")"
   Automation/Setup/vm-pwsh.sh "& 'C:\Acumatica-ERP\Automation\Setup\configure-acumatica-share.ps1' -DockerBridgeGateway '$gateway'"
   ```

## Wire and prove Linux visibility

Create empty backings on Linux at `~/.local/share/acumatica-data-volume/AcumaticaERP` and `<workspace>/AcumaticaERP`. Read the actual byte offset with `(Get-Partition -DriveLetter D).Offset` in Windows and confirm that D is on the secondary disk. Cross-check after shutdown with `sfdisk --json <image>`: the GPT Microsoft basic data partition's start sector times the image's logical sector size must equal that offset. Do not use an offset from another host or mount the entire GPT image as NTFS.

Install three `noauto` fstab entries through approved elevation. Substitute absolute paths, the computed offset, and the operator UID/GID. Store CIFS `username=` and `password=` in a private `0600` file outside the clone. Escape spaces in fstab paths.

```text
//127.0.0.1/AcumaticaData <volume-root>/AcumaticaERP cifs noauto,user,nosuid,nodev,exec,port=38145,credentials=<private-file>,uid=<uid>,gid=<gid>,forceuid,forcegid,file_mode=0600,dir_mode=0700,cache=none 0 0
<home>/.windows-acumatica-data/data2.img <volume-root> ntfs3 noauto,user,nosuid,nodev,exec,loop,offset=<bytes>,uid=<uid>,gid=<gid>,umask=0077,windows_names 0 0
<volume-root>/AcumaticaERP <workspace>/AcumaticaERP none noauto,user,nosuid,nodev,exec,bind 0 0
```

Use the same Linux account for lifecycle commands. Validate the fstab entries before mounting. If the distribution requires root for a mount helper, authenticate sudo in the same terminal for the wrapper's noninteractive fallback. Do not grant broad passwordless sudo.

1. **Windows running:** run `acumatica-data-volume.sh mount-running`. Check `status` reports the CIFS backing and no raw volume mount. Confirm `AcumaticaERP/Bin/PX.Data.dll` is readable from Linux. Record its SHA-256. Verify the Windows-local login page.
2. **Windows stopped:** for the first handoff, run `acumatica-data-volume.sh unmount`, shut down the guest cleanly, and verify Compose reports Windows stopped. Cross-check the partition offset before invoking `acumatica-data-volume.sh mount-stopped`. Use `acumatica-down.sh` for later shutdowns. Check `status` reports the `ntfs3` backing and no CIFS mount. Compare the same DLL's SHA-256 from `AcumaticaERP/`. This proves both paths refer to the deployed site, not a copied tree.
3. **Restart:** run `acumatica-up.sh --core-only`, then `acumatica-ready.sh`. Verify the raw NTFS mount is gone, CIFS is back, and the Linux login URL responds. Sign in from the Linux browser to the intended tenant. Use the recorded dev login, or `admin` / `setup` for a fresh site only. Complete any required password change and licensing. Save the current dev login in `dev-logins.env`. Verify an authenticated Acumatica page opens in the intended tenant. HTTP readiness is not a sign-in check. If integrations are requested, run `acumatica-up.sh` without `--core-only` and follow the [sidecar checks](../environment/references/docker-sidecars.md).

The CIFS view is for the canonical website. Named instances on `D:\AcumaticaInstances` remain isolated and use the Windows wrappers for inspection while Windows is running. Never mount a guest-owned raw disk on Linux to inspect them.

## Development and proof

Use the live check at each handoff to decide whether to proceed. If a check fails, diagnose that boundary before retrying the stack.

- Prepare .NET SDK, the project's target framework developer pack, and compatible MSBuild in Windows. Use Python 3.10+ in Windows for the Acuminator adapter. Use the official [Acuminator runner release](https://github.com/Acumatica/Acuminator/releases), extract the full archive in the guest, and pass `--runner <guest-path>` to `run-acuminator.sh`. Install frontend project dependencies only when needed, using the selected site's requirements.
- Confirm the canonical URL, installed build and IIS path. Run `acumatica-instance.sh status` and distinguish absent sites from unreachable SQL or IIS. Confirm `AcumaticaERP/App_Data/CodeRepository/` is present when source inspection is needed. Use the selected site's frontend checks, package builder, and Acuminator against a real requested project. Do not publish an invented package to prove setup.
- For customization work, create a named disposable instance with a supported build and checkpoint before publishing. Do not apply product upgrades or migrate customer data during setup.
- Report the site URL, exact build, SSH and mount checks, which development tools were verified, and any user-only blocker. For later startup and shutdown, use the environment skill. A successful Compose start alone is not readiness.
