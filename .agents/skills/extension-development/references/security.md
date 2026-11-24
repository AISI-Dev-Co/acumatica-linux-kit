Use `SM201020` for rights by screen, `SM201025` for rights by role, and `SM201030` for restriction groups. Users and roles are managed through `SM201010` and `SM201005`.

Apply the entity or branch restriction appropriate to every sensitive selector, view, or direct query. `Match<>` is common, not universal. Code that bypasses a restricted graph view needs an equivalent `PXRestrictor` or `PXAccess` check. Preserve related-DAC access scope. Actions declare `MapEnableRights` and `MapViewRights`; apply UI enablement only after access checks. Cross-branch processing needs `PXReadBranchRestrictedScope` or its applicable equivalent. API data follows entity rights as well as screen rights.

Verify with a limited role: screen access matches configuration, selectors exclude unauthorized company, branch, and entity rows, update actions stay unavailable without update rights, and processing cannot cross scope.
