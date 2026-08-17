# 107 — UAT Fix: Task Assignee Permission Tightening + Draft Activation

**Type:** Focused UAT correction. Not a redesign, no new permission system, no
Production change, no unrelated-module change.
**Baseline:** branch `claude/phase-2-continuation-mc4hr1`, HEAD `3d0c454` ("fix(tasks):
add standalone task creation UI").
**Date:** 2026-08-17.

---

## 1. UAT findings

1. A standalone task was created by "Normal staff" and assigned to "Room manager".
2. Room manager can see the task correctly under My Tasks.
3. The task remains in Draft status after assignment.
4. Room manager has no lifecycle action available to begin work.
5. Room manager CAN unassign himself from the task.
6. Room manager CAN edit the original task details created by another user.

## 2. Root causes

Read directly from `supabase/patch-shared-task-foundation.sql`, `js/views/task-detail.js`,
and `docs/47-task-editing-and-lifecycle.md` (the authoritative design doc for this exact
area) — nothing inferred from the frontend alone.

**Finding 6 (edit) — a genuine, evidence-confirmed over-grant, now fixed.**
`update_task()`'s authorization check has always included:

```sql
OR EXISTS (SELECT 1 FROM task_assignments ta WHERE ta.task_id = t.id
           AND ta.user_id = auth.uid() AND ta.is_active)
```

alongside creator/supervisor-in-scope/admin — i.e. **any active assignee**, not just
the creator or a manager. This was a documented, deliberate decision at the time
(`docs/47` §Permissions, T3C): the frontend's `_canEdit()` was written specifically to
mirror this exact (broad) RPC behavior, reasoning that hiding Edit from an assignee the
backend would still accept the call from would be "under-mirroring," not a fix. Live
UAT now shows the real consequence: an assignee with no special role can redefine the
task's title/description/priority/owning section — fields the creator or an in-scope
manager set, not the assignee's own work product.

This is inconsistent with the rest of this same file's own established pattern:
`cancel_task()` and `assign_task()` (both structural/manage-tier actions) have **never**
had an assignee branch; only `complete_task()` (marking your own assigned work
done — genuinely contribute-tier) and `unassign_task()` (see Finding 5 below) do.
`update_task()` was the one outlier.

**Finding 5 (self-unassign) — intentional, not a defect. Left unchanged.**
`unassign_task()`'s authorization is:

```sql
OR p_user_id = v_actor
```

This only ever lets a caller remove **their own** assignment — never someone else's —
and already writes an `audit_logs` row. This is architecturally distinct from, and much
narrower than, "an assignee can remove any assignment." No file in this repository
shows a broader or different intended behavior, and no existing "decline/return
assignment with reason" workflow exists to reuse. Per this correction's own instruction
to prefer the narrowest fix and not invent new workflows, **this was not changed.**

**§1's named functions — most don't exist.** No `task_access_level()`,
`assign_task_user()`, `revoke_task_assignment()`, `set_task_dates()`, or `start_task()`
function exists anywhere in this schema (confirmed by searching every `supabase/*.sql`
file) — the real names are `can_manage_task()` (defined in
`patch-request-task-integration.sql`, used only by that module's own linking logic, not
by `update_task()`), `assign_task()`, `unassign_task()`, and `update_task()` itself.
`task_assignments` has **no `assignment_role` column** — every assignment row carries
exactly one, undifferentiated role. Reviewer/Approver personas and a "Request Review"
action (§2/§8 of the governing task) have **no backing capability in the current
architecture** and are correctly out of scope here — not invented.

**Findings 3/4 (Draft activation) — a real, pre-acknowledged gap, now closed for the
manage tier.** `create_task()` always starts a task at `status = 'draft'`.
`valid_task_status_transition()` has always permitted `('draft', 'open')`, and
`update_task()`'s own status guard only ever blocked setting `completed`/`cancelled`
directly — `'open'` was never blocked. `docs/47` itself already named this exact gap
under "Known limitations"/"Future enhancements": T3C's own scope was Complete/Cancel
only, and other transitions the same allow-list permits were "intentionally not exposed
... though nothing about the backend prevents adding them in a future, separately-scoped
milestone." No backend change was needed to close it — only a frontend action.

## 3. Resolved persona matrix

Evaluated against the real schema/RPCs — not invented. `—` means the current
architecture has no such action at all (not merely "not exposed to this persona").

| Persona | View | Edit fields | Change dates | Assign users | Remove assignment | Remove self | Start (Draft→Open) | Complete | Cancel | Comment | Watch |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Creator | ✅ | ✅ | ✅ | ✅ | ✅ | n/a | ✅ | ✅ | ✅ | ✅ | ✅ |
| Owning-section supervisor | ✅ | ✅ | ✅ | ✅ | ✅ | n/a | ✅ | ✅ | ✅ | ✅ | ✅ |
| Org admin / super admin | ✅ | ✅ | ✅ | ✅ | ✅ | n/a | ✅ | ✅ | ✅ | ✅ | ✅ |
| Assignee (e.g. Room manager) | ✅ | ❌ *(was ✅ — fixed)* | ❌ *(was ✅ — fixed)* | ❌ | ❌ | ✅ *(unchanged, intentional)* | ❌ | ✅ *(if status allows)* | ❌ | ✅ | ✅ |
| Watcher | ✅ | ❌ | ❌ | ❌ | ❌ | n/a | ❌ | ❌ | ❌ | ✅ | ✅ (toggle) |
| Reviewer / Approver | — | — | — | — | — | — | — | — | — | — | — |
| Unrelated (cross-org) user | ❌ (RLS) | ❌ | ❌ | ❌ | ❌ | n/a | ❌ | ❌ | ❌ | ❌ | ❌ |

"Change dates" and "edit fields" both route through `update_task()`, so they always
carry the same answer per persona — no separate `set_task_dates()` exists.

## 4. Assignee self-unassign decision

**Not changed — see Finding 5 above.** This is a deliberate, narrow, already-audited
capability (self only, never someone else's assignment), not the "an assignee can
remove an assignment given by another authorized user" pattern the governing task
flagged as the default-undesirable case. No "Decline / Return Assignment" workflow was
invented; the existing narrow self-service unassign already covers the same real need
without any new schema/RPC/audit-event surface.

## 5. Draft activation behavior

A **Start Task** action was added to the Task Detail lifecycle panel, visible only when
`status === 'draft'` and only to the manage tier (creator / supervisor-in-scope / admin
— matching update_task()'s own, now-narrowed authorization). It calls
`TasksAPI.updateTask(taskId, { status: 'open' })` — the exact same existing RPC and
data-layer wrapper every other edit already uses, no new RPC. Confirmed via
`valid_task_status_transition()` that draft→open was already, and remains, a permitted
transition.

**Deliberately not addressed here:** the remainder of the lifecycle chain
(`open` → `in_progress`, which `complete_task()` requires before Complete becomes
available) has no UI action either — this is the same pre-existing, separately-scoped
gap `docs/47` already named ("T3C's own scope is Complete/Cancel only... other
transitions ... intentionally not exposed"). Closing it was outside this correction's
narrow scope (Draft→Open specifically, per the governing task's own §5 heading and §6E
wording) and is not implied to be fixed by this patch.

## 6. Backend changes

`supabase/patch-task-assignee-permission-and-activation-fix.sql` (new) — restates
`update_task()` with the assignee branch removed, matching `cancel_task()`'s exact
authorization shape. No table, column, RLS policy, or other function was changed.

**Deliberately unchanged, and why:** the task-attachment RLS policy
(`attachments_insert`/`attachments_delete`'s `'task'` branch, most recently restated in
`patch-attachments-authorization-restoration.sql`) mirrors the SAME broad
"creator OR active assignee OR supervisor" shape `update_task()` used to have, by its
own separate, explicit design (`docs/48` §Permissions — "losing edit access ... revokes
delete on your own past uploads too"). Attachments were not part of the UAT finding;
narrowing that policy would remove an assignee's ability to attach files to their own
assigned work — a legitimate contribute-tier action nobody flagged as wrong. Left
unchanged; the frontend correction (§7) introduces a separate predicate for it instead
of narrowing it alongside Edit.

`supabase/rollback-task-assignee-permission-and-activation-fix.sql` (new) — restores
`update_task()`'s exact pre-correction definition.

`supabase/test-task-assignee-permission-and-activation-fix.sql` (new) — behavioral test,
see §9.

`supabase/deploy/canonical-migration-order.txt` — appended the new patch after
`patch-attachments-authorization-restoration.sql` (must run after
`patch-shared-task-foundation.sql`, whose `update_task()` it restates).

## 7. Frontend changes

`js/views/task-detail.js`:

- `_canEdit()` narrowed to `return this._canManage();` (drops the active-assignee
  branch), matching the backend correction exactly.
- **New**, separately-named `_canManageOwnAttachments()` = `_canManage() ||
  _isActiveAssignee()` — the OLD, still-correct predicate — used by
  `_canUploadAttachment()`/`_canDeleteAttachment()` instead of the now-narrower
  `_canEdit()`, so attachment capability is unaffected by this correction (§6).
- `_actionsHtml()` — adds a `canStart` check (`status === 'draft' && canManage`) and a
  **Start Task** button.
- `_confirmLifecycleAction()` — refactored (Start/Complete/Cancel now share one
  action-copy table instead of two hardcoded branches) to add the Start Task confirm
  flow, calling `TasksAPI.updateTask(taskId, { status: 'open' })`. No notes/reason field
  is shown for Start (unlike Complete/Cancel) since `update_task()` takes no such
  parameter — showing one would silently discard whatever the user typed.

No other file was touched.

## 8. Expected frontend result (post-fix) for the reported scenario

Normal staff creates a task → assigns Room manager. Room manager:

- Sees the task under My Tasks — unchanged.
- Opens it, comments, watches — unchanged (view/comment/watch never depended on the
  over-broad `update_task()` grant).
- Sees **Unassign Me** — unchanged, intentional (§4).
- Does **not** see **Edit** — fixed.
- Does **not** see **Add Assignee** — already correct before this fix (`assign_task()`
  never had an assignee branch).
- Does **not** see **Cancel** — already correct before this fix.
- Does **not** see **Start Task** — new action, manage-tier only.
- Sees **Complete** once the task reaches `in_progress`/`waiting` and its own
  dependency-lifecycle check passes — unchanged (`complete_task()`'s assignee branch was
  always correct and is untouched).
- **Request Review** — no such action exists in the current architecture (§2); not
  offered to anyone.

## 9. Tests

Backend (`supabase/test-task-assignee-permission-and-activation-fix.sql`): built and run
against a full local disposable Postgres baseline via
`supabase/deploy/apply-canonical-schema.sh --local-test-harness` (all 82 canonical
migration files applied with zero errors), then this patch applied on top. Reproduces
the exact reported scenario (creator creates a Draft task, assigns a plain assignee) via
the real RPCs, then exercises 14 scenarios using the repo's own established
`set_config('request.jwt.claims', ...)` user-impersonation convention (same technique
`supabase/test-task-relationships.sql` already uses):

```
 scenario |                           name                            | passed
----------+-----------------------------------------------------------+--------
        0 | fixture: task starts Draft                                | t
        1 | creator can edit own task                                 | t
        2 | plain assignee cannot edit task details                   | t
        3 | assignee cannot unassign a different user                 | t
        4 | supervisor can unassign another user                      | t
        5 | watcher cannot edit                                       | t
        6 | assignee can comment                                      | t
        7 | creator can activate Draft -> Open                        | t
        8 | assignee still cannot edit after activation               | t
        9 | cross-org user cannot manage                              | t
       10 | activity history recorded assignment/edit/comment actions | t
       11 | super admin can still edit any task                       | t
      601 | assignee can still self-unassign (intentional, unchanged) | t
      901 | cross-org user cannot even view the task (RLS)            | t

 passed_count | failed_count
---------------+--------------
           14 |            0
```

The rollback file was also verified: applying it flips scenario 2 back to failing (the
old over-broad behavior returns), confirming patch and rollback are exact inverses.

Frontend (`tests/task-assignee-permission-and-activation-frontend.test.js`, new) — 8
checks, headless Chromium via the `playwright` package against this environment's
pre-installed `/opt/pw-browsers/chromium` (same `PLAYWRIGHT_CORE_PATH`/`EDGE_PATH` gap
`docs/98` already documented — degrades gracefully rather than false-passing if
unavailable):

```
PASS: creator (manage-tier) sees Edit on the Details panel
PASS: plain assignee (not creator, not supervisor) does NOT see Edit — this is the UAT fix
PASS: supervisor-in-scope still sees Edit (unchanged manage-tier authority)
PASS: plain assignee still can upload/delete their own attachments (unchanged, separate predicate)
PASS: Draft task: creator sees Start Task; plain assignee does not
PASS: Open task: Start Task no longer offered (already activated)
PASS: Start Task confirm modal has no note field and calls updateTask(status: open), then reloads
PASS: Start Task failure shows a recoverable inline error and re-enables the button
TASK ASSIGNEE PERMISSION + ACTIVATION: 8 PASSED, 0 FAILED
```

Existing suites re-run, unmodified, with no regression:

```
$ node tests/task-relationships-frontend.test.js   (PLAYWRIGHT_CORE_PATH/EDGE_PATH set)
TASK FRONTEND: 59 PASSED, 0 FAILED

$ node tests/frontend-bootstrap-integrity-frontend.test.js
FRONTEND BOOTSTRAP: 7 PASSED, 0 FAILED

$ node tests/task-standalone-creation-frontend.test.js
TASK STANDALONE CREATION: 13 PASSED, 0 FAILED

$ bash tests/test-frontend-config.sh
── Summary: 11 passed, 0 failed ──
```

## 10. Staging deployment

The repository changes (SQL patch/rollback/test files, canonical migration order,
frontend fix, new frontend tests, this document) are committed and pushed — see the
accompanying final report for the exact SHA.

**The SQL patch itself could not be applied to the live CorLink Staging database
(`vjobntuyzymhcuanyeak`) in this session** — the Supabase MCP connector was disconnected
for this entire session (confirmed repeatedly via `ToolSearch`, consistent with the
same gap `docs/101`–`docs/106` document at various points). It is fully verified against
a complete, from-scratch local replica of the real canonical migration chain (§9), and
is a two-line, single-function, `CREATE OR REPLACE`, idempotent, forward-only change —
but it has not yet touched the real staging database. This is the one remaining action
an operator (or a future session with working Supabase MCP access) needs to take:
apply `supabase/patch-task-assignee-permission-and-activation-fix.sql` to
`vjobntuyzymhcuanyeak` via `apply_migration` or the deploy script.

## 11. Production untouched confirmation

No Supabase tool was invoked against `infjjroktzzhaxjvfknr` (Production) — none was
reachable at all this session. `config/environments/production.env` and `main` are
unchanged (confirmed via `git diff`, empty). Only Task-module files were touched; no
other module's SQL, RLS, or frontend code was modified.
