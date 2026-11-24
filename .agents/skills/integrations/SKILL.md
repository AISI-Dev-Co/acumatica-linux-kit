---
name: integrations
description: "Use for Acumatica APIs, n8n workflows, OAuth, webhooks, approvals, retries, or reconciliation."
---

- Use contract REST for CRUD and actions. Use OData for read-heavy filter, select, expand, and page queries.
- Use the environment-supported OAuth or token flow. Never invent or downgrade authentication.
- Change state through supported API actions, never direct DB writes.
- Record endpoint, tenant or company, auth, payload, response or error shape, and resulting state.
- Design transient retries and reconciliation. Add duplicate protection where the current create or retry path can duplicate.
- Keep artifacts credential-based. Never check in secrets.

Read `references/n8n-workflow-design.md` before changing workflow JSON.

- n8n API `401`: use the container `n8n` CLI for workflow inspection, import, or export. Acumatica API `401`: check the request's credentials and tenant.
- Canonical Acumatica unreachable with VM and SQL already running: run `Automation/Setup/acumatica-ready.sh`. The canonical base is `http://127.0.0.1:38121/AcumaticaERP`.
- OAuth `invalid_grant`: verify site readiness, then diagnose the credential's client, tenant, user, and redirect configuration. Reauthorize through the configured workflow.
- `n8n execute --rawOutput`: parse stdout as JSON. This mode suppresses other text.

Validate the API or workflow result against UI or read-only DB evidence. Report endpoint or action, auth requirements, payload mapping, retry and duplicate policy, and required import or setup.
