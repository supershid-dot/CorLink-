# 29 — Recurring Meetings Phase 2: Production Deployment Runbook

Operator-ready runbook for applying the CorLink Recurring Meetings Phase 2 SQL patch
chain to the production Supabase project. This document is mechanical: it names exact
files, exact queries, and exact stop conditions so an authorized operator with real
production credentials can execute the deployment without improvising steps at
execution time.

This document was prepared without any connection to production Supabase. No SQL in
this runbook has been executed against production. All "expected" values below are
derived from direct inspection of the patch files in this repository at commit
`eec4e3b7c4805dc3cee549ab1b087ab3cb7c2174` on `main`.

---

## 1. Deployment metadata

| Field | Value |
|---|---|
| Environment | Production |
| Supabase project ID | `<PRODUCTION_PROJECT_ID>` *(placeholder — operator fills in before execution; do not commit the real value into this file)* |
| Operator name | `<OPERATOR_NAME>` |
| Reviewer name | `<REVIEWER_NAME>` |
| Start time | `<START_TIME_UTC>` |
| End time | `<END_TIME_UTC>` |
| Change ticket / reference | `<CHANGE_TICKET_ID>` |
| Current application commit | `eec4e3b7c4805dc3cee549ab1b087ab3cb7c2174` (`main`) |
| Current database version / checkpoint | `<PRE_DEPLOYMENT_CHECKPOINT_ID>` *(backup/PITR identifier captured in §2 below)* |

---

## 2. Pre-deployment checklist

Every box below must be checked, by the operator, before any SQL in §5 runs. If any
item cannot be checked, stop — do not proceed to execution.

- [ ] Approved maintenance window is active (window: `<WINDOW_START>`–`<WINDOW_END>`, approved by `<APPROVER_NAME>`)
- [ ] A verified, restorable backup or PITR checkpoint exists, taken immediately before this deployment starts (checkpoint ID: `<PRE_DEPLOYMENT_CHECKPOINT_ID>`, verified restorable: yes/no)
- [ ] Production credentials for the target project are available to the operator and scoped appropriately (not shared, not embedded in any script or file)
- [ ] No other schema deployment, migration, or `supabase db push` is currently running or scheduled to overlap this window
- [ ] Application support contacts are reachable for the duration of the window (name/contact: `<SUPPORT_CONTACT>`)
- [ ] Rollback authority is identified and reachable (name: `<ROLLBACK_AUTHORITY>`) — see §11 for when their approval is required
- [ ] Production prerequisites confirmed present (queries in §3, expected results below):
  - [ ] `meeting_series` table exists
  - [ ] `can_view_meeting()` function exists
  - [ ] `meeting_series_exceptions` table exists
  - [ ] Current RPC signatures for `update_meeting()`, `cancel_meeting()`, `reschedule_booking()` match the expected **pre-Phase-2** state (i.e. none of them yet have `p_suppress_notification` or `p_preserve_series_membership` — if they already do, stop; a partial or repeated deployment may be in progress and must be investigated before continuing)

---

## 3. Pre-deployment SQL verification queries

Run all of the following before applying patch 1. All queries in this section are
**read-only**. Record the actual output of each in the deployment log (§12) or an
attached appendix.

```sql
-- Current database and connected user/role
SELECT current_database(), current_user, session_user, now();
```

```sql
-- Prerequisite tables
SELECT to_regclass('public.meeting_series')            AS meeting_series,
       to_regclass('public.meetings')                  AS meetings,
       to_regclass('public.meeting_series_exceptions')  AS meeting_series_exceptions,
       to_regclass('public.audit_logs')                AS audit_logs,
       to_regclass('public.notifications')              AS notifications;
```

```sql
-- Prerequisite functions
SELECT proname, pg_get_function_identity_arguments(oid) AS args
FROM pg_proc
WHERE proname IN (
  'can_view_meeting', 'can_manage_meeting', 'update_meeting', 'cancel_meeting',
  'reschedule_booking', 'is_super_admin', 'get_my_org_id', 'is_supervisor_or_above',
  'meetings_module_active_for', 'is_meeting_lock_overridable',
  'can_view_case_audit_record'
)
ORDER BY proname;
```

