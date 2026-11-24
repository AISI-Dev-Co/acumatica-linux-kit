---
name: acumatica-upgrade
description: "Read before assessing, rehearsing, or executing an Acumatica upgrade."
---

Treat an upgrade assessment as planning, not authority to alter an instance. Gather task-specific facts afresh. Do not promote an assessment into standing instructions.

1. Confirm exact source and target builds, supported path, license, target package, Configuration Wizard requirements, and vendor prerequisites from the target release's official documentation. A marketing release is not a build.
2. Inspect the deployed site, database, wizard, hosting, tenants, portal instances, maintenance constraints, backups, and rollback path. Source, packages, and a stopped site do not establish deployed state.
3. Inventory every relevant `SM204505` project, its exported package, published state, dependencies, workflow/UI changes, and ISV support. Inventory API versions, webhooks, OAuth, file transfer, import scenarios, reports, and scheduled jobs.
4. Export deployed projects and preserve package checksums, source commits, configuration, and verified database backups before unpublishing anything. Portal publication is independent.
5. Rehearse on a disposable clone. Install the approved target package, unpublish projects through supported tooling, run compatibility validation, rebuild against target assemblies, then publish only validated packages.
6. Run the platform, customization, integration, and representative data-lifecycle regressions that the inventory identifies. Verify accounting and business identities, not only screen status.

Do not click an upgrade action, run the wizard, alter the database, or publish or unpublish a project without approval for that operation. Use the documented combined site-and-database operation. Do not bypass validation with `CheckCustomizationCompatibility=False`, SQL edits, or an improvised website-only or database-only sequence.

The Configuration Wizard is normally the supported major-upgrade surface. Treat browser Apply Updates as maintenance-package tooling unless the target documentation says otherwise.

Stop if the exact build or license is unclear, backup and restore are unverified, deployed projects cannot be exported, an ISV is unsupported, compatibility validation fails, or critical workflows lack a rehearsal. Preserve wizard, IIS, and application logs on failure. If site and database versions diverge, keep IIS and integrations stopped and recover only through the documented procedure and verified backup.

Record the exact builds, authoritative URLs and access dates, topology, inventory, risk rating with evidence, rehearsal and regression results, stop conditions, and actions still awaiting authorization in the task assessment.
