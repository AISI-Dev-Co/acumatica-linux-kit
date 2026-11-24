---
name: code-navigation
description: "Use to trace Acumatica screens, graphs, DACs, workflows, actions, or modern bindings."
---

Resolve the build and website from `Automation/Setup/instances/profiles/<id>.json`. Use `AcumaticaERP/` for the canonical 26R1 site only. Read named sites through the VM wrappers.

From the selected website root, locate Classic pages at `Pages/<Module>/<ScreenID>.aspx`, backend code in `App_Data/CodeRepository/`, and product Modern screens in `FrontendSources/screen/src/screens/`. Standalone Modern screens live under `<package>/FrontendSources/screen/src/development/screens/`. Published output sits under `customizationScreens/<Tenant>/screens/` or, in older layouts, `customizationScreens/screens/`.

**Classic:** ASPX `PXDataSource.TypeName` / `PrimaryView` → graph → public views/actions/events → primary DAC.

- Primary DAC: `PXGraph<TGraph, TPrimary>`.
- Views: `PXSelect<>`, `SelectFrom<>`, joins, delegates.
- Actions: `PXAction<T>`, `[PXButton]`, `[PXUIField]`, delegate method.
- Events: `RowSelected`, `RowPersisting`, `FieldUpdated`, `FieldVerifying`.

**DAC:** verify `PrimaryKeyOf<T>.By<...>` / `IsKey`, audit fields, `NoteID`, nested `FK`, `[PXParent]`, selectors/restrictors. Business logic normally belongs graph-side. Do not assume nested `PXEntityEvent<T>` exists.

**Modern:** C# public member ↔ TS property ↔ HTML binding. `@graphInfo.graphType` is the full C# graph type; `primaryView` is its graph primary view. `createSingle` is a form view, `createCollection` a grid view, and `PXActionState` a backend action. HTML `view.bind` and `state.bind` name TS properties.

Trace only unless implementation was requested.
