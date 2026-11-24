---
name: acuminator
description: "Use for Acuminator runs, runner failures, PX diagnostics, or suppression decisions."
---

Run `Automation/Setup/run-acuminator.sh <target.csproj-or.sln>` from the repository root. Select the smallest affected project for the intended build. Omitting the target selects the canonical `AcumaticaERP/App_Data/CodeRepository/CodeRepository.csproj`, not the active client.

Use `describe` to inspect the local adapter contract, not to check the VM runner. The wrapper routes Linux analysis through Windows and handles CodeRepository shadow staging. Use a repo-relative path or an explicit Windows path visible to the guest. Set `ACUMINATOR_FORCE_LOCAL=1` only with a deliberately prepared local Mono/MSBuild toolchain. Do not change product or runtime source to satisfy the analyzer.

Read the report's `status`, `exitCode`, totals, severity counts, diagnostic IDs, and diagnostics. Separate runner, build, or path failures from source findings. For each material PX ID, read the upstream [diagnostic index](https://github.com/Acumatica/Acuminator/blob/dev/docs/Summary.md) and the relevant `PX####.md`, retain version and ISV qualifiers, fix the source, and rerun the same target.

Suppress only intentional code with a narrow reason:

```csharp
// Acuminator disable once PX1053 ConcatenationPriorLocalization [reason]
```

After an Acumatica upgrade, rebuild each customization against target assemblies and analyze the rebuilt project's source. A successful analysis verifies that the runner analyzed that target. It does not verify runtime compatibility. Run the relevant publish and behavior checks separately. A changed ERP version alone does not require an Acuminator update.

On first setup, run `Automation/Setup/run-acuminator.sh describe` and use `recommendedRunner.downloadUrl`. Extract the complete official Console Runner archive in Windows. Pass `--runner <path to Acuminator.Runner.NetFramework.exe in Windows>` to the wrapper. No source checkout or rebuild needed. When changing the runner version, update the wrapper's pin and any affected flags or report parsing together. Verify the new runner through the wrapper against a real customization project. Use the wrapper for CodeRepository NuGet failures. Start the runtime for VM-backed analysis. Treat no Acumatica Platform reference as expected only for unrelated test code.

Report the target, status and exit code, severity and PX-ID counts, highest-signal files, decisions, and rerun command.
