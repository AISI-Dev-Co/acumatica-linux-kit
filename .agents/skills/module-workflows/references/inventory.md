Trace receipts through `IN301000` → `PX.Objects.IN.INReceiptEntry`, issues through `IN302000` → `PX.Objects.IN.INIssueEntry`, and transfers through `IN304000` → `PX.Objects.IN.INTransferEntry`. Each uses `INRegister` and `INTran`.

Documents move `Hold → Balanced → Released`. Release updates inventory and, by posting setup, GL. Read `IN/INReceiptEntry.cs`, `IN/INIssueEntry.cs`, and `IN/INTransferEntry.cs`. Verify one released receipt, issue, or transfer, then confirm quantities, site/location, cost, and GL effect where configured.
