Trace typical bank transactions through `CA306000` → `PX.Objects.CA.CABankTransactionsMaint` → `CABankTran`, and reconciliation through `CA302000` → `PX.Objects.CA.CAReconEntry` → `CARecon`.

Bank transactions are imported or created, matched and processed against payments or receipts, then reconciled by cash account. Items move from `Unreconciled` to `Reconciled`. Read `CA/CABankTransactionsMaint.cs` and `CA/CAReconEntry.cs`. Verify matched transactions point to expected cash documents and reconciliation closes with the expected balance and status.
