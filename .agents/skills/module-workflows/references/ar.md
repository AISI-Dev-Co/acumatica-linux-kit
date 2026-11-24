Trace AR invoices through `AR301000` → `PX.Objects.AR.ARInvoiceEntry` → `ARInvoice` / `ARTran`, and payments and applications through `AR302000` → `PX.Objects.AR.ARPaymentEntry` → `ARPayment` / `ARAdjust`.

Invoices move `Hold → Balanced → Open → Closed` after full application. Release is separate. Payment release runs through `ARPaymentEntry`. Read `AR/ARInvoiceEntry.cs` and `AR/ARPaymentEntry.cs`. Verify by releasing an invoice, creating, applying, and releasing a payment, then confirming invoice zero balance and payment release/open-or-closed state.
