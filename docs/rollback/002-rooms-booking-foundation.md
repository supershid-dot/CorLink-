# Rollback — 002: Rooms and Booking Database Foundation

Companion to `docs/11-rooms-booking-database-foundation.md`. Explains how to undo this phase (`supabase/patch-rooms-booking-foundation.sql`) if it needs to be reversed after being applied. As of this document's creation, the migration has **not** been applied to any Supabase project — it has only been applied to, and tested against, a local disposable PostgreSQL instance.

This rollback is scoped narrowly to what this phase actually created: 4 new tables (`meeting_rooms`, `meeting_room_managers`, `meeting_room_blocks`, `meeting_room_bookings`), their triggers/constraints, 10 new functions, 8 new RLS policies, and 3 extended CHECK constraints (`notifications.type`, `audit_logs.action`, `audit_logs.record_type`). It does not touch `organizations`, `users`, `user_assignments`, `requests`, `external_correspondence`, or any other pre-existing CorLink table or data — none of those are written to by this phase's migration, and this was directly confirmed during rollback testing (see §3).

---

## 1. Prerequisite check (must pass before running §2)

The CHECK-constraint reversion step in §2 restores `notifications.type`, `audit_logs.action`, and `audit_logs.record_type` to their pre-Phase-4 definitions — which no longer include the new values this phase added (`booking_submitted`, `booking_approved`, `booking_rejected`, `booking_cancelled`, `booking_changed`, `booking_conflict_attention`, `rejected`, `rescheduled`, `conflict_overridden`, `meeting_room`, `meeting_room_block`, `meeting_room_booking`). Postgres validates every existing row against a new `CHECK` constraint at the moment it's added, so **this step fails outright if any live row still carries one of those values** — confirmed directly during local testing (see §4).

Before running §2, confirm this returns zero rows for all three:

```sql
SELECT id, type FROM notifications WHERE type IN (
  'booking_submitted', 'booking_approved', 'booking_rejected',
  'booking_cancelled', 'booking_changed', 'booking_conflict_attention'
);
SELECT id, action FROM audit_logs WHERE action IN ('rejected', 'rescheduled', 'conflict_overridden');
SELECT id, record_type FROM audit_logs WHERE record_type IN (
  'meeting_room', 'meeting_room_block', 'meeting_room_booking'
);
```

If any rows are returned, either delete them (acceptable if this rollback is happening because the whole phase is being abandoned, since the 4 tables those rows reference are about to be dropped in §2 step 7 anyway) or reconsider whether a full rollback is really appropriate — the presence of these rows means the Rooms/Booking feature has real, referenced audit/notification history.

## 2. Remove the new database objects safely

