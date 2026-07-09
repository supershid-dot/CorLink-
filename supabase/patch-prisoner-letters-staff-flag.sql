-- ─── Patch: restrict Prisoner Letters to individually-flagged staff ──
-- Prisoner letters previously followed the same "submitter, assignee,
-- or any supervisor" visibility shape as every other module — anyone
-- in the org could see the "Prisoner Letters" menu and (once opened)
-- their own letters, and any supervisor could see the org's whole
-- traffic. This narrows the whole module down to staff individually
-- designated for prisoner-letters duty (users.is_prisoner_letters_staff,
-- granted per-user via Admin > Manage User) — deliberately with NO
-- automatic bypass for supervisors/admins, unlike every other
-- "designated X" feature in this codebase. Grant it to whoever should
-- actually handle this after running this patch, or nobody will be
-- able to use the module at all.
--
-- Idempotent — safe to run more than once.

BEGIN;

ALTER TABLE users ADD COLUMN IF NOT EXISTS is_prisoner_letters_staff BOOLEAN NOT NULL DEFAULT FALSE;

CREATE OR REPLACE FUNCTION is_prisoner_letters_staff()
RETURNS BOOLEAN AS $$
  SELECT COALESCE((SELECT is_prisoner_letters_staff FROM users WHERE id = auth.uid()), FALSE);
$$ LANGUAGE sql STABLE SECURITY DEFINER;

DROP POLICY IF EXISTS "prisoner_letters_select" ON prisoner_letters;
CREATE POLICY "prisoner_letters_select" ON prisoner_letters
  FOR SELECT USING (
    is_prisoner_letters_staff()
    AND (from_prison_id = get_my_org_id() OR to_org_id = get_my_org_id())
  );

DROP POLICY IF EXISTS "prisoner_letters_insert" ON prisoner_letters;
CREATE POLICY "prisoner_letters_insert" ON prisoner_letters
  FOR INSERT WITH CHECK (
    submitted_by = auth.uid()
    AND is_prisoner_letters_staff()
    AND from_prison_id = get_my_org_id()
    AND EXISTS (SELECT 1 FROM organizations o WHERE o.id = from_prison_id AND o.type = 'mcs')
    AND EXISTS (SELECT 1 FROM organizations o WHERE o.id = to_org_id AND o.type = 'authority')
  );

DROP POLICY IF EXISTS "prisoner_letters_update" ON prisoner_letters;
CREATE POLICY "prisoner_letters_update" ON prisoner_letters
  FOR UPDATE USING (
    is_prisoner_letters_staff()
    AND (from_prison_id = get_my_org_id() OR to_org_id = get_my_org_id())
  );

DROP POLICY IF EXISTS "prisoner_replies_select" ON prisoner_replies;
CREATE POLICY "prisoner_replies_select" ON prisoner_replies
  FOR SELECT USING (
    is_prisoner_letters_staff()
    AND EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE pl.id = letter_id
        AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    )
  );

DROP POLICY IF EXISTS "prisoner_replies_insert" ON prisoner_replies;
CREATE POLICY "prisoner_replies_insert" ON prisoner_replies
  FOR INSERT WITH CHECK (
    replied_by = auth.uid()
    AND is_prisoner_letters_staff()
    AND EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE pl.id = letter_id
        AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    )
  );

DROP POLICY IF EXISTS "attachments_select" ON attachments;
CREATE POLICY "attachments_select" ON attachments
  FOR SELECT USING (
    uploaded_by = auth.uid()
    OR (record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id IN (SELECT my_section_ids())
          OR r.created_by = auth.uid()
          OR is_admin()
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
          OR is_admin()
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
    OR (record_type = 'prisoner_letter' AND is_prisoner_letters_staff() AND EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE pl.id = record_id
        AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    ))
    OR (record_type = 'prisoner_reply' AND is_prisoner_letters_staff() AND EXISTS (
      SELECT 1 FROM prisoner_replies pr
      JOIN prisoner_letters pl ON pl.id = pr.letter_id
      WHERE pr.id = record_id
        AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
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
    )
  );

DROP POLICY IF EXISTS "prisoners_select" ON prisoners;
CREATE POLICY "prisoners_select" ON prisoners
  FOR SELECT USING (
    org_id = get_my_org_id()
    AND (is_prisoner_letters_staff() OR is_prisoner_registry_manager(org_id))
  );

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
    OR (is_prisoner_letters_staff() AND EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE (pl.submitted_by = users.id OR pl.assigned_to = users.id)
        AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    ))
    OR (is_prisoner_letters_staff() AND EXISTS (
      SELECT 1 FROM prisoner_replies pr JOIN prisoner_letters pl2 ON pl2.id = pr.letter_id
      WHERE pr.replied_by = users.id
        AND (pl2.from_prison_id = get_my_org_id() OR pl2.to_org_id = get_my_org_id())
    ))
  );

COMMIT;
