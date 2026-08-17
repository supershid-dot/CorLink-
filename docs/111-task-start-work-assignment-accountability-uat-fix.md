# 111 — Task "Start Work" Action + Assignment Accountability (UAT Fix)

**Outcome: DEPLOYED.** Live staging UAT against the reconciled permission fix
(docs/108-110) surfaced two follow-up findings. Both are corrected here: a
frontend-only "Start Work" action that reuses `update_task()`'s
already-shipped, dependency-aware Open → In Progress path, and a backend
authorization change removing self-unassign from `unassign_task()`. Verified
first on a disposable local Postgres instance, then applied to and verified
on CorLink Staging (`vjobntuyzymhcuanyeak`). Production was never touched.

Repository: `supershid-dot/CorLink-`. Development branch:
`claude/phase-2-continuation-mc4hr1`. Staging branch:
`feature/corlink-platform-migration`. Baseline SHA (confirmed identical on
both branches before any work began): `c40c187586f6dd5008935139b0aac17fad42eba6`.

---

## 1. Live UAT findings

**Finding 1 — "No actions available."** An assignee (Room Manager persona)
opening their own Open task saw no lifecycle action at all, even though
`update_task()` has, since `patch-task-dependency-lifecycle-enforcement.sql`
(preserved through `patch-task-assignee-permission-and-activation-fix.sql`,
docs/109), already supported a dependency-aware Open → In Progress
transition for an active assignee via the narrow `v_is_pure_start_request`
exception. This was purely a missing frontend affordance — no button in
`js/views/task-detail.js` ever called `update_task()` with a pure
`{ status: 'in_progress' }` request.

**Finding 2 — self-unassign.** An assignee could remove their own
assignment via `unassign_task()`'s `p_user_id = v_actor` branch and the
"Unassign Me" UI. This was a deliberate, audited design at the time
(docs/107 Finding 2) but is superseded by a new product decision: assignment
is now an accountable management action, and only creator/supervisor-in-scope/
admin may remove any assignment, including the assignee's own.

## 2. Actual `update_task()` provenance (no backend change needed)

Independently re-read the current, already-reconciled `update_task()` body
(`patch-task-assignee-permission-and-activation-fix.sql`) and
`get_task_dependency_lifecycle_state()`
(`patch-task-dependency-lifecycle-enforcement.sql`). Confirmed:

- `update_task()`'s manage-tier branch (`is_super_admin()` OR creator OR
  supervisor-in-scope) is **unconditional** — a manage-tier caller can
  already call `update_task(..., p_status:='in_progress')` regardless of
  bundled fields.
- Its `v_is_pure_start_request` exception already re-admits an active
  assignee for exactly a genuine, unbundled start request.
- `get_task_dependency_lifecycle_state()`'s `can_start` column already
  evaluates `can_manage_task(p_task_id) AND status IN ('open','waiting') AND
  NOT is_blocked` — and `can_manage_task()`
  (`patch-request-task-integration.sql`) already includes an active-assignee
  branch alongside creator/supervisor-in-scope/admin. So `can_start` is
  already `true` for exactly the same actor set `update_task()` itself would
  accept for a pure start request.

**Conclusion: no `update_task()` restatement was needed.** The frontend
"Start Work" button reuses the existing RPC and the existing `can_start`
capability field verbatim — no new RPC, column, or index.

## 3. Functionality removed by this correction

`unassign_task()` (only ever defined once, in
`patch-shared-task-foundation.sql`, never restated since) had:

```sql
OR p_user_id = v_actor
```

as a third, independent authorization branch. This file's **only** SQL
change removes that branch. Everything else — the
`is_super_admin()`/creator/supervisor-in-scope branches, the idempotent
no-op on an already-inactive assignment, the `audit_logs` insert — is
preserved byte-for-byte.

## 4. Corrected design — Start Work (frontend only)

`js/views/task-detail.js`:

