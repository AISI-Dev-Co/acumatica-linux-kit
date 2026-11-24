---
name: setup
description: "Use when asked to set up this repository or provision the Linux host, Windows VM, SQL Server, Acumatica, or development tools."
---

Run setup from the clone. Do not hand the user the checklist. Inspect first, reuse a matching environment, and execute each stage until verified. Ask only for decisions, licenses, elevation, or guest actions you cannot perform. Do not reset an existing site, credential, VM disk, or SQL volume to get past a failed check.

Load `../environment/SKILL.md` for runtime operations. The environment uses a local Dockur Windows guest, Linux MSSQL container, and a dedicated NTFS data disk. The protected baseline is the build in `Automation/Setup/instances/profiles/default.json`. Use `acumatica-instance.sh` for additional sites after the baseline is ready.

## Adapt and report

Treat the supplied files as a starting point. If a command or default doesn't fit the host, inspect the failure and the relevant upstream documentation. Make the smallest local change that fixes it, then rerun the live check that failed. Preserve instance isolation and the NTFS ownership handoff. Don't work around a failure by wiping data or disabling safeguards.

For a reproducible kit defect or portability gap, prefer updating an existing issue or filing one at [AISI-Dev-Co/acumatica-linux-kit](https://github.com/AISI-Dev-Co/acumatica-linux-kit/issues). Include the kit revision, Linux distro, failed setup stage, sanitised error, and what you changed or verified. Don't post credentials, customer data, or unreviewed logs. If you can't post, leave an issue-ready summary for the user. Don't pitch a one-off local override as a kit bug.

## Select the setup path

Check the existing runtime before provisioning. Reuse a matching stack with a deployed canonical site, its CIFS backing, and its local runtime configuration. If those are missing on a fresh host, load `references/first-install.md` for Windows, SQL, IIS, and the data-volume handoff. If an existing stack is incomplete, resume at the failed stage instead of recreating its resources.

Use `ACUMATICA_RUNTIME_DIR` if set. Otherwise use `${XDG_CONFIG_HOME:-$HOME/.config}/acumatica-runtime`. This is a disposable local dev box. Read existing local credentials before asking for a login or attempting a reset. Keep the passwords out of Git and logs. Business deployments supply their own environment and secret management.

## Start and sign in

Run `acumatica-up.sh --core-only`, then `acumatica-ready.sh`. Verify the raw NTFS mount is gone, CIFS is back, and the Linux login URL responds. Sign in from the Linux browser to the intended tenant. Use the recorded dev login, or `admin` / `setup` for a fresh site only. Complete any required password change and licensing. Save the current dev login in the runtime directory's `dev-logins.env`. Verify an authenticated Acumatica page opens in the intended tenant. HTTP readiness is not a sign-in check. If integrations are requested, run `acumatica-up.sh` without `--core-only` and follow the [SQL and n8n checks](../environment/SKILL.md#sql-and-n8n).

## Development and proof

Use the live check at each handoff to decide whether to proceed. If a check fails, diagnose that boundary before retrying the stack.

- Prepare .NET SDK, the project's target framework developer pack, and compatible MSBuild in Windows. Use Python 3.10+ in Windows for the Acuminator adapter. Install the pinned Windows console runner using the applicable analysis skill. Install frontend project dependencies only when needed, using the selected site's requirements.
- Confirm the canonical URL, installed build and IIS path. Run `acumatica-instance.sh status` and distinguish absent sites from unreachable SQL or IIS. Confirm `AcumaticaERP/App_Data/CodeRepository/` is present when source inspection is needed. Use the selected site's frontend checks, package builder, and Acuminator against a real requested project. Do not publish an invented package to prove setup.
- For customization work, create a named disposable instance with a supported build and checkpoint before publishing. Do not apply product upgrades or migrate customer data during setup.
- Report the site URL, exact build, SSH and mount checks, which development tools were verified, and any user-only blocker. For later startup and shutdown, use the environment skill. A successful Compose start alone is not readiness.
