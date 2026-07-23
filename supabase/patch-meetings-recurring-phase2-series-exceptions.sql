-- ============================================================
-- CorLink — Recurring Meetings Phase 2: Series Exceptions
-- Foundation
-- ============================================================
-- Scope, precisely: this patch adds exactly one new function,
-- create_series_exception(p_series_id UUID, p_exception_date DATE,
-- p_exception_type TEXT, p_replacement_meeting_id UUID DEFAULT NULL)
-- RETURNS meeting_series_exceptions — the first-ever writer of the
-- meeting_series_exceptions table, which has existed since
-- patch-meetings-recurring.sql purely as inert, forward-staged Phase 2
-- schema (that file's own header: "zero RPCs write to it and zero UI
-- references it in this phase"). This patch is that first writer.
--
-- Nothing else changes. No recurring-series Phase 2 RPC beyond this
-- one is implemented here (no update_entire_series(),
-- update_series_this_and_future(), cancel_entire_series(),
-- cancel_series_this_and_future()). No skip-occurrence or moved-
-- occurrence WORKFLOW is implemented — this patch only records a raw
-- exception row; the actual meaning of "skipped" (e.g. cancelling the
-- underlying occurrence) or "modified" (e.g. moving it) is future work
-- for those not-yet-built RPCs, which will call this helper as their
-- own first step, exactly like create_recurring_meeting() already
-- calls create_meeting() as its own first step per occurrence. No
-- table, column, RLS policy, or CHECK constraint is created or
-- altered — meeting_series_exceptions' shape (including its existing
-- UNIQUE(series_id, exception_date) and exception_type CHECK) is used
-- exactly as already staged. No meeting, booking, or notification row
-- is ever written by this function, and no audit_logs row either — a
-- deliberate scope boundary: this is a narrow, reusable primitive
-- (matching this task's own explicit "helper," not "workflow," framing
-- and its explicit "do not modify audits" requirement); the future
-- skip/move workflow RPCs that call this helper are the correct place
-- to add their own audit_logs entries alongside whatever meeting-level
-- mutation they also perform, exactly like create_recurring_meeting()
-- writes its own audit row itself rather than pushing that
-- responsibility onto create_meeting().
--
-- Requires patch-meetings-recurring.sql already applied
-- (meeting_series/meeting_series_exceptions must exist) and
-- patch-meetings-recurring-phase2-series-auth.sql already applied
-- (can_manage_series(), reused here exactly as directed rather than
-- re-implementing any permission logic).
--
-- ─── Design decisions ────────────────────────────────────────────
-- 1. Existence and authorization are two separate, explicit checks
--    with two distinct error messages ("Meeting series not found" vs.
--    "Not authorized to manage this meeting series"), matching the
--    exact convention every other mutating RPC in this module already
--    follows (update_meeting(), cancel_meeting(), etc. each check
--    existence, then authorization, as separate steps) — not
--    collapsed into one ambiguous rejection.
-- 2. "Unknown series" resolves to RAISE EXCEPTION, not a boolean
--    FALSE return. This function's return type is the inserted row
--    (meeting_series_exceptions), not BOOLEAN, so a FALSE return has
--    no meaning here; RAISE EXCEPTION on a missing record is also the
--    universal convention for every existing mutating RPC in this
--    codebase (create_meeting, update_meeting, cancel_meeting,
--    assign_room_booking, etc. all raise "<Record> not found" rather
--    than returning a sentinel value) — can_manage_series() itself
--    returning FALSE for an unknown series (patch-meetings-recurring-
--    phase2-series-auth.sql) is the correct behavior for a pure
--    read-only decision helper, not a pattern this mutating RPC needs
--    to replicate.
-- 3. The Meetings-module-active-for-organization gate
--    (meetings_module_active_for()) is checked explicitly here, as its
--    own step, exactly mirroring update_meeting()/cancel_meeting()/
--    assign_room_booking() — can_manage_series() deliberately does not
--    include this check itself (mirroring can_manage_meeting()'s own
--    scope, which also omits it), since module-gating is this
--    codebase's own established separate, per-RPC layer, not folded
--    into the shared permission helper. Omitting it here would be a
--    real, if narrow, gap relative to every sibling RPC in this
--    module — an organization that has disabled the Meetings module
--    should not be able to accumulate series-exception rows any more
--    than it can create/edit/cancel a meeting.
-- 4. Duplicate-date rejection relies on the existing
--    UNIQUE(series_id, exception_date) constraint, caught via
--    EXCEPTION WHEN unique_violation and re-raised with a friendly
--    message — the exact same pattern add_participant() already uses
--    for meeting_participants' own unique constraints
--    (patch-meetings-drafts.sql), rather than a separate pre-check
--    SELECT that would leave a race window between the check and the
--    insert. This is TOCTOU-safe by construction: the constraint
--    itself, not any prior read, is what actually prevents a
--    duplicate.
-- 5. p_exception_type is validated against the exact same two values
--    the table's own CHECK constraint already allows ('skipped',
--    'modified') — this mirrors the CHECK rather than replacing it
--    (the CHECK is still the authoritative enforcement; this
--    validation exists purely to raise a clearer application-level
--    error before ever reaching the constraint, matching this
--    module's existing convention of pre-validating enum-shaped
--    inputs, e.g. update_meeting()'s own p_status validation).
-- 6. p_replacement_meeting_id is accepted and inserted exactly as
--    given, with no cross-field validation against p_exception_type
--    (e.g. "required for modified, forbidden for skipped") —
--    deliberately, since that pairing rule belongs to the not-yet-
--    built moved-occurrence workflow this patch explicitly excludes,
--    not to this narrow storage primitive. The column's own existing
--    FK (REFERENCES meetings(id)) already rejects a nonexistent
--    meeting id at the database level with no additional code needed
--    here.
--
-- Idempotent — safe to re-run.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION create_series_exception(
  p_series_id UUID,
  p_exception_date DATE,
  p_exception_type TEXT,
  p_replacement_meeting_id UUID DEFAULT NULL
) RETURNS meeting_series_exceptions AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_series meeting_series;
  v_exception meeting_series_exceptions;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_series_exception requires an authenticated caller';
  END IF;

  SELECT * INTO v_series FROM meeting_series WHERE id = p_series_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting series not found';
  END IF;

  IF NOT can_manage_series(p_series_id) THEN
    RAISE EXCEPTION 'Not authorized to manage this meeting series';
  END IF;

  IF NOT meetings_module_active_for(v_series.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  IF p_exception_type NOT IN ('skipped', 'modified') THEN
    RAISE EXCEPTION 'Invalid exception_type: % (expected skipped or modified)', p_exception_type;
  END IF;

  BEGIN
    INSERT INTO meeting_series_exceptions (
      series_id, exception_date, exception_type, replacement_meeting_id, created_by
    ) VALUES (
      p_series_id, p_exception_date, p_exception_type, p_replacement_meeting_id, v_actor
    ) RETURNING * INTO v_exception;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'An exception already exists for this series on %', p_exception_date;
  END;

  RETURN v_exception;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMIT;
