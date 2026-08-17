# 109 — Task Permission Patch Reconciliation: Preserve Dependency Lifecycle Enforcement

**Type:** Narrow corrective development checkpoint. No live Supabase migration was
performed in this checkpoint. Production/main untouched.
**Baseline:** branch `claude/phase-2-continuation-mc4hr1`, HEAD `336baf5` ("docs(uat):
verify task permission fix on staging"), which already contains `docs/108`'s pre-flight
finding.
**Date:** 2026-08-17.

---

## 1. Defect reproduced

Read directly, not assumed from `docs/108`. Three files in this repository's history
each `CREATE OR REPLACE FUNCTION update_task(...)`, in this exact canonical order
(confirmed by `grep -n "CREATE OR REPLACE FUNCTION update_task" supabase/*.sql` — only
these three, no others):

1. `supabase/patch-shared-task-foundation.sql` — the original, simple version (creator /
   active assignee / supervisor-in-scope / admin; no in-progress logic at all).
2. `supabase/patch-task-dependency-lifecycle-enforcement.sql` — canonical order line 114,
   runs before the assignee-permission patch. Adds an entire `p_status = 'in_progress'`
   branch: validates the transition via `valid_task_status_transition()`, takes an
   organization-scoped `pg_advisory_xact_lock`, re-reads the row `FOR UPDATE`,
   revalidates authorization and the transition under that lock, calls
   `get_task_dependency_state(p_task_id)`, and rejects with
   `'Task cannot be started because one or more prerequisites are unresolved.'` if
   blocked. This file's own comment: *"update_task() is the repository's only start
   path: open/waiting -> in_progress."*
3. `supabase/patch-task-assignee-permission-and-activation-fix.sql` (commit `70fffd5`,
   docs/107) — canonical order line 149.

Confirmed directly (not merely trusted from `docs/108`): the commit-`70fffd5` version of
file 3's `CREATE OR REPLACE FUNCTION update_task(...)` body had **no `p_status =
'in_progress'` branch, no `v_dependency_state` variable, no advisory lock, and no call
to `get_task_dependency_state()` anywhere** — `grep -c "in_progress\|pg_advisory_xact_lock"`
against the stale file's text returned only 1 match, and that single match was in a
prose comment, not code. Applying it as originally written would have used
`CREATE OR REPLACE` to silently delete file 2's entire dependency-blocking mechanism —
already shipped, already validated (`docs/101` §5 references
`validate-task-dependency-lifecycle-enforcement.sql` passing cleanly on staging).

**Root cause, confirmed in the file's own text**: its `canonical-migration-order.txt`
comment stated it *"Must run after `patch-shared-task-foundation.sql`, whose
`update_task()` it restates"* — the wrong predecessor. It was authored against file 1's
body, not file 2's actual, live one.

## 2. Actual immediate predecessor of `update_task()`

`patch-task-dependency-lifecycle-enforcement.sql`'s version (file 2 above) — captured
directly via `pg_get_functiondef()` against a disposable Postgres instance built from
the real canonical chain truncated immediately after
`patch-attachments-authorization-restoration.sql` (the entry immediately before the
assignee-permission patch). This captured text is the ground truth this checkpoint's
corrected patch and rollback are both based on.

## 3. Functionality the stale patch would have removed

Everything inside file 2's `p_status = 'in_progress'` branch:
`valid_task_status_transition()` re-validation, the organization-scoped
`pg_advisory_xact_lock`, the `FOR UPDATE` row re-lock and authorization revalidation,
and the `get_task_dependency_state()`/`is_blocked` rejection — i.e. the entire
"you cannot start a task while an unresolved prerequisite blocks it" safety mechanism,
plus its concurrency protection.

## 4. Corrected forward-patch design

`supabase/patch-task-assignee-permission-and-activation-fix.sql` was rewritten from
scratch, based on file 2's actual body (§2), preserving every line verbatim **except
one authorization change** — and that change itself required more precision than the
original "just remove the assignee branch" framing, for a reason discovered only by
reconciling against evidence this checkpoint required inspecting (§4a below).

### 4a. A second finding, discovered mid-reconciliation

Running the full pre-existing Task regression suite (§16, per this checkpoint's own
instruction not to declare success on the new test alone) surfaced a real regression: a
naive "remove the assignee branch entirely, both places it appears" correction — which
does exactly what §4 of this checkpoint's own instructions literally describe — broke
`supabase/test-task-dependency-lifecycle-enforcement.sql` scenario 20. That scenario
impersonates `"Hidden Endpoint Assignee"`, an **active assignee with no creator/
supervisor/admin standing**, calling `update_task(..., p_status:='in_progress')` on
their own assigned task, and asserts the call reaches the dependency-block error
(`'Task cannot be started because...'`) rather than being denied at the authorization
stage. This is **pre-existing, already-shipped, already-tested backend behavior** — not
part of the UAT finding (which was about structural fields: title/description/priority/
section), and this checkpoint's own §9 independently names exactly this: *"the backend
ALREADY supports a dependency-aware Open -> In Progress transition... this checkpoint
only ensures the existing backend behavior is not accidentally deleted."*

**Corrected design**: the assignee branch is not removed outright — it is **narrowed**,
in both authorization checks (the initial one and the in_progress-path revalidation
under row lock), to only match a genuine, unbundled start request:

```sql
v_is_pure_start_request BOOLEAN := (
  p_status = 'in_progress'
  AND p_title IS NULL AND p_description IS NULL AND p_priority IS NULL
  AND p_visibility IS NULL AND p_due_date IS NULL AND p_start_date IS NULL
  AND p_owning_section_id IS NULL
);
...
OR (v_is_pure_start_request AND EXISTS (
      SELECT 1 FROM task_assignments ta WHERE ta.task_id = v_task.id AND ta.user_id = v_actor AND ta.is_active
    ))
```

computed once from the call's own parameters (not from `v_task`, so it stays valid
across the row re-fetch under lock) and reused identically in both checks. A call that
bundles a structural field with `p_status:='in_progress'` does **not** match this
condition — it falls through to the manage-tier-only checks exactly like any other
structural edit. There is no side channel back into the removed authority; §12's
scenario 18 proves this directly.

**Draft -> Open remains manage-tier only, unaffected by this refinement** —
`v_is_pure_start_request` only ever matches `p_status = 'in_progress'`, never `'open'`,
so the assignee branch never applies to the Draft activation path. This matches
`docs/107`'s persona matrix, which this checkpoint's own §5 restates near-verbatim
("Assignee must NOT gain merely from assignment: ... manage-tier Start Task").

## 5. Corrected rollback

`supabase/rollback-task-assignee-permission-and-activation-fix.sql` was rewritten to
restore file 2's body **exactly** — byte-for-byte, including the original unconditional
assignee branch in both authorization checks — not a "better" intermediate state and not
the older, dependency-enforcement-free version file 1 had. (The narrower assignee
condition is this forward patch's own correction; rolling back means undoing *this*
patch specifically, back to what was live immediately before it — see §15 for the
byte-for-byte proof.)

## 6. Corrected tests

`supabase/test-task-assignee-permission-and-activation-fix.sql` — extended from 14 to 22
scenarios. New/changed coverage, mapped to this checkpoint's own required assertion
list:

| # | Assertion required | Scenario(s) |
|---|---|---|
| 1 | active assignee cannot structurally edit task details | 2 |
| 2 | creator/manage-tier actor can edit | 1, 4, 11 |
| 3 | Draft -> Open remains permitted for correct actor | 7 (creator); 8 (assignee still denied after) |
| 4 | Open -> In Progress still executes through the dependency-aware path | 12, 13, 17, 19 |
| 5 | Open -> In Progress rejected when prerequisites unresolved | 12 (manage-tier actor), 17 (assignee) |
| 6 | Once resolved, transition proceeds | 13 (manage-tier actor), 19 (assignee) |
| 7 | Dependency checks not removed from `update_task()` | 12+13 and 17+19 combined (a version missing the check would make 12/17 wrongly succeed); 14 (structural: function body still contains `pg_advisory_xact_lock`, `get_task_dependency_state`, `FOR UPDATE`) |
| 8 | Advisory/concurrency protection present where structurally testable | 14 (structural proof — lock acquisition itself has no external side effect to assert on in a single-session script) |
| 9 | Self-unassign remains permitted | 601 |
| 10 | Assignee cannot remove another user's assignment | 3 (denied); 4 (supervisor can) |
| 11 | Attachment capability unaffected | 16 (`attachments_insert` RLS policy still contains its own, separate, unconditional assignee branch) |
| 12 | Unrelated/cross-org actors remain denied | 9, 901 |

Two more scenarios close the gap §4a's finding exposed: **18** (assignee bundling a
structural edit with a start request is still denied — no side channel) and **15**
(structural proof the assignee branch is now *guarded*, not unconditional — this
replaced an earlier, wrong version of scenario 15 that checked for the branch's total
*absence*, which would have failed against the correct, narrowly-guarded design too).

**Proven to fail against the stale `70fffd5` version and pass against the corrected
one** (§14 of this checkpoint's instructions): the stale patch was applied on top of the
same canonical predecessor in a second disposable database, and the corrected test file
run against it — scenarios **12** ("Open -> In Progress rejected while prerequisite
unresolved") and **14** ("body still contains advisory lock + dependency-state check")
both **FAILED** (17 passed, 2 failed) as expected, since the stale body has no
in_progress branch at all and therefore raises no rejection when it should. Against the
corrected patch, all 22 scenarios pass.

## 7. Canonical-order verification

`patch-task-dependency-lifecycle-enforcement.sql` (line 114) already appears before
`patch-task-assignee-permission-and-activation-fix.sql` (line 149) — no reordering was
needed. Only the explanatory comment above the final entry was corrected, to name the
actual predecessor instead of the original foundation file. No unrelated migration was
reordered.

## 8. Clean-build result

Full committed canonical chain applied from zero, via
`supabase/deploy/apply-canonical-schema.sh --local-test-harness`, no manual SQL
corrections between migrations: **83 file(s) applied, zero errors.** The resulting
`update_task()` (captured via `pg_get_functiondef`) was independently confirmed to
contain **both**:

- **A.** the corrected, guarded authorization (`v_is_pure_start_request AND EXISTS` — 1
  occurrence, guarding both checks correctly; zero occurrences of the old, unconditional
  `OR EXISTS (SELECT 1 FROM task_assignments ta WHERE ta.task_id = v_task.id AND
  ta.user_id = v_actor AND ta.is_active)` form with no guard).
- **B.** the dependency-aware lifecycle enforcement (`get_task_dependency_state`
  appearing twice — call site and comment; `pg_advisory_xact_lock` once).

## 9. Rollback round-trip

On the same disposable database, after the clean build (§8):

1. **Predecessor captured independently**: a *separate* disposable database was built
   from the canonical chain truncated immediately after
   `patch-attachments-authorization-restoration.sql` (i.e. without either version of the
   assignee-permission patch), and its `update_task()` captured via
   `pg_get_functiondef()`.
2. **Apply corrected patch → tests**: 22/22 scenarios passed (§6).
3. **Rollback**: `rollback-task-assignee-permission-and-activation-fix.sql` applied.
4. **Compare**: the post-rollback `pg_get_functiondef()` output was diffed byte-for-byte
   against the independently-captured predecessor from step 1 — **`diff` reported zero
   differences.** Comparison method: `pg_get_functiondef()` returns a PL/pgSQL
   function's `$$...$$` body exactly as stored (Postgres does not reparse/reformat
   plpgsql body text), so a plain text `diff` is a valid byte-for-byte equality proof
   here, not merely a semantic approximation.
5. **Reapply corrected patch → tests**: 22/22 scenarios passed again.

## 10. Regression totals

Backend (`supabase/test-*.sql`, run against the clean-built database from §8, in
addition to this checkpoint's own suite):

| Suite | Result |
|---|---|
| `test-task-assignee-permission-and-activation-fix.sql` | 22 PASSED, 0 FAILED |
| `test-task-dependencies.sql` | 31 PASSED, 0 FAILED |
| `test-task-dependency-lifecycle-enforcement.sql` | **30 PASSED, 0 FAILED** (this suite's own assertions; see note below) |
| `test-task-relationships.sql` | 30 PASSED, 0 FAILED |
| `test-task-attachments.sql` | final assertion `t` (unauthorized-uploader-delete-blocked check) — no failure |
| `test-task-audit-visibility.sql` | ALL 11 SCENARIOS PASSED |
| `test-task-dependency-candidate-management.sql` | 25 PASSED, 0 FAILED |

**Note on `test-task-dependency-lifecycle-enforcement.sql`**: before the §4a
refinement, this suite's own scenario 20 assertion genuinely failed (`ERROR: unsafe
hidden error: Not authorized to update this task`) — this was the regression this
reconciliation exists to catch, and it was caught by running *this* pre-existing suite,
not by this checkpoint's own new test alone, exactly per this checkpoint's own
instruction not to declare success prematurely. After the refinement, this suite's own
`NOTICE: TASK DEPENDENCY LIFECYCLE: 30 PASSED, 0 FAILED` confirms full recovery. A
separate, unrelated issue was also observed and is called out for completeness, not
fixed (out of scope — this file was not modified by this checkpoint): its own cleanup
section deletes `users` before `platform_outbox_events` rows referencing them,
producing a foreign-key error *after* all 30 assertions already succeeded and were
reported. This is a pre-existing cleanup-ordering gap in a test file this checkpoint did
not author or touch, unrelated to the CAP-003 outbox mechanism this file predates; it
does not affect the validity of the "30 PASSED, 0 FAILED" result above.

## 11. Frontend regression totals

No frontend file was changed by this checkpoint (confirmed via `git status` — only
`supabase/deploy/canonical-migration-order.txt` and the three
`*-task-assignee-permission-and-activation-fix.sql` files are modified). Re-run for
completeness, all pass:

| Suite | Result |
|---|---|
| `tests/task-assignee-permission-and-activation-frontend.test.js` | 8 PASSED, 0 FAILED |
| `tests/task-relationships-frontend.test.js` (`PLAYWRIGHT_CORE_PATH`/`EDGE_PATH` set) | 59 PASSED, 0 FAILED |
| `tests/task-standalone-creation-frontend.test.js` | 13 PASSED, 0 FAILED |
| `tests/frontend-bootstrap-integrity-frontend.test.js` | 7 PASSED, 0 FAILED |
| `tests/test-frontend-config.sh` | 11 passed, 0 failed |

Per this checkpoint's own scope (§4/§8: "Preserve the frontend Start Task feature...
Do NOT remove it. Do NOT redesign it"; §9: "DO NOT add an Open -> In Progress frontend
action during this checkpoint"), no frontend action was added for the Open -> In
Progress transition even though the backend now correctly supports it for both the
manage tier and, for a pure start request, the assignee — that remains dormant,
backend-only capability until a future, separately-scoped UAT milestone evaluates it.

## 12. Staging deployment status

**Still pending.** No `execute_sql`/`apply_migration` call was made against
`vjobntuyzymhcuanyeak` (or any other Supabase project) in this checkpoint — the
Supabase MCP connector was not used at all. **No live Supabase migration was performed
in this checkpoint.** The corrected patch is now safely applicable — proven against a
complete, from-scratch local replica of the real canonical chain, with the exact
regression this reconciliation exists to prevent reproduced and shown fixed — but it has
not yet touched any live database. Applying it to staging remains the next action for a
future, separately-scoped deployment checkpoint.

## 13. Production untouched

No Supabase tool was invoked against `infjjroktzzhaxjvfknr` or `vjobntuyzymhcuanyeak` —
none was reachable or used at all this session. `config/environments/production.env`
and `main` are unchanged (confirmed via `git diff` against `main`, empty). Only
`supabase/deploy/canonical-migration-order.txt` (comment only),
`supabase/patch-task-assignee-permission-and-activation-fix.sql`,
`supabase/rollback-task-assignee-permission-and-activation-fix.sql`, and
`supabase/test-task-assignee-permission-and-activation-fix.sql` were modified.
