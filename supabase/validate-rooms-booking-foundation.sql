-- ─── Validation: Rooms and Booking Database Foundation ────────
-- Read-only. Run manually against a project AFTER
-- patch-rooms-booking-foundation.sql has been applied there, to
-- confirm the migration behaved as designed. Every query below is a
-- SELECT — nothing here writes data. A query returning zero rows in
-- the "should be empty" checks means that check passed.
--
-- Corresponds to docs/03-migration-architecture.md Phase 4,
-- docs/09-rooms-booking-v1-decisions.md, and
-- docs/10-rooms-booking-technical-readiness.md §18's test matrix.
-- The full concurrency/RPC-behavior matrix was already exercised
-- against a local Postgres instance during implementation
-- (docs/11-rooms-booking-database-foundation.md "Local Testing
-- Results") — this script is the structural/static half of that,
-- meant to be re-run against any target project (including a hosted
-- Supabase project this session could not reach).

-- ─── 1. Extension ───────────────────────────────────────────
SELECT extname, extversion FROM pg_extension WHERE extname = 'btree_gist';
-- Expect: exactly 1 row.

-- ─── 2. Tables exist with expected column counts ──────────────
SELECT table_name, COUNT(*) AS column_count
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('meeting_rooms', 'meeting_room_managers', 'meeting_room_blocks', 'meeting_room_bookings')
GROUP BY table_name
ORDER BY table_name;
-- Expect: meeting_rooms=9, meeting_room_managers=4,
-- meeting_room_blocks=14, meeting_room_bookings=24.

-- ─── 3. meeting_room_bookings.meeting_id has NO foreign key ───
-- (the meetings table does not exist yet — this is intentional,
-- docs/10 §17 step 5 / §20 item 5, not an oversight).
SELECT tc.constraint_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu ON kcu.constraint_name = tc.constraint_name
WHERE tc.table_name = 'meeting_room_bookings'
  AND tc.constraint_type = 'FOREIGN KEY'
  AND kcu.column_name = 'meeting_id';
-- Expect: 0 rows.

-- ─── 4. Exclusion constraint exists on meeting_room_bookings ──
SELECT conname, contype
FROM pg_constraint
WHERE conrelid = 'meeting_room_bookings'::regclass AND contype = 'x';
-- Expect: 1 row, conname = 'meeting_room_bookings_no_overlap'.

-- ─── 5. Both conflict-guard triggers + status trigger attached ─
SELECT event_object_table, trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE event_object_table IN ('meeting_room_bookings', 'meeting_room_blocks')
ORDER BY event_object_table, trigger_name;
-- Expect on meeting_room_bookings: booking_conflict_guard (INSERT +
-- UPDATE, 2 rows), check_booking_status (UPDATE), set_updated_at
-- (UPDATE). Expect on meeting_room_blocks: block_conflict_guard
-- (INSERT), set_updated_at (UPDATE).

-- ─── 6. CHECK constraints extended correctly ──────────────────
SELECT pg_get_constraintdef(oid) FROM pg_constraint
WHERE conname = 'notifications_type_check';
-- Expect: includes booking_submitted, booking_approved,
-- booking_rejected, booking_cancelled, booking_changed,
-- booking_conflict_attention alongside all pre-existing values.

SELECT pg_get_constraintdef(oid) FROM pg_constraint
WHERE conname = 'audit_logs_action_check';
-- Expect: includes rejected, rescheduled, conflict_overridden
-- alongside all pre-existing values.

SELECT pg_get_constraintdef(oid) FROM pg_constraint
WHERE conname = 'audit_logs_record_type_check';
-- Expect: includes meeting_room, meeting_room_block,
-- meeting_room_booking alongside all pre-existing values.

-- ─── 7. RLS enabled on all 4 tables ────────────────────────────
SELECT relname, relrowsecurity, relforcerowsecurity
FROM pg_class
WHERE relname IN ('meeting_rooms', 'meeting_room_managers', 'meeting_room_blocks', 'meeting_room_bookings');
-- Expect: relrowsecurity = true for all 4 rows.

-- ─── 8. Exactly the expected RLS policies exist per table ──────
SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename IN ('meeting_rooms', 'meeting_room_managers', 'meeting_room_blocks', 'meeting_room_bookings')
ORDER BY tablename, cmd;
-- Expect meeting_rooms: SELECT, INSERT, UPDATE (no DELETE).
-- Expect meeting_room_managers: SELECT, INSERT, DELETE (no UPDATE).
-- Expect meeting_room_blocks: SELECT only.
-- Expect meeting_room_bookings: SELECT only.

-- ─── 9. Security invariant: NO write policy exists on the two ──
-- conflict-sensitive tables (docs/09 §15, docs/10 §14/§18 test 15).
-- This is the critical, must-be-zero check — every mutation must go
-- exclusively through the RPCs.
SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename IN ('meeting_room_bookings', 'meeting_room_blocks')
  AND cmd IN ('INSERT', 'UPDATE', 'DELETE');
-- Expect: 0 rows.

-- ─── 10. All 10 RPCs exist, SECURITY DEFINER, search_path pinned ─
SELECT p.proname,
       p.prosecdef AS is_security_definer,
       (SELECT array_agg(cfg) FROM unnest(p.proconfig) cfg WHERE cfg LIKE 'search_path=%') AS search_path_setting
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'create_booking_hold', 'submit_booking_request', 'create_room_booking',
    'approve_booking', 'reject_booking', 'cancel_booking', 'reschedule_booking',
    'create_room_block', 'cancel_room_block', 'check_room_availability'
  )
