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

- n8n API `401`: use the container `n8n` CLI for workflow inspection, import, or export. Acumatica API `401`: check the request's credentials and tenant.
- Canonical Acumatica unreachable with VM and SQL already running: run `Automation/Setup/acumatica-ready.sh`. The canonical base is `http://127.0.0.1:38121/AcumaticaERP`.
- OAuth `invalid_grant`: verify site readiness, then diagnose the credential's client, tenant, user, and redirect configuration. Reauthorize through the configured workflow.
- `n8n execute --rawOutput`: parse stdout as JSON. This mode suppresses other text.

Validate the API or workflow result against UI or read-only DB evidence. Report endpoint or action, auth requirements, payload mapping, retry and duplicate policy, and required import or setup.

## n8n workflow design

Implement current behavior only. Do not leave disabled future branches or placeholder nodes. Prefer native nodes and sub-nodes. Write code only at a real boundary: provider envelope, binary conversion, schema validation, split/merge, or unavailable capability. Give each node one operation and carry only values used downstream.

For AI Agent structured output, connect Structured Output Parser, set `hasOutputParser: true`, and consume `$json.output`. Do not add parser code when the installed version supports the parser sub-node. For Anthropic Messages, parse `content[0].text`; the HTTP node returns the provider envelope. Keep schemas small. Nullable unions and optional-property piles can fail compilation, so use a stable core with `additionalFields` or `notes`. Convert PDF binary to base64 before building an Anthropic `document` block.

Give extraction only the source document. Give drafting or matching the extracted data and the relevant Acumatica records. Omit delivery metadata, unrelated thread content, routing fields, and approval text unless the model needs them.

For approval, verify what the installed node version supports for response collection and attachments. If the approval action cannot attach a source document, link to the original message or file with appropriate access. Keep approval replies out of the intake trigger. Show the exact proposed Acumatica payload. The model drafts, the human approves, then the write runs.

Add a create or action branch only after endpoint, auth, and mapping are testable. Implement idempotency when the current create or retry path can duplicate. Otherwise record the deliberate duplicate policy. Verify workflow output and Acumatica UI or DB state.

Before handoff, confirm no replaceable code nodes, placeholders, or future branches; model context contains only task inputs; approval cannot trigger intake; artifacts use credentials or placeholders rather than secrets; and JSON parses and imports locally.
