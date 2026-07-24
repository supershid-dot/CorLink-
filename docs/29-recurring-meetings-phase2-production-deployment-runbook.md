# 29 — CorLink Platform Migration, Rooms, Meetings, Recurring Meetings & Draft Meetings: Production Deployment Runbook

Operator-ready runbook for applying the complete CorLink Platform Migration SQL chain —
Platform Module Foundation, Rooms & Booking, Meetings (core + RSVP/attendance/minutes/
lock/personal notes/groups), Recurring Meetings (Phase 1 + Phase 2), and Draft Meetings —
to the production Supabase project. This document is mechanical: it names exact files,
exact queries, and exact stop conditions so an authorized operator with real production
credentials can execute the deployment without improvising steps at execution time.

This document was prepared without any connection to production Supabase. No SQL in
this runbook has been executed against production. All "expected" values below are
derived from direct inspection of the patch files in this repository at commit
`2d3f7cbe55013f478679afffe5917f9909b986c6` on `main`.

This runbook **replaces** the prior Phase-2-only version of this document (files #14–#22
below). It does not itself constitute authorization to execute — see §4 for the human
approvals required before any step in §9 onward is performed.

---

## 1. Deployment scope and confirmed production baseline

**Confirmed production state (as reported for this runbook, not independently queried
by this document):** production currently contains only the legacy CorLink baseline —
the pre-migration `schema.sql`/`rls.sql` core (Requests, Entry, Prisoner Letters,
Admin, notifications, audit). **None** of the Platform Migration / Rooms / Meetings
stack — none of the 24 files in §8 — has been applied to production. This is a
from-scratch deployment of the entire stack, not an incremental patch on top of a
partially-migrated production database.

**Confirmed staging state:** staging has successfully applied and validated files
**#4–#22** (this runbook's numbering — RSVP through Recurring Phase 2 audit-visibility)
in the rehearsal described in §2. Staging is additionally reported to be at overall
schema parity with `main` except for two specific, deliberate gaps, recorded in full in
§3. This runbook does not independently verify when files #1–#3 (Platform Module
Foundation, Rooms Booking Foundation, Meetings Foundation) or #23–#24 (route
activations) were applied to staging — only that the rehearsal evidence in §2 is scoped
to #4–#22, and that the broader "schema parity with main" statement implies the rest of
the chain is also present on staging. Production readiness in §27 is judged against
exactly what is stated here, not against an assumed fuller staging history.

**What this runbook governs:** the 24-file SQL migration chain in §8, applied to the
production Supabase database. It does not govern frontend deployment or Cloudflare
configuration — those are separate, later actions gated in §22.

---

## 2. Staging rehearsal evidence

The staging migration rehearsal is reported to have successfully validated the
following, exercising files #4–#22:

- RSVP (respond to invitation)
- Attendance marking
- Meeting minutes (update + finalize)
- Meeting lock / unlock (including override tiers)
- Personal participant notes (privacy-scoped)
- Meeting groups (create, membership, apply-to-meeting)
- Draft meetings (create, edit, delete, promote to scheduled)
- Recurring series creation
- Recurring notification batching (single consolidated room-approval notification)
- Entire Series update (`update_entire_series()`)
- This and Future update (`update_series_this_and_future()`, including the
  first-occurrence-collapse and split-series behavior)
- Entire Series cancellation (`cancel_entire_series()`)
- This and Future cancellation (`cancel_series_this_and_future()`)
- Series exceptions (`create_series_exception()`)
- Creator audit visibility (`can_view_case_audit_record()` — `meeting_series` branch,
  creator persona)
- Anonymous rejection (unauthenticated caller correctly denied)
- Single-meeting regression behavior (non-recurring meetings unaffected by the Phase 2
  RPC surface)
- Schema/function/constraint/RLS integrity (no unexpected overloads, CHECK values, or
  RLS gaps found during the rehearsal)

This is real, reported validation evidence — not a substitute for the production
smoke test in §20, which must still be performed against production itself after
deployment. A successful staging rehearsal reduces risk; it does not eliminate the
need for the same checks in the actual target environment.

---

## 3. Known validation gap

Two gaps are explicitly carried forward from staging into this production deployment
and must not be silently treated as closed:

1. **Calendar route activation (file #10) remains deliberately inactive.** This is a
   product decision, not an oversight — see §18. Calendar staying inactive during
   initial production deployment is an accepted, intentional state, not a defect to
   fix before proceeding.
2. **Multi-persona audit-visibility validation remains incomplete.** Staging has only
   one real user account, so only the creator/super-admin persona and the anonymous
   (unauthenticated) rejection case were exercised for `can_view_case_audit_record()`'s
   `meeting_series` branch. The same-organization supervisor, authorized participant,
   unauthorized same-organization user, and cross-organization user personas have
   **not** been tested anywhere yet. This is a required production-readiness/UAT gate,
   detailed in full in §21 — it is not satisfied by the staging rehearsal and must not
   be represented as satisfied.

---

## 4. Human approvals and prerequisites

- [ ] Change ticket / reference approved: `<CHANGE_TICKET_ID>`
- [ ] Deployment approved by: `<APPROVER_NAME>`, date: `<APPROVAL_DATE>`
- [ ] Operator name: `<OPERATOR_NAME>`
- [ ] Reviewer name: `<REVIEWER_NAME>`
- [ ] Rollback authority identified and reachable: `<ROLLBACK_AUTHORITY>`
- [ ] Application support contacts reachable for the duration of the window: `<SUPPORT_CONTACT>`
- [ ] This runbook (docs/29, this version) has been reviewed and accepted by the reviewer named above
- [ ] The multi-persona gap (§3 item 2) and the calendar-inactive decision (§3 item 1)
      have been explicitly acknowledged by the approver as acceptable to proceed with —
      **not** treated as blockers, per this runbook's own framing, but the approver must
      still consciously accept them, not merely be unaware of them

---

## 5. Backup/PITR and rollback checkpoint

- [ ] A verified, restorable backup or PITR checkpoint exists, taken immediately before
      this deployment starts (checkpoint ID: `<PRE_DEPLOYMENT_CHECKPOINT_ID>`, verified
      restorable: yes/no)
- [ ] Because production currently contains none of the target schema (§1), the
      "current function definitions" rollback snapshots required by the Phase-2-only
      predecessor of this document are not applicable to files #1–#13 and #23–#24 (they
      create objects that do not yet exist in production — there is nothing prior to
      snapshot). They remain applicable to files #14–#22 only insofar as those files
      redefine functions created earlier in *this same* deployment (see §17's rollback
      note and §25).
- [ ] Full backup/PITR checkpoint is the primary rollback mechanism for this
      deployment, given it is a from-scratch application of the entire stack — see §25.

---

## 6. Maintenance-window confirmation

- [ ] Approved maintenance window is active (window: `<WINDOW_START>`–`<WINDOW_END>`,
      approved by `<APPROVER_NAME>`)