ORDER BY p.proname;
-- Expect: 10 rows, is_security_definer = true for every row,
-- search_path_setting containing 'search_path=public, pg_temp' for
-- every row.

-- ─── 11. Helper functions exist ────────────────────────────────
SELECT proname FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND proname IN (
    'room_lock_key', 'rooms_module_active_for', 'is_room_manager',
    'room_manager_recipient_ids', 'booking_effective_status',
    'valid_booking_status_transition', 'trigger_check_booking_status',
    'meeting_room_bookings_conflict_guard', 'meeting_room_blocks_conflict_guard'
  )
ORDER BY proname;
-- Expect: 9 rows.

-- ─── 12. No orphaned rows (belt-and-suspenders on FKs) ─────────
SELECT b.id FROM meeting_room_bookings b
LEFT JOIN meeting_rooms r ON r.id = b.room_id
LEFT JOIN organizations o ON o.id = b.org_id
WHERE r.id IS NULL OR o.id IS NULL;
-- Expect: 0 rows.

-- ─── 13. Functional / RLS checks requiring impersonation ────────
-- Run each block below via `BEGIN; SET LOCAL ROLE authenticated;
-- SET LOCAL request.jwt.claim.sub = '<uuid>';` impersonating a
-- representative user (standard pattern already used for this
-- repo's other patches), then ROLLBACK. All of the following were
-- already exercised end-to-end during implementation (see docs/11
-- "Local Testing Results" for the full matrix and results) — re-run
-- against a hosted project to confirm identical behavior there:
--
--  a. An ordinary staff member of an org with 'rooms' enabled can
--     create_booking_hold()/submit_booking_request() for a room in
--     their own org, but not create_room_booking() (manager-only) or
--     book a room in a different org.
--  b. A room manager (org-wide supervisor/admin, or an explicit
--     meeting_room_managers grant) can create_room_booking(),
--     approve_booking(), reject_booking(), create_room_block().
--  c. A user cannot approve_booking() their own request, even while
--     also holding manager/admin authority for that room — except a
--     super admin supplying an explicit override reason.
--  d. A direct INSERT/UPDATE against meeting_room_bookings or
--     meeting_room_blocks is rejected by RLS regardless of role.
--  e. The anon role sees 0 rows from every one of the 4 tables and
--     every RPC call raises "requires an authenticated caller".
--  f. A user in an org where 'rooms' is disabled (module_enabled_for_org
--     = false) cannot call any of the 10 RPCs successfully.
--  g. Two genuinely concurrent sessions booking/holding an
--     overlapping window on the same room: exactly one succeeds, no
--     deadlock (docs/10 §18 tests 3/4).

-- ─── 14. Idempotency ────────────────────────────────────────────
-- Re-run patch-rooms-booking-foundation.sql a second time against
-- the same project, then re-run checks 2, 4, 5, 8, 9, 10 above — all
-- must return identical results (no duplicate tables/constraints/
-- triggers/policies/functions).
