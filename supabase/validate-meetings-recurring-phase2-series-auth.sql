-- ─── Validation: Recurring Meetings Phase 2 — Series ───────────────
-- ─── Authorization Foundation ───────────────────────────────────────
-- Read-only. Run manually against a project AFTER
-- patch-meetings-recurring-phase2-series-auth.sql has been applied
-- there, to confirm the migration behaved as designed. Every query
-- below is a SELECT — nothing here writes data.
--
-- Scope reminder: this patch adds exactly one new function,
-- can_manage_series(p_series_id UUID) RETURNS BOOLEAN. No recurring-
-- series Phase 2 RPC (create_series_exception, update_entire_series,
-- update_series_this_and_future, cancel_entire_series,
-- cancel_series_this_and_future) is implemented by this patch or
-- validated here.

-- ─── 1. Exactly one overload exists ─────────────────────────────────
SELECT p.proname, COUNT(*) AS overload_count
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'can_manage_series'
GROUP BY p.proname;
-- Expect: 1 row, count = 1.

-- ─── 2. SECURITY DEFINER with search_path pinned ────────────────────
SELECT p.proname, p.prosecdef, p.proconfig, p.provolatile
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'can_manage_series';
-- Expect: prosecdef = true, proconfig containing
-- 'search_path=public, pg_temp', provolatile = 's' (STABLE — a pure
-- read/decision function, matching can_manage_meeting()'s own
-- volatility).

-- ─── 3. Exact signature ──────────────────────────────────────────────
SELECT pg_get_function_identity_arguments(p.oid) AS args, pg_get_function_result(p.oid) AS ret
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'can_manage_series';
-- Expect: args = 'p_series_id uuid', ret = 'boolean'.

-- ─── 4. RLS unchanged — no new policy anywhere ──────────────────────
SELECT tablename, policyname, cmd FROM pg_policies WHERE tablename = 'meeting_series' ORDER BY policyname;
-- Expect: identical to the pre-existing set — only
-- 'meeting_series_select' (SELECT). This patch contains no ALTER
-- TABLE ... ENABLE ROW LEVEL SECURITY or CREATE POLICY statement at
-- all.

-- ─── 5. Functional test — empirically verified via local Postgres ──
-- ─── (schema.sql + rls.sql + security-functions.sql, then the full ────
-- ─── rooms/meetings patch chain through patch-meetings-recurring- ─────
-- ─── phase2-notification-suppression.sql, then this patch; hex-only ───
-- ─── UUID fixtures; SET ROLE authenticated + request.jwt.claim.sub ────
-- ─── per test) — summary for reference: ────────────────────────────────
--
--   A) The series' own creator: can_manage_series() returns TRUE.
--   B) A same-organization org admin (not the series creator):
--      can_manage_series() returns TRUE.
--   B2) A same-organization supervisor (not the series creator):
--      can_manage_series() returns TRUE — confirms the reused
--      is_supervisor_or_above() tier grants access exactly as it does
--      for can_manage_meeting(), not merely the admin role alone.
--   C) A super admin (different from the series' own organization
--      context): can_manage_series() returns TRUE.
--   D) A plain staff member, same organization as the series, but
--      neither its creator nor supervisor-or-above: can_manage_series()
--      returns FALSE.
--   E) A staff member in a DIFFERENT organization from the series:
--      can_manage_series() returns FALSE — confirmed independent of
--      role, since org isolation is checked before any role grant
--      other than super admin or exact creator match can apply.
--   F) An unknown (nonexistent) series id: can_manage_series() returns
--      FALSE for EVERY caller tested, including a super admin — this
--      is a deliberate, documented refinement over can_manage_meeting()'s
--      literal `is_super_admin() OR EXISTS(...)` short-circuit shape
--      (see this patch's own header comment for the full rationale);
--      it has no effect on any real caller, since every future series
--      RPC will perform its own existence check before ever calling
--      this helper, exactly as every existing meeting RPC already does
--      before calling can_manage_meeting().
--   G) A NULL auth.uid() (no request.jwt.claim.sub set): rejected with
--      "can_manage_series requires an authenticated caller" — an
--      actual exception, not a silent FALSE, exactly as required.
--   (Regression) can_manage_meeting() itself, re-verified after this
--      patch: a meeting's own creator still gets TRUE, a same-org
--      supervisor still gets TRUE, and a non-manager (same-org, not
--      creator, not added as a participant) still gets FALSE — this
--      patch does not modify, redefine, or otherwise touch
--      can_manage_meeting() in any way (confirmed also by this patch's
--      own file contents containing no CREATE OR REPLACE FUNCTION
--      can_manage_meeting statement).
--   (Side-effect check) Repeated can_manage_series() calls (across all
--      of A–G) produced zero new rows in meetings, notifications, or
--      audit_logs beyond the single series-creation row each already
--      had from setup — confirmed by exact row counts before and
--      after the full test run. can_manage_series() is a pure
--      read-only decision function with no side effects, exactly as
--      required.

-- ─── 6. Idempotency ─────────────────────────────────────────────
-- Re-run patch-meetings-recurring-phase2-series-auth.sql a second time
-- against the same project, then re-run checks 1–4 above — all must
-- return identical results. The patch contains no seed/UPDATE
-- statement against existing rows, only one CREATE OR REPLACE
-- FUNCTION, idempotent by construction. (No DROP FUNCTION is required
-- or present — this is a brand-new function name with no prior
-- signature to remove.)
