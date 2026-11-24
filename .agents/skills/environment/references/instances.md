Use `Automation/Setup/acumatica-instance.sh` for registered client instances. The Windows VM and SQL Server are shared, databases are not. `default` is the protected canonical site.

```sh
Automation/Setup/acumatica-instance.sh list
Automation/Setup/acumatica-instance.sh builds
Automation/Setup/acumatica-instance.sh status
Automation/Setup/acumatica-instance.sh use client-a
Automation/Setup/acumatica-instance.sh use default
Automation/Setup/acumatica-instance.sh up default client-a
Automation/Setup/acumatica-instance.sh stop client-a
Automation/Setup/acumatica-instance.sh create client-a --release 25r1
Automation/Setup/acumatica-instance.sh create client-b --release 26r1
Automation/Setup/acumatica-instance.sh publish client-b
Automation/Setup/acumatica-instance.sh checkpoint client-a before-change
Automation/Setup/acumatica-instance.sh reset client-a --checkpoint before-change --confirm client-a
```

- `use` starts and probes the selected site before stopping other registered pools. `up` adds sites without stopping others. A failed warm-up stops the target, not the previous client. A stopped pool releases its worker, not SQL's shared cache.
- Named URLs use `<id>.localhost:38121/Acu_<id>` to separate browser cookies. Use the printed hostname, not a different port on the same hostname. These URLs are local to the machine with the existing port forward; remote access needs the corresponding host mapping or forwarding.
- `create --release 25r1` pins **25.101.0153 Classic**; `--release 26r1` pins **26.101.0225 Modern**. Omitting the selector preserves the 26R1 default. `--build` accepts either exact build instead of `--release`. Presets live in `instances/builds.json`; there is no floating latest build, implicit upgrade, or automatic servicing-patch application. Match the customer's full build and patch level before onboarding; other builds require deliberate support.
- Creation downloads a missing installer from Acumatica's build archive, verifies its Acumatica Authenticode signature, and administratively extracts it into `C:\AcumaticaBuilds\<build>`. It never replaces the installed Configuration Wizard or copies a live website. A private extraction receipt pins the installer and assembly hashes; the original 26R1 image instead retains its signed-installer and exact-version checks. Failed extraction staging is not a usable build.
- New sites have an empty Company tenant. The normal first login is `admin` / `setup`; complete Acumatica's password change, license agreement, and feature activation through its UI before application work. No license was activated by the controller. Classic UI does not mean IIS Classic pipeline mode; both builds use Integrated mode.
- `acumatica-up.sh` with no arguments retains the canonical full-runtime behavior. Its `--core-only` branch starts VM/SQL and the volume handoff without warming the canonical app or n8n. `acumatica-ready.sh [port]` remains a canonical-only compatibility entrypoint. Do not use it to select a client.
- The shared n8n container belongs to `default` only. Exclusive selection of another site stops it before the default pool. Returning to default restarts it with its original URLs and credentials. Other profiles have no automatic n8n integration. Never retarget global n8n URLs during a swap. Drain active workflows before switching; container shutdown is not proof that an external job has completed.

Profiles live in `Automation/Setup/instances/profiles/<id>.json`. IDs derive unique application, pool, path and database names. Identity retargeting, duplicate selection, unsafe package paths, missing prerequisites and dependency cycles fail before mutation. The default profile refuses publication, checkpoint and reset through this controller.

Use the selected profile's website for source inspection and package building. Read a 25R1 Classic screen from that site's `Pages/` and matching `App_Data/CodeRepository/` through the VM wrappers, not the canonical 26R1 tree. UI presets are initialized on creation; reset preserves the checkpoint's UI configuration.

Set a named profile's `packages` to its **complete** desired set. Each entry contains:

```json
{
  "name": "NewWork",
  "path": "development/package/new-work/NewWork.zip",
  "sha256": "<64 lowercase hex characters from the built ZIP>",
  "level": 20,
  "dependsOn": ["PrerequisiteX", "PrerequisiteY"]
}
```

Follow the package's build contract in its subrepository. For manifest-based packages, use `build-extension-package.ps1 -WebsiteRoot <profile.path>`. The builder passes `AcumaticaWebsiteRoot` to MSBuild and checks resolved PX assembly references before compilation. It does not rewrite hardcoded references. `-SkipDotnetBuild` requires a successful build receipt beside the DLL, matching its bytes, the selected build, and `PX.Data.dll`. A customization DLL's own version is not evidence of its Acumatica target. Update profile archive hashes after rebuilding.

Each prerequisite needs its own entry. `level` must match the ZIP's `project.xml`; it is conflict precedence, not dependency resolution. On 26R1 the publisher stages verified ZIPs privately, imports prerequisites before dependents, and publishes the complete set once without `/merge`. It preserves previously executed database scripts. A matching receipt skips publication only when the published names and archive hash still agree. Ordinary switching never publishes anything.

The controller's nonempty CLI publication is blocked before mutation on **25.101.0153** after replacement and `DeleteProject` failed in the clean-site smoke test. Do not delete projects or edit the database to bypass the guard. Use supported UI or authenticated API publication. An already-empty 25R1 site still accepts the controller's empty-set no-op.

An empty package set is not a clean reset. Unpublish leaves database changes behind. Use the matched checkpoint to undo schema and data changes.

Storage operations stop only the target pool. Checkpoints contain the website ZIP and a native SQL backup with checksums, identity metadata and a completion marker. Checkpoint capture refuses active standard blob providers, external blob references, recognized out-of-site storage paths and website reparse points. Arbitrary custom external systems are not backed up.

- Website archives: `D:\AcumaticaInstanceCheckpoints\<id>\<name>`.
- SQL backups: `/var/opt/mssql/data/acu_<id>_<name>.bak` inside the existing SQL volume.
- Private installer logs and operation state: `C:\ProgramData\AcumaticaInstances`.
- Failed operations leave a blocked marker and no successful readiness result. Inspect the named resources before recovery. `reset` can recover a blocked publication from its own checkpoint. An incomplete initial provision requires inspection and explicit repair; `provision <id>` is not a destructive overwrite option.
- Restore staging uses short private `D:\AcuTmp` paths because .NET Framework ZIP extraction hits MAX_PATH with long sibling names. Successful restores remove staging. Do not turn failed staging into an alternative deployment.

Raw client backup import, builds beyond the two pinned presets, external attachment restores, client-specific n8n activation, and ISV licensing are not automated. Onboard those deliberately, with production integrations quarantined before the first site start. Do not point a fresh profile at a production database.

For the two-build live gate, provision an empty `clean25` with `create clean25 --release 25r1` and bring it up alongside `default`. Run `bash Automation/Setup/instances/verify.sh default clean25`. The package guard fixture uses those two website paths. Management mutations serialize under the existing host environment lock and a Windows mutex. Browser work in separate pools remains parallel. Do not raise RAM until representative client workloads show pressure.
