Decide whether valid, unique input is an accepted precondition or the scenario must fail closed. It fails closed only when it distinguishes zero, one, and many targets before business logic runs. Use native `SM206025` configuration for an accepted unique-input precondition. Add an action or external preflight when missing, stale, or ambiguous input must be rejected.

1. Trace the screen action to its graph delegate and the exact `Current<>` or key fields it consumes.
2. Trace projected or grid fields to the underlying DAC identity. Visible document type and reference can omit the real key.
3. Treat `DependOnGrid` as a warning: browser selection can post hidden identity that an Import Scenario field tree cannot reproduce.
4. Check business-key cardinality. Header keys and visible detail values can still match several rows.

Source-provider `IsKey` fields identify or group source rows, not necessarily the target search. Direct `@@` mappings are not equivalent to the linked key and Cancel commands an ordinary target-field Search creates. Search builds lookup commands but does not prove a failed detail lookup clears the graph's current row. Commit and Execute Action scope persistence and action execution, not identity safety. Inspect compiled screen commands and test a no-match row.

Verify business rows and hidden identity, not Import History alone:

| Case | Required observation |
|---|---|
| first and non-first detail | only the requested detail changes |
| missing parent or detail | no mutation or current-row fallback |
| duplicate visible key | explicit rejection or documented precondition |
| retry or already processed | no duplicate mutation |
| several details or parents | context remains isolated |
| closed and open states | native transitions and persistence remain valid |

Create fixtures through supported APIs. Use SQL only for read-only cardinality and post-action verification. Inspect the affected DAC, projected-row key, status, and release state.

When native mapping cannot prove identity, accept business keys as action parameters, query authoritative active candidates, require exactly one, resolve it to the projected/grid identity used by the native action, set the current row, and invoke native business logic. Do not duplicate reversal or release logic. When several source rows affect one document, persist row work first and release that document once.
