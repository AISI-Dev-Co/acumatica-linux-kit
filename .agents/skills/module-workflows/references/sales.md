Trace sales orders through `SO301000` → `PX.Objects.SO.SOOrderEntry` → `SOOrder` / `SOLine`, shipments through `SO302000` → `PX.Objects.SO.SOShipmentEntry` → `SOShipment` / `SOShipLine`, and invoices through `SO303000` → `PX.Objects.SO.SOInvoiceEntry` → `ARInvoice` / `ARTran`.

Orders usually move `Hold → Open → Shipping → Completed/Invoiced`; exact states depend on order type and workflow. Read `SO/SOOrderEntry.cs`, `SO/SOShipmentEntry.cs`, and `SO/SOInvoiceEntry.cs`. Verify an order through shipment confirmation, invoice creation and release, then inspect `SOOrderShipment` links and status.

`SOOrder` is keyed by `(OrderType, OrderNbr)`; `SOLine` shares those keys. `SO201000` changes quote, order, return, and invoice-only behavior. Inspect inventory, site, currency, hold/status, and shipment/invoice links. Use shipment graphs and actions, never line mutation, to create shipments.
