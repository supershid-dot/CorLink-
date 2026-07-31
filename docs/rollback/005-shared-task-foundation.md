# Rollback — 005: Shared Task Foundation

Companion to `docs/32-shared-task-foundation.md`. Explains how to undo
`supabase/patch-shared-task-foundation.sql` if it needs to be reversed
after being applied. As of this document's creation, the migration has
**not** been applied to any Supabase project — it has only been
applied to, and tested against, a local disposable PostgreSQL instance
built by replaying the full existing migration chain plus
`patch-security-definer-search-path-hardening.sql`.

This rollback is scoped narrowly to what this milestone actually
created: 5 new tables (`tasks`, `task_assignments`, `task_watchers`,
`task_comments`, `task_number_sequences`), their triggers/indexes/
constraints, 15 new functions (11 RPCs + `can_view_task()` +
`generate_task_number()` + the status-transition allow-list function +
its trigger function), 4 new RLS policies, and 3 extended CHECK
constraints (`audit_logs.record_type`, `audit_logs.action`,
`notifications.type`). It does not touch `organizations`, `users`,
`user_assignments`, `sections`, `requests`, `meetings`, or any other
pre-existing CorLink table — none of those are written to by this
migration, and no existing function, policy, or RPC was altered.

---

## 1. Prerequisite check (must pass before running §2)

The CHECK-constraint reversion step in §2 restores `audit_logs.
record_type`, `audit_logs.action`, and `notifications.type` to their
pre-R3 definitions (i.e. exactly as
`patch-security-definer-search-path-hardening.sql` left them) — which
no longer include `'task'`, `'completed'`, `'commented'`,
`'task_assigned'`, `'task_completed'`, `'task_comment_added'`.
Postgres validates every existing row against a new `CHECK` constraint
at the moment it's added, so **this step fails outright if any live
row still carries one of those values** — confirmed directly during
local testing (see §4).

Before running §2, confirm this returns zero rows for all three:

```sql
SELECT id, record_type FROM audit_logs WHERE record_type = 'task';
SELECT id, action FROM audit_logs WHERE action IN ('completed', 'commented');
SELECT id, type FROM notifications WHERE type IN ('task_assigned', 'task_completed', 'task_comment_added');
```

If any rows are returned, either delete them (acceptable if this
rollback is happening because the whole milestone is being abandoned,
since the 5 tables those rows reference are about to be dropped in §2
step 5 anyway) or reconsider whether a full rollback is really
appropriate — the presence of these rows means Tasks has real,
referenced audit/notification history.

## 2. Remove the new database objects safely

Run as a superuser/service-role connection, in this exact order —
every dependent object before the thing it depends on:

```sql
BEGIN;

-- 1. Drop the 11 RPCs.
DROP FUNCTION IF EXISTS create_task(UUID, TEXT, TEXT, UUID, TEXT, TEXT, DATE, DATE);
DROP FUNCTION IF EXISTS update_task(UUID, TEXT, TEXT, TEXT, TEXT, DATE, DATE, UUID, TEXT);
DROP FUNCTION IF EXISTS cancel_task(UUID, TEXT);
DROP FUNCTION IF EXISTS complete_task(UUID, TEXT);
DROP FUNCTION IF EXISTS assign_task(UUID, UUID);
DROP FUNCTION IF EXISTS unassign_task(UUID, UUID);
DROP FUNCTION IF EXISTS watch_task(UUID);
DROP FUNCTION IF EXISTS unwatch_task(UUID);
DROP FUNCTION IF EXISTS add_task_comment(UUID, TEXT);
DROP FUNCTION IF EXISTS get_task(UUID);
DROP FUNCTION IF EXISTS list_tasks(UUID, UUID, TEXT, BOOLEAN, INTEGER);

-- 2. Drop RLS policies on the 4 RLS-bearing tables.
DROP POLICY IF EXISTS "tasks_select" ON tasks;
DROP POLICY IF EXISTS "task_assignments_select" ON task_assignments;
DROP POLICY IF EXISTS "task_watchers_select" ON task_watchers;
DROP POLICY IF EXISTS "task_comments_select" ON task_comments;

-- 3. Drop triggers on tasks and their functions.
DROP TRIGGER IF EXISTS set_updated_at ON tasks;
DROP TRIGGER IF EXISTS task_status_transition ON tasks;
DROP FUNCTION IF EXISTS trigger_check_task_status();
DROP FUNCTION IF EXISTS valid_task_status_transition(TEXT, TEXT);

-- 4. Revert the CHECK-constraint extensions to their pre-R3 definitions.
--    Fails here if §1's prerequisite check was skipped and a live row
--    still uses a new value.
ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_record_type_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_record_type_check
  CHECK (record_type IN (
    'request', 'response', 'internal_request', 'prisoner_letter', 'deadline_extension',
    'user', 'organization', 'section', 'session', 'attachment', 'external_correspondence',
    'meeting_room', 'meeting_room_block', 'meeting_room_booking', 'meeting', 'meeting_group', 'meeting_series'
  ));

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_action_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_action_check
  CHECK (action IN (
    'created', 'edited', 'submitted', 'approved', 'returned',
    'sent', 'received', 'routed', 'assigned', 'returned_to_sender', 'cancelled',
    'extension_requested', 'extension_approved', 'extension_denied',
    'viewed', 'login', 'logout', 'login_failed', 'locked',
    'password_changed', 'user_created', 'user_deactivated',
    'rejected', 'rescheduled', 'conflict_overridden', 'unassigned',
    'participant_added', 'participant_removed', 'attachment_added', 'attachment_removed',
    'invitation_responded', 'attendance_marked', 'minutes_updated', 'minutes_finalized',
    'meeting_locked', 'meeting_unlocked', 'meeting_group_created', 'meeting_group_updated',
    'meeting_group_deleted', 'meeting_group_members_updated', 'meeting_series_created',
    'meeting_draft_deleted', 'meeting_series_updated', 'meeting_series_split', 'meeting_series_cancelled'
  ));

ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
  CHECK (type IN (
    'new_request', 'new_response', 'approval_requested', 'draft_returned',
    'deadline_warning', 'extension_requested', 'extension_decided',
    'new_prisoner_letter', 'letter_replied',
    'new_external_correspondence', 'external_correspondence_replied',
    'request_cancelled',
    'booking_submitted', 'booking_approved', 'booking_rejected',
    'booking_cancelled', 'booking_changed', 'booking_conflict_attention',
    'meeting_created', 'participant_added', 'meeting_updated', 'room_assigned',
    'meeting_cancelled', 'participant_removed', 'participant_responded',
    'meeting_series_created', 'recurring_booking_submitted', 'meeting_series_updated',
    'meeting_series_split', 'meeting_series_cancelled'
  ));

-- 5. Drop the 4 dependent tables, then the numbering table.
DROP TABLE IF EXISTS task_comments;
DROP TABLE IF EXISTS task_watchers;
DROP TABLE IF EXISTS task_assignments;
DROP TABLE IF EXISTS tasks;
DROP TABLE IF EXISTS task_number_sequences;

-- 6. Drop remaining standalone helper functions — after the tables so
--    no RLS policy/trigger still references them.
DROP FUNCTION IF EXISTS can_view_task(UUID);
DROP FUNCTION IF EXISTS generate_task_number(UUID);

COMMIT;
```

