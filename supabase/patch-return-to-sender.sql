-- ─── Patch: Return to Sender Section ─────────────────────────────
-- Lets a wrongly-routed section send an external request back to
-- whoever routed it there (one hop back, not a fixed org default),
-- and the equivalent for Internal Collaboration.
--
-- External requests get a new previous_section_id column, kept in
-- sync by a trigger independent of the status trigger — it fires on
-- every to_section_id change regardless of which code path makes it
-- (route, re-route, or a return itself), so ping-pong (A routes to B,
-- B returns to A, A can route it elsewhere again) keeps working.
-- IS DISTINCT FROM guards against a column-list trigger firing on a
-- same-value SET; OLD.to_section_id IS NOT NULL skips the very first
-- route, where there's no "previous section" yet.
--
-- Internal Collaboration needs NO schema/RLS change — internal_requests
-- .from_section_id is already fixed at creation and never touched by
-- reroute(), so it already IS the "who sent this to me" pointer, and
-- internal_requests_update's existing to_section_id-membership branch
-- already covers any member (not just supervisors) of the current
-- holder section.
--
-- 'returned_to_sender' is a new, distinct audit_logs action — not a
-- reuse of the existing 'returned' (used by returnRequest's draft-
-- rejection flow), so the two show up as separate, distinguishable
-- events in the case timeline.
--
-- No new RLS policy is needed for the write itself — requests_update_
-- supervisor already permits any org-scoped supervisor to change
-- to_section_id regardless of current holder (pre-existing, intentional
-- broadness documented on that policy). Narrower enforcement (which
-- section can click the button) lives in the UI gate, matching how
-- "Route to Another Section" already works today.
--
-- Idempotent — safe to run more than once.

BEGIN;

ALTER TABLE requests
  ADD COLUMN IF NOT EXISTS previous_section_id UUID REFERENCES sections(id);

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_action_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_action_check CHECK (action IN (
  'created', 'edited', 'submitted', 'approved', 'returned',
  'sent', 'received', 'routed', 'assigned',
  'returned_to_sender', 'cancelled',
  'extension_requested', 'extension_approved', 'extension_denied',
  'viewed', 'login', 'logout', 'login_failed', 'locked',
  'password_changed', 'user_created', 'user_deactivated'
));

CREATE OR REPLACE FUNCTION trigger_track_previous_section()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.to_section_id IS DISTINCT FROM OLD.to_section_id AND OLD.to_section_id IS NOT NULL THEN
    NEW.previous_section_id := OLD.to_section_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS track_previous_section ON requests;
CREATE TRIGGER track_previous_section BEFORE UPDATE OF to_section_id ON requests
  FOR EACH ROW EXECUTE FUNCTION trigger_track_previous_section();

COMMIT;
