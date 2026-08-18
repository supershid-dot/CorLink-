# 113 — Task Dependency Authority + Activity History (UAT Correction)

## 1. Live UAT Findings

Two issues were reported from live staging testing against the real UAT tasks (`TSK-MCS-STG-2026-0001/0002/0003`), by the real "Normal staff" (creator) and "Room manager" (assignee) accounts:

**Issue A — Assignee can remove a dependency.** Task A (`TSK-MCS-STG-2026-0002`) is an active prerequisite of Task B (`TSK-MCS-STG-2026-0003`). Logged in as Room manager — the *assignee* of Task B, not its creator or a supervisor — the Task Detail page exposed **Remove Dependency**, and the underlying RPC would have honored the call. An assignee must not be able to change structural workflow dependencies merely because they are responsible for executing the task; doing so lets them bypass sequencing/accountability.

**Issue B — Activity history is too generic.** When Room manager moved Task B from Open → In Progress, the Activity timeline showed "Room manager Updated task details" — technically true, operationally useless. Separately (found during inspection, not originally reported but strictly worse): dependency add/remove wrote no visible activity at all on the task's own timeline.

## 2. Root Cause

**Issue A — root cause B (backend).** `can_manage_task()` (`patch-request-task-integration.sql`) is `TRUE` for a task's active assignee by design — it's the single predicate `update_task()`/`assign_task()`/`complete_task()` all reuse for ordinary task management. `create_task_dependency()`, `remove_task_dependency()`, `get_task_dependency_capabilities()`, and `list_task_dependencies()`'s `can_remove` column all gated on `can_manage_task()` for both dependency endpoints, so an assignee with no other standing already had, and could exercise, add/remove authority. The frontend (`js/views/task-detail.js`) was already correct — it renders Add Prerequisite / Remove Dependency purely from `_dependencyCapabilities.can_add_dependency` / `can_remove_dependency` + per-row `can_remove`; once the RPCs return the right values, no frontend change was needed at all.

**Issue B — root cause B (backend).** `update_task()` is the only path for both Draft → Open and Open → In Progress, and always wrote the single generic `'edited'` audit action regardless of what changed. Separately, `create_task_dependency()`/`remove_task_dependency()` already wrote `'task_dependency_added'`/`'task_dependency_removed'` audit rows — but with `record_type = 'task_dependency'` and `record_id` = the dependency row's own id, not `record_type = 'task'` / `record_id` = the dependent task's id, which is what `TasksAPI.fetchTaskAuditTrail()` actually queries. So dependency add/remove rendered **nothing** on the task's own Activity timeline — a bigger gap than "generic wording," caught by direct inspection rather than assumed from the bug report's framing.

**Stale-baseline catch.** Before writing the migration, I confirmed every function's *true* current predecessor directly against live staging (`vjobntuyzymhcuanyeak`) rather than trusting the most-recently-read repo file. This caught a real discrepancy: `update_task()`'s true predecessor is `patch-task-assignee-permission-and-activation-fix.sql` (docs/109/110), not `patch-task-dependency-lifecycle-enforcement.sql` as initially assumed. The later file already narrowed `update_task()`'s general authorization to manage-tier only, carving out a `v_is_pure_start_request` exception that is the *only* way a plain assignee can call `update_task()` at all (and the exact mechanism behind "Room manager started work on this task"). The migration restates this body with that exception preserved verbatim.

## 3. Access Matrix Applied

| Actor | View dependencies | Add prerequisite | Remove dependency |
|---|---|---|---|
| Creator | Yes | Yes | Yes |
| Supervisor-in-scope | Yes | Yes | Yes |
| Super-admin | Yes | Yes | Yes |
| Active assignee (no other standing) | Yes | **No** | **No** |
| Watcher | Yes (if can otherwise view) | No | No |
| Unrelated / cross-org / anonymous | No | No | No |

Start Work and completion eligibility (`get_task_dependency_lifecycle_state()`) deliberately keep the broader `can_manage_task()` (assignee included) — starting/completing one's own assigned work is not a structural dependency change and was explicitly out of scope.

## 4. Backend Changes

New function: `can_manage_task_dependency(p_task_id)` — an exact copy of `can_manage_task()` with the active-assignee branch removed (creator / supervisor-in-scope / super-admin only).

