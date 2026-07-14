-- ─── Patch: fix routing/return aborting via RLS SELECT-visibility ──
-- Root cause of "new row violates row-level security policy for table
-- requests" when a section-scoped supervisor routes or returns a
-- request AWAY from their own section — diagnosed by replicating the
-- reporting org's exact data on a local Postgres and bisecting policies
-- until the real mechanism was isolated:
--
-- Postgres re-checks the POST-update row against the table's SELECT
-- policies on any UPDATE that reads columns — and every real UPDATE
-- reads columns (the WHERE clause alone is enough; no RETURNING
-- needed). A supervisor whose visibility comes only from their own
-- section loses SELECT access to a request the instant it's routed to
-- a different section, so the very act of handing a case off aborted
-- the hand-off itself. requests_select's own received_by clause
-- already documents this exact mechanic for the front-desk case; the
-- section-scoped route/return path needed its equivalent.
--
-- Fix: the track_previous_section trigger already repoints
-- previous_section_id at the mover's own section in the same UPDATE —
-- adding "previous_section_id IN my_section_ids()" to the SELECT
-- policies keeps the mover's hand-off visible to them, and (deliberate
-- side effect) gives the section that most recently handed a case off
-- continued read access — one hop of history, overwritten on the next
-- move.
--
-- Also fixes two more bugs found during the same investigation:
--
-- 1. internal_requests_update's cancelled-parent EXISTS (added by
--    patch-cancel-request.sql) referenced parent_request_id UNQUALIFIED
--    inside `FROM requests r` — and requests also has a column named
--    parent_request_id, so it resolved to r.parent_request_id ("is
--    this request its own parent", always false), silently making the
--    policy match ZERO rows. This broke EVERY internal-collaboration
--    update (Mark Received / Assign / Reroute / Close / Return) since
--    that patch ran. The identical trap is already documented on
--    internal_requests_insert; the update policy now qualifies it the
--    same way.
--
-- 2. internal_requests_update had no explicit WITH CHECK, so its USING
--    was reused against the post-update row — a plain member of the
--    wrongly-routed section returning an internal request (Return to
--    Sender is deliberately open to any member) no longer matches
--    to/from/supervisor terms after the move. internal_requests gets
--    its own trigger-maintained previous_section_id (mirroring
--    requests), referenced by an explicit WITH CHECK and by
--    internal_requests_select.
--
-- Also reverts patch-fix-section-receiver-supervisor-conflict.sql's
-- WITH CHECK loosening on requests_update_section_receiver: verified
-- empirically that permissive policies' WITH CHECKs are OR'd (one
-- passing policy is enough — a narrower policy whose USING matches
-- cannot veto a write another policy allows), so that change was
-- inert; the real blocker was always the SELECT-visibility mechanism
-- above. Restoring the original narrow WITH CHECK keeps the "pure
-- assigned_receiver can't move a request elsewhere" rule exactly as
-- designed.
--
-- Verified empirically against a real local Postgres instance seeded
-- with the reporting org's exact live data shape (dual-role
-- supervisor+assigned_receiver, plain staff, unrelated third section):
-- external route + return by the dual-role supervisor succeed; internal
-- return by a plain member succeeds; internal Mark Received works again;
-- ping-pong (return, then onward route by the receiving section)
-- maintains previous_section_id correctly; an unrelated section still
-- sees nothing and can update nothing; cancel still works and a
-- cancelled parent still freezes its internal requests.
--
-- Idempotent — safe to run more than once.

BEGIN;

-- ── internal_requests: previous-holder pointer (mirrors requests) ──
ALTER TABLE internal_requests
  ADD COLUMN IF NOT EXISTS previous_section_id UUID REFERENCES sections(id);

CREATE OR REPLACE FUNCTION trigger_track_internal_previous_section()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.to_section_id IS DISTINCT FROM OLD.to_section_id AND OLD.to_section_id IS NOT NULL THEN
    NEW.previous_section_id := OLD.to_section_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS track_internal_previous_section ON internal_requests;
CREATE TRIGGER track_internal_previous_section BEFORE UPDATE OF to_section_id ON internal_requests
  FOR EACH ROW EXECUTE FUNCTION trigger_track_internal_previous_section();

-- ── requests_select: previous-holder visibility ──────────────────
DROP POLICY IF EXISTS "requests_select" ON requests;
CREATE POLICY "requests_select" ON requests
  FOR SELECT USING (
    (from_org_id = get_my_org_id() OR to_org_id = get_my_org_id())
    AND (
      is_admin()
      OR from_section_id IN (SELECT my_section_ids())
      OR to_section_id   IN (SELECT my_section_ids())
      OR previous_section_id IN (SELECT my_section_ids())
      OR created_by      = auth.uid()
      OR received_by      = auth.uid()
    )
  );

-- ── internal_requests_select: same ───────────────────────────────
DROP POLICY IF EXISTS "internal_requests_select" ON internal_requests;
CREATE POLICY "internal_requests_select" ON internal_requests
  FOR SELECT USING (
    from_section_id IN (SELECT my_section_ids())
    OR to_section_id IN (SELECT my_section_ids())
    OR previous_section_id IN (SELECT my_section_ids())
    OR created_by = auth.uid()
    OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', to_section_id))
  );

-- ── internal_requests_update: qualification fix + explicit WITH CHECK ──
DROP POLICY IF EXISTS "internal_requests_update" ON internal_requests;
CREATE POLICY "internal_requests_update" ON internal_requests
  FOR UPDATE USING (
    (
      to_section_id IN (SELECT my_section_ids())
      OR from_section_id IN (SELECT my_section_ids())
      OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', to_section_id))
    )
    AND EXISTS (SELECT 1 FROM requests r WHERE r.id = internal_requests.parent_request_id AND r.status <> 'cancelled')
  )
  WITH CHECK (
    (
      to_section_id IN (SELECT my_section_ids())
      OR from_section_id IN (SELECT my_section_ids())
      OR previous_section_id IN (SELECT my_section_ids())
      OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', to_section_id))
    )
    AND EXISTS (SELECT 1 FROM requests r WHERE r.id = internal_requests.parent_request_id AND r.status <> 'cancelled')
  );

-- ── revert the inert section-receiver WITH CHECK loosening ───────
DROP POLICY IF EXISTS "requests_update_section_receiver" ON requests;
CREATE POLICY "requests_update_section_receiver" ON requests
  FOR UPDATE USING (
    to_section_id IS NOT NULL AND has_role_in_section(to_section_id, 'assigned_receiver')
  )
  WITH CHECK (
    to_section_id IS NOT NULL AND has_role_in_section(to_section_id, 'assigned_receiver')
  );

COMMIT;
