-- ─── Validation: Meetings Database Foundation ──────────────────
-- Read-only. Run manually against a project AFTER
-- patch-meetings-foundation.sql has been applied there (which itself
-- requires patch-rooms-booking-foundation.sql already applied), to
-- confirm the migration behaved as designed. Every query below is a
-- SELECT — nothing here writes data. A query returning zero rows in
-- the "should be empty" checks means that check passed.
--
-- Corresponds to docs/03-migration-architecture.md Phase 3,
-- docs/12-meetings-v1-decisions.md, and
-- docs/13-meetings-technical-readiness.md §18's validation matrix.
-- The full functional/concurrency matrix was already exercised
-- against a local Postgres instance during implementation (see
-- docs/14-meetings-database-foundation.md "Local Testing Results")
-- — this script is the structural/static half of that, meant to be
-- re-run against any target project (including a hosted Supabase
-- project this session could not reach).

-- ─── 1. Tables exist with expected column counts ──────────────
SELECT table_name, COUNT(*) AS column_count
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name IN ('meetings', 'meeting_participants')
GROUP BY table_name ORDER BY table_name;
-- Expect: meetings=20, meeting_participants=18.

-- ─── 2. meeting_room_bookings extensions present ───────────────
SELECT conname FROM pg_constraint
WHERE conrelid = 'meeting_room_bookings'::regclass AND conname = 'meeting_room_bookings_meeting_id_fkey';
-- Expect: 1 row (the FK deliberately deferred by Rooms/Booking, added now).

SELECT indexname FROM pg_indexes
WHERE tablename = 'meeting_room_bookings' AND indexname = 'meeting_room_bookings_one_active_per_meeting';
-- Expect: 1 row.

SELECT p.proname, pg_get_function_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'reschedule_booking';
-- Expect: 1 row, args including p_new_timezone text DEFAULT NULL::text
-- as the 5th parameter (the one required, additive touch to the
-- already-shipped Rooms/Booking RPC).

-- ─── 3. Only ONE overload of every RPC whose signature changed ─
SELECT proname, COUNT(*) FROM pg_proc
WHERE proname IN ('reschedule_booking', 'assign_room_booking')
GROUP BY proname HAVING COUNT(*) <> 1;
-- Expect: 0 rows — confirms no stale overload was left behind by a
-- signature change (a real gap found and fixed during this
-- migration's own testing — see docs/14).

-- ─── 4. Meeting-link-guard trigger attached ────────────────────
SELECT trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE event_object_table = 'meeting_room_bookings' AND trigger_name = 'meeting_link_guard';
-- Expect: 1 row (fires on INSERT and each watched UPDATE OF column,
-- shown as separate rows or combined depending on the Postgres version).

-- ─── 5. meetings/meeting_participants triggers ─────────────────
SELECT event_object_table, trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE event_object_table IN ('meetings', 'meeting_participants')
ORDER BY event_object_table, trigger_name;
-- Expect on meetings: check_meeting_status (UPDATE), set_updated_at
-- (UPDATE), set_updated_by (UPDATE). Expect on meeting_participants:
-- set_updated_at (UPDATE).

-- ─── 6. CHECK constraints extended correctly ───────────────────
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'notifications_type_check';
-- Expect: includes meeting_created, participant_added, meeting_updated,
-- room_assigned, meeting_cancelled, participant_removed (NOT
-- meeting_reminder) alongside all pre-existing values.

SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_action_check';
-- Expect: includes unassigned, participant_added, participant_removed,
-- attachment_added, attachment_removed alongside all pre-existing values.

SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_record_type_check';
-- Expect: includes 'meeting' alongside all pre-existing values.

SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'attachments_record_type_check';
-- Expect: includes 'meeting' alongside all 8 pre-existing values.

-- ─── 7. RLS enabled on both tables ──────────────────────────────
SELECT relname, relrowsecurity FROM pg_class WHERE relname IN ('meetings', 'meeting_participants');
-- Expect: relrowsecurity = true for both rows.

-- ─── 8. Exactly the expected RLS policies exist ─────────────────
SELECT tablename, policyname, cmd FROM pg_policies
WHERE tablename IN ('meetings', 'meeting_participants') ORDER BY tablename;
-- Expect exactly 2 rows total: meetings_select (SELECT) and
-- meeting_participants_select (SELECT). No other policy on either table.

-- ─── 9. Security invariant: NO write policy on either table ────
-- The critical, must-be-zero check — every mutation must go
-- exclusively through the 7 RPCs.
SELECT tablename, policyname, cmd FROM pg_policies
WHERE tablename IN ('meetings', 'meeting_participants') AND cmd IN ('INSERT', 'UPDATE', 'DELETE');
-- Expect: 0 rows.

-- ─── 10. No blanket USING (true) policy anywhere on either table ─
SELECT tablename, policyname FROM pg_policies
WHERE tablename IN ('meetings', 'meeting_participants') AND qual = 'true';
-- Expect: 0 rows.

-- ─── 11. All 7 RPCs + helper functions exist, SECURITY DEFINER, ─
--     search_path pinned
SELECT p.proname, p.prosecdef AS is_security_definer,
       (SELECT array_agg(cfg) FROM unnest(p.proconfig) cfg WHERE cfg LIKE 'search_path=%') AS search_path_setting
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN (
  'create_meeting', 'update_meeting', 'cancel_meeting', 'add_participant',
  'remove_participant', 'assign_room_booking', 'detach_room_booking'
) ORDER BY p.proname;
-- Expect: 7 rows, is_security_definer = true for every row,
-- search_path_setting containing 'search_path=public, pg_temp' for
-- every row. Confirm no complete_meeting row exists (it must not,
-- since completion is derived only):
SELECT proname FROM pg_proc WHERE proname = 'complete_meeting';
-- Expect: 0 rows.

SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND proname IN (
  'meeting_effective_status', 'valid_meeting_status_transition', 'trigger_check_meeting_status',
  'trigger_set_updated_by', 'meetings_module_active_for', 'can_view_meeting', 'can_manage_meeting',
  'meeting_participant_recipient_ids', 'meeting_participant_list', 'meeting_room_bookings_meeting_link_guard'
) ORDER BY proname;
-- Expect: 10 rows.

-- ─── 12. No orphaned rows ────────────────────────────────────────
SELECT mp.id FROM meeting_participants mp
LEFT JOIN meetings m ON m.id = mp.meeting_id
WHERE m.id IS NULL;
-- Expect: 0 rows.

SELECT b.id FROM meeting_room_bookings b
WHERE b.meeting_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM meetings m WHERE m.id = b.meeting_id);
-- Expect: 0 rows (the FK itself already guarantees this — belt-and-suspenders).

