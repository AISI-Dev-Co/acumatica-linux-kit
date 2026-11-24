Trace AP bills through `AP301000` → `PX.Objects.AP.APInvoiceEntry` → `APInvoice` / `APTran`, and checks and payments through `AP302000` → `PX.Objects.AP.APPaymentEntry` → `APPayment` / `APAdjust` / `APTaxTran`.

Bills move `Hold → Balanced → Open → Closed`. Payments move `Hold → Balanced → Open/Closed`, subject to setup, applications, and voids. Release is separate and moves Balanced documents to Open or Closed. Approval arrives through workflow extensions and approval maps.

Read `AP/APInvoiceEntry.cs`, `AP/APPaymentEntry.cs`, `AP/APPaymentEntry_Workflow.cs`, and applicable approval extensions. Verify by creating and releasing a bill, creating, applying, and releasing a payment, then confirming the bill balance, payment state, and GL impact. Preserve `Match<>` and branch scope in custom views or selectors. Map action rights explicitly.