```sql
-- Current overloads of the functions this deployment will touch (baseline —
-- expect exactly ONE overload each for update_meeting, cancel_meeting,
-- reschedule_booking, can_view_case_audit_record; expect ZERO rows for
-- can_manage_series, create_series_exception, update_entire_series,
-- update_series_this_and_future, cancel_entire_series,
-- cancel_series_this_and_future -- those six must not exist yet)
SELECT proname, pg_get_function_identity_arguments(oid) AS args, oid::regprocedure
FROM pg_proc
WHERE proname IN (
  'update_meeting', 'cancel_meeting', 'reschedule_booking',
  'can_view_case_audit_record',
  'can_manage_series', 'create_series_exception',
  'update_entire_series', 'update_series_this_and_future',
  'cancel_entire_series', 'cancel_series_this_and_future'
)
ORDER BY proname, args;
```

```sql
-- Current CHECK constraint on audit_logs.action
SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'public.audit_logs'::regclass AND conname = 'audit_logs_action_check';
```

```sql
-- Current CHECK constraint on notifications.type
SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'public.notifications'::regclass AND conname = 'notifications_type_check';
```

```sql
-- Table sizes (baseline, and input to the lock-sensitive gates in §7)
SELECT relname,
       pg_size_pretty(pg_total_relation_size(oid)) AS total_size,
       pg_size_pretty(pg_relation_size(oid))        AS table_size,
       (SELECT reltuples::bigint FROM pg_class WHERE oid = c.oid) AS approx_row_count
FROM pg_class c
WHERE relname IN ('audit_logs', 'notifications') AND relkind = 'r';
```

```sql
-- Active sessions
SELECT pid, usename, application_name, client_addr, state, query_start, state_change, wait_event_type, wait_event
FROM pg_stat_activity
WHERE datname = current_database()
ORDER BY query_start;
```

```sql
-- Long-running transactions (older than 5 minutes)
SELECT pid, usename, xact_start, now() - xact_start AS duration, state, query
FROM pg_stat_activity
WHERE datname = current_database()
  AND xact_start IS NOT NULL
  AND now() - xact_start > interval '5 minutes'
ORDER BY xact_start;
```

```sql
-- Blocked and blocking sessions
SELECT
  blocked.pid       AS blocked_pid,
  blocked.query      AS blocked_query,
  blocking.pid       AS blocking_pid,
  blocking.query     AS blocking_query
FROM pg_locks bl
JOIN pg_stat_activity blocked ON bl.pid = blocked.pid
JOIN pg_locks kl ON kl.locktype = bl.locktype
  AND kl.database IS NOT DISTINCT FROM bl.database
  AND kl.relation IS NOT DISTINCT FROM bl.relation
  AND kl.pid <> bl.pid AND kl.granted
JOIN pg_stat_activity blocking ON kl.pid = blocking.pid
WHERE NOT bl.granted;
```

```sql
-- Rollback snapshots: current function definitions for every function this
-- deployment will REPLACE (not the new functions it creates -- those have no
-- prior definition to snapshot). Save the full output of each verbatim.
SELECT pg_get_functiondef('update_meeting'::regproc);
SELECT pg_get_functiondef('cancel_meeting'::regproc);
SELECT pg_get_functiondef('reschedule_booking'::regproc);
SELECT pg_get_functiondef('can_view_case_audit_record'::regproc);
```

> Note: `'update_meeting'::regproc` resolves only while exactly one overload exists.
> If ambiguous, use `pg_get_functiondef(oid)` with the `oid::regprocedure` value
> captured from the overloads query above instead.

