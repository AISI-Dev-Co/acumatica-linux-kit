Use `Automation/Setup/n8n-up.sh` and `n8n-down.sh` for n8n. The canonical host URL is `http://127.0.0.1:5678`. Enable only on a development machine with inbound access to port 5678 restricted to its host and VM.

With host networking, n8n reaches the canonical site at `http://127.0.0.1:38121/AcumaticaERP`. Verify canonical readiness before debugging n8n. Use the container `n8n` CLI for workflow inspection, import, or export when the n8n API returns `401`. For Acumatica OAuth or API failures, load the applicable integration skill.

MSSQL runs in `mssql` with volume `acumatica-mssql-data`. Probe it with container `sqlcmd`; the guest endpoint is `172.30.0.1:1433`. When UI state is ambiguous, use read-only queries to verify integration results.

Trace connectivity in this order:

1. Windows guest → SQL `172.30.0.1:1433`
2. Windows-local → IIS `127.0.0.1:80`
3. Host → Acumatica `127.0.0.1:38121`
4. n8n → Acumatica `127.0.0.1:38121`
5. Host → n8n `127.0.0.1:5678`
