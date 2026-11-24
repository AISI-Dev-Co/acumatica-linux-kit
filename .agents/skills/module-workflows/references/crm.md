Trace CRM leads through `CR301000` → `PX.Objects.CR.LeadMaint` → `CRLead`, opportunities through `CR304000` → `PX.Objects.CR.OpportunityMaint` → `CROpportunity`, and quotes through `CR304500` → `PX.Objects.CR.QuoteMaint` → `CRQuote`.

The normal flow is lead → opportunity → quote → sales order, subject to enabled features and workflow. Read `CR/Graphs/LeadMaint/LeadMaint.cs`, `CR/Graphs/OpportunityMaint/OpportunityMaint.cs`, and `CR/Graphs/QuoteMaint/QuoteMaint.cs`. Verify conversion, opportunity products, quote creation, optional order creation, and preserved source links.