**Stop condition for this section:** if any query above returns something other than
the documented expected result (missing prerequisite table/function, an unexpected
existing overload of any of the six new Phase 2 functions, a CHECK constraint that
already contains any of `meeting_series_updated` / `meeting_series_split` /
`meeting_series_cancelled`, or `update_meeting()` / `cancel_meeting()` /
`reschedule_booking()` already carrying `p_suppress_notification` or
`p_preserve_series_membership`) — stop. Do not proceed to §5. Investigate before any
further action; this indicates either stale assumptions about production state or a
partially-applied prior deployment attempt.

---

## 4. Exact patch execution order

1. `supabase/patch-meetings-recurring-phase2-notification-suppression.sql`
2. `supabase/patch-meetings-recurring-phase2-series-auth.sql`
3. `supabase/patch-meetings-recurring-phase2-series-exceptions.sql`
4. `supabase/patch-meetings-recurring-phase2-update-entire-series.sql`
5. `supabase/patch-meetings-recurring-phase2-update-series-this-and-future.sql`
6. `supabase/patch-meetings-recurring-phase2-preserve-series-membership.sql`
7. `supabase/patch-meetings-recurring-phase2-cancel-entire-series.sql`
8. `supabase/patch-meetings-recurring-phase2-cancel-series-this-and-future.sql`
9. `supabase/patch-meetings-recurring-phase2-audit-visibility.sql`

This order is required, not stylistic: patch 3 depends on patch 2 (`can_manage_series()`);
patches 4/5/6/7/8 form a strict backward-referencing chain (each documented in its own
file header); patch 9 depends only on objects that predate this entire chain
(`meeting_series`, `can_view_meeting()`) and is placed last by convention.

---

## 5. Execution instructions

### Method A — psql

Connect with `ON_ERROR_STOP` enabled so any error inside a patch's own
`BEGIN…COMMIT` halts the session immediately rather than continuing past a failure:

```
psql "<PRODUCTION_CONNECTION_STRING>" -v ON_ERROR_STOP=1
```

Then, one patch at a time — run the `\i` command, confirm the transaction committed
(psql prints `BEGIN` then `COMMIT` with no interleaved `ERROR`), then run that patch's
verification block from §6 before moving to the next `\i`:

```
\i supabase/patch-meetings-recurring-phase2-notification-suppression.sql
-- run patch 1 verification block (§6) here, confirm pass, THEN continue
\i supabase/patch-meetings-recurring-phase2-series-auth.sql
-- run patch 2 verification block (§6) here, confirm pass, THEN continue
\i supabase/patch-meetings-recurring-phase2-series-exceptions.sql
-- run patch 3 verification block (§6) here, confirm pass, THEN continue
\i supabase/patch-meetings-recurring-phase2-update-entire-series.sql
-- run patch 4 lock-sensitive gate (§7) BEFORE this \i, then verification block (§6) after
\i supabase/patch-meetings-recurring-phase2-update-series-this-and-future.sql
-- run patch 5 lock-sensitive gate (§7) BEFORE this \i, then verification block (§6) after
\i supabase/patch-meetings-recurring-phase2-preserve-series-membership.sql
-- run patch 6 verification block (§6) here, confirm pass, THEN continue
\i supabase/patch-meetings-recurring-phase2-cancel-entire-series.sql
-- run patch 7 lock-sensitive gate (§7) BEFORE this \i, then verification block (§6) after
\i supabase/patch-meetings-recurring-phase2-cancel-series-this-and-future.sql
-- run patch 8 verification block (§6) here, confirm pass, THEN continue
\i supabase/patch-meetings-recurring-phase2-audit-visibility.sql
-- run patch 9 verification block (§6) here, confirm pass, THEN continue to §8
```

Do not queue all nine `\i` commands in one paste. Run one, wait for its result,
verify, then proceed — exactly as the execution rules require.

### Method B — Supabase SQL Editor

For each patch file, in order:

1. Open the patch file from the repository (`supabase/<filename>`) in a text editor;
   copy its **entire, unmodified** contents.
2. Paste into a **new** SQL Editor query tab in the Supabase dashboard for the
   production project. Do not append other patches or verification queries into the
   same tab.
