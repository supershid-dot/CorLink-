-- ─── Patch: comment before approving an Entry reply ──────────────
-- Extends the existing review_comments mechanism (already used for
-- request/response drafts and internal-collaboration replies — a
-- supervisor leaves a comment before approving, the drafter resolves
-- it and resubmits) to also cover external_correspondence_replies
-- (Entry module replies). Reuses the same table/policies rather than
-- inventing a new mechanism — just a new record_type branch.
--
-- Idempotent — safe to run more than once.

BEGIN;

ALTER TABLE review_comments DROP CONSTRAINT IF EXISTS review_comments_record_type_check;
ALTER TABLE review_comments ADD CONSTRAINT review_comments_record_type_check
  CHECK (record_type IN ('request', 'response', 'internal_reply', 'entry_reply'));

DROP POLICY IF EXISTS "review_comments_select" ON review_comments;
CREATE POLICY "review_comments_select" ON review_comments
  FOR SELECT USING (
    created_by = auth.uid()
    OR (record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r WHERE r.id = record_id AND r.from_org_id = get_my_org_id()
    ))
    OR (record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses resp JOIN requests r ON r.id = resp.request_id
      WHERE resp.id = record_id AND r.to_org_id = get_my_org_id()
    ))
    OR (record_type = 'internal_reply' AND EXISTS (
      SELECT 1 FROM internal_request_replies irr JOIN internal_requests ir ON ir.id = irr.internal_request_id
      WHERE irr.id = record_id
        AND (ir.to_section_id IN (SELECT my_section_ids())
             OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id)))
    ))
    OR (record_type = 'entry_reply' AND EXISTS (
      SELECT 1 FROM external_correspondence_replies ecr JOIN external_correspondence ec ON ec.id = ecr.entry_id
      WHERE ecr.id = record_id
        AND (ec.to_section_id IN (SELECT my_section_ids())
             OR (is_supervisor_or_above() AND ec.to_section_id IS NOT NULL AND get_my_org_id() = scope_org_id('section', ec.to_section_id)))
    ))
  );

DROP POLICY IF EXISTS "review_comments_insert" ON review_comments;
CREATE POLICY "review_comments_insert" ON review_comments
  FOR INSERT WITH CHECK (
    created_by = auth.uid()
    AND is_supervisor_or_above()
    AND (
      (record_type = 'request' AND EXISTS (
        SELECT 1 FROM requests r WHERE r.id = record_id AND r.from_org_id = get_my_org_id()
      ))
      OR (record_type = 'response' AND EXISTS (
        SELECT 1 FROM responses resp JOIN requests r ON r.id = resp.request_id
        WHERE resp.id = record_id AND r.to_org_id = get_my_org_id()
      ))
      OR (record_type = 'internal_reply' AND EXISTS (
        SELECT 1 FROM internal_request_replies irr JOIN internal_requests ir ON ir.id = irr.internal_request_id
        WHERE irr.id = record_id AND get_my_org_id() = scope_org_id('section', ir.to_section_id)
      ))
      OR (record_type = 'entry_reply' AND EXISTS (
        SELECT 1 FROM external_correspondence_replies ecr JOIN external_correspondence ec ON ec.id = ecr.entry_id
        WHERE ecr.id = record_id AND ec.to_section_id IS NOT NULL AND get_my_org_id() = scope_org_id('section', ec.to_section_id)
      ))
    )
  );

DROP POLICY IF EXISTS "review_comments_update" ON review_comments;
CREATE POLICY "review_comments_update" ON review_comments
  FOR UPDATE USING (
    (record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r WHERE r.id = record_id AND r.from_org_id = get_my_org_id()
    ))
    OR (record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses resp JOIN requests r ON r.id = resp.request_id
      WHERE resp.id = record_id AND r.to_org_id = get_my_org_id()
    ))
    OR (record_type = 'internal_reply' AND EXISTS (
      SELECT 1 FROM internal_request_replies irr JOIN internal_requests ir ON ir.id = irr.internal_request_id
      WHERE irr.id = record_id
        AND (ir.to_section_id IN (SELECT my_section_ids())
             OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id)))
    ))
    OR (record_type = 'entry_reply' AND EXISTS (
      SELECT 1 FROM external_correspondence_replies ecr JOIN external_correspondence ec ON ec.id = ecr.entry_id
      WHERE ecr.id = record_id
        AND (ec.to_section_id IN (SELECT my_section_ids())
             OR (is_supervisor_or_above() AND ec.to_section_id IS NOT NULL AND get_my_org_id() = scope_org_id('section', ec.to_section_id)))
    ))
  );

COMMIT;
