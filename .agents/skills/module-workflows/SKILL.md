---
name: module-workflows
description: "Use for Acumatica module screens, graphs, DACs, lifecycle states, source landmarks, or verification."
---

Load only the required module reference:

- AP: `references/ap.md`
- AR: `references/ar.md`
- GL: `references/gl.md`
- CA: `references/cash-management.md`
- IN: `references/inventory.md`
- PO: `references/purchase.md`
- SO: `references/sales.md`
- CRM: `references/crm.md`
- PM: `references/project.md`

For cross-module flows, load only participating modules. Resolve the build and website from the registered profile. Treat `Source` paths as landmarks under that website's `App_Data/CodeRepository/PX.Objects/` and verify names against the selected build. Trace `screen → graph → DAC`, then use the listed flow for browser verification.