3. Run the query. Confirm the result panel shows success with no error — Supabase's
   SQL Editor reports `COMMIT` or a success status for the statement batch; a `ROLLBACK`
   or an error message means the patch did not apply and must be diagnosed before
   any further action.
4. Screenshot or copy the success output into the deployment log / appendix for this
   step.
5. Open a **new** query tab and run that patch's verification block from §6 (or the
   lock-sensitive gate from §7 first, for patches 4/5/7). Confirm every expected
   result before opening the tab for the next patch.
6. Only after verification passes, proceed to the next patch's tab.

---

## 6. Per-patch verification blocks

### Patch 1 — notification-suppression

```sql
-- Expected: p_suppress_notification present on all three; exactly one overload each
SELECT proname, pg_get_function_identity_arguments(oid) AS args
FROM pg_proc
WHERE proname IN ('update_meeting', 'cancel_meeting', 'reschedule_booking')
ORDER BY proname;

-- Explicit parameter check
SELECT proname,
       pg_get_function_identity_arguments(oid) LIKE '%p_suppress_notification%' AS has_suppress_param
FROM pg_proc
WHERE proname IN ('update_meeting', 'cancel_meeting', 'reschedule_booking');
```
Pass criteria: exactly one row per function name; `has_suppress_param = true` for all three; no second overload of any of the three appears anywhere else in the same query with a differing argument list (i.e. the old pre-patch signature is gone, replaced — not duplicated).

### Patch 2 — series-auth

```sql
SELECT proname, pg_get_function_identity_arguments(oid) AS args, prosecdef
FROM pg_proc WHERE proname = 'can_manage_series';
```
Pass criteria: exactly one row; `args = 'p_series_id uuid'`; `prosecdef = true` (SECURITY DEFINER).

### Patch 3 — series-exceptions

```sql
SELECT proname, pg_get_function_identity_arguments(oid) AS args
FROM pg_proc WHERE proname = 'create_series_exception';

-- Confirm it depends on can_manage_series (patch 2 must already be applied)
SELECT pg_get_functiondef('create_series_exception'::regproc) LIKE '%can_manage_series%' AS calls_can_manage_series;
```
Pass criteria: exactly one row for `create_series_exception`; `calls_can_manage_series = true`.

### Patch 4 — update-entire-series

```sql
SELECT proname, pg_get_function_identity_arguments(oid) AS args
FROM pg_proc WHERE proname = 'update_entire_series';

SELECT pg_get_constraintdef(oid) LIKE '%meeting_series_updated%' AS audit_has_value
FROM pg_constraint WHERE conname = 'audit_logs_action_check';

SELECT pg_get_constraintdef(oid) LIKE '%meeting_series_updated%' AS notif_has_value
FROM pg_constraint WHERE conname = 'notifications_type_check';
```
Pass criteria: exactly one row for `update_entire_series`; both CHECK checks `true`; no other row in the constraint definition was removed (spot-check the full `pg_get_constraintdef` output against the pre-deployment snapshot from §3 — it must be a strict superset with exactly one new trailing value).

### Patch 5 — update-series-this-and-future

```sql
SELECT proname, pg_get_function_identity_arguments(oid) AS args
FROM pg_proc WHERE proname = 'update_series_this_and_future';

SELECT pg_get_constraintdef(oid) LIKE '%meeting_series_split%' AS audit_has_value
FROM pg_constraint WHERE conname = 'audit_logs_action_check';

SELECT pg_get_constraintdef(oid) LIKE '%meeting_series_split%' AS notif_has_value
FROM pg_constraint WHERE conname = 'notifications_type_check';
```
Pass criteria: exactly one row for `update_series_this_and_future`; both CHECK checks `true`; `meeting_series_updated` from patch 4 still present (superset, not replaced).

### Patch 6 — preserve-series-membership

