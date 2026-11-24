Trace purchase orders through `PO301000` → `PX.Objects.PO.POOrderEntry` → `POOrder` / `POLine`, and receipts through `PO302000` → `PX.Objects.PO.POReceiptEntry` → `POReceipt` / `POReceiptLine`.

Purchase orders move `Hold → Open → Closed`. Receipts move `Hold → Balanced → Released`; release updates inventory and AP accruals. Read `PO/POOrderEntry.cs` and `PO/POReceiptEntry.cs`. Verify an opened PO, a receipt from PO lines, release, received quantities, and resulting PO state.