Restated functions (each from its confirmed true predecessor, diff limited to the stated change):
- `create_task_dependency()` — both `can_manage_task()` gates → `can_manage_task_dependency()`; plus a second `audit_logs` row (see §5).
- `remove_task_dependency()` — same swap; plus a second `audit_logs` row.
- `list_task_dependencies()` — the `can_remove` column's two `can_manage_task()` calls → `can_manage_task_dependency()`.
- `get_task_dependency_capabilities()` — `can_add_dependency`/`can_remove_dependency` → `can_manage_task_dependency()`.
- `update_task()` — computes `v_action` (`'task_started'` for Draft→Open, `'task_work_started'` for Open/Waiting→In Progress, else the existing `'edited'`) and writes it instead of the hardcoded literal. `v_is_pure_start_request` and both authorization blocks preserved verbatim.
- `assign_task()` — `notes` now stores the target's `full_name` (one indexed lookup) instead of a raw UUID. CAP-003 outbox enqueue preserved verbatim.
- `unassign_task()` — same enrichment for the (former) assignee's name.
- `audit_logs_action_check` — widened to add `'task_started'`, `'task_work_started'` only; every prior value preserved.

## 5. Activity Event/Action Mapping

| Transition / action | Action code | Frontend wording |
|---|---|---|
| `create_task()` | `created` (unchanged) | "created this task" |
| Draft → Open | `task_started` (new) | "started this task" |
| Open/Waiting → In Progress | `task_work_started` (new) | "started work on this task" |
| Other edit (no lifecycle transition) | `edited` (unchanged) | "updated task details" |
| `complete_task()` | `completed` (unchanged) | "completed this task" |
| `cancel_task()` | `cancelled` (unchanged) | "cancelled this task" |
| `assign_task()` | `assigned` (unchanged code; named notes) | "assigned {name}" |
| `unassign_task()` | `unassigned` (unchanged code; named notes) | "removed {name} from the task" |
| Dependency add | `task_dependency_added` (existing code, new `record_type='task'` row) | "added {task} as a prerequisite" / "added a prerequisite task" |
| Dependency remove | `task_dependency_removed` (existing code, new `record_type='task'` row) | "removed {task} as a prerequisite" / "removed a prerequisite task" |

Frontend: `js/views/task-detail.js`'s `_auditEvent()` map extended with the two new action codes and the two dependency codes; `_relatedTaskActivityTitle()` resolves the linked task via a batched `TasksAPI.fetchTasksByIds()` call (one query per Activity panel load, not per row).

## 6. Security

The new `record_type='task'` dependency-activity rows are read through the same `audit_select_own_records → can_view_case_audit_record('task', record_id)` RLS path every other `'task'` row already uses — visible only to someone who can already view the dependent task. The *other* task's title/number is deliberately **not** baked into `notes` at write time — only `related_task_id=<uuid>` is stored. Baking the title in at write time would let it survive in the audit trail even if that task's visibility to a given viewer changed later. Instead, the frontend batch-resolves ids through a plain `SELECT id, task_number, title FROM tasks WHERE id = ANY(...)`, which the existing `tasks_select` RLS policy (`can_view_task(id)`) already filters — an unauthorized id is simply absent from the result, and the timeline falls back to safe generic wording ("added a prerequisite task"). No RLS policy changed; no new grants beyond `can_manage_task_dependency()`'s own `GRANT EXECUTE ... TO authenticated`.

## 7. Migration / Rollback

- Forward: `supabase/patch-task-dependency-authority-and-activity-history.sql`
- Rollback: `supabase/rollback-task-dependency-authority-and-activity-history.sql` — restores every function's exact pre-correction body and the narrower `audit_logs_action_check`. Does not delete any `audit_logs` rows the new code path already wrote while live; if `'task_started'`/`'task_work_started'` rows exist, the rollback's `ADD CONSTRAINT` will correctly refuse (constraint validation runs against existing data) rather than silently stranding them — same convention as `rollback-notification-target-expansion.sql`'s strand-refusal.
- Canonical order: appended as section 14 in `supabase/deploy/canonical-migration-order.txt`, with the true predecessor for every restated function documented inline (including the `update_task()` stale-baseline correction).

## 8. Tests

