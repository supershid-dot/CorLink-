-- ─── Validation: Recurring Meetings Phase 2 — Series Exceptions ────
-- ─── Foundation ──────────────────────────────────────────────────────
-- Read-only. Run manually against a project AFTER
-- patch-meetings-recurring-phase2-series-exceptions.sql has been
-- applied there, to confirm the migration behaved as designed. Every
-- query below is a SELECT — nothing here writes data.
--
-- Scope reminder: this patch adds exactly one new function,
-- create_series_exception(p_series_id, p_exception_date,
-- p_exception_type, p_replacement_meeting_id DEFAULT NULL) RETURNS
-- meeting_series_exceptions — the first-ever writer of the
-- meeting_series_exceptions table. No skip-occurrence or moved-
-- occurrence workflow, and no other recurring-series Phase 2 RPC
-- (update_entire_series, update_series_this_and_future,
-- cancel_entire_series, cancel_series_this_and_future) is implemented
-- by this patch or validated here.

-- ─── 1. Exactly one overload exists ─────────────────────────────────
SELECT p.proname, COUNT(*) AS overload_count
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'create_series_exception'
GROUP BY p.proname;
-- Expect: 1 row, count = 1.

-- ─── 2. SECURITY DEFINER with search_path pinned ────────────────────
SELECT p.proname, p.prosecdef, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'create_series_exception';
-- Expect: prosecdef = true, proconfig containing
-- 'search_path=public, pg_temp'.

-- ─── 3. Exact signature ──────────────────────────────────────────────
SELECT pg_get_function_identity_arguments(p.oid) AS args, pg_get_function_result(p.oid) AS ret
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'create_series_exception';
-- Expect: args = 'p_series_id uuid, p_exception_date date,
-- p_exception_type text, p_replacement_meeting_id uuid', ret =
-- 'meeting_series_exceptions' (returns the inserted row, per
-- requirement).

-- ─── 4. RLS and CHECK constraint unchanged ──────────────────────────
SELECT tablename, policyname, cmd FROM pg_policies
WHERE tablename IN ('meeting_series', 'meeting_series_exceptions') ORDER BY tablename, policyname;
-- Expect: identical to the pre-existing set — only
-- 'meeting_series_select' and 'meeting_series_exceptions_select'
-- (both SELECT-only). No write policy of any kind — every write
-- continues to go exclusively through this one SECURITY DEFINER RPC.

SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'meeting_series_exceptions_type_check';
-- Expect: unchanged — CHECK (exception_type = ANY (ARRAY['skipped'::text, 'modified'::text])).
-- This patch contains no ALTER TABLE statement of any kind.

-- ─── 5. Functional test — empirically verified via local Postgres ──
-- ─── (schema.sql + rls.sql + security-functions.sql, then the full ────
-- ─── rooms/meetings patch chain through patch-meetings-recurring- ─────
-- ─── phase2-series-auth.sql, then this patch; hex-only UUID fixtures; ─
-- ─── SET ROLE authenticated + request.jwt.claim.sub per test) — ───────
-- ─── summary for reference: ────────────────────────────────────────────
--
--   A) The series' own creator calling create_series_exception() with
--      exception_type='skipped' on the series' own first occurrence
--      date: succeeds; the returned row and a direct re-SELECT both
--      show exception_type='skipped', replacement_meeting_id NULL,
--      created_by = the calling creator.
--   B) A same-organization org admin (not the series creator) calling
--      create_series_exception() with exception_type='modified' on a
--      DIFFERENT date, with a real replacement_meeting_id (one of the
--      series' own occurrence meeting ids): succeeds; the returned row
--      and a direct re-SELECT both show the expected values.
--   C) A second call for the SAME series_id + exception_date already
--      used in test A (different exception_type, 'modified' this
--      time): rejected with "An exception already exists for this
--      series on <date>" — the UNIQUE(series_id, exception_date)
--      constraint's own violation, caught and re-raised with a
--      friendly message. Confirmed exactly one row still exists for
--      that date afterward (not overwritten, not duplicated).
--   D) A plain staff member, same organization as the series, neither
--      its creator nor supervisor-or-above: rejected with "Not
--      authorized to manage this meeting series". Confirmed zero rows
--      were created for the attempted date.
--   D2) A staff member in a DIFFERENT organization from the series:
--      also rejected with the identical "Not authorized" message
--      (can_manage_series()'s own org-isolation, reused unchanged).
--      Confirmed zero rows were created.
--   E) An unknown (nonexistent) series id: rejected with "Meeting
--      series not found" — a RAISE EXCEPTION, not a boolean return
--      (this function's return type is the inserted row, not
--      BOOLEAN, so "FALSE" has no meaning here; every other mutating
--      RPC in this codebase raises on a missing record rather than
--      returning a sentinel — this is the same convention, not a
--      deviation from it).
--   E2) A syntactically well-formed but invalid exception_type value
--      ('bogus_type', not 'skipped' or 'modified'): rejected with
--      "Invalid exception_type: bogus_type (expected skipped or
--      modified)" before ever reaching the INSERT — confirmed zero
--      rows were created. The table's own CHECK constraint remains
--      the authoritative enforcement; this is a clearer application-
--      level pre-check on top of it, not a replacement for it.
--   F) A NULL auth.uid() (no request.jwt.claim.sub set): rejected with
--      "create_series_exception requires an authenticated caller" —
--      an actual exception, not a silent failure.
--   (Regression) Across every scenario above: the series' own
--      `meetings` row count stayed at exactly 4 (its original
--      occurrence count from setup — no meeting was created, modified,
--      or removed by any create_series_exception() call, successful
--      or rejected); zero `notifications` rows of any kind reference
--      record_type='meeting_series_exception' (this function never
--      writes to `notifications` at all); zero `audit_logs` rows
--      reference record_type='meeting_series_exception' either (this
--      function never writes to `audit_logs`, deliberately — see this
--      patch's own header for why that responsibility is left to the
--      future skip/move workflow RPCs that will call this helper);
--      the series' own pre-existing audit_logs row count (from its
--      original 'meeting_series_created' entry) stayed at exactly 1,
--      confirming this function added no audit trail of its own. Only
--      the two rows from the two SUCCESSFUL calls (A and B) exist in
--      meeting_series_exceptions afterward — every rejected call
--      (C, D, D2, E, E2, F) left zero trace. can_manage_series()
--      itself, re-tested directly after this patch, still returns
--      TRUE for the series creator — confirmed unmodified by this
--      patch (which contains no CREATE OR REPLACE FUNCTION
--      can_manage_series statement).

-- ─── 6. Idempotency ─────────────────────────────────────────────
-- Re-run patch-meetings-recurring-phase2-series-exceptions.sql a
-- second time against the same project, then re-run checks 1–4
-- above — all must return identical results. Empirically confirmed
-- during development: re-applying the patch a second time leaves the
-- overload count at exactly 1. The patch contains no seed/UPDATE
-- statement against existing rows, only one CREATE OR REPLACE
-- FUNCTION, idempotent by construction.