-- ─── 13. Functional / RLS / concurrency checks requiring ────────
-- impersonation or multiple sessions. Run each block via `BEGIN; SET
-- LOCAL ROLE authenticated; SET LOCAL request.jwt.claim.sub =
-- '<uuid>';` impersonating a representative user, then ROLLBACK
-- (standard pattern already used for this repo's other patches). All
-- of the following were already exercised end-to-end during
-- implementation (see docs/14 "Local Testing Results" for the full
-- matrix and results) — re-run against a hosted project to confirm
-- identical behavior there:
--
--  a. Draft/scheduled creation succeeds; invalid time ranges,
--     invalid location-mode combinations, and unsafe (non-https)
--     virtual-link schemes are all rejected.
--  b. A creator manages their own meeting; a supervisor manages
--     another creator's meeting in their own org; an ordinary,
--     unrelated user is denied.
--  c. An internal participant can read a meeting they're listed on
--     (visibility = private/participants); a non-participant,
--     non-supervisor cannot.
--  d. Duplicate internal participants are rejected; external
--     participants dedup by normalized email only (two different
--     people sharing a name with no email, or different emails, both
--     succeed); the sole active organizer cannot be removed;
--     removal is soft (row retained with removed_at set).
--  e. meeting_participant_list() nulls external_email/external_phone
--     for a non-privileged caller viewing another participant's row,
--     and never nulls them for a privileged (creator/manager) caller.
--  f. A direct INSERT/UPDATE against meetings or meeting_participants
--     is rejected by RLS regardless of role; the anon role sees 0
--     rows from either table and every RPC call raises "requires an
--     authenticated caller".
--  g. A user in an org where 'meetings' is disabled cannot call any
--     of the 7 RPCs successfully, and sees 0 rows via meetings_select
--     even for otherwise-qualifying meetings.
--  h. One active linked booking per meeting is enforced (a second
--     assign_room_booking on the same meeting fails); cancel_meeting
--     atomically cancels the meeting and its active linked booking;
--     an INDEPENDENT cancel_booking (Rooms/Booking module, not via
--     Meetings) does NOT cancel the meeting (documented asymmetry);
--     detach_room_booking cancels the booking, preserves the
--     meeting, and clears location_mode.
--  i. update_meeting reschedule atomically updates both the meeting
--     and its linked booking; a reschedule into an already-occupied
--     window rolls back BOTH records; a timezone-only update_meeting
--     call succeeds and syncs the linked booking's timezone too
--     (regression check for the reschedule_booking extension, §10).
--  j. Notification generation for all 6 types (meeting_created,
--     participant_added, meeting_updated, room_assigned,
--     meeting_cancelled, participant_removed), each addressed to the
--     expected recipient(s), actor always excluded.
--  k. Audit generation for created/edited/cancelled/rescheduled/
--     assigned/unassigned/participant_added/participant_removed.
--  l. Meeting attachment insert/select/delete by role — manager and
--     uploader-self behave per docs/13 §14; a non-manager,
--     non-uploader is denied; delete stays uploader-only (not
--     "any meeting manager"), matching the existing convention for
--     every other attachment record type.
--  m. Six concurrency scenarios (docs/13 §19): two different meetings
--     racing to assign the same room/overlapping window; two
--     concurrent assignments to the SAME meeting; a reschedule racing
--     a separate direct room booking; cancel_meeting racing an
--     independent cancel_booking on the same linked booking; two
--     concurrent add_participant calls for the same internal user;
--     two concurrent add_participant calls for the same normalized
--     external email. All six verified deterministic (exactly one
--     winner, no partial state, no deadlock).

-- ─── 14. Idempotency ─────────────────────────────────────────────
-- Re-run patch-meetings-foundation.sql a second time against the
-- same project, then re-run checks 1, 3, 4, 5, 8, 9, 11 above — all
-- must return identical results (no duplicate tables/constraints/
-- triggers/policies/functions, and critically no duplicate overload
-- of reschedule_booking or assign_room_booking).
