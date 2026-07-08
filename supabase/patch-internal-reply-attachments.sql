-- ─── Patch: Attachments on Internal Reply Drafts ────────────────
-- "Draft Reply" (Internal Collaboration) can now attach files, same
-- pending-then-upload-after-create pattern used everywhere else in
-- this app. New 'internal_reply' record_type for attachments, plus
-- matching attachments_select/attachments_insert branches mirroring
-- internal_request_replies_select's own visibility shape.
--
-- Idempotent — safe to run more than once.

BEGIN;

ALTER TABLE attachments DROP CONSTRAINT IF EXISTS attachments_record_type_check;
ALTER TABLE attachments ADD CONSTRAINT attachments_record_type_check
  CHECK (record_type IN ('request', 'response', 'prisoner_letter', 'internal_request', 'prisoner_reply', 'internal_reply'));

DROP POLICY IF EXISTS "attachments_select" ON attachments;
CREATE POLICY "attachments_select" ON attachments
  FOR SELECT USING (
    uploaded_by = auth.uid()
    OR is_supervisor_or_above()
    OR (record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id IN (SELECT my_section_ids())
          OR r.created_by = auth.uid()
        )
    ))
    OR (record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses re
      JOIN requests r ON r.id = re.request_id
      WHERE re.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id IN (SELECT my_section_ids())
          OR r.created_by = auth.uid()
        )
    ))
    OR (record_type = 'internal_request' AND EXISTS (
      SELECT 1 FROM internal_requests ir
      WHERE ir.id = record_id
        AND (
          ir.from_section_id IN (SELECT my_section_ids())
          OR ir.to_section_id IN (SELECT my_section_ids())
          OR ir.created_by = auth.uid()
          OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
        )
    ))
    OR (record_type = 'prisoner_letter' AND EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE pl.id = record_id
        AND (pl.submitted_by = auth.uid() OR pl.assigned_to = auth.uid()
             OR pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    ))
    OR (record_type = 'prisoner_reply' AND EXISTS (
      SELECT 1 FROM prisoner_replies pr
      JOIN prisoner_letters pl ON pl.id = pr.letter_id
      WHERE pr.id = record_id
        AND (pl.submitted_by = auth.uid() OR pl.assigned_to = auth.uid()
             OR pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    ))
    OR (record_type = 'internal_reply' AND EXISTS (
      SELECT 1 FROM internal_request_replies irr
      JOIN internal_requests ir ON ir.id = irr.internal_request_id
      WHERE irr.id = record_id
        AND (
          ir.to_section_id IN (SELECT my_section_ids())
          OR irr.created_by = auth.uid()
          OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
          OR (
            irr.status = 'sent'
            AND (ir.from_section_id IN (SELECT my_section_ids()) OR ir.created_by = auth.uid())
          )
        )
    ))
  );

DROP POLICY IF EXISTS "attachments_insert" ON attachments;
CREATE POLICY "attachments_insert" ON attachments
  FOR INSERT WITH CHECK (
    uploaded_by = auth.uid()
    AND (
      (record_type = 'request' AND EXISTS (
        SELECT 1 FROM requests r WHERE r.id = record_id
          AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
          AND r.is_locked = FALSE
      ))
      OR (record_type = 'response' AND EXISTS (
        SELECT 1 FROM responses re JOIN requests r ON r.id = re.request_id
        WHERE re.id = record_id
          AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
          AND re.is_locked = FALSE
      ))
      OR (record_type = 'internal_request' AND EXISTS (
        SELECT 1 FROM internal_requests ir WHERE ir.id = record_id
          AND (
            ir.from_section_id IN (SELECT my_section_ids())
            OR ir.to_section_id IN (SELECT my_section_ids())
            OR ir.created_by = auth.uid()
          )
      ))
      OR (record_type = 'prisoner_letter' AND EXISTS (
        SELECT 1 FROM prisoner_letters pl WHERE pl.id = record_id
          AND (pl.submitted_by = auth.uid() OR pl.assigned_to = auth.uid()
               OR pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
      ))
      OR (record_type = 'prisoner_reply' AND EXISTS (
        SELECT 1 FROM prisoner_replies pr JOIN prisoner_letters pl ON pl.id = pr.letter_id
        WHERE pr.id = record_id
          AND (pr.replied_by = auth.uid() OR pl.to_org_id = get_my_org_id())
      ))
      OR (record_type = 'internal_reply' AND EXISTS (
        SELECT 1 FROM internal_request_replies irr WHERE irr.id = record_id
          AND irr.created_by = auth.uid() AND irr.status IN ('draft', 'pending_approval')
      ))
    )
  );

COMMIT;
