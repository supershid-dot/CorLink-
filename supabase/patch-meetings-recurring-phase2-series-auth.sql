-- ============================================================
-- CorLink — Recurring Meetings Phase 2: Series Authorization
-- Foundation
-- ============================================================
-- Scope, precisely: this patch adds exactly one new function,
-- can_manage_series(p_series_id UUID) RETURNS BOOLEAN — a single
-- centralized authorization helper every future recurring-series RPC
-- (update_entire_series(), update_series_this_and_future(),
-- cancel_entire_series(), cancel_series_this_and_future(),
-- create_series_exception(), none of which are implemented by this
-- patch) will call to decide whether the caller may act on a whole
-- series, mirroring exactly how every existing single-meeting RPC
-- already calls can_manage_meeting() for the same purpose.
--
-- Nothing else changes. No recurring-series Phase 2 RPC is
-- implemented here. No table, column, RLS policy, or CHECK constraint
-- is created or altered. No meeting, booking, notification, or audit
-- row is ever written by this function — it is a pure read-only
-- decision function, exactly like can_manage_meeting() itself.
--
-- Requires patch-meetings-recurring.sql already applied (meeting_series
-- must exist) and security-functions.sql (is_super_admin(),
-- get_my_org_id(), is_supervisor_or_above() — the exact same three
-- helpers can_manage_meeting() itself already composes).
--
-- ─── Permission model — deliberately mirrors can_manage_meeting() ──
-- can_manage_meeting(p_meeting_id) grants management to: a super
-- admin (any org), the record's own creator, or a same-organization
-- supervisor-or-above. can_manage_series() below grants the identical
-- three-tier model, keyed on meeting_series.created_by/organization_id
-- instead of meetings.created_by/organization_id — no new permission
-- tier, no new role check, nothing beyond what already governs a
-- single meeting.
--
-- ─── One deliberate structural difference from can_manage_meeting(), ──
-- ─── and why ─────────────────────────────────────────────────────────
-- can_manage_meeting() is `is_super_admin() OR EXISTS (SELECT 1 FROM
-- meetings WHERE id = ... AND (...))` — a plain SQL function where the
-- super-admin branch short-circuits BEFORE the EXISTS, so a super
-- admin technically gets TRUE even for a bogus/nonexistent meeting id.
-- This has never mattered in practice because every real caller
-- (update_meeting(), cancel_meeting(), etc.) already does its own
-- `SELECT ... WHERE id = p_meeting_id; IF NOT FOUND THEN RAISE
-- EXCEPTION 'Meeting not found'` before ever calling
-- can_manage_meeting() — the "unknown record" case is always caught
-- earlier by the calling RPC's own explicit existence check, so
-- can_manage_meeting() is never actually exercised against a
-- genuinely nonexistent id in the live call chain.
--
-- can_manage_series() is specified to be tested and used as a
-- standalone existence-plus-permission decision (its own required
-- behavior list explicitly orders "verify the series exists" before
-- the permission checks, and requires FALSE for an unknown series
-- unconditionally). To satisfy that unambiguously for every caller,
-- including a super admin, the existence check runs FIRST here and
-- gates the entire decision — "can I manage a series that does not
-- exist" is FALSE for everyone, full stop. This has zero practical
-- effect on any future real caller (which will still do its own
-- existence check first, exactly like every existing meeting RPC
-- does today), and does not change or weaken can_manage_meeting()
-- itself in any way — that function is not touched by this patch.
--
-- ─── Explicit authenticated-caller rejection, and why this differs ────
-- ─── from can_manage_meeting()'s own shape ─────────────────────────────
-- can_manage_meeting() is a plain SQL function with no NULL-actor
-- guard of its own — an anonymous caller simply falls through every
-- OR/EXISTS branch to FALSE, since it is designed to be safely
-- query-composable (including, potentially, inside an RLS policy,
-- where a hard exception would break every row evaluation). can_manage_
-- series() has an explicit requirement to REJECT a NULL actor (not
-- merely return FALSE for one), so it is written as a PL/pgSQL
-- function with its own `IF auth.uid() IS NULL THEN RAISE EXCEPTION`
-- guard, matching the exact wording convention every other RPC in this
-- module already uses ("<fn> requires an authenticated caller"). It is
-- not referenced by any RLS policy, so this does not risk the
-- policy-evaluation problem a hard exception would otherwise pose.
--
-- Idempotent — safe to re-run.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION can_manage_series(
  p_series_id UUID
) RETURNS BOOLEAN AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_series meeting_series;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'can_manage_series requires an authenticated caller';
  END IF;

  SELECT * INTO v_series FROM meeting_series WHERE id = p_series_id;
  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  RETURN (
    is_super_admin()
    OR v_series.created_by = v_actor
    OR (v_series.organization_id = get_my_org_id() AND is_supervisor_or_above())
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

COMMIT;
