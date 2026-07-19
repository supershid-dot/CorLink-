-- ─── Patch: track "returned for correction" on Entry replies ──────
-- requests-api.js's returnRequest/returnResponse insert a row into
-- approvals (decision='returned') so the dashboard's "Returned for
-- Correction" row can find it later — entry-api.js's returnReply()
-- never did this, so the equivalent case for Entry replies was
-- silently invisible on the drafting staff member's dashboard. This
-- adds the missing record_type to approvals so entry-api.js can start
-- inserting into it (see the accompanying JS change).
--
-- Idempotent — safe to run more than once.

BEGIN;

ALTER TABLE approvals DROP CONSTRAINT IF EXISTS approvals_record_type_check;
ALTER TABLE approvals ADD CONSTRAINT approvals_record_type_check
  CHECK (record_type IN ('request', 'response', 'prisoner_letter', 'deadline_extension', 'external_correspondence_reply'));

DROP POLICY IF EXISTS "approvals_select" ON approvals;
CREATE POLICY "approvals_select" ON approvals
  FOR SELECT USING (
    reviewed_by = auth.uid()
    OR (record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r WHERE r.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          is_admin()
          OR r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id   IN (SELECT my_section_ids())
          OR r.created_by      = auth.uid()
          OR r.received_by     = auth.uid()
        )
    ))
    OR (record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses re JOIN requests r ON r.id = re.request_id
      WHERE re.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          is_admin()
          OR r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id   IN (SELECT my_section_ids())
          OR r.created_by      = auth.uid()
          OR re.created_by     = auth.uid()
          OR re.received_by    = auth.uid()
        )
    ))
    OR (record_type = 'external_correspondence_reply' AND EXISTS (
      SELECT 1 FROM external_correspondence_replies ecr
      JOIN external_correspondence ec ON ec.id = ecr.entry_id
      WHERE ecr.id = record_id
        AND ec.org_id = get_my_org_id()
        AND (
          is_admin()
          OR (ec.to_section_id IS NOT NULL AND ec.to_section_id IN (SELECT my_section_ids()))
          OR ecr.created_by = auth.uid()
        )
    ))
  );

COMMIT;