- [ ] No other schema deployment, migration, or `supabase db push` is currently running
      or scheduled to overlap this window
- [ ] Window duration accounts for 24 sequential file applications plus verification
      after each — do not compress verification steps to fit a shorter window; extend
      the window instead

---

## 7. Production schema preflight

Run before applying file #1. All queries are **read-only**.

```sql
-- Current database and connected user/role
SELECT current_database(), current_user, session_user, now();
```

```sql
-- Confirm the target objects do NOT yet exist (production has none of this stack)
SELECT to_regclass('public.platform_modules')          AS platform_modules,
       to_regclass('public.organization_modules')      AS organization_modules,
       to_regclass('public.meeting_rooms')              AS meeting_rooms,
       to_regclass('public.meeting_room_bookings')       AS meeting_room_bookings,
       to_regclass('public.meetings')                    AS meetings,
       to_regclass('public.meeting_participants')         AS meeting_participants,
       to_regclass('public.meeting_series')                AS meeting_series,
       to_regclass('public.meeting_series_exceptions')      AS meeting_series_exceptions,
       to_regclass('public.meeting_groups')                  AS meeting_groups,
       to_regclass('public.meeting_participant_notes')        AS meeting_participant_notes;
-- Expected: every column NULL. Any non-null result is a STOP CONDITION (§24) —
-- it means production is not at the assumed clean legacy baseline and this runbook's
-- ordering assumptions must be re-verified before proceeding.
```

```sql
-- Confirm the legacy baseline tables this stack extends DO already exist
SELECT to_regclass('public.audit_logs')      AS audit_logs,
       to_regclass('public.notifications')   AS notifications,
       to_regclass('public.organizations')   AS organizations,
       to_regclass('public.users')           AS users,
       to_regclass('public.attachments')     AS attachments;
-- Expected: all non-null.
```

```sql
-- Baseline CHECK constraints (starting point for the superset checks in §15)
SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conname IN ('audit_logs_action_check', 'notifications_type_check',
                   'audit_logs_record_type_check', 'attachments_record_type_check');
```

```sql
-- Table sizes (baseline, and input to the lock-sensitive gates in §17)
SELECT relname,
       pg_size_pretty(pg_total_relation_size(oid)) AS total_size,
       (SELECT reltuples::bigint FROM pg_class WHERE oid = c.oid) AS approx_row_count
FROM pg_class c
WHERE relname IN ('audit_logs', 'notifications') AND relkind = 'r';
```

```sql
-- Active sessions / long-running transactions / blocked-blocking (baseline)
SELECT pid, usename, application_name, state, query_start, wait_event_type, wait_event
FROM pg_stat_activity WHERE datname = current_database() ORDER BY query_start;
```

**Stop condition for this section:** if any target object in the first query already
exists, or any legacy baseline table in the second query is missing, stop. Do not
proceed to §9. The assumption underlying this entire runbook — a from-scratch
deployment onto a clean legacy baseline — does not hold, and the deployment plan must
be re-derived before any file is applied.

---

## 8. Exact 24-file dependency chain

1. `supabase/patch-platform-module-foundation.sql`
2. `supabase/patch-rooms-booking-foundation.sql`
3. `supabase/patch-meetings-foundation.sql`
4. `supabase/patch-meetings-rsvp.sql`
5. `supabase/patch-meetings-attendance.sql`
6. `supabase/patch-meetings-minutes.sql`
7. `supabase/patch-meetings-lock.sql`
8. `supabase/patch-meetings-personal-notes.sql`
9. `supabase/patch-meetings-groups.sql`
10. `supabase/patch-calendar-route-activation.sql` — **deferred; see §18, do not apply in this stage**
11. `supabase/patch-meetings-recurring.sql`
12. `supabase/patch-meetings-recurring-notifications.sql`
13. `supabase/patch-meetings-drafts.sql`
14. `supabase/patch-meetings-recurring-phase2-series-auth.sql`
15. `supabase/patch-meetings-recurring-phase2-notification-suppression.sql`
16. `supabase/patch-meetings-recurring-phase2-series-exceptions.sql`
17. `supabase/patch-meetings-recurring-phase2-update-entire-series.sql`
18. `supabase/patch-meetings-recurring-phase2-update-series-this-and-future.sql`
19. `supabase/patch-meetings-recurring-phase2-preserve-series-membership.sql`
20. `supabase/patch-meetings-recurring-phase2-cancel-entire-series.sql`
21. `supabase/patch-meetings-recurring-phase2-cancel-series-this-and-future.sql`
22. `supabase/patch-meetings-recurring-phase2-audit-visibility.sql`
23. `supabase/patch-meetings-route-activation.sql` — **deferred; see §18, do not apply in this stage**
24. `supabase/patch-rooms-route-activation.sql` — **deferred; see §18, do not apply in this stage**

All 24 filenames verified present in `supabase/` at commit `2d3f7cbe55013f478679afffe5917f9909b986c6`.

