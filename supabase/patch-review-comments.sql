-- ─── Patch: Review comments on drafts awaiting approval ─────────
-- Word-style review loop: the supervisor quotes a passage of the
-- pending draft and attaches a note; the drafter fixes the draft,
-- resolves the comment, and resubmits — repeating until approved.
-- Idempotent; safe to run more than once.

BEGIN;

CREATE TABLE IF NOT EXISTS review_comments (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  record_type  TEXT        NOT NULL CHECK (record_type IN ('request', 'response', 'internal_reply')),
  record_id    UUID        NOT NULL,
  quoted_text  TEXT,
  comment      TEXT        NOT NULL,
  created_by   UUID        NOT NULL REFERENCES users(id),
  resolved_by  UUID        REFERENCES users(id),
  resolved_at  TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE review_comments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "review_comments_select" ON review_comments;
DROP POLICY IF EXISTS "review_comments_insert" ON review_comments;
DROP POLICY IF EXISTS "review_comments_update" ON review_comments;

-- ─── review_comments ────────────────────────────────────────────
-- Supervisor feedback on drafts is strictly a same-side, internal
-- artifact: comments on a REQUEST draft belong to the drafting org
-- (from_org), comments on a RESPONSE draft to the responding org
-- (to_org), and comments on an internal reply to the replying section's
-- side. The counterpart organization can never see review chatter.
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
  );

-- Only supervisors/admins comment (the reviewing role); the same-side
-- scoping repeats so a supervisor can't attach comments to the OTHER
-- org's drafts.
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
    )
  );

-- Resolving is the drafter's side of the loop — any same-side viewer
-- may update (set resolved_by/resolved_at); the visibility expression
-- above already excludes the counterpart org entirely.
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
  );

COMMIT;
