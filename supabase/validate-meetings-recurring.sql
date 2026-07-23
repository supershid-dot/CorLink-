-- ─── Validation: Recurring Meetings (Phase 1) ───────────────────
-- Read-only. Run manually against a project AFTER
-- patch-meetings-recurring.sql has been applied there, to confirm
-- the migration behaved as designed. Every query below is a SELECT —
-- nothing here writes data. A query returning zero rows in the
-- "should be empty" checks means that check passed.
--
-- Corresponds to docs/22-rooms-meetings-meetflow-parity-roadmap.md
-- and docs/23-rooms-meetings-implementation-specification.md
-- "Phase F — Recurring meetings (Phase 1)".

-- ─── 1. Tables + columns present, correct type ──────────────────
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'meeting_series'
ORDER BY column_name;
-- Expect: id, organization_id, created_by, recurrence_pattern,
-- interval_count, days_of_week, series_start_date, series_end_date,
-- template_title, template_description, template_meeting_type,
-- template_visibility, template_start_time, template_end_time,
-- template_timezone, template_location_mode,
-- template_external_location, template_virtual_link,
-- template_room_id, is_draft_series, status, created_at, updated_at.

SELECT column_name, data_type FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'meetings'
  AND column_name IN ('series_id', 'series_occurrence_date', 'series_detached', 'is_placeholder')
ORDER BY column_name;
-- Expect: 4 rows.

SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'meeting_series_exceptions'
ORDER BY column_name;
-- Expect: id, series_id, exception_date, exception_type,
-- replacement_meeting_id, created_by, created_at.

-- ─── 2. meeting_series_exceptions has ZERO rows and ZERO write ──
-- ─── path — Phase 2 placeholder only, confirms nothing was ────────
-- ─── accidentally half-built in this phase ─────────────────────────
SELECT count(*) FROM meeting_series_exceptions;
-- Expect: 0.
SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prokind = 'f'
  AND pg_get_functiondef(p.oid) ILIKE '%INSERT INTO meeting_series_exceptions%';
-- Expect: 0 rows — no function anywhere writes this table yet.

-- ─── 3. RPC exists, SECURITY DEFINER, search_path pinned ───────
SELECT p.proname, p.prosecdef, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'create_recurring_meeting';
-- Expect: 1 row, prosecdef = true, proconfig containing
-- 'search_path=public, pg_temp'.

-- ─── 4. RLS: SELECT-only on both new tables ────────────────────
SELECT policyname, cmd, qual FROM pg_policies
WHERE tablename IN ('meeting_series', 'meeting_series_exceptions')
ORDER BY tablename, policyname;
-- Expect: exactly 2 rows total, both SELECT, no INSERT/UPDATE/DELETE
-- policy on either table for any role.

-- ─── 5. update_meeting() unconditionally stamps series_detached ─
SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'update_meeting'
  AND pg_get_functiondef(oid) ILIKE '%series_detached = CASE WHEN series_id IS NOT NULL%';