Run as a superuser/service-role connection, in this exact order (matches `docs/10-rooms-booking-technical-readiness.md` §19's specified FK-safe order — every dependent object before the thing it depends on):

```sql
BEGIN;

-- 1. Drop the 10 RPCs (9 mutating + 1 read-only convenience RPC).
DROP FUNCTION IF EXISTS create_booking_hold(UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, UUID, UUID);
DROP FUNCTION IF EXISTS submit_booking_request(UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, UUID, UUID, UUID);
DROP FUNCTION IF EXISTS create_room_booking(UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, UUID, UUID);
DROP FUNCTION IF EXISTS approve_booking(UUID, TEXT);
DROP FUNCTION IF EXISTS reject_booking(UUID, TEXT);
DROP FUNCTION IF EXISTS cancel_booking(UUID, TEXT);
DROP FUNCTION IF EXISTS reschedule_booking(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS create_room_block(UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT);
DROP FUNCTION IF EXISTS cancel_room_block(UUID, TEXT);
DROP FUNCTION IF EXISTS check_room_availability(UUID, TIMESTAMPTZ, TIMESTAMPTZ);

-- 2. Drop RLS policies on the 4 new tables.
DROP POLICY IF EXISTS "meeting_rooms_select" ON meeting_rooms;
DROP POLICY IF EXISTS "meeting_rooms_insert" ON meeting_rooms;
DROP POLICY IF EXISTS "meeting_rooms_update" ON meeting_rooms;
DROP POLICY IF EXISTS "meeting_room_managers_select" ON meeting_room_managers;
DROP POLICY IF EXISTS "meeting_room_managers_insert" ON meeting_room_managers;
DROP POLICY IF EXISTS "meeting_room_managers_delete" ON meeting_room_managers;
DROP POLICY IF EXISTS "meeting_room_bookings_select" ON meeting_room_bookings;
DROP POLICY IF EXISTS "meeting_room_blocks_select" ON meeting_room_blocks;

-- 3. Drop the 2 conflict-guard triggers + set_updated_at triggers on
--    the new tables (status-transition trigger dropped in step 5).
DROP TRIGGER IF EXISTS booking_conflict_guard ON meeting_room_bookings;
DROP TRIGGER IF EXISTS block_conflict_guard ON meeting_room_blocks;
DROP TRIGGER IF EXISTS set_updated_at ON meeting_room_bookings;
DROP TRIGGER IF EXISTS set_updated_at ON meeting_room_blocks;
DROP TRIGGER IF EXISTS set_updated_at ON meeting_rooms;

-- 4. Drop the exclusion constraint.
ALTER TABLE meeting_room_bookings DROP CONSTRAINT IF EXISTS meeting_room_bookings_no_overlap;

-- 5. Drop the status-transition trigger + its functions.
DROP TRIGGER IF EXISTS check_booking_status ON meeting_room_bookings;
DROP FUNCTION IF EXISTS trigger_check_booking_status();
DROP FUNCTION IF EXISTS valid_booking_status_transition(TEXT, TEXT);

-- 6. Revert the CHECK-constraint extensions to their prior definitions.
--    Fails here if §1's prerequisite check was skipped and a live row
--    still uses a new value.
ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
  CHECK (type IN (
    'new_request', 'new_response', 'approval_requested', 'draft_returned',
    'deadline_warning', 'extension_requested', 'extension_decided',
    'new_prisoner_letter', 'letter_replied',
    'new_external_correspondence', 'external_correspondence_replied',
    'request_cancelled'
  ));

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_action_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_action_check
  CHECK (action IN (
    'created', 'edited', 'submitted', 'approved', 'returned',
    'sent', 'received', 'routed', 'assigned',
    'returned_to_sender', 'cancelled',
    'extension_requested', 'extension_approved', 'extension_denied',
    'viewed', 'login', 'logout', 'login_failed', 'locked',
    'password_changed', 'user_created', 'user_deactivated'
  ));

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_record_type_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_record_type_check
  CHECK (record_type IN (
    'request', 'response', 'internal_request', 'prisoner_letter', 'deadline_extension',
    'user', 'organization', 'section', 'session', 'attachment', 'external_correspondence'
  ));

-- 7. Drop the 4 new tables, in dependency order.
DROP TABLE IF EXISTS meeting_room_managers;
DROP TABLE IF EXISTS meeting_room_blocks;
DROP TABLE IF EXISTS meeting_room_bookings;
DROP TABLE IF EXISTS meeting_rooms;

-- 8. Drop the conflict-guard functions and remaining standalone
--    helper functions — after the tables so no RLS policy or trigger
--    still references them.
DROP FUNCTION IF EXISTS meeting_room_blocks_conflict_guard();
DROP FUNCTION IF EXISTS meeting_room_bookings_conflict_guard();
DROP FUNCTION IF EXISTS room_manager_recipient_ids(UUID, UUID);
DROP FUNCTION IF EXISTS is_room_manager(UUID, UUID);
DROP FUNCTION IF EXISTS rooms_module_active_for(UUID);
DROP FUNCTION IF EXISTS booking_effective_status(TEXT, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS room_lock_key(UUID);

-- 9. btree_gist is left enabled — no destructive footprint (docs/10 §2),
--    matches Phase 1's rollback never disabling an extension either.

COMMIT;
```

**This is safe and non-destructive to the rest of CorLink**: every dropped object is exclusively new and exclusively created by this phase. Nothing outside this phase references any of these tables/functions (`meeting_room_bookings.meeting_id` was deliberately created with no FK at all, since the `meetings` table doesn't exist yet — see `docs/10` §17 step 5 — so there is no cross-phase dependency to worry about in either direction). Dropping this phase's objects cannot cascade into `organizations`, `users`, `requests`, or any correspondence data.

**Do not** run any broader statement (`DROP SCHEMA`, `TRUNCATE` on any pre-existing table, or anything wildcard-based) to accomplish this rollback — the explicit list above is the entire footprint of this phase.

## 3. Remove the room manager grant precedent, if desired

`meeting_room_managers` is dropped in §2 step 7 along with the other 3 tables — no separate step needed. Its grants carry no meaning outside this phase (there is no other table anywhere in CorLink that reads from it).

## 4. What was actually tested (this session, local Postgres only)

- **Prerequisite failure confirmed real**, not just documented: with live test data present (20 `notifications` rows carrying new `booking_*` types, 28 `audit_logs` rows carrying new record types/actions), running the rollback script above failed at the `notifications_type_check` step with `ERROR: check constraint "notifications_type_check" of relation "notifications" is violated by some row` — and the entire transaction rolled back atomically (confirmed `meeting_rooms` still had its pre-rollback row count of 3 immediately after the failed attempt, not a partial rollback).
- **Clean success after clearing the conflicting rows**: deleting the offending `notifications`/`audit_logs` rows and re-running the identical script completed with a clean `COMMIT` and no errors.
- **Clean removal confirmed**: `to_regclass()` for all 4 tables returned `NULL` after rollback; `is_room_manager`/`room_lock_key`/`booking_effective_status`/`create_booking_hold` all confirmed absent from `pg_proc`; `btree_gist` confirmed still enabled (left in place per §2 step 9).
- **No collateral damage confirmed**: `organizations` (2 rows), `users` (7 rows), and `platform_modules` (11 rows) — all pre-existing, unrelated tables — had identical row counts before and after the full rollback cycle.
- **Reapply-and-revalidate confirmed**: re-running `patch-rooms-booking-foundation.sql` after the rollback recreated all 4 tables, the exclusion constraint, all 6 triggers, all 8 RLS policies, and all 10 RPCs — `supabase/validate-rooms-booking-foundation.sql` passed identically to its pre-rollback run.

## 5. Confirm existing CorLink functionality remains intact

After a full rollback (§2), verify:

- Existing users can log in and land on the Dashboard; Requests, Entry, Prisoner Correspondence, and Administration are all reachable exactly as before this phase.
- `SELECT COUNT(*) FROM organizations;`, `SELECT COUNT(*) FROM users;`, and equivalent counts on `requests`/`external_correspondence`/`prisoner_letters` match their pre-rollback values exactly.
- `supabase/validate-rooms-booking-foundation.sql`'s queries against the 4 new tables return "relation does not exist"-style errors (or simply no rows, for the FK/orphan checks) after a full rollback — confirming clean removal.
