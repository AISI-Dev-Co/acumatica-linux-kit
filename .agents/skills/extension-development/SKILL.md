---
name: extension-development
description: "Use for Acumatica customizations, import scenarios, packages, workflows, or modern extension screens."
---

- Extend, do not edit core: `PXCacheExtension<TDAC>`, `PXGraphExtension<TGraph>`.
- Do not redeclare `PXSave<TPrimary>` / `PXCancel<TPrimary>` on `PXGraph<TGraph, TPrimary>` descendants.
- `Usr` fields require the matching BQL field class.
- New actions need `PXAction<T>`, `[PXButton]`, and explicit `MapEnableRights` / `MapViewRights`.
- `[PXOverride]` needs the exact signature and the base delegate when preserving core behavior.
- Keep `RowSelected` and `FieldSelecting` cheap. `RowSelected` owns UI state. Validate and default in `RowPersisting`, `FieldUpdated`, or `FieldVerifying`.
- Prefer set-based BQL. Avoid selector or event N+1 queries.
- Use `PXLongOperation` for heavy work and `PXProcessing<T>` for queues.
- Use `IsActive()` for conditional graph extensions where applicable.
- Keep workflow states, actions, transitions, and conditions together. Recheck action rights and enablement.
- Tenant-scoped custom tables include `CompanyID`. Make shared or system scope explicit. Add indexes only for a proven need.
- Use standard names such as `BAccountID` and `ContactID`. Do not ship runtime hacks or breadcrumb comments.

Use setup/customization metadata first for numbering (`CS201010`), dimensions (`CS202000`), approval or assignment maps (`EP205000` / `EP205010`), import scenarios (`SM206025`), and generic inquiries or dashboards (`SM208000` / `SM208600`). Customization fields use `Usr` and deploy globally, not as personalization.

Load `references/import-scenarios.md` for `SM206025` and fail-closed actions.

For access failures, trace `SM201020`, `SM201025`, and `SM201030`. For disabled actions, inspect status, approval, workflow, and `RowSelected`. For release failures, inspect hold, required fields, approval map, and trace. For slow screens, start with hot events, selectors, and N+1 BQL.

Verify changed rights and action behavior. Rebuild the package after deliverable changes. Never start watch or dev servers.

## Packaging

Keep a package's source, package scripts, n8n assets, and release ZIP in its standalone subrepository. Use one source of truth and namespace files by extension. Typical owned directories are `DAC/`, `Graph/`, `Helper/` or `App_RuntimeCode/`, `FrontendSources/`, `_project/`, `sql/`, `scripts/`, and optional `n8n/`.

`_project/` is shipped customization metadata. `sql/` is its review companion. Build through Acumatica's customization path and package script. Never hand-stage ZIP contents. Keep n8n workflows credential-based, UI-importable, and one JSON object each. Exclude environment fixes, probes, temporary shims, duplicate trees, and breadcrumb comments from a deliverable. Isolate a required compatibility workaround from production extension source.

Before handoff, run the smallest backend or package build, triage Acuminator, audit C# ↔ TS ↔ HTML bindings when relevant, confirm the ZIP has expected modern paths and no accidental ASPX or template shims, and parse/import included n8n JSON.

## Modern UI

Put standalone screens under their package's `FrontendSources/screen/src/development/screens/<Module>/<ScreenID>/`. Put product screens under deployed `FrontendSources/screen/src/screens/<Module>/<ScreenID>/`. Published customization output is under `customizationScreens/<Tenant>/screens/<Module>/<ScreenID>/`, or the older unscoped `customizationScreens/screens/<Module>/<ScreenID>/`. Inspect both published layouts when tracing an existing site. Do not mix roots in a standalone package. Modern-only screens have no ASPX.

1. Inventory screen IDs, graph type, primary view, public views, and actions.
2. Map C# graph/view/action members through `@graphInfo`, `@viewInfo`, `createSingle`, `createCollection`, and `PXActionState`.
3. Match HTML `view.bind` and `state.bind` to TS property names exactly.
4. Use framework controls for ordinary date, datetime, text, and selector fields.
5. Run the package binding audit after graph, TS, or HTML changes.

Use tabs, double quotes, and no `any`. Do not import `.html` without a proven runtime need. Do not add empty template shims or loader hacks. For missing views or bindings, compare public C# members, TS bindings, and HTML binds; derive only required template changes from a current neighboring screen.

## Access and processing

Use `SM201020` for rights by screen, `SM201025` for rights by role, and `SM201030` for restriction groups. Users and roles are managed through `SM201010` and `SM201005`.

Apply the entity or branch restriction appropriate to every sensitive selector, view, or direct query. `Match<>` is common, not universal. Code that bypasses a restricted graph view needs an equivalent `PXRestrictor` or `PXAccess` check. Preserve related-DAC access scope. Actions declare `MapEnableRights` and `MapViewRights`; apply UI enablement only after access checks. Cross-branch processing needs `PXReadBranchRestrictedScope` or its applicable equivalent. API data follows entity rights as well as screen rights.

Verify with a limited role: screen access matches configuration, selectors exclude unauthorized company, branch, and entity rows, update actions stay unavailable without update rights, and processing cannot cross scope.