**Backend** (`supabase/test-task-dependency-authority-and-activity-history.sql`): 24 scenarios covering creator/supervisor/assignee/watcher/unrelated/cross-org/anonymous dependency add/remove authorization, `get_task_dependency_capabilities()`/`list_task_dependencies()` agreement, Start Work blocked/resolved, cycle prevention (verified before either endpoint is completed, so a rejection can only come from real cycle detection, not the separate status guard), creation/assignment/unassignment/lifecycle/completion/cancellation activity wording, the new dependency-activity timeline rows, the generic-edit fallback, and a direct reproduction of the live bug (a plain assignee's pure Start Work call). **Written but not executed in this environment** (no local PostgreSQL available) — substituted with live-transaction verification against real staging (§9), which is materially the same or stronger evidence since it exercises the actual deployed functions against real accounts.

**Frontend** (`tests/task-dependency-authority-and-activity-history-frontend.test.js`, new file): 16 scenarios — dependency control visibility for assignee vs. manage-tier, dependency state (READY/BLOCKED) remaining visible to a non-manage-tier viewer, Start Work regression, all new activity wording (`task_started`, `task_work_started`, `assigned`/`unassigned` naming, dependency add/remove with and without a resolvable related task), unknown-action fallback safety, HTML-escaping, and the no-leak guarantee for an unauthorized related task. **Executed for real** (installed `playwright` against the pre-installed Chromium): **16/16 PASSED**.

**Regression** (existing suites, re-run for real):
- `tests/task-relationships-frontend.test.js`: 70/70 PASSED
- `tests/task-assignee-permission-and-activation-frontend.test.js`: 8/8 PASSED
- `tests/task-standalone-creation-frontend.test.js`: 13/13 PASSED
- `tests/task-start-work-and-assignment-accountability-frontend.test.js`: 10/10 PASSED

## 9. Live Staging Verification

Performed against `vjobntuyzymhcuanyeak`, using the real `TSK-MCS-STG-2026-0002`/`0003` tasks and the real "Normal staff" (creator) / "Room manager" (assignee) accounts, inside transactions with no final `COMMIT` (auto-rolled-back). Two runs; both confirmed to leave staging state completely unchanged afterward (task statuses, dependency rows, and audit rows verified identical before/after).

A real active dependency already existed between the two tasks (Task B depends on Task A) from prior human UAT activity — this let the verification reproduce the *exact* reported scenario rather than a synthetic stand-in:

1. Room manager's `get_task_dependency_capabilities()` on Task B: `view=true, add=false, remove=false`.
2. Room manager attempts to remove the real, pre-existing dependency → **denied** ("Not authorized to manage both dependency endpoint tasks") — the exact bug, fixed.
3. Room manager attempts to add a new prerequisite → **denied**.
4. Creator adds a new prerequisite → succeeds; activity row confirmed: `action=task_dependency_added, notes=related_task_id=<uuid>`.
5. Creator removes it → succeeds; activity row confirmed: `action=task_dependency_removed`.
6. Room manager performs the pure Start Work call (Open → In Progress) on Task B → succeeds (via `v_is_pure_start_request`); exactly one `task_work_started` audit row written this transaction, zero `edited` rows — the exact bug, fixed.
7. Draft → Open on a disposable task (never committed) → exactly one `task_started` row.

## 10. Preserved UAT Data

`TSK-MCS-STG-2026-0001/0002/0003` and their real dependency/assignment/audit history were not modified — every mutating call used in verification ran inside a transaction that was never committed. Both verification runs were followed by an explicit re-query confirming task statuses, dependency rows, and audit history were byte-identical to before.

## 11. Remaining Limitations

- Task relationship activity (`create_task_relationship()`/`remove_task_relationship()`) has the identical `record_type` mismatch dependencies had — relationship add/remove still doesn't appear on either task's own Activity timeline. Not fixed here: relationships weren't part of either live UAT finding, and the product decision (Step 3) explicitly leaves relationship authorization untouched ("manage task relationships according to existing rules"). Fixing it would follow the same pattern as this correction's dependency fix.
- `watch_task()`/`unwatch_task()` write no audit row at all today, so watcher activity cannot appear on the timeline regardless of frontend wording. Not fixed here — no live UAT finding, and adding it would mean inventing a new write path, not just wiring existing data.
- Per-field diff wording for a plain details edit (e.g., "Changed priority from Normal to High") was deliberately not added — the correction's own instructions treat the generic "Updated task details" fallback as acceptable when specific wording isn't cheaply available, and adding field-by-field diffing was judged out of proportion for this milestone.
- The backend test file could not be executed in this environment (no local PostgreSQL); live-transaction verification against real staging was used as the primary evidence instead.

## 12. Files Changed

- `supabase/patch-task-dependency-authority-and-activity-history.sql` (new)
- `supabase/rollback-task-dependency-authority-and-activity-history.sql` (new)
- `supabase/test-task-dependency-authority-and-activity-history.sql` (new)
- `supabase/deploy/canonical-migration-order.txt` (appended section 14)
- `js/views/task-detail.js` (Activity timeline rendering)
- `js/data/tasks-api.js` (`fetchTasksByIds()`)
- `tests/task-dependency-authority-and-activity-history-frontend.test.js` (new)
- `docs/113-task-dependency-authority-activity-history-uat-fix.md` (this file)
