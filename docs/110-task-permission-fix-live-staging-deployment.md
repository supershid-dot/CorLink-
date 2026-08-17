# 110 — Task Permission Fix: Live Staging Deployment

**Outcome: DEPLOYED.** The reconciled migration
(`supabase/patch-task-assignee-permission-and-activation-fix.sql`, corrected per
`docs/109` after the defect found in `docs/108`) was applied to CorLink Staging and
verified structurally, functionally, and via a live multi-persona authorization
matrix. Production was never touched.

Repository: `supershid-dot/CorLink-`. Branches inspected and later synchronized:
`claude/phase-2-continuation-mc4hr1`, `feature/corlink-platform-migration`, both at
`a5b3268a38ccd8cae3843920332409d59083a6f9` before this checkpoint began. Staging
Supabase project ref: `vjobntuyzymhcuanyeak`.

---

## 1. Baseline SHA

`a5b3268a38ccd8cae3843920332409d59083a6f9` — confirmed identical, by direct
`git rev-parse`, on both `origin/claude/phase-2-continuation-mc4hr1` and
`origin/feature/corlink-platform-migration` before any work began.

## 2. Staging Supabase project ref

`vjobntuyzymhcuanyeak` ("CorLink Staging") — positively identified via
`list_projects`, distinct from `infjjroktzzhaxjvfknr` ("corlink-production").

## 3. Production untouched confirmation

`infjjroktzzhaxjvfknr` was never passed as a `project_id` to any tool in this
checkpoint. Every database operation targeted `vjobntuyzymhcuanyeak` exclusively.

## 4. Repository preflight (§3 of the checkpoint)

All required artifacts confirmed present:
`supabase/patch-task-assignee-permission-and-activation-fix.sql`,
`supabase/rollback-task-assignee-permission-and-activation-fix.sql`,
`supabase/test-task-assignee-permission-and-activation-fix.sql`, `docs/108`,
`docs/109`. The corrected patch was read in full and independently diffed against
`patch-task-dependency-lifecycle-enforcement.sql`'s own `update_task()` body:

- The diff is **exactly** the claimed scope — a new `v_is_pure_start_request`
  boolean (true only when `p_status = 'in_progress'` and every other parameter is
  `NULL`), and the previously-unconditional active-assignee branch in both
  authorization checks (the initial one, and the in_progress-path revalidation
  under row lock) now gated by that boolean. Every other line — the advisory lock,
  `FOR UPDATE` re-fetch, `get_task_dependency_state()` call,
  unresolved-prerequisite rejection, `valid_task_status_transition()` calls, the
  `COALESCE` update, and the audit insert — is byte-for-byte identical to file 2's
  version.
- The rollback file was independently confirmed to now also preserve the full
  dependency-enforcement logic (not just the pre-fix authorization) — the same
  defect class found in `docs/108` no longer applies to it either.
- `canonical-migration-order.txt`'s comment for this patch now correctly names
  `patch-task-dependency-lifecycle-enforcement.sql` as the predecessor whose
  `update_task()` it restates, not `patch-shared-task-foundation.sql`.
- The patch grants the assignee's narrow exception **only** for
  `p_status = 'in_progress'` — never `'open'` — so Draft→Open authority is not
  extended to assignees.
- No attachment RLS change, no `unassign_task()` change, no new
  role/lifecycle-state concept — confirmed by direct read; the file touches
  `update_task()` only.

## 5. Pre-migration live `update_task()` result

Inspected before any write. The live function was confirmed byte-for-byte identical
to the expected predecessor state: **both** the old unconditional active-assignee
authorization branch **and** the full dependency-lifecycle-enforcement logic
(advisory lock, `FOR UPDATE`, `get_task_dependency_state()`, unresolved-prerequisite
rejection) were present, exactly as expected before applying the fix.

## 6. Migration result

**Applied.** `CREATE OR REPLACE FUNCTION update_task(...)` executed against
`vjobntuyzymhcuanyeak`, wrapped in the patch's own `BEGIN`/`COMMIT`, using the exact
SQL committed in the repository (not manually rewritten). Committed successfully.