- `_actionsHtml()`: added `startWorkAuthorized = t.status === 'open' &&
  (canManage || isActiveAssignee)` and `canStartWork = startWorkAuthorized
  && this._dependencyLifecycleState?.can_start === true` — reusing the
  dependency-lifecycle state already fetched for the Complete button (no
  extra database call). Restricted to `status === 'open'` only (not
  `'waiting'`, which `can_start` also covers) — this milestone is scoped to
  Open → In Progress, per its own instructions. A blocked-but-authorized
  case renders a disabled Start Work button plus the same
  `data-task-dependency-blocked` explanation pattern Complete already uses,
  with wording matching the spec: *"This task cannot be started because N
  prerequisite(s) [is/are] unresolved."*
- `_LIFECYCLE_ACTION_COPY.start_work`: `{ title: 'Start work on this task?',
  message: 'This will move the task to In Progress.', confirmLabel: 'Start
  Work', hasNote: false }`.
- `_confirmLifecycleAction()`: `action === 'start_work'` calls
  `TasksAPI.updateTask(this._taskId, { status: 'in_progress' })` — every
  other field is omitted, so `TasksAPI.updateTask()`'s own `?? null`
  defaults send a pure request, matching `v_is_pure_start_request` exactly.

No new RPC, no direct table write, no client-side dependency-authority
duplication — the backend's `get_task_dependency_state()` remains the sole
authority; the frontend only *displays* what it already computed.

## 5. Corrected design — assignment accountability

`supabase/patch-task-start-work-and-assignment-accountability.sql`
redefines `unassign_task()` only, removing the `OR p_user_id = v_actor`
branch (§3 above). No reassignment-request/decline/return workflow was
introduced — no existing RPC supports one, and building a new table/workflow
engine to replace a single authorization branch would be out of proportion
for this correction (see §14, "future enhancement").

Frontend (`js/views/task-detail.js`):

- `_assigneesHtml()`: removed the "Unassign Me" button entirely (not
  replaced with a disabled one), and the per-row remove control (`✕`) is now
  gated on `canManage` alone — previously `canManage || a.user_id ===
  this._user.id`, which would otherwise have left a working self-removal
  path even after the bulk button was removed. Added a neutral hint,
  consistent with the existing Watchers panel's own hint style: *"Contact
  the task owner or supervisor if reassignment is required."*
- `_bindAssigneesPanel()`: removed the `data-unassign-self` binding.
- `js/views/tasks.js` (Task List row-actions menu): removed the equivalent
  "Unassign Me" row action and its `unassign-me` handler branch — this menu
  offered the exact same now-rejected capability and was fixed for
  consistency with the same backend change, not as scope creep.

## 6. Access matrix (unchanged elsewhere, confirmed)

| Actor | Start Work (Open → In Progress) | Remove any assignment |
|---|---|---|
| Creator / supervisor-in-scope / admin | Yes (already unconditional) | Yes (unchanged) |
| Active assignee | Yes, pure request only, dependency-checked | **No (this correction)** |
| Unrelated same-org user | No | No |
| Cross-org user | No | No |
| Anonymous | No | No |

Self-unassign is no longer a special case for anyone — "remove any
assignment" now means exactly the same authority for every target,
including the caller's own.

## 7. Canonical migration order

`supabase/deploy/canonical-migration-order.txt` — appended
`patch-task-start-work-and-assignment-accountability.sql` immediately after
`patch-task-assignee-permission-and-activation-fix.sql` (§11), as a new
§12. `unassign_task()`'s only-ever predecessor is
`patch-shared-task-foundation.sql`, already many entries earlier in the
chain — the new entry's position after §11 is chronological (the next UAT
round against that deployment), not a structural dependency. No unrelated
entries were reordered.

## 8. Tests — backend (15/15 scenarios, both discriminating proofs pass)

`supabase/test-task-start-work-and-assignment-accountability.sql`:

