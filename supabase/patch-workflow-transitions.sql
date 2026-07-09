-- ─── Patch: server-side enforcement of requests/responses status transitions ──
-- RLS gates WHO can update these rows, but says nothing about WHICH
-- status transition is being made — a legitimately-authorized
-- supervisor's UPDATE grant could, via a direct API call bypassing
-- js/data/requests-api.js entirely, jump a request straight from
-- 'draft' to 'sent' (skipping the approvals-table record of who
-- reviewed it and why), or otherwise walk the status column somewhere
-- the app's own workflow never goes.
--
-- Every edge below is taken directly from js/data/requests-api.js's
-- actual .update({status: ...}) call sites. 'overdue' (requests only;
-- set by check_deadlines() in supabase/notifications.sql) is treated
-- as an orthogonal flag layered on top of pending_approval/sent/
-- received/in_progress rather than its own branch — every downstream
-- edge any of those four could take is allowed FROM 'overdue' too.
--
-- Verified against a real local Postgres instance: the full legitimate
-- chain (draft -> pending_approval -> sent -> received -> in_progress
-- -> responded -> closed), the return-for-correction loop, and the
-- overdue overlay all succeed; a direct draft -> sent skip and a
-- closed -> draft reversal are both rejected; a non-status UPDATE
-- (e.g. assigned_to only) doesn't invoke the trigger at all.
--
-- Idempotent — safe to run more than once.

BEGIN;

CREATE OR REPLACE FUNCTION valid_request_status_transition(old_status TEXT, new_status TEXT)
RETURNS BOOLEAN AS $$
  SELECT old_status = new_status OR (old_status, new_status) IN (
    ('draft', 'pending_approval'),
    ('pending_approval', 'sent'),
    ('pending_approval', 'draft'),
    ('pending_approval', 'overdue'),
    ('sent', 'received'),
    ('sent', 'overdue'),
    ('received', 'in_progress'),
    ('received', 'overdue'),
    ('in_progress', 'responded'),
    ('in_progress', 'overdue'),
    ('responded', 'closed'),
    ('overdue', 'sent'),
    ('overdue', 'draft'),
    ('overdue', 'received'),
    ('overdue', 'in_progress'),
    ('overdue', 'responded')
  );
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION trigger_check_request_status()
RETURNS TRIGGER AS $$
BEGIN
  IF NOT valid_request_status_transition(OLD.status, NEW.status) THEN
    RAISE EXCEPTION 'Invalid request status transition: % -> %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS check_request_status ON requests;
CREATE TRIGGER check_request_status BEFORE UPDATE OF status ON requests
  FOR EACH ROW EXECUTE FUNCTION trigger_check_request_status();

CREATE OR REPLACE FUNCTION valid_response_status_transition(old_status TEXT, new_status TEXT)
RETURNS BOOLEAN AS $$
  SELECT old_status = new_status OR (old_status, new_status) IN (
    ('draft', 'pending_approval'),
    ('pending_approval', 'sent'),
    ('pending_approval', 'draft')
  );
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION trigger_check_response_status()
RETURNS TRIGGER AS $$
BEGIN
  IF NOT valid_response_status_transition(OLD.status, NEW.status) THEN
    RAISE EXCEPTION 'Invalid response status transition: % -> %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS check_response_status ON responses;
CREATE TRIGGER check_response_status BEFORE UPDATE OF status ON responses
  FOR EACH ROW EXECUTE FUNCTION trigger_check_response_status();

COMMIT;
