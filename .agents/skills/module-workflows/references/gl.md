Trace journal transactions through `GL301000` → `PX.Objects.GL.JournalEntry` → `Batch` / `GLTran`.

Batches move `Hold → Balanced → Released → Posted`; posting timing depends on configuration. Debit and credit must balance before release. Read `GL/JournalEntry.cs` and `GL/JournalEntry_Workflow.cs`. Verify a balanced batch through hold removal and release, then inspect `Batch.status`, posting state, history, and balances.