```sql
SELECT proname, pg_get_function_identity_arguments(oid) AS args
FROM pg_proc WHERE proname = 'update_meeting';

SELECT pg_get_function_identity_arguments(oid) LIKE '%p_preserve_series_membership%' AS has_preserve_param
FROM pg_proc WHERE proname = 'update_meeting';

-- Confirm the two Phase-2 series RPCs now pass the new parameter through
SELECT pg_get_functiondef('update_entire_series'::regproc) LIKE '%p_preserve_series_membership%' AS entire_series_uses_it;
SELECT pg_get_functiondef('update_series_this_and_future'::regproc) LIKE '%p_preserve_series_membership%' AS this_and_future_uses_it;
```
Pass criteria: exactly one row for `update_meeting`; `has_preserve_param = true`; both delegation checks `true`. No CHECK constraint value is expected to change in this patch.

### Patch 7 — cancel-entire-series

```sql
SELECT proname, pg_get_function_identity_arguments(oid) AS args
FROM pg_proc WHERE proname = 'cancel_entire_series';

SELECT pg_get_constraintdef(oid) LIKE '%meeting_series_cancelled%' AS audit_has_value
FROM pg_constraint WHERE conname = 'audit_logs_action_check';

SELECT pg_get_constraintdef(oid) LIKE '%meeting_series_cancelled%' AS notif_has_value
FROM pg_constraint WHERE conname = 'notifications_type_check';
```
Pass criteria: exactly one row for `cancel_entire_series`; both CHECK checks `true`; `meeting_series_updated` and `meeting_series_split` still present (superset).

### Patch 8 — cancel-series-this-and-future

```sql
SELECT proname, pg_get_function_identity_arguments(oid) AS args
FROM pg_proc WHERE proname = 'cancel_series_this_and_future';

-- Confirm no duplicate/second value was added — constraint definition must be
-- byte-identical to the post-patch-7 snapshot
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_action_check';
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'notifications_type_check';
```
Pass criteria: exactly one row for `cancel_series_this_and_future`; both constraint definitions match the patch-7 snapshot exactly (patch 8 must not touch either CHECK constraint).

### Patch 9 — audit-visibility

```sql
SELECT proname, pg_get_function_identity_arguments(oid) AS args
FROM pg_proc WHERE proname = 'can_view_case_audit_record';

SELECT pg_get_functiondef('can_view_case_audit_record'::regproc) LIKE '%meeting_series%' AS has_meeting_series_branch;
```
Pass criteria: exactly one row (still, since this is `CREATE OR REPLACE` on an existing function — the OID may change but the overload count must not); `has_meeting_series_branch = true`.

**Every block above additionally requires:** no unrelated function name appears
unexpectedly in any of the `pg_proc` result sets for that step, and no application
error rate increase is observed for the duration of that patch's application (check
via `get_logs`/dashboard error monitoring or equivalent, outside the scope of this
SQL-only document).

---

## 7. Lock-sensitive patch gates (before patches 4, 5, 7)

Each of these three patches alters the `audit_logs_action_check` and
`notifications_type_check` CHECK constraints via `DROP CONSTRAINT` /
`ADD CONSTRAINT`, which requires an `ACCESS EXCLUSIVE` lock on the table for the
duration of the constraint validation (a full scan of existing rows). Run this gate
immediately before each of the three patches, not once at the start of the session —
table size and active-session state can change during the window.

```sql
-- Table size (re-check; compare against §3 baseline)
SELECT relname,
       pg_size_pretty(pg_total_relation_size(oid)) AS total_size,
       (SELECT reltuples::bigint FROM pg_class WHERE oid = c.oid) AS approx_row_count
FROM pg_class c
WHERE relname IN ('audit_logs', 'notifications') AND relkind = 'r';

-- Active transactions right now
SELECT pid, usename, xact_start, now() - xact_start AS duration, state, query
FROM pg_stat_activity
WHERE datname = current_database() AND xact_start IS NOT NULL
ORDER BY xact_start;

-- Blocked/blocking sessions right now
SELECT
  blocked.pid AS blocked_pid, blocked.query AS blocked_query,
  blocking.pid AS blocking_pid, blocking.query AS blocking_query
FROM pg_locks bl
JOIN pg_stat_activity blocked ON bl.pid = blocked.pid
JOIN pg_locks kl ON kl.locktype = bl.locktype
  AND kl.database IS NOT DISTINCT FROM bl.database
  AND kl.relation IS NOT DISTINCT FROM bl.relation
  AND kl.pid <> bl.pid AND kl.granted
JOIN pg_stat_activity blocking ON kl.pid = blocking.pid
WHERE NOT bl.granted;
```