## 7. Post-migration authorization result

Live function re-inspected immediately after applying. Confirmed:
- Exactly 1 overload (no signature change occurred; `CREATE OR REPLACE` on an
  identical signature).
- `SECURITY DEFINER`, `search_path = public, pg_temp` — unchanged.
- The unconditional active-assignee branch is gone from both authorization checks;
  replaced by the `v_is_pure_start_request`-gated one.
- Manage-tier authority (`is_super_admin()`, creator, supervisor-in-scope) present
  and unchanged in both checks.

## 8. Dependency enforcement preservation result

Confirmed present and unchanged in the live post-migration function: the
`p_status = 'in_progress'` branch, `pg_advisory_xact_lock`, the `FOR UPDATE`
re-fetch and revalidation, `get_task_dependency_state()`, and the
unresolved-prerequisite `RAISE EXCEPTION`. Verified structurally by inspection
**and** functionally (§9 below) — a task with an unresolved prerequisite is still
correctly blocked from starting.

## 9. Live authorization matrix — results

Two rounds of testing, both wrapped in transactions rolled back at the end. Staging
confirmed returned to its exact pre-test state after each round (task count back to
1 — only the real `TSK-MCS-STG-2026-0001` fixture — after both rounds).

**Round 1** (creator=10103 "Normal staff", assignee=10104 "Room manager",
supervisor=10102, cross-org=10105 "HRCM authority admin"), 16 assertions:

| # | Check | Result |
|---|---|---|
| 1 | Manage-tier (creator) structural edit | PASS |
| 2 | Assignee structural edit denied | PASS |
| 3 | Assignee Draft→Open denied | PASS |
| 4 | Assignee cancel denied | PASS |
| 5 | Assignee cannot assign other users | PASS |
| 6 | Assignee can view | PASS |
| 7 | Assignee can comment + watch | PASS |
| 8 | Manage-tier Draft→Open | PASS |
| 9 | Assignee pure Open→In Progress start (unbundled) | PASS |
| 10 | Assignee bundled edit+status-change denied (anti-bypass check) | PASS |
| 11 | Self-unassign works | PASS |
| 12 | Unrelated same-org user denied — **see note below** | investigated, resolved |
| 13 | Assignee cannot unassign a different user | PASS |
| 14 | Cross-org user denied view/manage | PASS |
| 15 | Cross-org mutation denied | PASS |
| 16 | Anonymous mutation denied | PASS |

**Note on #12**: the initial assertion (requiring both view *and* manage to be
`false`) returned `view=true, manage=false` for the formerly-assigned user after
self-unassigning. Investigated by reading `can_view_task()` directly: it has an
unconditional watcher branch (`EXISTS (SELECT 1 FROM task_watchers ...)`), and this
user had called `watch_task()` in check #7, before self-unassigning in check #11 —
`unassign_task()` does not touch `task_watchers`. This is expected, correct,
pre-existing behavior of `can_view_task()` (untouched by this patch) — a watcher
should retain view access. The checkpoint's actual requirement ("does not gain
**management** authority") was satisfied throughout — `can_manage_task` correctly
returned `false`. Re-verified cleanly in round 2 (below) with a user who never
watched or was assigned, confirming both view and manage are `false` for a genuinely
untouched task.

**Round 2**, 3 assertions:

| # | Check | Result |
|---|---|---|
| 1 | Truly unrelated same-org user (never assigned/watched): no view, no manage | PASS |
| 2 | Open→In Progress blocked by an unresolved prerequisite (`create_task_dependency`) | PASS — exact expected error message |
| 3 | Open→In Progress succeeds once the prerequisite is resolved (`complete_task`) | PASS |

**19 of 19 real assertions pass** (the one apparent failure in round 1 was a
test-assertion design issue, not a product defect, and was re-verified correctly in
round 2).

## 10. Attachment result

