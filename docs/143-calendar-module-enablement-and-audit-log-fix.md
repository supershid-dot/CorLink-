# 143 — Calendar Nav Missing for Regular Users + Audit Log Constraint Fix

## 1. UAT

Screenshot of user "Hussain" (HZ) at org MCS-STG, whose sidebar shows Dashboard/Tasks/Requests/Entry/Meeting Rooms/Meetings but no Calendar item:

> "cannot see the calendar tab for others users"

## 2. Root cause

CorLink gates each module's nav item behind two independent layers:

1. **Per-organization enablement** (`organization_modules.is_enabled`) — checked by `AppShell.isModuleEnabled()`. Super admins bypass this check entirely, which is why the Calendar tab has looked fine in every screenshot taken from a super-admin account throughout this feature's development.
2. **Role/assignment checks** — unrelated here.

`patch-calendar-route-activation.sql` activated Calendar's frontend *route* platform-wide, but — by that migration's own documented design — left per-organization enablement as a separate, later admin action, mirroring how `rooms`/`meetings` were rolled out. That later step was never taken: `organization_modules` had no row (`is_enabled = NULL`) for `calendar` in either staging organization, while `rooms`/`meetings` were already `true` for MCS-STG. Hussain's `user.enabledModules` array therefore never contained `'calendar'`, so his nav (built by a non-super-admin path) omitted it — exactly matching the screenshot.

## 3. A second bug found while fixing the first

Enabling a module for an organization is normally done via Admin > Modules, which calls `ModulesAPI.setModuleEnabled()` (`js/data/modules-api.js`). That function upserts `organization_modules` and then inserts an `audit_logs` row with `action: 'module_enabled'` / `'module_disabled'`. Reproducing that exact write against CorLink Staging revealed `audit_logs_action_check` has never allowed either value — the constraint was last widened by `patch-task-relationship-authority-and-activity-history.sql`, before `patch-platform-module-foundation.sql`'s module-toggle feature ever shipped, and no later migration added the two codes it needs. In practice this means **every previous Admin > Modules toggle has thrown after its `organization_modules` write already committed** — the toggle silently took effect, but the calling admin would have seen an error.

Fixed in `supabase/patch-audit-logs-module-actions.sql`: widens `audit_logs_action_check` to add `'module_enabled'`/`'module_disabled'`, preserving every previously-allowed value verbatim (same drop+recreate pattern this constraint has always used). Companion `validate-…`/`rollback-…` scripts added, matching this repo's convention.

## 4. Fix applied

- Migration applied + validated on CorLink Staging (constraint now permits both values; validator confirms no previously-allowed value was lost).
- `organization_modules` upserted for org **MCS-STG** (`calendar` module, `is_enabled = true`), using the identical shape `ModulesAPI.setModuleEnabled()` performs, plus the matching `audit_logs` row (which now succeeds).
- No code changes were needed — `AppShell.isModuleEnabled()` and the nav-building logic were already correct; this was purely a missing data row plus the newly-fixed constraint bug blocking the normal admin path from setting that row going forward.

## 5. Files

- `supabase/patch-audit-logs-module-actions.sql` / `validate-…` / `rollback-…` — widen `audit_logs_action_check`.
- Data fix (not a migration file — a one-time per-org enablement, same as any other Admin > Modules click): `organization_modules` row for MCS-STG + `calendar`.

## 6. Deployment

Migration + validator run on CorLink Staging. `organization_modules` data fix applied directly to CorLink Staging. Admin > Modules can now be used going forward (for MCS-STG's own Rooms/Meetings history, and for HRCM-STG or any other org/module combination) without hitting the audit-log error this also fixed.
