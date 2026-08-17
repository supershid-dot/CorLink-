# 108 — Task Assignee Permission + Activation Fix: Staging Deployment Checkpoint

**Outcome: NOT APPLIED. A defect was found in the migration file during required
pre-flight inspection, before any write was made to staging. Per this checkpoint's
own instructions ("STOP if the repository does not match the approved milestone";
"If a new defect is found: DOCUMENT IT AND STOP before expanding scope"; "Do NOT
apply speculative fixes"), the migration was withheld and this document reports the
finding instead of a completed deployment.**

Repository: `supershid-dot/CorLink-`. Branch inspected:
`claude/phase-2-continuation-mc4hr1` at `70fffd5e90fd34b710eaeab37debc3745d65b1fa`
(confirmed identical on `feature/corlink-platform-migration`). Staging Supabase
project ref: `vjobntuyzymhcuanyeak`. Production ref `infjjroktzzhaxjvfknr` was never
used — confirmed via `list_projects`, only `vjobntuyzymhcuanyeak` was ever passed as
`project_id` in this checkpoint.

---

## 1. Baseline SHA

`70fffd5e90fd34b710eaeab37debc3745d65b1fa` — confirmed identical, by direct
`git rev-parse`, on both `origin/claude/phase-2-continuation-mc4hr1` and
`origin/feature/corlink-platform-migration`.

## 2. Pre-flight repository verification (§3)

All four required artifacts exist and were read directly (not assumed from this
checkpoint's own prompt):

- `supabase/patch-task-assignee-permission-and-activation-fix.sql`
- `supabase/rollback-task-assignee-permission-and-activation-fix.sql`
- `supabase/test-task-assignee-permission-and-activation-fix.sql`
- `docs/107-uat-task-assignee-permission-lifecycle-fix.md`

`supabase/deploy/canonical-migration-order.txt` correctly lists the forward patch as
its final entry (§11), with a stated rationale.

Confirmed true, by direct inspection of the forward patch:
- `update_task()` is restated via `CREATE OR REPLACE`.
- The active-assignee authorization branch
  (`OR EXISTS (SELECT 1 FROM task_assignments ta WHERE ...)`) is removed from the
  check; the remaining shape is `is_super_admin() OR created_by = actor OR
  supervisor-in-scope` — exactly `cancel_task()`'s shape, as the patch's header
  claims.
- No other function is touched by the file — `assign_task()`, `unassign_task()`,
  `complete_task()`, `can_view_task()`, `can_manage_task()` are absent from it
  entirely.
- No new role/permission concept is introduced.
- `unassign_task()`'s self-unassign branch is not touched (the file doesn't
  reference `unassign_task()` at all).
- The task-attachment RLS policy is not referenced anywhere in the file; the header
  explicitly and correctly documents why it's deliberately out of scope.
- No `open → in_progress` transition logic is *added*.

**Found instead — the patch's replacement body is missing logic that already
exists live**, which is the actual, more serious defect: see §3 below.

## 3. The defect

`update_task()` has been redefined by three files in this repository's history, in
this canonical order:

1. `patch-shared-task-foundation.sql` — the original, simple version.
2. `patch-task-dependency-lifecycle-enforcement.sql` (canonical order line 114) —
   adds an entire `p_status = 'in_progress'` branch: validates the transition via
   `valid_task_status_transition()`, takes an organization-scoped
   `pg_advisory_xact_lock`, re-reads and re-validates authorization under `FOR
   UPDATE`, then calls `get_task_dependency_state(p_task_id)` and raises if
   `is_blocked` — i.e., **a task cannot move to `in_progress` while an unresolved
   prerequisite blocks it.** This file's own comment states: *"update_task() is the
   repository's only start path: open/waiting -> in_progress."*
3. `patch-task-assignee-permission-and-activation-fix.sql` (canonical order line
   149, this checkpoint's subject) — its `CREATE OR REPLACE FUNCTION update_task(...)`
   body has **no `p_status = 'in_progress'` branch, no dependency-state variable, no
   advisory lock, and no call to `get_task_dependency_state()` anywhere.**

Because `CREATE OR REPLACE FUNCTION` fully replaces a function's body (there is no
partial/incremental replacement in PostgreSQL), applying file 3 as currently written
would **silently delete** the dependency-blocking enforcement file 2 added — even
though file 2 runs earlier in the same canonical chain and is already applied and
already validated on staging (`validate-task-dependency-lifecycle-enforcement.sql`
passed cleanly in the prior staging verification checkpoint, `docs/101` §5).

**Root cause, found in the patch's own text**: its canonical-migration-order.txt
comment states the file *"Must run after `patch-shared-task-foundation.sql`, whose
`update_task()` it restates."* That is the wrong baseline — the function it should
be restating on top of is `patch-task-dependency-lifecycle-enforcement.sql`'s
version (the one actually live), not the original foundation version. This confirms
the patch was authored against a stale snapshot of `update_task()`, not an
intentional decision to drop dependency enforcement.

**Same defect confirmed in the paired artifacts**, not just the forward patch:
- `supabase/rollback-task-assignee-permission-and-activation-fix.sql`'s replacement
  body has the identical omission (no `in_progress` branch, no dependency check) —
  it would not actually restore the true prior state either.
- `supabase/test-task-assignee-permission-and-activation-fix.sql` contains no
  reference to `in_progress` or dependency behavior at all — consistent with the
  whole milestone having been authored without awareness of the intervening patch.
- `docs/107-uat-task-assignee-permission-lifecycle-fix.md` mentions `in_progress`
  and "dependency-lifecycle check" only in the context of describing
  `complete_task()` (unchanged, correctly) — it does not discuss or acknowledge that
  the new patch's own `update_task()` restatement would drop this logic.

This is a real functional regression risk, not a cosmetic issue: a live,
already-validated safety mechanism (you cannot start a task whose prerequisites
aren't resolved) would silently disappear from a live RPC on staging, discoverable
only by someone testing task-dependency behavior after this checkpoint — exactly
the kind of gap this checkpoint's own pre-flight-verification requirement exists to
catch before it reaches even staging.

## 4. Pre-migration live state (§5) — evidence the underlying fix idea is still needed

Confirmed directly against staging before any decision was made:

- `tasks`, `update_task()`, `assign_task()`, `unassign_task()`, `complete_task()`,
  `can_view_task()`, `can_manage_task()` all exist, each with exactly one overload.
- The live `update_task()` **does** still contain the over-broad active-assignee
  authorization branch this milestone is meant to remove (confirmed twice in the
  live body — once in the initial check, once in the in_progress-path revalidation
  under row lock). The underlying finding this milestone addresses is real and still
  live.
- `TSK-MCS-STG-2026-0001` ("Arrange meeting") exists, status `draft`, created by the
  same real "Normal staff" account used throughout this engagement's UAT. It was not
  inspected further, not modified, and not deleted.

## 5. Migration application result

**Not applied.** No `execute_sql`/`apply_migration` call was made against
`update_task()` or any other object. Staging's `update_task()` remains exactly as
found in §4 — the pre-fix, over-broad-assignee-authorization version, with the
dependency-enforcement logic intact.

## 6. Post-migration verification, authorization matrix, regression checks

**Not performed.** These are meaningless without a migration having been applied,
and running them would not have changed the outcome of §3's finding. No test data
was created or modified as part of this checkpoint.

## 7. Deviation from the checkpoint's instructions, and why

This checkpoint's own text is explicit: *"Do NOT apply speculative fixes"* and
*"If a new defect is found: DOCUMENT IT AND STOP before expanding scope."* Rewriting
the patch myself to correctly incorporate the dependency-enforcement logic would be
exactly the kind of speculative, scope-expanding fix those lines prohibit — it would
require re-deriving the exact intended interaction between two independently-authored
milestones without the original author's review, on a database this checkpoint was
explicitly scoped not to redesign anything on. The correct action, and the one taken,
is to stop before the write and hand this back for the patch (and its paired
rollback/test files) to be corrected against the actual current baseline.

## 8. Recommended fix (for the milestone owner, not applied here)

Rebase `patch-task-assignee-permission-and-activation-fix.sql`'s `update_task()`
body onto `patch-task-dependency-lifecycle-enforcement.sql`'s version: keep that
version's `p_status = 'in_progress'` branch (advisory lock, revalidation,
`get_task_dependency_state()` check) entirely intact, and apply *only* this
milestone's actual change — removing the active-assignee branch from both
authorization checks in that function (the initial one and the in_progress-path
revalidation, since both currently contain it). Apply the identical correction to
the rollback file's body, and update the canonical-migration-order.txt comment to
name the correct predecessor. Update the test file to also cover the
`in_progress`/dependency-blocking path if it's meant to be regression-covered
by this milestone.

## 9. Existing UAT fixture status

`TSK-MCS-STG-2026-0001` ("Arrange meeting") — unchanged, still `draft`, not deleted,
not reset, not otherwise touched by this checkpoint.

## 10. Remaining known limitation

Unrelated to this checkpoint's finding: `open → in_progress` already has full
backend support including dependency-blocking (confirmed live in §3-4), consistent
with what `docs/107` describes as a known frontend gap. This checkpoint made no
frontend changes and did not investigate whether a "Start" action for that
transition exists in the deployed UI — out of scope per this checkpoint's own §11.

## 11. Final decision

**STOP. Migration withheld.** The repository does not match a safely-applicable
approved milestone: `patch-task-assignee-permission-and-activation-fix.sql` (and its
paired rollback/test files) were authored against a stale baseline of `update_task()`
and would silently remove already-shipped, already-validated task-dependency
enforcement if applied as currently written. This is not a rejection of the
milestone's actual intent (narrowing assignee authorization, adding Draft→Open) —
both are sound and still needed, per §4's live-state evidence — only of applying
these specific SQL files verbatim in their current state.
