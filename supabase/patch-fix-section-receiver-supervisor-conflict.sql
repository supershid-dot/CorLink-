-- ─── Patch: fix supervisor+assigned_receiver dual-role routing block ──
-- Real bug, found while testing Return to Sender Section — NOT
-- introduced by that feature. Any user who holds BOTH 'supervisor' and
-- 'assigned_receiver' roles on the same section (a normal combination —
-- a section supervisor also flagged as their section's assigned
-- receiver) could not route or return a request away from that section
-- at all, even though their supervisor role alone should fully
-- authorize it. "Route to Another Section" has had this latent bug
-- since assigned_receiver's policies were introduced; it just hadn't
-- been exercised by that exact role combination before.
--
-- Root cause: Postgres RLS requires EVERY policy whose USING clause
-- matches the pre-update row to ALSO have its WITH CHECK pass on the
-- new row — a broader policy (requests_update_supervisor) authorizing
-- the write does NOT exempt a narrower policy whose USING also matched.
-- requests_update_section_receiver's USING matches any request routed
-- to a section the actor holds assigned_receiver in; its WITH CHECK
-- (deliberately, for a PURE assigned_receiver — "no rank of its own")
-- then blocks moving it anywhere else. For a dual-role user this fired
-- even though requests_update_supervisor's own WITH CHECK was
-- independently true the whole time.
--
-- Fix: add "OR is_supervisor_or_above()" to this policy's WITH CHECK,
-- so holding the narrower assigned_receiver role never downgrades
-- someone who is ALSO a supervisor. The USING clause is untouched —
-- this only affects which further section a request can be moved to,
-- not which requests a plain assigned_receiver can act on in the
-- first place.
--
-- Confirmed empirically against the reporting org's live database: a
-- user who is both supervisor and assigned_receiver on the same
-- section had "Route to Another Section" and "Return to Sender
-- Section" both throw "new row violates row-level security policy for
-- table requests" before this fix (isolated via direct SQL
-- impersonation of that exact account, ruling out every other
-- candidate cause first).
--
-- Idempotent — safe to run more than once.

BEGIN;

DROP POLICY IF EXISTS "requests_update_section_receiver" ON requests;
CREATE POLICY "requests_update_section_receiver" ON requests
  FOR UPDATE USING (
    to_section_id IS NOT NULL AND has_role_in_section(to_section_id, 'assigned_receiver')
  )
  WITH CHECK (
    (to_section_id IS NOT NULL AND has_role_in_section(to_section_id, 'assigned_receiver'))
    OR is_supervisor_or_above()
  );

COMMIT;
