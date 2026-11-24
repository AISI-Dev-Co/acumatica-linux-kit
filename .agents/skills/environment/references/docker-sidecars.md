Use `Automation/Setup/n8n-up.sh` and `n8n-down.sh` for local n8n. Host networking lets n8n reach the existing Acumatica tunnel. n8n listens on `127.0.0.1:5678` only. There is no Windows-to-n8n callback route by default. If a workflow needs callbacks, design a private route for that workflow instead of widening the default listener.

Run `Automation/Setup/acumatica-up.sh` without `--core-only` for the full stack. For an already-ready canonical site, use `n8n-up.sh`. It creates or reuses `n8n_data` and verifies both n8n health and n8n-to-Acumatica HTTP. Complete first-time owner setup in the browser. Save the disposable owner login in `dev-logins.env` under the runtime directory. Don't reset an existing owner account. The owner account is not an Acumatica API credential. Configure workflow authentication and tenant separately, then verify a read-only request before enabling writes.

Use the container `n8n` CLI for workflow inspection, import, or export when the n8n API returns `401`. For Acumatica OAuth or API failures, load the applicable integration skill.

MSSQL runs in `mssql` with volume `acumatica-mssql-data`. Probe it with container `sqlcmd`; the guest endpoint is `172.30.0.1:1433`. When UI state is ambiguous, use read-only queries to verify integration results.

Trace connectivity in this order:

1. Windows guest → authenticated SQL query against `AcumaticaDB` via `Automation/Setup/vm-pwsh.sh < Automation/Setup/check-acumatica-sql.ps1`
2. Windows-local → IIS `127.0.0.1:80`
3. Host → Acumatica `127.0.0.1:38121`
4. n8n → Acumatica `127.0.0.1:38121`
5. Host → n8n `http://127.0.0.1:5678/healthz`