| # | Assertion | Result |
|---|---|---|
| 1 | Open task, active assignee, no prerequisite: Start Work succeeds | PASS |
| 2 | Open task, unresolved prerequisite: Start Work blocked | PASS |
| 3 | Start Work succeeds once the prerequisite is resolved | PASS |
| 4 | Draft task: assignee cannot bypass Draft → Open directly to In Progress | PASS |
| 5 | Assignee cannot bundle a structural edit with a start request | PASS |
| 6 | Unrelated same-org user cannot Start Work | PASS |
| 7 | Cross-org user cannot Start Work | PASS |
| 8 | Anonymous caller cannot Start Work | PASS |
| 9 | Active assignee cannot unassign self | PASS |
| 10 | Assignee cannot remove another assignee | PASS |
| 11 | Creator (manage-tier) can remove an assignee | PASS |
| 12 | Supervisor-in-scope (manage-tier) can remove an assignee | PASS |
| 13 | Assignment (`assign_task`) still works | PASS |
| 14 | Re-assignment (remove then re-add) still works | PASS |
| 15 | Audit evidence: correct assigned/unassigned counts, no self-unassign row | PASS |

**Stale-vs-corrected differential proof**: applied the rollback (restoring
`OR p_user_id = v_actor`) on the same fixtures and re-ran the suite —
13/15 passed, with scenarios 9 and 15 failing exactly as expected (self-
unassign succeeded where it should have been rejected, and the audit-count
assertion caught the resulting extra `unassigned` row attributed to the
assignee). Reapplied the forward patch afterward — back to 15/15.

## 9. Tests — frontend (10/10 scenarios)

`tests/task-start-work-and-assignment-accountability-frontend.test.js`
(same Playwright single-component harness as
`tests/task-assignee-permission-and-activation-frontend.test.js`):

1. Open task + eligible active assignee → Start Work visible — PASS
2. Draft task + assignee → Start Work not visible — PASS
3. In Progress task → Start Work not visible — PASS
4. Blocked-by-prerequisite → dependency-block message + disabled button — PASS
5. Successful Start Work calls `updateTask(status: 'in_progress')` and reloads — PASS
6. Assignee sees no "Unassign Me" / no remove control on their own row — PASS
7. Manage-tier user still sees full assignment management — PASS
8. No direct table writes added (`grep`-verified: zero `.update(`/`.insert(`/`.delete(` in the file; zero `data-unassign-self` remaining) — PASS
9. `_canEdit()` remains manage-tier only — PASS
10. `_canManageOwnAttachments()` (attachments predicate) unchanged — PASS

## 10. Canonical clean-build result