**This is safe and non-destructive to the rest of CorLink**: every
dropped object is exclusively new and exclusively created by this
milestone. No pre-existing table, function, policy, or RPC references
any of these tables/functions — Tasks was built with zero references
out to `requests`/`internal_requests`/`meetings`/
`external_correspondence`/`prisoner_letters` by design (see docs/32),
so there is no cross-module dependency to worry about in either
direction.

**Do not** run any broader statement (`DROP SCHEMA`, `TRUNCATE` on any
pre-existing table, or anything wildcard-based) to accomplish this
rollback — the explicit list above is the entire footprint of this
milestone.

## 3. No separate follow-on step needed

Unlike Rooms (which had a room-manager grant table with its own
optional cleanup note), every object this milestone created is dropped
in §2 — there is nothing left over.

## 4. What was actually tested (this session, local Postgres only)

- **Prerequisite failure confirmed real**, not just documented: with
  live test data present (4 `audit_logs` rows carrying
  `record_type = 'task'` and actions `completed`/`commented`, plus
  matching `task_assigned`/`task_completed` `notifications` rows from
  the functional test scenario in §5 of docs/32's validation work),
  running the rollback script above failed at the
  `audit_logs_record_type_check` step with `ERROR: check constraint
  "audit_logs_record_type_check" of relation "audit_logs" is violated
  by some row` — and the entire transaction rolled back atomically
  (confirmed `to_regclass('public.tasks')` still resolved, i.e. the
  table was still present, immediately after the failed attempt — not
  a partial rollback).
- **Clean success after clearing the conflicting rows**: deleting the
  4 offending `audit_logs` rows and 11 offending `notifications` rows,
  then re-running the identical script, completed with a clean
  `COMMIT` and no errors.
- **Clean removal confirmed**: `to_regclass()` for all 5 tables
  (`tasks`, `task_assignments`, `task_watchers`, `task_comments`,
  `task_number_sequences`) returned `NULL` after rollback;
  `create_task`, `can_view_task`, `generate_task_number`, `get_task`,
  and `list_tasks` all confirmed absent from `pg_proc`.
- **No collateral damage confirmed**: `organizations` (2 rows),
  `users` (5 rows — the test fixtures created for this milestone's own
  functional testing), and `requests` (0 rows, untouched throughout)
  had identical counts before and after the full rollback cycle.
- **Reapply-and-revalidate confirmed**: re-running
  `patch-shared-task-foundation.sql` after the rollback recreated all
  5 tables, both triggers, all 4 RLS policies, and all 15
  functions/RPCs — `supabase/validate-shared-task-foundation.sql`
  passed identically to its pre-rollback run.

## 5. Confirm existing CorLink functionality remains intact

After a full rollback (§2), verify:

- Existing users can log in and land on the Dashboard; Requests,
  Entry, Prisoner Correspondence, Internal Collaboration, Meetings,
  Rooms, and Administration are all reachable exactly as before this
  milestone (none of them reference any Task table/function).
- `SELECT COUNT(*) FROM organizations;`, `SELECT COUNT(*) FROM
  users;`, and equivalent counts on `requests`/
  `external_correspondence`/`prisoner_letters`/`meetings` match their
  pre-rollback values exactly.
- `supabase/validate-shared-task-foundation.sql`'s queries against the
  5 new tables/15 functions/4 policies all report `exists = f` (or the
  final `DO $$` block raises the "missing" exception) after a full
  rollback — confirming clean removal.
