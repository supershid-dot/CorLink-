-- ─── Patch: block deleting attachments after the record locks ──
-- attachments_delete previously only checked `uploaded_by = auth.uid()`
-- — no lock/editability check at all, unlike attachments_insert (which
-- blocks new uploads once the parent record is locked/sent/closed).
-- That let an uploader delete their own attachment from a request or
-- response AFTER it had been approved and sent (or an internal reply/
-- Entry record after it left draft), silently removing a file from
-- what's supposed to be an immutable case record once it's out the
-- door — a real evidence-integrity gap for a correctional-service
-- correspondence system.
--
-- Now mirrors attachments_insert's own per-record_type editability
-- conditions exactly, so "can I delete this?" and "could I have
-- uploaded this right now?" are the same question:
--   - request/response: only while is_locked = FALSE
--   - internal_request/prisoner_letter/prisoner_reply: same org/
--     section-membership conditions as insert (no lock concept on
--     these today, matching insert's own lack of one)
--   - internal_reply/external_correspondence_reply: only while still
--     draft/pending_approval
--   - external_correspondence: only while status != 'closed'
--
-- Idempotent — safe to run more than once.

BEGIN;

DROP POLICY IF EXISTS "attachments_delete" ON attachments;
CREATE POLICY "attachments_delete" ON attachments
  FOR DELETE USING (
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
      OR (record_type = 'prisoner_letter' AND is_prisoner_letters_staff() AND EXISTS (
        SELECT 1 FROM prisoner_letters pl WHERE pl.id = record_id
          AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
      ))
      OR (record_type = 'prisoner_reply' AND is_prisoner_letters_staff() AND EXISTS (
        SELECT 1 FROM prisoner_replies pr JOIN prisoner_letters pl ON pl.id = pr.letter_id
        WHERE pr.id = record_id
          AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
      ))
      OR (record_type = 'internal_reply' AND EXISTS (
        SELECT 1 FROM internal_request_replies irr WHERE irr.id = record_id
          AND irr.created_by = auth.uid() AND irr.status IN ('draft', 'pending_approval')
      ))
      OR (record_type = 'external_correspondence' AND EXISTS (
        SELECT 1 FROM external_correspondence ec WHERE ec.id = record_id
          AND ec.org_id = get_my_org_id() AND is_entry_staff(ec.org_id) AND ec.status != 'closed'
      ))
      OR (record_type = 'external_correspondence_reply' AND EXISTS (
        SELECT 1 FROM external_correspondence_replies ecr WHERE ecr.id = record_id
          AND ecr.created_by = auth.uid() AND ecr.status IN ('draft', 'pending_approval')
      ))
    )
  );

COMMIT;