Gate checklist (repeat before each of patches 4, 5, 7):

- [ ] Table size reviewed; no unexpected growth since §3 baseline
- [ ] No long-running transaction holds a conflicting lock on `audit_logs` or `notifications`
- [ ] No session is currently blocked on either table
- [ ] Operator confirms the lock window (estimated from table size and current load) is acceptable for this specific patch — **Patch 4 gate confirmed: `<INITIALS>`** / **Patch 5 gate confirmed: `<INITIALS>`** / **Patch 7 gate confirmed: `<INITIALS>`**
- [ ] **Stop condition:** if the estimated lock window is unacceptable, or a long-running transaction or blocking session is present, stop this patch and reschedule — do not force the `ALTER TABLE` through.

---

## 8. Final verification SQL

Run after all nine patches have passed their individual verification blocks.

```sql
-- 1. All six Phase 2 RPCs exist with exactly one intended overload each
SELECT proname, count(*) AS overload_count, array_agg(pg_get_function_identity_arguments(oid)) AS all_args
FROM pg_proc
WHERE proname IN (
  'can_manage_series', 'create_series_exception', 'update_entire_series',
  'update_series_this_and_future', 'cancel_entire_series', 'cancel_series_this_and_future'
)
GROUP BY proname
ORDER BY proname;
-- Pass: overload_count = 1 for every row, six rows total.
```

```sql
-- 2a. p_suppress_notification present on all intended underlying RPCs
SELECT proname, pg_get_function_identity_arguments(oid) LIKE '%p_suppress_notification%' AS has_param
FROM pg_proc WHERE proname IN ('update_meeting', 'cancel_meeting', 'reschedule_booking');

-- 2b. p_preserve_series_membership present on update_meeting()
SELECT pg_get_function_identity_arguments(oid) LIKE '%p_preserve_series_membership%' AS has_param
FROM pg_proc WHERE proname = 'update_meeting';

-- 2c. All three audit action / notification type values present, superset-checked
SELECT pg_get_constraintdef(oid) AS audit_logs_action_check FROM pg_constraint WHERE conname = 'audit_logs_action_check';
SELECT pg_get_constraintdef(oid) AS notifications_type_check FROM pg_constraint WHERE conname = 'notifications_type_check';
-- Pass: both definitions contain 'meeting_series_updated', 'meeting_series_split',
-- and 'meeting_series_cancelled', AND every value present in the §3 baseline
-- snapshot is still present (strict superset, nothing removed).

-- 2d. can_view_case_audit_record() contains the meeting_series branch
SELECT pg_get_functiondef('can_view_case_audit_record'::regproc) LIKE '%meeting_series%' AS has_branch;
```

```sql
-- RLS remains enabled on relevant tables
SELECT relname, relrowsecurity
FROM pg_class
WHERE relname IN ('meeting_series', 'meetings', 'meeting_series_exceptions', 'audit_logs', 'notifications');
-- Pass: relrowsecurity = true for every row.
```

```sql
-- No unexpected schema changes: diff this against the §3 baseline function/constraint
-- inventory. Only the nine objects this deployment intended to add or modify should differ.
SELECT proname, pg_get_function_identity_arguments(oid) AS args
FROM pg_proc
WHERE proname IN (
  'update_meeting', 'cancel_meeting', 'reschedule_booking', 'can_view_case_audit_record',
  'can_manage_series', 'create_series_exception', 'update_entire_series',
  'update_series_this_and_future', 'cancel_entire_series', 'cancel_series_this_and_future'
)
ORDER BY proname, args;
```

