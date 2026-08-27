# 114 — Task Relationship Authority + Activity History (UAT Correction)

## 1. Live UAT Finding

Manual UAT confirmed Task Relationships work correctly end-to-end — creation, partial-title search, and relationship cards showing type/number/title/status/priority/assignee/due date all passed. However, logged in as Room manager — the *active assignee* of the real UAT task (`TSK-MCS-STG-2026-0003`), not its creator or a supervisor — the Related Tasks section still exposed **Add Relationship** and **Remove Relationship**. A previous checkpoint had also flagged that relationship add/remove had an Activity-history visibility gap. Both are corrected together in this milestone, mirroring docs/113's dependency correction.

## 2. Authorization Root Cause

Identical shape to docs/113. `can_manage_task()` is `TRUE` for a task's active assignee by design. `create_task_relationship()`, `remove_task_relationship()`, `list_related_tasks()`'s `can_remove` column, and `get_task_relationship_capabilities()` all gated on `can_manage_task()` for both endpoint tasks — so an assignee with no other manage-tier standing already had, and could exercise, Add/Remove Relationship. **Root cause B (backend)** — confirmed by direct inspection, not assumed. The frontend already rendered both controls purely from `_relationshipCapabilities.can_create` / per-row `can_remove`; no frontend authorization change was needed.

## 3. Activity History Root Cause

`create_task_relationship()`/`remove_task_relationship()` already wrote `'task_linked'`/`'task_unlinked'` audit rows, but with `record_type = 'task_relationship'` and `record_id` = the relationship row's own id — not `record_type = 'task'` / `record_id` = a task's id, which is what `TasksAPI.fetchTaskAuditTrail()` actually queries. Relationship add/remove therefore rendered **nothing** on either task's own Activity timeline — the exact same defect shape docs/113 found and fixed for dependencies.

## 4. Backend/Frontend Defect Classification

Both issues: **root cause B (backend only)**.

## 5. Access Matrix Applied

| Actor | View relationships | Add relationship | Remove relationship |
|---|---|---|---|
| Creator | Yes | Yes | Yes |
| Supervisor-in-scope | Yes | Yes | Yes |
| Super-admin | Yes | Yes | Yes |
| Active assignee (no other standing) | Yes | **No** | **No** |
| Watcher | Yes (if can otherwise view) | No | No |
| Unrelated / cross-org / anonymous | No | No | No |

## 6. Relationship Functions Changed

- `create_task_relationship()` — both `can_manage_task()` gates → `can_manage_task_relationship()`; plus a second `audit_logs` row.
- `remove_task_relationship()` — same swap; gains a new `p_viewer_task_id UUID DEFAULT NULL` parameter; the old single-argument overload is explicitly `DROP`ped first (see §7); plus a second `audit_logs` row.
- `list_related_tasks()` — the `can_remove` column's two `can_manage_task()` calls → `can_manage_task_relationship()`.
- `get_task_relationship_capabilities()` — `can_create`/`can_remove` → `can_manage_task_relationship()`.

## 7. New Authorization Helper

`can_manage_task_relationship(p_task_id)` — a **deliberate twin** of docs/113's `can_manage_task_dependency()`, not a reuse or rename of it. Both alternatives would have required touching already-UAT-passed Dependency code, which this milestone's own instructions explicitly forbid absent a regression-verification need that doesn't exist here. Identical body: creator / supervisor-in-scope / super-admin only, no active-assignee branch.

A signature-identity pitfall was caught before it shipped: adding `p_viewer_task_id` to `remove_task_relationship()` via bare `CREATE OR REPLACE` would **not** replace the old one-argument function — Postgres treats a changed argument-type list (even with a `DEFAULT`) as a different function identity, so the old, un-narrowed overload would have remained live and callable alongside the new one. The migration explicitly `DROP FUNCTION IF EXISTS remove_task_relationship(UUID)` before recreating it with the new signature.

## 8. Audit/Action Changes

