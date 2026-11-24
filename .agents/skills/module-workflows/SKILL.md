---
name: module-workflows
description: "Use for Acumatica module screens, graphs, DACs, lifecycle states, source landmarks, or verification."
---

Resolve the build and website from the registered profile. Source landmarks are under that site's `App_Data/CodeRepository/PX.Objects/`. Verify names against the selected build. Trace screen → graph → DAC, then verify the relevant flow in the browser. For cross-module work, use the participating sections.

## AP: Payables

Trace AP bills through `AP301000` → `PX.Objects.AP.APInvoiceEntry` → `APInvoice` / `APTran`, and checks and payments through `AP302000` → `PX.Objects.AP.APPaymentEntry` → `APPayment` / `APAdjust` / `APTaxTran`.

Bills move `Hold → Balanced → Open → Closed`. Payments move `Hold → Balanced → Open/Closed`, subject to setup, applications, and voids. Release is separate and moves Balanced documents to Open or Closed. Approval arrives through workflow extensions and approval maps.

Read `AP/APInvoiceEntry.cs`, `AP/APPaymentEntry.cs`, `AP/APPaymentEntry_Workflow.cs`, and applicable approval extensions. Verify by creating and releasing a bill, creating, applying, and releasing a payment, then confirming the bill balance, payment state, and GL impact. Preserve `Match<>` and branch scope in custom views or selectors. Map action rights explicitly.

## AR: Receivables

Trace AR invoices through `AR301000` → `PX.Objects.AR.ARInvoiceEntry` → `ARInvoice` / `ARTran`, and payments and applications through `AR302000` → `PX.Objects.AR.ARPaymentEntry` → `ARPayment` / `ARAdjust`.

Invoices move `Hold → Balanced → Open → Closed` after full application. Release is separate. Payment release runs through `ARPaymentEntry`. Read `AR/ARInvoiceEntry.cs` and `AR/ARPaymentEntry.cs`. Verify by releasing an invoice, creating, applying, and releasing a payment, then confirming invoice zero balance and payment release/open-or-closed state.

## GL: General ledger

Trace journal transactions through `GL301000` → `PX.Objects.GL.JournalEntry` → `Batch` / `GLTran`.

Batches move `Hold → Balanced → Released → Posted`; posting timing depends on configuration. Debit and credit must balance before release. Read `GL/JournalEntry.cs` and `GL/JournalEntry_Workflow.cs`. Verify a balanced batch through hold removal and release, then inspect `Batch.status`, posting state, history, and balances.

## CA: Cash management

Trace typical bank transactions through `CA306000` → `PX.Objects.CA.CABankTransactionsMaint` → `CABankTran`, and reconciliation through `CA302000` → `PX.Objects.CA.CAReconEntry` → `CARecon`.

Bank transactions are imported or created, matched and processed against payments or receipts, then reconciled by cash account. Items move from `Unreconciled` to `Reconciled`. Read `CA/CABankTransactionsMaint.cs` and `CA/CAReconEntry.cs`. Verify matched transactions point to expected cash documents and reconciliation closes with the expected balance and status.

## IN: Inventory

Trace receipts through `IN301000` → `PX.Objects.IN.INReceiptEntry`, issues through `IN302000` → `PX.Objects.IN.INIssueEntry`, and transfers through `IN304000` → `PX.Objects.IN.INTransferEntry`. Each uses `INRegister` and `INTran`.

Documents move `Hold → Balanced → Released`. Release updates inventory and, by posting setup, GL. Read `IN/INReceiptEntry.cs`, `IN/INIssueEntry.cs`, and `IN/INTransferEntry.cs`. Verify one released receipt, issue, or transfer, then confirm quantities, site/location, cost, and GL effect where configured.

## PO: Purchasing

Trace purchase orders through `PO301000` → `PX.Objects.PO.POOrderEntry` → `POOrder` / `POLine`, and receipts through `PO302000` → `PX.Objects.PO.POReceiptEntry` → `POReceipt` / `POReceiptLine`.

Purchase orders move `Hold → Open → Closed`. Receipts move `Hold → Balanced → Released`; release updates inventory and AP accruals. Read `PO/POOrderEntry.cs` and `PO/POReceiptEntry.cs`. Verify an opened PO, a receipt from PO lines, release, received quantities, and resulting PO state.

## SO: Sales

Trace sales orders through `SO301000` → `PX.Objects.SO.SOOrderEntry` → `SOOrder` / `SOLine`, shipments through `SO302000` → `PX.Objects.SO.SOShipmentEntry` → `SOShipment` / `SOShipLine`, and invoices through `SO303000` → `PX.Objects.SO.SOInvoiceEntry` → `ARInvoice` / `ARTran`.

Orders usually move `Hold → Open → Shipping → Completed/Invoiced`; exact states depend on order type and workflow. Read `SO/SOOrderEntry.cs`, `SO/SOShipmentEntry.cs`, and `SO/SOInvoiceEntry.cs`. Verify an order through shipment confirmation, invoice creation and release, then inspect `SOOrderShipment` links and status.

`SOOrder` is keyed by `(OrderType, OrderNbr)`; `SOLine` shares those keys. `SO201000` changes quote, order, return, and invoice-only behavior. Inspect inventory, site, currency, hold/status, and shipment/invoice links. Use shipment graphs and actions, never line mutation, to create shipments.

## CRM

Trace CRM leads through `CR301000` → `PX.Objects.CR.LeadMaint` → `CRLead`, opportunities through `CR304000` → `PX.Objects.CR.OpportunityMaint` → `CROpportunity`, and quotes through `CR304500` → `PX.Objects.CR.QuoteMaint` → `CRQuote`.

The normal flow is lead → opportunity → quote → sales order, subject to enabled features and workflow. Read `CR/Graphs/LeadMaint/LeadMaint.cs`, `CR/Graphs/OpportunityMaint/OpportunityMaint.cs`, and `CR/Graphs/QuoteMaint/QuoteMaint.cs`. Verify conversion, opportunity products, quote creation, optional order creation, and preserved source links.

## PM: Projects

Trace projects through `PM301000` → `PX.Objects.PM.ProjectEntry` → `PMProject` plus budget/history DACs, and tasks through `PM302000` → `PX.Objects.PM.ProjectTaskEntry` → `PMTask`.

Projects usually move `Planned → Active → Completed/Closed`, depending on type. Tasks and budgets feed billing; enabled extensions can add change orders. Read `PM/ProjectEntry.cs` and `PM/ProjectTaskEntry.cs`. Verify activation, tasks/budgets, billing, generated AR invoice or pro forma as configured, and project balances.