-- Expect: 1 row — confirms the bookkeeping fires on every field
-- update, not conditionally per-field (docs/23's explicit warning).

-- ─── 6. CHECK constraints extended correctly (full accumulated ──
-- ─── list, not a bare addition) ──────────────────────────────────
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_action_check';
-- Expect: includes 'meeting_series_created' alongside every
-- pre-existing value (including 'meeting_group_members_updated').
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_record_type_check';
-- Expect: includes 'meeting_series' alongside 'meeting_group'.
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'notifications_type_check';
-- Expect: includes 'meeting_series_created'.

-- ─── 7. Functional test — empirically verified via local ───────
-- ─── Postgres (see session record) — summary for reference: ───────
--   a) Weekly/biweekly/monthly series creation produces the correct
--      occurrence dates, including a day-31-anchored monthly series
--      spanning Jan→Apr with ZERO drift (01-31, 02-28, 03-31, 04-30 —
--      never 03-03), proving index-based (not incremental) date
--      generation.
--   b) Editing exactly one occurrence (update_meeting) sets
--      series_detached = TRUE on that occurrence only; the
--      meeting_series template row and every sibling occurrence are
--      unaffected.
--   c) Cancelling exactly one occurrence (cancel_meeting) leaves
--      every sibling occurrence's status untouched.
--   d) A room-booked series succeeds end-to-end: one confirmed
--      meeting_room_bookings row per occurrence, no advisory-lock
--      self-deadlock across repeated same-room bookings within one
--      transaction.
--   e) A room-booked series that collides with a pre-existing booking
--      on ANY one occurrence raises and rolls back the ENTIRE batch —
--      zero meetings, zero series, zero bookings persisted (verified
--      via before/after row counts).
--   f) Meeting locking is per-occurrence: locking one occurrence
--      blocks a non-overriding actor (e.g. a section supervisor) from
--      editing it while leaving every sibling occurrence editable;
--      the creator's own override-on-lock behavior (inherited,
--      unmodified from patch-meetings-lock.sql) still applies.
--   g) RSVP (respond_to_invitation), attendance (mark_attendance),
--      minutes (update_minutes/finalize_minutes), and personal notes
--      (update_my_notes/get_my_notes) all work unmodified on an
--      occurrence and are fully occurrence-scoped — verified a
--      target occurrence's minutes/attendance/RSVP/notes do not leak
--      onto a sibling occurrence. Personal-notes privacy (a
--      non-owner, including an org admin, cannot read another user's
--      notes) is preserved on occurrences exactly as on non-recurring
--      meetings.
--   h) Applying a meeting group at series-creation time
--      (p_group_id) adds that group's current members as
--      participants on EVERY occurrence independently; editing the
--      group's membership AFTER the series was created does not
--      retroactively change any already-created occurrence's
--      participant list (no permanent dependency, per docs/23).
--   i) A group belonging to a different organization is rejected
--      ("This meeting group belongs to a different organization...")
--      with a full rollback (zero rows persisted). A room belonging
--      to a different organization is rejected via the existing,
--      unmodified submit_booking_request() cross-org check, also
--      with a full rollback.
--   j) Unauthenticated and anon-role callers are rejected
--      ("create_recurring_meeting requires an authenticated caller").
--   k) Input validation rejects: 'custom_days' as a direct RPC
--      pattern argument (table CHECK allows it for future Draft-
--      series use, but the RPC itself only accepts weekly/biweekly/
--      monthly), interval_count < 1, series_end_date before
--      series_start_date, end_time not after start_time, and a
--      date range exceeding 5 years.
--   l) Cross-organization SELECT isolation on meeting_series: a user
--      from a different organization sees 0 rows; a super admin sees
--      every organization's series.

-- ─── 8. Direct table write still rejected by RLS ───────────────
-- As any authenticated user: attempt
--   INSERT INTO meeting_series (organization_id, created_by,
--     recurrence_pattern, series_start_date, series_end_date,
--     template_title, template_start_time, template_end_time)
--     VALUES (<org_id>, auth.uid(), 'weekly', '2026-01-01',
--     '2026-01-08', 'direct insert', '09:00', '10:00');
-- Expect: "new row violates row-level security policy for table
-- meeting_series" — no INSERT/UPDATE/DELETE policy exists for any
-- role; create_recurring_meeting() is the only path that can ever
-- write meeting_series, and no RPC at all writes
-- meeting_series_exceptions in this phase.

-- ─── 9. Idempotency ─────────────────────────────────────────────
-- Re-run patch-meetings-recurring.sql a second time against the same
-- project (confirmed empirically), then re-run checks 1, 3, 4, 5, 6
-- above — all must return identical results, and no existing
-- meeting_series/meetings/meeting_series_exceptions row is touched
-- (the patch contains no seed/UPDATE statement touching existing
-- rows, only DDL with IF NOT EXISTS/DROP POLICY+CREATE POLICY guards
-- and CREATE OR REPLACE FUNCTION definitions).
