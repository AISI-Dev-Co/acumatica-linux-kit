Trace projects through `PM301000` → `PX.Objects.PM.ProjectEntry` → `PMProject` plus budget/history DACs, and tasks through `PM302000` → `PX.Objects.PM.ProjectTaskEntry` → `PMTask`.

Projects usually move `Planned → Active → Completed/Closed`, depending on type. Tasks and budgets feed billing; enabled extensions can add change orders. Read `PM/ProjectEntry.cs` and `PM/ProjectTaskEntry.cs`. Verify activation, tasks/budgets, billing, generated AR invoice or pro forma as configured, and project balances.