---

## 9. Controlled production smoke-test procedure

Use only approved disposable test data and approved test accounts — never real
production case/meeting data. Perform every step through the CorLink application UI
(not direct SQL), so the smoke test exercises the actual RPCs exactly as end users
will.

1. Create a recurring series (disposable test org/section, test accounts).
2. Perform an **Entire Series** edit (title/time change) — confirm the change applies
   to all eligible occurrences and a single consolidated notification/audit entry is
   produced (not one per occurrence).
3. Perform a **This and Future** edit on a later occurrence — confirm the series
   splits correctly, the original series' earlier occurrences are unaffected, and a
   single consolidated notification/audit entry is produced for the split.
4. Create a series exception (skip or modify a single occurrence) — confirm it does
   not affect other occurrences and is reflected in the activity/exception UI.
5. Perform a **This and Future cancellation** on the split series — confirm eligible
   future occurrences are cancelled, past/completed/already-cancelled/detached
   occurrences are correctly skipped and reported, and a single consolidated
   notification/audit entry is produced.
6. Perform an **Entire Series cancellation** on a **separate** disposable test series
   — confirm the series is marked cancelled and further mutating actions against it
   are correctly rejected.
7. Verify consolidated notifications: confirm participants received exactly one
   notification per bulk action above, not one per occurrence.
8. Verify audit entries: confirm each bulk action produced exactly one `audit_logs`
   row with the documented `scope=...; affected=...; skipped=...` note format.
9. Verify authorized audit visibility: as a super admin, the series creator, and a
   same-org supervisor, confirm the series' audit trail is visible.
10. Verify unauthorized visibility denial: as a same-org user with no relationship to
    the series (not creator, not supervisor, no visible occurrence), confirm the audit
    trail is **not** visible.
11. Verify cross-organization denial: as a user in a different organization, confirm
    the series and its audit trail are **not** visible at all.
12. Verify normal single-meeting edit and cancellation (a meeting with no series
    association) still behave exactly as before this deployment — no regression in
    the non-recurring path.

Test data cleanup: cancel or archive all disposable test series/meetings created
above **through the application's normal cancellation/archival workflows only**. Do
not run direct `DELETE`/`UPDATE` SQL against production data as cleanup.

---

## 10. Stop conditions

Stop immediately — do not apply the next patch, do not proceed to the next section —
if any of the following occurs at any point during this deployment:

- Any patch's SQL execution returns an error, or its transaction does not show a
  clean `COMMIT`.
- Any verification query in §6, §7, or §8 fails its stated pass criteria.
- An unexpected function overload appears (more than the intended one overload for
  any Phase 2 function, or a stray signature for `update_meeting()` / `cancel_meeting()`
  / `reschedule_booking()`).
- An expected dependency is found missing (e.g. `can_manage_series()` absent when
  applying patch 3 or later).
- A CHECK constraint contains a value not accounted for in this runbook, or is
  missing a value a prior patch in this same deployment added.
- Blocking or lock waits during a §7 gate are judged unsafe.
- Application error rates rise during or immediately after a patch.
- Audit visibility (patch 9, or the smoke test in §9) is broader than intended — e.g.
  a cross-organization or unauthorized-user check in §9 unexpectedly succeeds.
- Notification behavior becomes per-occurrence instead of the documented single
  consolidated notification per bulk action.

On any stop condition: halt execution, notify the rollback authority (§2) and
application support contacts, and do not attempt remediation SQL without following
§11.

---

## 11. Rollback guidance

Rollback is not a single command — its shape depends on what the patch changed.