**Route-activation rule (files #10, #23, #24):** these three files are simple,
single-row `UPDATE platform_modules SET route = '<module>' ...` statements. They are
**not** an automatic schema requirement and must **not** be applied as part of the main
schema deployment pass in §9. Each is a distinct product/release decision, timed to a
specific frontend cutover — see §18 for the gate governing when each may be applied.

---

## 9. Staged deployment plan

The 21 non-route-activation files are grouped into 10 stages, applied strictly in
order. Verification (§10–§16) runs after every individual file, not just at stage
boundaries.

| Stage | Files | Content |
|---|---|---|
| 0 | — | Preflight (§7) |
| 1 | #1 | Platform Module Foundation |
| 2 | #2 | Rooms & Booking Foundation |
| 3 | #3 | Meetings Foundation — **lock-sensitive gate (§17)** |
| 4 | #4, #5 | Meetings Phase A: RSVP, Attendance |
| 5 | #6, #7, #8 | Meetings Phase B: Minutes, Lock, Personal Notes |
| 6 | #9 | Meeting Groups |
| 7 | #11 | Recurring Meetings Phase 1 — **lock-sensitive gate (§17)** |
| 8 | #12 | Recurring Notification Batching |
| 9 | #13 | Draft Meetings |
| 10 | #14–#22 | Recurring Meetings Phase 2 (three lock-sensitive gates within, §17) |
| — | #10, #23, #24 | Route activation — **held for §18, not part of this deployment pass** |

Stage order matches file numbering exactly except that stages 1–9 skip #10 (deferred)
and stage 10 covers #14–#22 contiguously; #23/#24 are likewise deferred past the end
of the schema deployment.

---

## 10. Per-file prerequisites

| # | File | Requires (must already be applied) |
|---|---|---|
| 1 | platform-module-foundation | Legacy baseline only (`organizations`, `users`, `audit_logs`, `notifications`) |
| 2 | rooms-booking-foundation | Legacy baseline; `btree_gist` extension (created by this file itself) |
| 3 | meetings-foundation | #2 (extends `meeting_room_bookings`, its FK to `meetings` is added here) |
| 4 | meetings-rsvp | #3 |
| 5 | meetings-attendance | #3, #4 |
| 6 | meetings-minutes | #3, #4, #5 |
| 7 | meetings-lock | #3, #4, #5, #6 |
| 8 | meetings-personal-notes | #3, #4, #5, #6, #7 |
| 9 | meetings-groups | #3 (`can_manage_meeting()`, `meetings_module_active_for()`, `add_participant()`) |
| 10 | calendar-route-activation | #1 (`platform_modules` row for `calendar`) — **deferred, see §18** |
| 11 | meetings-recurring | #3, #4, #5, #6, #7, #8, #9 |
| 12 | meetings-recurring-notifications | #2 (`submit_booking_request()`, `assign_room_booking()`), #11 (`create_recurring_meeting()`) |
| 13 | meetings-drafts | #3–#9, #11, #12 (redefines `update_meeting()`, `cancel_meeting()`, `add_participant()`, `remove_participant()`, `assign_room_booking()`, `respond_to_invitation()`, `mark_attendance()`, `update_minutes()`, `finalize_minutes()`, `lock_meeting()`) |
| 14 | phase2-series-auth | #11 (`meeting_series`), `security-functions.sql` helpers (already in legacy baseline) |
| 15 | phase2-notification-suppression | #13 (final pre-Phase-2 `update_meeting()`/`cancel_meeting()`), #2/#3/#11 (`reschedule_booking()` chain) |
| 16 | phase2-series-exceptions | #14 (`can_manage_series()` — genuine functional dependency, confirmed by direct read of this file's body; see docs/28 §14) |
| 17 | phase2-update-entire-series | #14, #15 — **lock-sensitive gate (§17)** |
| 18 | phase2-update-series-this-and-future | #14, #15, #17 (delegates to `update_entire_series()` for first-occurrence collapse) — **lock-sensitive gate (§17)** |
| 19 | phase2-preserve-series-membership | #15, #17, #18 (redefines `update_meeting()` signature; redefines bodies of #17/#18's functions) |
| 20 | phase2-cancel-entire-series | `meeting_series.status` (#11), #15, #14, #19-baseline — **lock-sensitive gate (§17)** |
| 21 | phase2-cancel-series-this-and-future | #15, #14, #18 (split-series pattern), #20 (delegates for first-occurrence collapse; reuses its CHECK value) |
| 22 | phase2-audit-visibility | #11 (`meeting_series`), #3 (`can_view_meeting()`) — no dependency on #14–#21 |
| 23 | meetings-route-activation | #1 (`platform_modules` row for `meetings`) — **deferred, see §18** |
| 24 | rooms-route-activation | #1 (`platform_modules` row for `rooms`) — **deferred, see §18** |

---

## 11. Per-file execution command

### Method A — psql

Connect with `ON_ERROR_STOP` enabled:

```
psql "<PRODUCTION_CONNECTION_STRING>" -v ON_ERROR_STOP=1
```

Apply one file at a time, running that file's verification block (§12/§13, and the §17
gate where noted) before the next `\i`. Do not queue multiple `\i` commands in one
paste.

```
\i supabase/patch-platform-module-foundation.sql
\i supabase/patch-rooms-booking-foundation.sql
\i supabase/patch-meetings-foundation.sql
\i supabase/patch-meetings-rsvp.sql
\i supabase/patch-meetings-attendance.sql
\i supabase/patch-meetings-minutes.sql
\i supabase/patch-meetings-lock.sql
\i supabase/patch-meetings-personal-notes.sql
\i supabase/patch-meetings-groups.sql
\i supabase/patch-meetings-recurring.sql
\i supabase/patch-meetings-recurring-notifications.sql
\i supabase/patch-meetings-drafts.sql
\i supabase/patch-meetings-recurring-phase2-series-auth.sql
\i supabase/patch-meetings-recurring-phase2-notification-suppression.sql
\i supabase/patch-meetings-recurring-phase2-series-exceptions.sql
\i supabase/patch-meetings-recurring-phase2-update-entire-series.sql
\i supabase/patch-meetings-recurring-phase2-update-series-this-and-future.sql
\i supabase/patch-meetings-recurring-phase2-preserve-series-membership.sql
\i supabase/patch-meetings-recurring-phase2-cancel-entire-series.sql
\i supabase/patch-meetings-recurring-phase2-cancel-series-this-and-future.sql
\i supabase/patch-meetings-recurring-phase2-audit-visibility.sql
```

Note: this list is 21 lines — files #10, #23, #24 are intentionally absent. They are
executed separately, later, under §18's gate, never in this sequence.

### Method B — Supabase SQL Editor

For each of the 21 files, in order:

1. Open the file from the repository; copy its entire, unmodified contents.
2. Paste into a **new** SQL Editor query tab. Do not combine files or append
   verification queries into the same tab.
3. Run the query. Confirm success (`COMMIT`, no error). A `ROLLBACK` or error means the
   file did not apply — diagnose before any further action.
4. Record the success output in the deployment log (§26).
5. Open a new tab and run that file's verification block (§12/§13) — and, for files #3,
   #11, #17, #18, #20, the lock-sensitive gate (§17) **before** opening the file's own
   tab in step 2.
6. Only after verification passes, proceed to the next file.

---

## 12. Per-file verification query

### #1 platform-module-foundation
```sql
SELECT to_regclass('public.platform_modules'), to_regclass('public.organization_modules');
SELECT module_key, route FROM platform_modules ORDER BY module_key;
-- Expected rows include 'rooms', 'meetings', 'calendar' all with route = NULL at this point.
SELECT proname FROM pg_proc WHERE proname IN
  ('module_enabled_for_org', 'current_user_module_enabled', 'is_module_active');
```

### #2 rooms-booking-foundation
```sql
SELECT to_regclass('public.meeting_rooms'), to_regclass('public.meeting_room_managers'),
       to_regclass('public.meeting_room_blocks'), to_regclass('public.meeting_room_bookings');
SELECT proname, pg_get_function_identity_arguments(oid) FROM pg_proc
WHERE proname IN ('create_booking_hold','submit_booking_request','create_room_booking',
                   'approve_booking','reject_booking','cancel_booking','reschedule_booking',
                   'create_room_block','cancel_room_block','check_room_availability')
ORDER BY proname;
SELECT relrowsecurity FROM pg_class WHERE relname IN
  ('meeting_rooms','meeting_room_managers','meeting_room_blocks','meeting_room_bookings');
-- Expected: all four true.
```

### #3 meetings-foundation
```sql
SELECT to_regclass('public.meetings'), to_regclass('public.meeting_participants');
SELECT proname FROM pg_proc WHERE proname IN
  ('can_view_meeting','can_manage_meeting','create_meeting','update_meeting',
   'cancel_meeting','add_participant','remove_participant','assign_room_booking',
   'detach_room_booking','meetings_module_active_for');
SELECT relrowsecurity FROM pg_class WHERE relname IN ('meetings','meeting_participants');
```

### #4 meetings-rsvp
```sql
SELECT proname, pg_get_function_identity_arguments(oid) FROM pg_proc WHERE proname = 'respond_to_invitation';
SELECT column_name FROM information_schema.columns
WHERE table_name = 'meeting_participants' AND column_name = 'invitation_note';
```

### #5 meetings-attendance
```sql
SELECT proname FROM pg_proc WHERE proname = 'mark_attendance';
SELECT column_name FROM information_schema.columns WHERE table_name = 'meeting_participants'
  AND column_name IN ('attendance_marked_by','attendance_marked_at','attendance_note');
```

### #6 meetings-minutes
```sql
SELECT proname FROM pg_proc WHERE proname IN ('update_minutes','finalize_minutes');
SELECT column_name FROM information_schema.columns WHERE table_name = 'meetings'
  AND column_name IN ('minutes','minutes_finalized','minutes_updated_by','minutes_updated_at');
```

### #7 meetings-lock
```sql
SELECT proname FROM pg_proc WHERE proname IN ('lock_meeting','unlock_meeting','is_meeting_lock_overridable');
SELECT column_name FROM information_schema.columns WHERE table_name = 'meetings'
  AND column_name IN ('is_locked','locked_by','locked_at');
SELECT pg_get_function_identity_arguments(oid) FROM pg_proc WHERE proname = 'update_meeting';
-- Confirm no second overload of update_meeting/cancel_meeting/reschedule_booking/
-- add_participant/remove_participant/assign_room_booking/mark_attendance/
-- update_minutes/finalize_minutes/cancel_booking exists (all redefined here).
SELECT proname, count(*) FROM pg_proc WHERE proname IN
  ('update_meeting','cancel_meeting','reschedule_booking','add_participant',
   'remove_participant','assign_room_booking','mark_attendance','update_minutes',
   'finalize_minutes','cancel_booking')
GROUP BY proname;
-- Expected: count = 1 for every row.
```

### #8 meetings-personal-notes
```sql
SELECT to_regclass('public.meeting_participant_notes');
SELECT proname FROM pg_proc WHERE proname IN ('get_my_notes','update_my_notes');
SELECT relrowsecurity FROM pg_class WHERE relname = 'meeting_participant_notes';
```

### #9 meetings-groups
```sql
SELECT to_regclass('public.meeting_groups'), to_regclass('public.meeting_group_members');
SELECT proname FROM pg_proc WHERE proname IN
  ('create_meeting_group','update_meeting_group','delete_meeting_group',
   'set_group_members','add_group_as_participants');
SELECT relrowsecurity FROM pg_class WHERE relname IN ('meeting_groups','meeting_group_members');
```

### #11 meetings-recurring
```sql
SELECT to_regclass('public.meeting_series'), to_regclass('public.meeting_series_exceptions');
SELECT column_name FROM information_schema.columns WHERE table_name = 'meetings'
  AND column_name IN ('series_id','series_occurrence_date','series_detached','is_placeholder');
SELECT proname FROM pg_proc WHERE proname = 'create_recurring_meeting';
SELECT relrowsecurity FROM pg_class WHERE relname IN ('meeting_series','meeting_series_exceptions');
```

### #12 meetings-recurring-notifications
```sql
SELECT pg_get_function_identity_arguments(oid) LIKE '%p_suppress_notification%' AS has_param
FROM pg_proc WHERE proname = 'submit_booking_request';
SELECT pg_get_function_identity_arguments(oid) LIKE '%p_suppress_notification%' AS has_param
FROM pg_proc WHERE proname = 'assign_room_booking';
SELECT proname, count(*) FROM pg_proc
WHERE proname IN ('submit_booking_request','assign_room_booking','create_recurring_meeting')
GROUP BY proname;
-- Expected: count = 1 for every row.
```

### #13 meetings-drafts
```sql
SELECT proname FROM pg_proc WHERE proname = 'delete_draft_meeting';
SELECT proname, count(*) FROM pg_proc WHERE proname IN
  ('update_meeting','cancel_meeting','add_participant','remove_participant',
   'assign_room_booking','respond_to_invitation','mark_attendance','update_minutes',
   'finalize_minutes','lock_meeting','delete_draft_meeting')
GROUP BY proname;
-- Expected: count = 1 for every row (all redefined here, no stray overload).
```

### #14–#22 (Recurring Meetings Phase 2)
See §15 (CHECK constraints) and §14 (function overloads) for the consolidated
per-function verification — these nine files are individually verified using the same
per-patch blocks already established for this chain: confirm the named function exists
with exactly one overload, confirm the expected new parameter/CHECK value is present,
and confirm no prior value or overload was lost (strict superset). Key checks:

```sql
-- #14 series-auth
SELECT proname, pg_get_function_identity_arguments(oid) FROM pg_proc WHERE proname = 'can_manage_series';

-- #15 notification-suppression
SELECT proname, pg_get_function_identity_arguments(oid) LIKE '%p_suppress_notification%' AS has_param
FROM pg_proc WHERE proname IN ('update_meeting','cancel_meeting','reschedule_booking');

-- #16 series-exceptions
SELECT proname FROM pg_proc WHERE proname = 'create_series_exception';
SELECT pg_get_functiondef('create_series_exception'::regproc) LIKE '%can_manage_series%' AS calls_can_manage_series;

-- #17 update-entire-series
SELECT proname FROM pg_proc WHERE proname = 'update_entire_series';
SELECT pg_get_constraintdef(oid) LIKE '%meeting_series_updated%' FROM pg_constraint WHERE conname = 'audit_logs_action_check';

-- #18 update-series-this-and-future
SELECT proname FROM pg_proc WHERE proname = 'update_series_this_and_future';
SELECT pg_get_constraintdef(oid) LIKE '%meeting_series_split%' FROM pg_constraint WHERE conname = 'audit_logs_action_check';

-- #19 preserve-series-membership
SELECT pg_get_function_identity_arguments(oid) LIKE '%p_preserve_series_membership%' AS has_param
FROM pg_proc WHERE proname = 'update_meeting';

-- #20 cancel-entire-series
SELECT proname FROM pg_proc WHERE proname = 'cancel_entire_series';
SELECT pg_get_constraintdef(oid) LIKE '%meeting_series_cancelled%' FROM pg_constraint WHERE conname = 'audit_logs_action_check';

-- #21 cancel-series-this-and-future
SELECT proname FROM pg_proc WHERE proname = 'cancel_series_this_and_future';
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_action_check';
-- Confirm identical to the #20 snapshot — this file must not add a new value.

-- #22 audit-visibility
SELECT pg_get_functiondef('can_view_case_audit_record'::regproc) LIKE '%meeting_series%' AS has_branch;
```

---

## 13. Matching validate-*.sql usage where available

| # | File | Matching validate-*.sql | Usage |
|---|---|---|---|
| 1 | platform-module-foundation | `validate-platform-module-foundation.sql` | Run via `\i` immediately after the patch, before proceeding |
| 2 | rooms-booking-foundation | `validate-rooms-booking-foundation.sql` | Same |
| 3 | meetings-foundation | `validate-meetings-foundation.sql` | Same |
| 4 | meetings-rsvp | `validate-meetings-rsvp.sql` | Same |
| 5 | meetings-attendance | `validate-meetings-attendance.sql` | Same |
| 6 | meetings-minutes | `validate-meetings-minutes.sql` | Same |
| 7 | meetings-lock | `validate-meetings-lock.sql` | Same |
| 8 | meetings-personal-notes | `validate-meetings-personal-notes.sql` | Same |
| 9 | meetings-groups | `validate-meetings-groups.sql` | Same |
| 10 | calendar-route-activation | none | Deferred file — not applicable in this pass |
| 11 | meetings-recurring | `validate-meetings-recurring.sql` | Run via `\i` immediately after the patch |
| 12 | meetings-recurring-notifications | `validate-meetings-recurring-notifications.sql` | Same |
| 13 | meetings-drafts | `validate-meetings-drafts.sql` | Same |
| 14 | phase2-series-auth | `validate-meetings-recurring-phase2-series-auth.sql` | Same |
| 15 | phase2-notification-suppression | `validate-meetings-recurring-phase2-notification-suppression.sql` | Same |
| 16 | phase2-series-exceptions | `validate-meetings-recurring-phase2-series-exceptions.sql` | Same |
| 17 | phase2-update-entire-series | `validate-meetings-recurring-phase2-update-entire-series.sql` | Same |
| 18 | phase2-update-series-this-and-future | `validate-meetings-recurring-phase2-update-series-this-and-future.sql` | Same |
| 19 | phase2-preserve-series-membership | `validate-meetings-recurring-phase2-preserve-series-membership.sql` | Same |
| 20 | phase2-cancel-entire-series | `validate-meetings-recurring-phase2-cancel-entire-series.sql` | Same |
| 21 | phase2-cancel-series-this-and-future | `validate-meetings-recurring-phase2-cancel-series-this-and-future.sql` | Same |
| 22 | phase2-audit-visibility | none | No matching validate script exists in the repository — rely on §12's manual verification query and the smoke test (§20) for this file |
| 23 | meetings-route-activation | none | Deferred file — not applicable in this pass |
| 24 | rooms-route-activation | none | Deferred file — not applicable in this pass |

19 of the 21 in-scope files have a matching `validate-*.sql` script; run each
immediately after its corresponding patch, in the same session, before proceeding to
the next file. Files #22 has no matching script — its §12 query and the smoke test
carry the full verification burden for that file.

---

## 14. Function overload verification

Run after every file that creates or redefines a function (essentially all of #1–#22),
and again as part of §19's final pass:

```sql
SELECT proname, count(*) AS overload_count, array_agg(pg_get_function_identity_arguments(oid)) AS all_args
FROM pg_proc
WHERE proname IN (
  -- Foundation
  'module_enabled_for_org','current_user_module_enabled','is_module_active',
  'create_booking_hold','submit_booking_request','create_room_booking','approve_booking',
  'reject_booking','cancel_booking','reschedule_booking','create_room_block',
  'cancel_room_block','check_room_availability',
  'can_view_meeting','can_manage_meeting','create_meeting','update_meeting',
  'cancel_meeting','add_participant','remove_participant','assign_room_booking',
  'detach_room_booking',
  -- Phase A/B/E
  'respond_to_invitation','mark_attendance','update_minutes','finalize_minutes',
  'lock_meeting','unlock_meeting','get_my_notes','update_my_notes',
  'create_meeting_group','update_meeting_group','delete_meeting_group',
  'set_group_members','add_group_as_participants',
  -- Recurring Phase 1 / notifications / drafts
  'create_recurring_meeting','delete_draft_meeting',
  -- Recurring Phase 2
  'can_manage_series','create_series_exception','update_entire_series',
  'update_series_this_and_future','cancel_entire_series','cancel_series_this_and_future',
  -- Cross-cutting
  'can_view_case_audit_record'
)
GROUP BY proname
ORDER BY proname;
```

Pass criteria: `overload_count = 1` for every row. Any row with `overload_count > 1` is
a **stop condition** (§24) — it means a `DROP FUNCTION` that should have removed a
prior signature did not run, or ran against the wrong signature.

---

## 15. CHECK-constraint verification

Files that extend `audit_logs.action`, `audit_logs.record_type`,
`notifications.type`, `attachments.record_type`, `meeting_room_bookings` (exclusion
constraint), `meeting_participants` (attendance pairing), or `meetings` (minutes/lock
alignment) via `DROP CONSTRAINT` / `ADD CONSTRAINT`: #2, #3, #4, #5, #6, #7, #9, #11,
#12, #13, #17, #18, #20.

```sql
SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
WHERE conname IN (
  'audit_logs_action_check', 'audit_logs_record_type_check', 'notifications_type_check',
  'attachments_record_type_check', 'meeting_room_bookings_no_overlap',
  'meeting_participants_attendance_marked_pair_check',
  'meetings_minutes_finalized_requires_minutes_check', 'meetings_lock_alignment_check'
);
```

Pass criteria for `audit_logs_action_check` / `notifications_type_check` /
`audit_logs_record_type_check` / `attachments_record_type_check` specifically: each
successive file's constraint definition must be a **strict superset** of the
definition captured after the previous file that touched it — compare against the §7
baseline and each prior verification step's captured output. No value is ever removed
across this entire 24-file chain (confirmed monotonically additive by direct file
inspection). Any missing prior value is a **stop condition** (§24).

Final expected state after file #22 for `audit_logs.action` includes (among the
legacy baseline values) at minimum: `meeting_created`-equivalent meeting lifecycle
actions from #3 onward, `meeting_locked`/`meeting_unlocked` (#7), `meeting_group_*`
(#9), `meeting_series_created`/`meeting_draft_deleted` (#11/#13),
`meeting_series_updated` (#17), `meeting_series_split` (#18), `meeting_series_cancelled`
(#20). Final expected state for `notifications.type` includes the equivalent
`meeting_*`/`booking_*`/`recurring_booking_submitted`/`meeting_series_*` values.

---

## 16. RLS verification

```sql
SELECT relname, relrowsecurity FROM pg_class
WHERE relname IN (
  'platform_modules', 'organization_modules',
  'meeting_rooms', 'meeting_room_managers', 'meeting_room_blocks', 'meeting_room_bookings',
  'meetings', 'meeting_participants', 'meeting_participant_notes',
  'meeting_groups', 'meeting_group_members',
  'meeting_series', 'meeting_series_exceptions'
);
-- Expected: relrowsecurity = true for every row, immediately after the file that
-- creates each table (§10 identifies which file creates which table).
```

Run this query as part of the verification for every file in §12 that creates a new
table (#1, #2, #3, #8, #9, #11), not only at the end — a table briefly existing without
RLS enabled between its `CREATE TABLE` and its own file's `ENABLE ROW LEVEL SECURITY`
statement is expected only within that single file's own transaction, never observable
between files since each file's `BEGIN…COMMIT` is atomic.

---

## 17. Lock-sensitive patch gates

Mandatory blocking-session and transaction checks immediately before these five files,
each of which performs `DROP CONSTRAINT` / `ADD CONSTRAINT` on `audit_logs` and/or
`notifications` (an `ACCESS EXCLUSIVE` lock plus a full table scan to revalidate
existing rows):

- **#3** `patch-meetings-foundation.sql`
- **#11** `patch-meetings-recurring.sql`
- **#17** `patch-meetings-recurring-phase2-update-entire-series.sql`
- **#18** `patch-meetings-recurring-phase2-update-series-this-and-future.sql`
- **#20** `patch-meetings-recurring-phase2-cancel-entire-series.sql`

(Several other files in this chain — #2, #4, #5, #6, #7, #9, #12, #13 — also touch one
or both of these CHECK constraints, but do so earlier in the deployment while
`audit_logs`/`notifications` are still at or near the legacy-baseline row count; the
five files above are called out as mandatory full gates because they occur at points
in the chain, or on tables, judged to carry the most realistic blocking risk. Running
the same gate queries before any of the other CHECK-touching files is not prohibited
and is good practice if time allows, but is not mandatory.)

Run immediately before each of the five files:

```sql
-- Table size (re-check; compare against §7 baseline)
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

-- Long-running transactions (older than 5 minutes)
SELECT pid, usename, xact_start, now() - xact_start AS duration, query
FROM pg_stat_activity
WHERE datname = current_database() AND xact_start IS NOT NULL
  AND now() - xact_start > interval '5 minutes';

-- Blocked and blocking sessions right now
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

Gate checklist (repeat before each of #3, #11, #17, #18, #20):

- [ ] Table size reviewed; no unexpected growth since the §7 baseline or the previous gate
- [ ] No long-running transaction holds a conflicting lock on `audit_logs` or `notifications`
- [ ] No session is currently blocked on either table
- [ ] Operator confirms the estimated lock window is acceptable for this specific file —
      **#3 gate: `<INITIALS>`** / **#11 gate: `<INITIALS>`** / **#17 gate: `<INITIALS>`**
      / **#18 gate: `<INITIALS>`** / **#20 gate: `<INITIALS>`**
- [ ] **Stop condition:** if the estimated lock window is unacceptable, or a
      long-running transaction or blocking session is present, stop this file and
      reschedule — do not force the `ALTER TABLE` through.

---

## 18. Route-activation decision gate

**Files #10 (`patch-calendar-route-activation.sql`), #23
(`patch-meetings-route-activation.sql`), and #24 (`patch-rooms-route-activation.sql`)
are not applied as part of the schema deployment in §9.** Each is a one-line
`UPDATE platform_modules SET route = '<module>' WHERE module_key = '<module>' ...`
statement that makes the corresponding frontend route reachable — activating them
early, before the frontend release they belong to, produces no schema risk but does
not accomplish anything useful and skips this runbook's own separation of "schema is
present" from "route is reachable."

- **File #10 (calendar) requires a separate product decision**, independent of this
  deployment. Calendar staying inactive during initial production deployment is an
  accepted, deliberate state, not a defect — consistent with the confirmed staging
  state in §1/§3. Do not apply #10 until that separate product decision is made and
  explicitly recorded, regardless of how the rest of this deployment goes.
- **File #23 (meetings) and file #24 (rooms)** should only be applied **immediately
  before frontend cutover** for their respective modules — i.e., timed to the actual
  frontend release, not to the completion of the SQL chain in §9. Applying #23/#24
  early would make the Meetings/Rooms modules reachable in the Admin "Modules" tab and
  toggleable per-organization before the frontend is confirmed live, which is an
  avoidable exposure window even though the underlying tables/RPCs are otherwise
  correct and safe.
- **Route activation must be verified against the intended frontend release** before
  each of #23/#24 is applied: confirm the frontend build being deployed actually
  contains the corresponding view/router wiring (`js/views/meetings.js` +
  `js/router.js` entries for #23; `js/views/rooms.js` + router entries for #24) before
  flipping the route, not after.

Gate checklist (repeat independently for each of #10, #23, #24, at the time each is
actually scheduled — not at the end of §9):

- [ ] Product/release decision to activate this route has been explicitly made and recorded
- [ ] The corresponding frontend build has been confirmed to contain the matching view/router code
- [ ] File applied: `\i supabase/patch-<module>-route-activation.sql`
- [ ] Post-application check:
  ```sql
  SELECT module_key, route FROM platform_modules WHERE module_key IN ('calendar','meetings','rooms');
  ```

---

## 19. Final schema verification

Run after all 21 non-deferred files (§9 stages 1–10) have individually passed
verification.

```sql
-- All Phase 2 RPCs exist with exactly one intended overload each
SELECT proname, count(*) AS overload_count
FROM pg_proc
WHERE proname IN ('can_manage_series','create_series_exception','update_entire_series',
                   'update_series_this_and_future','cancel_entire_series',
                   'cancel_series_this_and_future')
GROUP BY proname ORDER BY proname;
-- Pass: overload_count = 1, six rows.
```

```sql
-- Full parameter/CHECK/branch verification (mirrors §14/§15's queries, run once more as a final pass)
SELECT pg_get_function_identity_arguments(oid) LIKE '%p_suppress_notification%' AS has_param
FROM pg_proc WHERE proname IN ('update_meeting','cancel_meeting','reschedule_booking');

SELECT pg_get_function_identity_arguments(oid) LIKE '%p_preserve_series_membership%' AS has_param
FROM pg_proc WHERE proname = 'update_meeting';

SELECT pg_get_constraintdef(oid) AS audit_logs_action_check FROM pg_constraint WHERE conname = 'audit_logs_action_check';
SELECT pg_get_constraintdef(oid) AS notifications_type_check FROM pg_constraint WHERE conname = 'notifications_type_check';
-- Pass: both contain 'meeting_series_updated', 'meeting_series_split',
-- 'meeting_series_cancelled', AND every legacy-baseline value from §7 is still present.

SELECT pg_get_functiondef('can_view_case_audit_record'::regproc) LIKE '%meeting_series%' AS has_branch;
```

```sql
-- RLS remains enabled on every table this deployment created
SELECT relname, relrowsecurity FROM pg_class
WHERE relname IN (
  'platform_modules','organization_modules','meeting_rooms','meeting_room_managers',
  'meeting_room_blocks','meeting_room_bookings','meetings','meeting_participants',
  'meeting_participant_notes','meeting_groups','meeting_group_members',
  'meeting_series','meeting_series_exceptions'
);
-- Pass: relrowsecurity = true for every row.
```

```sql
-- No unexpected schema drift: full function inventory for a final diff against
-- the running deployment log
SELECT proname, pg_get_function_identity_arguments(oid) AS args
FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
  AND proname ~ '(meeting|room|booking|series|group|attendance|minutes|lock|notes|draft)'
ORDER BY proname, args;
```

---

## 20. Production smoke-test plan

Perform every step through the CorLink application UI, using approved disposable test
data and approved test accounts only — never real production case/meeting data.

- [ ] Platform module foundation: confirm the Admin Modules tab shows Rooms/Meetings/
      Calendar as schema-present, org-enable toggle still disabled until route
      activation (§18) — confirms Layer 1/Layer 2 separation works before any route is live
- [ ] Room creation and booking: create a room, submit a booking request, approve it,
      confirm conflict prevention rejects an overlapping booking
- [ ] Meeting creation: create a standalone (non-recurring) meeting
- [ ] RSVP: respond to an invitation as a participant
- [ ] Attendance: mark attendance as a meeting manager
- [ ] Minutes: update and finalize meeting minutes
- [ ] Locking: lock a meeting, confirm an ordinary staff member cannot override, confirm
      the documented override tiers (creator, org admin, super admin) behave correctly
- [ ] Personal notes: write a personal note as one participant, confirm another
      participant cannot see it
- [ ] Meeting groups: create a group, add members, apply the group as meeting participants
- [ ] Drafts: create a draft meeting, confirm RSVP/attendance/minutes/lock are blocked
      on it per the documented draft restrictions, promote it to scheduled
- [ ] Recurring meeting creation: create a weekly/biweekly/monthly series
- [ ] Notification batching: submit a recurring series requiring room approval, confirm
      exactly one consolidated notification reaches each relevant room manager (not one
      per occurrence)
- [ ] Entire Series update: confirm the change applies to all eligible occurrences with
      one consolidated notification/audit entry
- [ ] This and Future update: confirm the series splits correctly, earlier occurrences
      unaffected, one consolidated notification/audit entry
- [ ] Entire Series cancellation (on a separate test series): confirm the series is
      marked cancelled and further mutating actions against it are rejected
- [ ] This and Future cancellation: confirm eligible future occurrences are cancelled,
      lifecycle-excluded occurrences correctly skipped and reported
- [ ] Series exceptions: create a skip/modify exception, confirm it does not affect
      other occurrences
- [ ] Single-meeting regression behavior: confirm a meeting with no series association
      still edits/cancels exactly as before this deployment — no regression in the
      non-recurring path

Test data cleanup: cancel or archive all disposable test data **through the
application's normal cancellation/archival workflows only** — no direct
`DELETE`/`UPDATE` SQL against production data as cleanup.

---

## 21. Multi-persona authorization test plan

This is the gate that closes §3 item 2 — it is a **required production-readiness/UAT
step**, distinct from and not satisfied by the deployment or the smoke test above.
Requires real, distinct accounts (not shared logins) for each of the following seven
personas, run specifically against `can_view_case_audit_record()`'s `meeting_series`
branch (file #22) and, where relevant, against the Phase 2 RPCs' own `can_manage_series()`
authorization (files #14–#21):

| Persona | Tested on staging? | Production/UAT status |
|---|---|---|
| Super admin | Yes (creator/super-admin persona per §2) | Re-confirm in production UAT |
| Series creator | Yes (per §2) | Re-confirm in production UAT |
| Same-organization supervisor | **No** | **Required — not yet tested anywhere** |
| Authorized participant (visible occurrence, not creator/supervisor) | **No** | **Required — not yet tested anywhere** |
| Unauthorized same-organization user (no relationship to the series) | **No** | **Required — not yet tested anywhere** |
| Cross-organization user | **No** | **Required — not yet tested anywhere** |
| Anonymous / unauthenticated caller | Yes (per §2) | Re-confirm in production UAT |

For each of the four "Required" personas: confirm the persona **can** perform the
actions the design intends (e.g., a same-org supervisor can view the series' audit
trail; an authorized participant can view a series they have a visible occurrence in)
and, separately, confirm the negative case where the design intends denial (e.g., an
unauthorized same-org user cannot view an unrelated series' audit trail; a
cross-organization user cannot view the series or its audit trail at all, full stop).

**This table must remain in this form — populated with real results, not left as
placeholders — before §27's go/no-go can cite "ready for production" without a
carried-forward gap.** Until it is complete, any go/no-go conclusion must say "ready
with prerequisites," naming this gate explicitly (see §27).

---

## 22. Frontend deployment gate

Frontend deployment and Cloudflare configuration are explicitly **out of scope for
this SQL runbook** and are not authorized by any step above. Do not deploy the
frontend or touch Cloudflare configuration based on this document alone. The frontend
deployment gate specifically requires, in addition to everything above:

- [ ] §19's final schema verification passed in full
- [ ] §20's production smoke test passed in full
- [ ] §21's multi-persona authorization test plan completed in full (all seven
      personas, not just the three tested on staging)
- [ ] File #23 (`meetings-route-activation`) and/or #24 (`rooms-route-activation`)
      applied per §18's gate, matched to the specific frontend release being deployed
- [ ] A separate, explicit sign-off for frontend deployment specifically (this
      document's §26 sign-off covers the database deployment; frontend deployment is
      its own gated action, not implied by database sign-off)

---

## 23. Monitoring plan

During and immediately after the deployment window:

- Watch application error rates (via existing CorLink error monitoring / Supabase
  dashboard logs) for the duration of the deployment and at least 24 hours after —
  any elevated rate correlated with a specific file's application timestamp is a
  signal to investigate that file first.
- Watch `pg_stat_activity` for unexpected long-running queries or lock waits in the
  hour following each of the five lock-sensitive gates (§17), not only during the gate
  itself — a constraint validation completing does not guarantee no residual
  contention.
- Watch notification delivery volume after #12 (recurring-notifications) and the
  Phase 2 files (#17, #18, #20, #21) specifically for the consolidated-vs-per-occurrence
  distinction called out in §24 — a spike in per-meeting-shaped notification counts
  immediately after any of these files is a regression signal, not noise.
- Watch audit log write volume and `record_type` distribution after #22
  (audit-visibility) — this file changes only a SELECT-side authorization function
  and should produce zero change in write volume or shape; any write-side change
  correlated with #22 is unexpected and should be investigated.

---

## 24. Stop conditions

Stop immediately — do not apply the next file, do not proceed to the next section — if:

- Any file's SQL execution returns an error, or its transaction does not show a clean `COMMIT`.
- Any verification query in §12, §14, §15, §16, §17, or §19 fails its stated pass criteria.
- An unexpected function overload appears (§14).
- An expected dependency is found missing (§10).
- A CHECK constraint contains a value not accounted for in this runbook, or is missing
  a value a prior file in this same deployment added (§15).
- Blocking or lock waits during a §17 gate are judged unsafe.
- Application error rates rise during or immediately after a file (§23).
- Audit visibility (file #22, or the multi-persona test in §21) is broader than
  intended — e.g. a cross-organization or unauthorized-user check unexpectedly succeeds.
- Notification behavior becomes per-occurrence instead of the documented single
  consolidated notification per bulk action (files #12, #17, #18, #20, #21).
- A target object that §7 expected to be absent is found already present (production
  is not at the assumed clean baseline).
- Any route-activation file (§18) is about to be applied without its corresponding
  product decision or frontend-build confirmation checked off.

On any stop condition: halt execution, notify the rollback authority (§4) and
application support contacts (§4), and do not attempt remediation SQL without
following §25.

---

## 25. Rollback strategy

Because production begins this deployment with **none** of the target schema present
(§1, §7), rollback for files #1–#13, #22, #23, #24 is structurally simple: each creates
objects that did not exist before, so a targeted rollback is `DROP FUNCTION` /
`DROP TABLE` / `ALTER TABLE ... DROP COLUMN` / constraint reversion for exactly the
objects that specific file created, in reverse dependency order. There is no prior
function body to restore for these files — there was nothing there before.

Files #14–#21 (Recurring Meetings Phase 2) redefine functions created earlier **in this
same deployment** (by #3, #11, #13, or by #14–#20 themselves):

- **New functions with no prior definition** (#14, #16, #17, #18, #20, #21):
  `DROP FUNCTION <name>(<exact argument list>);` in reverse order (drop #21 before #20,
  #18 before #17, anything calling `can_manage_series` before dropping #14 itself).
- **Redefined functions with a prior definition from earlier in this deployment**
  (#19's redefinition of #17/#18's function bodies; #22's `CREATE OR REPLACE` of the
  `can_view_case_audit_record()` created by the legacy baseline's `rls.sql`): restore
  using `pg_get_functiondef()` captured immediately before applying #19 or #22
  respectively — capture this snapshot as part of that file's own verification step,
  not only at the very start of the deployment.
- **Signature-changing functions** (#15's `update_meeting()`/`cancel_meeting()`/
  `reschedule_booking()`; #19's `update_meeting()`): the new-signature function must be
  dropped with its exact new argument list, then the prior-signature function recreated
  from a captured snapshot. Because PostgREST/Supabase RPC calls resolve by named
  argument, confirm no in-flight application traffic depends on the new parameter
  before doing this.
- **CHECK-constraint changes** (#2, #3, #4, #5, #6, #7, #9, #11, #12, #13, #17, #18,
  #20): reverting means dropping and re-adding the narrower, pre-file list. **This is
  safe only if no row has yet been written with the newly added value.** Once any
  corresponding RPC has actually run against real or test data — including during the
  smoke test in §20 — narrowing the constraint will fail until those rows are found and
  remediated, and remediating audit/notification history is itself a data-altering
  action requiring its own explicit approval. Treat every CHECK-constraint addition in
  this chain as effectively one-way once its corresponding RPC has been exercised.

**When to use PITR / full backup restore instead of targeted rollback:** if more than
one file must be reverted, if the exact scope of a failure is unclear, if any
CHECK-constraint value has already been written to a row, or if targeted rollback
itself fails partway — stop attempting targeted SQL rollback and restore from the
pre-deployment checkpoint (§5) instead. Given this deployment starts from a clean
baseline, a full restore to the pre-deployment checkpoint is a comparatively low-risk
option at any point before real (non-test) production data begins flowing through the
new modules.

**Approval requirement:** no rollback action — targeted SQL or full restore — may be
executed without explicit sign-off from the rollback authority named in §4, following
the organization's incident/change-authority process. This runbook does not itself
constitute that approval.

---

## 26. Deployment log

| Step | File | Start time | End time | Result | Verification result | Operator initials | Notes |
|---|---|---|---|---|---|---|---|
| 0 | Approvals (§4) | | | | | | |
| 0 | Backup/PITR checkpoint (§5) | | | | | | |
| 0 | Maintenance window (§6) | | | | | | |
| 0 | Preflight (§7) | | | | | | |
| 1 | platform-module-foundation | | | | | | |
| 2 | rooms-booking-foundation | | | | | | |
| — | Lock gate before #3 (§17) | | | | | | |
| 3 | meetings-foundation | | | | | | |
| 4 | meetings-rsvp | | | | | | |
| 5 | meetings-attendance | | | | | | |
| 6 | meetings-minutes | | | | | | |
| 7 | meetings-lock | | | | | | |
| 8 | meetings-personal-notes | | | | | | |
| 9 | meetings-groups | | | | | | |
| — | Lock gate before #11 (§17) | | | | | | |
| 11 | meetings-recurring | | | | | | |
| 12 | meetings-recurring-notifications | | | | | | |
| 13 | meetings-drafts | | | | | | |
| 14 | phase2-series-auth | | | | | | |
| 15 | phase2-notification-suppression | | | | | | |
| 16 | phase2-series-exceptions | | | | | | |
| — | Lock gate before #17 (§17) | | | | | | |
| 17 | phase2-update-entire-series | | | | | | |
| — | Lock gate before #18 (§17) | | | | | | |
| 18 | phase2-update-series-this-and-future | | | | | | |
| 19 | phase2-preserve-series-membership | | | | | | |
| — | Lock gate before #20 (§17) | | | | | | |
| 20 | phase2-cancel-entire-series | | | | | | |
| 21 | phase2-cancel-series-this-and-future | | | | | | |
| 22 | phase2-audit-visibility | | | | | | |
| — | Final schema verification (§19) | | | | | | |
| — | Smoke test (§20) | | | | | | |
| — | Multi-persona UAT (§21) | | | | | | |
| — | Route activation #10 (calendar, if/when decided — §18) | | | | | | |
| — | Route activation #23 (meetings, at cutover — §18) | | | | | | |
| — | Route activation #24 (rooms, at cutover — §18) | | | | | | |

---

## 27. Sign-off

- [ ] Database deployment complete (21 non-deferred files applied and verified, §9–§19)
- [ ] Production smoke test complete (§20, all steps passed)
- [ ] Multi-persona authorization test plan complete (§21, all seven personas —
      **not** merely the three carried forward from staging)
- [ ] Route activation decisions recorded separately for #10, #23, #24 (§18) — not
      implied by database sign-off
- [ ] Frontend deployment authorized: yes / no (§22 gate)
- [ ] Rollback not required / rollback executed *(strike whichever does not apply; if
      executed, attach incident/change-authority approval reference)*

**This runbook does not itself claim production readiness.** Per §21, until the
multi-persona authorization test plan is complete with real results, the correct
conclusion for this deployment is **"Ready with prerequisites"** — the database
migration chain (§8–§19) is fully specified and verifiable, but sign-off is not
complete until §20 and §21 are executed against production with recorded results, and
§18's route-activation decisions are made separately from the database deployment
itself.

Operator signature: `______________________`  Date/time: `______________________`

Reviewer signature: `______________________`  Date/time: `______________________`
