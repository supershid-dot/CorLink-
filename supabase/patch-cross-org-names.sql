-- ============================================================
-- CorLink — Patch: cross-org name resolution
--
-- Run this INSTEAD of re-running the full rls.sql.
--
-- Why: users_select_same_org only lets a user read profiles within
-- their OWN organization. But the Requests/Prisoner Letters UI shows
-- WHO on the OTHER side of a conversation submitted/approved/received/
-- was assigned something — e.g. "Received by [Name], [Designation]"
-- already assumed this worked. Without a matching policy, PostgREST's
-- embedded resource join silently returns null for a cross-org user
-- (RLS applies to embedded resources too, not just the top-level
-- query), which showed up in the UI as "Unknown" or blank names even
-- though the parent request/response/approval row itself was
-- correctly visible.
--
-- Scoped narrowly: only a user who is genuinely named on a request,
-- response, approval, prisoner_letter, or prisoner_reply the viewer
-- can already see via that record's own SELECT policy — not general
-- cross-org directory access. Verified against a real local Postgres
-- instance: a genuinely unrelated third organization still cannot
-- resolve these names.
-- ============================================================

BEGIN;

DROP POLICY IF EXISTS "users_select_correspondence" ON users;
CREATE POLICY "users_select_correspondence" ON users
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM requests r
      WHERE (r.created_by = users.id OR r.assigned_to = users.id OR r.received_by = users.id)
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
    )
    OR EXISTS (
      SELECT 1 FROM responses resp JOIN requests r ON r.id = resp.request_id
      WHERE (resp.created_by = users.id OR resp.received_by = users.id)
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
    )
    OR EXISTS (
      SELECT 1 FROM approvals a
      WHERE a.reviewed_by = users.id
        AND (
          (a.record_type = 'request' AND EXISTS (
            SELECT 1 FROM requests r2 WHERE r2.id = a.record_id
              AND (r2.from_org_id = get_my_org_id() OR r2.to_org_id = get_my_org_id())
          ))
          OR (a.record_type = 'response' AND EXISTS (
            SELECT 1 FROM responses resp2 JOIN requests r3 ON r3.id = resp2.request_id
            WHERE resp2.id = a.record_id
              AND (r3.from_org_id = get_my_org_id() OR r3.to_org_id = get_my_org_id())
          ))
        )
    )
    OR EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE (pl.submitted_by = users.id OR pl.assigned_to = users.id)
        AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    )
    OR EXISTS (
      SELECT 1 FROM prisoner_replies pr JOIN prisoner_letters pl2 ON pl2.id = pr.letter_id
      WHERE pr.replied_by = users.id
        AND (pl2.from_prison_id = get_my_org_id() OR pl2.to_org_id = get_my_org_id())
    )
  );

COMMIT;