Full 84-file canonical chain (schema + every patch, including this
milestone's) applied to a fresh disposable Postgres 16 instance with zero
manual corrections between files: **zero errors.** Structurally confirmed
post-build: `update_task()` unchanged (still contains
`v_is_pure_start_request`, `pg_advisory_xact_lock`,
`get_task_dependency_state`), exactly one overload each of `update_task()`
and `unassign_task()`.

## 11. Rollback round-trip result

Built an independent 83-file "predecessor" database (the full chain minus
this milestone's patch) and captured its `unassign_task()` body via
`pg_get_functiondef()`. Separately: applied this milestone's forward patch,
then its rollback, to the main test database, and captured the
post-rollback `unassign_task()` body the same way. **`diff` of the two
captures was empty — byte-for-byte identical.** Reapplied the forward patch
afterward; the full 15-scenario suite passed again (15/15).

## 12. Regression totals — backend

| Suite | Result |
|---|---|
| `test-task-start-work-and-assignment-accountability.sql` (new) | 15/15 PASS |
| `test-task-assignee-permission-and-activation-fix.sql` | 22/22 PASS |
| `test-task-attachments.sql` | all scenarios PASS |
| `test-task-audit-visibility.sql` | 11/11 PASS |
| `test-task-dependencies.sql` | 31/31 PASS |
| `test-task-dependency-lifecycle-enforcement.sql` | 30/30 assertions PASS* |
| `test-task-relationships.sql` | 30/30 PASS |
| `test-task-dependency-candidate-management.sql` | 25/25 PASS |

\* This file has a pre-existing, unrelated cleanup-ordering bug (deletes
`users` before `platform_outbox_events` rows that reference them),
occurring only *after* all 30 assertions already pass. Not authored or
owned by this milestone — observed, not fixed, matching the same
transparency call made in docs/109 for the identical issue.

## 13. Regression totals — frontend

| Suite | Result |
|---|---|
| `task-start-work-and-assignment-accountability-frontend.test.js` (new) | 10/10 PASS |
| `task-assignee-permission-and-activation-frontend.test.js` | 8/8 PASS |
| `task-standalone-creation-frontend.test.js` | 13/13 PASS |
| `task-relationships-frontend.test.js` | 59/59 PASS |

## 14. Staging deployment

After the implementation commit (`951345c`) was pushed and
`feature/corlink-platform-migration` was fast-forwarded to match, the
incremental patch — **only**
`supabase/patch-task-start-work-and-assignment-accountability.sql`, not the
full canonical chain — was applied directly to CorLink Staging
(`vjobntuyzymhcuanyeak`, positively distinct from `infjjroktzzhaxjvfknr`
"corlink-production", confirmed via `list_projects`).

Pre-migration check: the live `unassign_task()` was inspected first and
confirmed byte-for-byte identical to the expected predecessor (still
carrying the `OR p_user_id = v_actor` branch this patch removes) — safe to
apply.

Migration applied via `apply_migration` using the exact SQL committed to the
repository (not manually retyped). Post-migration, the live function was
re-inspected: the self-unassign branch is gone, every other branch
(creator/supervisor-in-scope/admin, the idempotent no-op, the audit insert)
is unchanged, and exactly 1 overload each of `unassign_task`, `update_task`,
`assign_task`, and `complete_task` exists (no signature drift).

## 15. Live staging verification

A single transaction (`BEGIN` ... `ROLLBACK`), using the real staging
personas (Normal staff = creator, Room manager = assignee,
Supervisor = supervisor-in-scope), exercised the corrected function against
one disposable task created and destroyed entirely inside that transaction —
the real `TSK-MCS-STG-2026-0001` fixture was never touched:

| # | Check | Result |
|---|---|---|
| 1 | Active assignee (Room manager) cannot self-unassign | PASS |
| 2 | Creator (manage-tier) can remove that assignment | PASS |
| 3 | Supervisor-in-scope can also remove an assignment (distinct branch) | PASS |
| 4 | Assignee's pure Start Work request (unblocked) still succeeds, unaffected by this patch | PASS |
| 5 | Audit evidence: correct assigned/unassigned counts, no self-unassign row | PASS |

**5 of 5 live assertions pass.** After the `ROLLBACK`, staging's task count
was independently re-checked and confirmed still exactly 1 — only the real
`TSK-MCS-STG-2026-0001` fixture, no residue from the disposable verification
task.

## 16. Existing UAT task preserved

`TSK-MCS-STG-2026-0001` ("Arrange meeting", assigned to Room manager) was
**not** modified by this checkpoint. Its status was independently observed
to have organically progressed to `open` between sessions (the human tester
using the "Start Task" button docs/110 handed off, per that document's own
final recommendation) — this was pre-existing state observed, not caused by
anything in this checkpoint; every mutation this checkpoint performed against
live staging happened inside the single rolled-back transaction in §15.

## 17. Production untouched

`main` was not read, fetched into, or modified. Production Supabase
(`infjjroktzzhaxjvfknr`) was never referenced by any command in this
checkpoint.

## 18. Future enhancement (recorded, not built)

"Request Reassignment" / "Decline Assignment" / "Return Task" — a
formal, assignee-initiated reassignment-request workflow — has no
supporting RPC, table, or column anywhere in the current schema. Building
one was explicitly out of scope for this correction; the frontend's neutral
hint ("Contact the task owner or supervisor if reassignment is required.")
is a placeholder pointing at the manual path until such a workflow is
designed and scoped separately.

## 19. Remaining known Task UAT items

- The pre-existing cleanup-ordering bug in
  `test-task-dependency-lifecycle-enforcement.sql` (§12) remains unfixed —
  out of scope, not owned by this milestone.
- No frontend action exists yet for a manage-tier user to trigger Open → In
  Progress directly (only the flow this milestone adds, via Start Work, for
  assignees, plus whatever pre-existing affordance already covers
  manage-tier — not investigated further here, unchanged from docs/110 §15).
- A formal reassignment-request workflow (§18) remains a future,
  separately-scoped enhancement.
