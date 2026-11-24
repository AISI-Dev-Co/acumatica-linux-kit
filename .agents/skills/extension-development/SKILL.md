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

Load `references/repo-hygiene.md` for package shape or handoff, `references/import-scenarios.md` for `SM206025` and fail-closed actions, `references/modern-ui-extension.md` for modern UI, and `references/security.md` for permissions, restricted data, processing, or API exposure.

For access failures, trace `SM201020`, `SM201025`, and `SM201030`. For disabled actions, inspect status, approval, workflow, and `RowSelected`. For release failures, inspect hold, required fields, approval map, and trace. For slow screens, start with hot events, selectors, and N+1 BQL.

Run the smallest relevant build and Acuminator. Verify rights and action behavior. Audit modern bindings after graph, TS, or HTML changes. Rebuild the package after deliverable changes and parse/import n8n workflows when changed. Never start watch or dev servers.