**New functions with no prior definition (patches 2, 3, 4, 5, 7, 8; and patch 9's new
branch within an existing function):**
`DROP FUNCTION <name>(<exact argument list>);` removes the object cleanly, in reverse
patch order, since later patches may reference earlier ones (e.g. drop
`cancel_series_this_and_future` before `cancel_entire_series`, drop
`update_series_this_and_future` before `update_entire_series`, drop anything calling
`can_manage_series` before dropping `can_manage_series` itself).

**Redefined functions with a prior definition (patch 9's `can_view_case_audit_record()`,
and patch 6's body-only redefinition of `update_entire_series()`/`update_series_this_and_future()`):**
Restore using the exact `pg_get_functiondef()` output captured in the §3
pre-deployment snapshot: `CREATE OR REPLACE FUNCTION ...` with that captured body.
Because these use `CREATE OR REPLACE` (not `DROP` + `CREATE`), the function's OID is
stable and no dependent object needs to be recreated.

**Signature-changing functions (patch 1's `update_meeting()`/`cancel_meeting()`/
`reschedule_booking()`; patch 6's `update_meeting()`):**
The new-signature function must be dropped with its exact new argument list, then the
prior-signature function recreated from the captured `pg_get_functiondef()` snapshot.
Because PostgREST/Supabase RPC calls resolve by named argument, any application code
already relying on the new parameter will break once rolled back — confirm no
in-flight application traffic depends on the new parameter before doing this.

**CHECK-constraint changes (patches 4, 5, 7):**
Reverting means dropping and re-adding the narrower, pre-patch list captured in the
§3 snapshot. **This is safe only if no row has yet been written with the newly added
value** (`meeting_series_updated`, `meeting_series_split`, or `meeting_series_cancelled`).
Once the corresponding RPC has actually been invoked in production — including during
the smoke test in §9 — narrowing the constraint will fail until those rows are
found and remediated, and remediating audit/notification history is itself a
data-altering action requiring its own explicit approval. Treat the CHECK-constraint
additions as effectively one-way once any Phase 2 RPC has run against real or test
data in this environment.

**When to use PITR / full backup restore instead of targeted rollback:**
If more than one patch must be reverted, if the exact scope of a failure is unclear,
if any CHECK-constraint value has already been written to a row, or if targeted
rollback itself fails partway — stop attempting targeted SQL rollback and restore
from the pre-deployment checkpoint captured in §2 instead.

**Approval requirement:** No rollback action — targeted SQL or full restore — may be
executed without explicit sign-off from the rollback authority named in §2, following
the organization's incident/change-authority process. This runbook does not itself
constitute that approval.

---

## 12. Deployment log

| Step | Patch | Start time | End time | Result | Verification result | Operator initials | Notes |
|---|---|---|---|---|---|---|---|
| 0 | Pre-deployment checklist (§2) | | | | | | |
| 0 | Pre-deployment verification (§3) | | | | | | |
| 1 | notification-suppression.sql | | | | | | |
| 2 | series-auth.sql | | | | | | |
| 3 | series-exceptions.sql | | | | | | |
| — | Lock gate before patch 4 (§7) | | | | | | |
| 4 | update-entire-series.sql | | | | | | |
| — | Lock gate before patch 5 (§7) | | | | | | |
| 5 | update-series-this-and-future.sql | | | | | | |
| 6 | preserve-series-membership.sql | | | | | | |
| — | Lock gate before patch 7 (§7) | | | | | | |
| 7 | cancel-entire-series.sql | | | | | | |
| 8 | cancel-series-this-and-future.sql | | | | | | |
| 9 | audit-visibility.sql | | | | | | |
| — | Final verification (§8) | | | | | | |
| — | Smoke test (§9) | | | | | | |

---

## 13. Sign-off

- [ ] Database deployment complete (all nine patches applied and verified)
- [ ] Production smoke test complete (§9, all steps passed)
- [ ] Frontend deployment authorized: yes / no
- [ ] Rollback not required / rollback executed *(strike whichever does not apply; if executed, attach incident/change-authority approval reference)*

Operator signature: `______________________`  Date/time: `______________________`

Reviewer signature: `______________________`  Date/time: `______________________`