New action codes: `task_relationship_added`, `task_relationship_removed`, added to `audit_logs_action_check` (predecessor: docs/113's own migration — the last file in canonical order to touch this constraint, confirmed live before writing). Existing `'task_linked'`/`'task_unlinked'` rows (record_type='task_relationship') are left untouched — nothing currently consumes them, so removing them was out of this correction's scope.

## 9. Frontend Control Changes

None for authorization (already correct). One defense-in-depth hardening: the relationship card's Remove button now also checks `this._relationshipCapabilities?.can_remove === true` alongside the existing per-row `r.can_remove`, mirroring the dependency card's established double-gate pattern (`_dependencyCardHtml`). `row.can_remove=true` already implies `capabilities.can_remove=true` for well-formed data, but the extra AND costs nothing and closes a theoretical gap. Activity timeline rendering (`_auditEvent()`, new `_parseRelationshipNotes()`/`_relationshipActivityTitle()` helpers) extended for the two new action codes.

## 10-16. Semantics, Wording, and Validation Results

- **Related** (10/15): symmetric, canonicalized storage (`LEAST`/`GREATEST`), unchanged — verified both live and in the backend test suite.
- **Duplicate** (14): symmetric, unchanged — verified live (`create_task_relationship(TaskB, TaskC, 'duplicate')` succeeded; activity row correct).
- **Parent** (13/16): directional and unchanged — the viewer (always `p_source_task_id`, since this function's own direction rule is untouched) is always the parent side when adding with type `'parent'`, so the *other* task's role recorded is `'child'` (the exact synthetic label `list_related_tasks()` already computes for display — not a new stored type). Verified live: adding Task B → Task C as `'parent'` produced exactly one activity row with `relationship_type=child`.
- **Self-link / duplicate-pair / cycle prevention** (10/11/12): all unchanged logic, preserved verbatim, exercised in the backend test file.
- **Relationship-add wording** (18): `"linked {task} as a related task"` / `"marked {task} as a duplicate task"` / `"linked {task} as the child task"`.
- **Relationship-remove wording** (19): `"removed the relationship with {task}"` — type-agnostic, matching the correction's own example.

## 11. Security / No-Leak Design

Identical design to docs/113. The new `record_type='task'` rows are read through the existing `audit_select_own_records → can_view_case_audit_record('task', record_id)` RLS path, unchanged. The related task's title/number is never baked into `notes` — only its bare id (`related_task_id=<uuid>`, optionally `;relationship_type=<...>`) — so visibility is re-evaluated at render time through the frontend's existing RLS-filtered `TasksAPI.fetchTasksByIds()` batch call (built for docs/113, reused unchanged here). Live-verified: an unrelated same-org user's read of `audit_logs` for the relationship-activity row returned zero rows.

## 12. Historical Fallback Behavior

Old relationship mutations from before this patch have no Activity-timeline row (same as today) — not retroactively fabricated. Unknown/old action codes safely return `null` from `_auditEvent()` (frontend test confirms).

## 13. Files Changed

- `supabase/patch-task-relationship-authority-and-activity-history.sql` (new)
- `supabase/rollback-task-relationship-authority-and-activity-history.sql` (new)
- `supabase/test-task-relationship-authority-and-activity-history.sql` (new)
- `supabase/deploy/canonical-migration-order.txt` (appended section 15)
- `js/views/task-detail.js` (defense-in-depth remove-button gate; Activity timeline rendering)
- `js/data/tasks-api.js` (`removeTaskRelationship()` now passes `p_viewer_task_id`)
- `tests/task-relationships-frontend.test.js` (one existing fixture updated — see §14)
- `tests/task-relationship-authority-and-activity-history-frontend.test.js` (new)
- `docs/114-task-relationship-authority-activity-history-uat-fix.md` (this file)

## 14. Tests

**Backend** (`supabase/test-task-relationship-authority-and-activity-history.sql`): 22+ scenarios (the required 22 plus supervisor-in-scope and reverse-pair/symmetric-direction supplements) covering authorization (creator/supervisor/assignee/watcher/unrelated/cross-org/anonymous, both-side authority, org isolation), validation (self-link, duplicate, reverse-pair duplicate, parent cycle, Related/Duplicate/Parent semantics and direction), and activity (add/remove events, per-type wording metadata, structural id storage, no-leak). **Written but not executed in this environment** (no local PostgreSQL available) — substituted with live-transaction verification against real staging (§15).

**Frontend** (`tests/task-relationship-authority-and-activity-history-frontend.test.js`, new): 16 scenarios. **Executed for real** (playwright against pre-installed Chromium): **16/16 PASSED**. This run caught one real, if currently unreachable-by-real-data, inconsistency (§9's defense-in-depth fix) before it shipped.

**Regression** (existing suites, re-run for real after the fix):
- `tests/task-relationships-frontend.test.js`: 70/70 PASSED (one pre-existing test fixture at the "permission gating" check needed updating — it reset `_relationshipCapabilities` to `{can_create:true}`, dropping `can_remove`, which only started mattering once this milestone's defense-in-depth gate was added; fixed to `{can_create:true, can_remove:true}`)
- `tests/task-dependency-authority-and-activity-history-frontend.test.js`: 16/16 PASSED
- `tests/task-assignee-permission-and-activation-frontend.test.js`: 8/8 PASSED
- `tests/task-standalone-creation-frontend.test.js`: 13/13 PASSED
- `tests/task-start-work-and-assignment-accountability-frontend.test.js`: 10/10 PASSED

## 15. Live Staging Verification

Performed against `vjobntuyzymhcuanyeak`, using the real `TSK-MCS-STG-2026-0001/0002/0003` tasks and the real "Normal staff" (creator) / "Room manager" (assignee) accounts, inside transactions with no final `COMMIT` (auto-rolled-back), re-verified clean afterward both times.

A real active `related` relationship already existed between Task A and Task B from prior human UAT activity — used directly for the exact bug reproduction:

1. Room manager's `get_task_relationship_capabilities()` on Task B: `create=false, remove=false`.
2. Room manager attempts to remove the real, pre-existing relationship → **denied** ("Not authorized to remove this task relationship") — the exact bug, fixed.
3. Room manager attempts to add a new relationship → **denied**.
4. Creator adds Task C as a **Duplicate** of Task B → succeeds; activity row confirmed: `action=task_relationship_added, notes=related_task_id=<uuid>;relationship_type=duplicate`.
5. Creator removes it → succeeds; activity row confirmed: `action=task_relationship_removed`.
6. Creator adds Task B → Task C as **Parent** (Task B is the parent) → exactly one activity row on Task B's timeline with `relationship_type=child` — correct directionality.

## 16. Existing UAT Records Preserved

`TSK-MCS-STG-2026-0001/0002/0003` and the real active relationship between them were not modified — every mutating call used in verification ran inside a transaction that was never committed. Re-queried and confirmed byte-identical before/after both verification runs.

## 17. Rollback

`supabase/rollback-task-relationship-authority-and-activity-history.sql` restores every function's exact pre-correction body, drops `can_manage_task_relationship()` entirely, restores `remove_task_relationship()`'s original one-argument signature (dropping the two-argument version first, for the same identity reason), and restores `audit_logs_action_check` to its docs/113 shape. Not executed (would require local PostgreSQL) — same honestly-disclosed limitation as docs/113.

## 18. Remaining Task Relationship Limitations

- `search_tasks_for_relationship()`'s own candidate-search authorization remains `can_manage_task()`-gated (unchanged). It is unreachable by a non-manage-tier user through the UI (the Add Relationship button that opens it is already omitted), and this was not a live UAT finding — narrowing it now would be exactly the kind of "unrelated improvement" this correction is told not to make.
- The backend test file could not be executed in this environment; live-transaction verification against real staging was used as the primary evidence instead.
- No new relationship types were added or hidden ones exposed — Related/Duplicate/Parent remain exactly as they were.