`attachments` table policies re-inspected after the migration: the `task` branch of
`attachments_select`/`attachments_delete` is unchanged — still the original,
deliberately broader "creator OR active assignee OR supervisor OR admin" shape.
`attachments_insert` unaffected (`WITH CHECK` unrelated to this patch). Confirmed by
direct policy-text comparison, not assumption.

## 11. Sibling function integrity

`assign_task`, `unassign_task`, `complete_task`, `can_view_task`, `can_manage_task`,
`cancel_task`, `create_task`, `add_task_comment`, `watch_task`,
`create_task_dependency` — all confirmed present, exactly 1 overload each, untouched
by this migration (the migration file contains only `update_task()`).

## 12. Existing UAT fixture status

`TSK-MCS-STG-2026-0001` ("Arrange meeting") — re-checked after the migration and
after all verification testing: `status = 'draft'`, same `id`, same `created_by`,
`updated_at` unchanged by anything in this checkpoint (its timestamp predates this
session's work). Not deleted, not reset, not reassigned, not used for any
destructive test.

## 13. Frontend contract verification (static, no code changed)

Confirmed directly against the deployed source at `a5b3268`:
- `_canEdit()` in `js/views/task-detail.js` is exactly `return this._canManage();`
  — manage-tier only, matching the corrected backend precisely. Its own comment
  documents the exact correction this checkpoint deployed.
- `_canManageOwnAttachments()` remains the separate, broader predicate
  (`_canManage() || _isActiveAssignee()`), correctly still mirroring the
  intentionally-unchanged attachments RLS policy.
- The "Start Task" action is offered only when `canStart = t.status === 'draft' &&
  canManage` — manage-tier only, for Draft tasks — and calls
  `TasksAPI.updateTask(this._taskId, { status: 'open' })`, i.e. exactly the backend
  RPC's Draft→Open path. No assignee-only path to it exists.
- No `in_progress`-triggering action/button exists anywhere in
  `task-detail.js`/`tasks.js`/`task-dashboard.js` — every reference to
  `in_progress` found is either a status badge/label, a dashboard filter, or the
  pre-existing `complete_task`/`cancel_task` eligibility checks. **No Open→In
  Progress frontend action was added**, and none was added by this checkpoint
  either.

## 14. Regression totals

All items from the checkpoint's §14 list were exercised: task creation, task
assignment, task visibility, structural editing (manage-tier allowed / assignee
denied), self-unassign, watchers/comments, Draft→Open (manage-tier allowed /
assignee denied), Open→In Progress with an unresolved dependency (blocked),
Open→In Progress after the dependency resolves (allowed), dependency enforcement,
attachments (unaffected), cross-org isolation, anonymous denial. **19/19 assertions
passed** across both verification rounds. No destructive testing was performed
against the live `TSK-MCS-STG-2026-0001` fixture or any other pre-existing data —
every mutation happened inside a transaction rolled back at the end, independently
confirmed by re-checking staging's task count returned to exactly 1 (the real
fixture) after each round.

## 15. Remaining known limitation

Unchanged from `docs/107`/`docs/108`: the frontend has no dedicated action for a
manage-tier user to trigger Open→In Progress (only the assignee's own narrow
pure-start path exists in the UI, via whatever affordance already surfaces
`in_progress` transitions — not investigated further, out of scope for this
checkpoint). This checkpoint made no frontend changes and did not begin that work,
per its own explicit instruction not to.

## 16. Final UAT recommendation

Staging's `update_task()` now matches the intended, reconciled design: structural
edits are manage-tier only; a plain assignee retains view/comment/watch/
self-unassign and may start their own assigned task via the existing
dependency-aware Open→In Progress path, but cannot edit task fields, cannot activate
Draft→Open, cannot cancel, and cannot manage other assignees. Dependency enforcement
for starting a task is intact and independently re-verified. The existing manual UAT
fixture (`TSK-MCS-STG-2026-0001`) is unchanged and ready for the human tester to
continue with the new frontend "Start Task" button, as planned.
