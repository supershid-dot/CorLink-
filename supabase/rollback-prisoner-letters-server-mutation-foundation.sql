-- Prisoner Letters server-mutation-foundation rollback. Reverses
-- patch-prisoner-letters-server-mutation-foundation.sql exactly.
--
-- ─── What this rollback restores ────────────────────────────────
-- Drops all 6 new business-command RPCs this milestone introduced,
-- restores direct client INSERT/UPDATE/DELETE on prisoner_letters/
-- prisoner_replies to `authenticated` (the exact pre-milestone grant
-- posture), restores generate_prisoner_letter_reference() to its
-- original body (no search_path pin, PUBLIC-callable, matching
-- schema.sql's own definition -- this is the one function the patch
-- modified in place rather than adding), and restores every RLS
-- policy this milestone touched (prisoner_letters_select/_insert/
-- _update, prisoner_replies_select/_insert, and the prisoner_letter/
-- prisoner_reply branches of attachments_select/_insert/_delete) to
-- the exact CREATE POLICY bodies already shipped in rls.sql -- copied
-- verbatim from that file, not reconstructed from memory.
--
-- ─── What this rollback does NOT touch ──────────────────────────
-- Every prisoner_letters/prisoner_replies/audit_logs/attachments row
-- this milestone's RPCs ever wrote remains exactly as committed --
-- rollback removes the MUTATION BOUNDARY, never the business data or
-- history it already produced. Task integration (patch-prisoner-
-- letter-task-integration.sql) is NOT reverted by this file -- its own
-- can_view_prisoner_letter()/can_manage_prisoner_letter_task_link()
-- realignment is a separate, additive change layered on top of this
-- milestone's RLS model; reverting this rollback without also
-- reverting that companion file's own commit would leave those two
-- helpers referencing a predicate that no longer matches
-- prisoner_letters_select. Any operator applying this rollback in a
-- real environment must also revert the companion Task-integration
-- commit's helper-function change in the same maintenance window (see
-- docs/96 "Rollback" section). Requests/Entry/Internal Collaboration
-- mutation foundations are completely untouched, since this milestone
-- never modified them.
--
-- ─── Frontend rollback ───────────────────────────────────────────
-- js/data/prisoner-letters-api.js is reverted via a plain git revert
-- of this milestone's commit (this repository has no frontend
-- migration/versioning system, same convention as every prior CAP-003
-- phase's rollback) -- independent of whether this SQL rollback is
-- also applied. Reverting the frontend WITHOUT running this SQL
-- rollback would simply mean the (now unused) RPCs remain granted and
-- direct table writes remain revoked, which breaks the reverted
-- frontend's direct-write calls -- the two rollbacks are meant to be
-- applied together, exactly like the forward migration was.
\set ON_ERROR_STOP on
BEGIN;

GRANT INSERT, UPDATE, DELETE ON TABLE prisoner_letters, prisoner_replies TO authenticated;

DROP FUNCTION IF EXISTS create_prisoner_letter(UUID,UUID,UUID,TEXT);
DROP FUNCTION IF EXISTS mark_prisoner_letter_received(UUID);
DROP FUNCTION IF EXISTS route_prisoner_letter(UUID,UUID,UUID);
DROP FUNCTION IF EXISTS mark_prisoner_letter_slip_generated(UUID);
DROP FUNCTION IF EXISTS create_prisoner_letter_reply(UUID,TEXT);
DROP FUNCTION IF EXISTS mark_prisoner_letter_delivered(UUID);

-- Restore generate_prisoner_letter_reference() to its exact original
-- (pre-milestone) body -- verbatim from schema.sql.
CREATE OR REPLACE FUNCTION generate_prisoner_letter_reference(p_org_id UUID)
RETURNS TEXT AS $$
DECLARE
  v_year INTEGER := EXTRACT(YEAR FROM NOW());
  v_seq  INTEGER;
  v_code TEXT;
BEGIN
  INSERT INTO letter_reference_sequences (org_id, year, next_sequence)
  VALUES (p_org_id, v_year, 2)
  ON CONFLICT (org_id, year)
  DO UPDATE SET next_sequence = letter_reference_sequences.next_sequence + 1
  RETURNING next_sequence - 1 INTO v_seq;

  SELECT code INTO v_code FROM organizations WHERE id = p_org_id;
  RETURN 'PL-' || COALESCE(v_code, 'ORG') || '-' || v_year || '-' || LPAD(v_seq::TEXT, 4, '0');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION generate_prisoner_letter_reference(UUID) TO PUBLIC;

-- Restore prisoner_letters/prisoner_replies RLS to the exact bodies in
-- rls.sql (the coarse flag+party-org model, no submitted_by/
-- assigned_to/supervisor narrowing).
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

-- Restore attachments_select/_insert/_delete to the exact bodies in
-- rls.sql -- every record_type branch, verbatim, including the
-- prisoner_letter/prisoner_reply branches this milestone narrowed and
-- the finalization lock it added to attachments_insert/_delete.
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
      SELECT 1 FROM prisoner_letters pl WHERE pl.id = record_id
        AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
    ))
    OR (record_type = 'prisoner_reply' AND is_prisoner_letters_staff() AND EXISTS (
      SELECT 1 FROM prisoner_replies pr JOIN prisoner_letters pl ON pl.id = pr.letter_id
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
          AND (pr.replied_by = auth.uid() OR pl.to_org_id = get_my_org_id())
      ))
      OR (record_type = 'internal_reply' AND EXISTS (
        SELECT 1 FROM internal_request_replies irr WHERE irr.id = record_id
          AND irr.created_by = auth.uid() AND irr.status IN ('draft', 'pending_approval')
      ))
    )
  );

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
