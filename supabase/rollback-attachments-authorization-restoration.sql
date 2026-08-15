-- ============================================================
-- CorLink — Rollback: Attachments RLS Authorization Restoration
-- Reverses supabase/patch-attachments-authorization-restoration.sql
-- Testing-readiness P0-B correction (docs/100)
--
-- Restores attachments_select/_insert/_delete to the EXACT state
-- patch-prisoner-letters-server-mutation-foundation.sql (Phase 1.9A)
-- itself left them in — i.e. this rollback deliberately restores the
-- regression this correction fixed. This is a conscious choice
-- (matching every other rollback in this project, which restores to
-- the exact prior state rather than some "better" intermediate one):
-- rollback exists to undo THIS patch specifically, not to also
-- second-guess the patch before it.
--
-- Refuses if any attachment row of a record_type this patch restored
-- coverage for (meeting, task, external_correspondence,
-- external_correspondence_reply) already exists — rolling back would
-- silently make those rows permanently invisible/unmanageable through
-- RLS again, which is a real, not merely hypothetical, consequence
-- once this patch has been live in an environment for any length of
-- time. An operator who genuinely needs to roll back despite that
-- must first migrate or remove those rows out of band.
-- ============================================================

\set ON_ERROR_STOP on

DO $$
DECLARE
  v_count INT;
BEGIN
  SELECT count(*) INTO v_count
  FROM attachments
  WHERE record_type IN ('meeting', 'task', 'external_correspondence', 'external_correspondence_reply');

  IF v_count > 0 THEN
    RAISE EXCEPTION 'REFUSING rollback: % attachment row(s) exist for meeting/task/external_correspondence/external_correspondence_reply. Rolling back patch-attachments-authorization-restoration.sql would make these rows permanently unreadable/unmanageable through RLS (attachments_select/_insert/_delete would lose those branches again). Migrate or remove them out of band first if rollback is genuinely required.', v_count;
  END IF;
END $$;

BEGIN;

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
    OR (record_type = 'prisoner_letter' AND EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE pl.id = record_id
        AND (
          (pl.from_prison_id = get_my_org_id() AND (
            (is_prisoner_letters_staff() AND pl.submitted_by = auth.uid())
            OR is_supervisor_or_above()
          ))
          OR (pl.to_org_id = get_my_org_id() AND (
            (is_prisoner_letters_staff() AND pl.assigned_to = auth.uid())
            OR is_supervisor_or_above()
          ))
        )
    ))
    OR (record_type = 'prisoner_reply' AND EXISTS (
      SELECT 1 FROM prisoner_replies pr
      JOIN prisoner_letters pl ON pl.id = pr.letter_id
      WHERE pr.id = record_id
        AND (
          (pl.from_prison_id = get_my_org_id() AND (
            (is_prisoner_letters_staff() AND pl.submitted_by = auth.uid())
            OR is_supervisor_or_above()
          ))
          OR (pl.to_org_id = get_my_org_id() AND (
            (is_prisoner_letters_staff() AND pl.assigned_to = auth.uid())
            OR is_supervisor_or_above()
          ))
        )
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
          AND pl.status <> 'delivered'
          AND (
            (pl.from_prison_id = get_my_org_id() AND (
              (is_prisoner_letters_staff() AND pl.submitted_by = auth.uid())
              OR is_supervisor_or_above()
            ))
            OR (pl.to_org_id = get_my_org_id() AND (
              (is_prisoner_letters_staff() AND pl.assigned_to = auth.uid())
              OR is_supervisor_or_above()
            ))
          )
      ))
      OR (record_type = 'prisoner_reply' AND EXISTS (
        SELECT 1 FROM prisoner_replies pr JOIN prisoner_letters pl ON pl.id = pr.letter_id
        WHERE pr.id = record_id
          AND pl.status <> 'delivered'
          AND pl.to_org_id = get_my_org_id()
          AND (
            (is_prisoner_letters_staff() AND pl.assigned_to = auth.uid())
            OR is_supervisor_or_above()
          )
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
      OR (record_type = 'prisoner_letter' AND EXISTS (
        SELECT 1 FROM prisoner_letters pl WHERE pl.id = record_id
          AND pl.status <> 'delivered'
          AND (
            (pl.from_prison_id = get_my_org_id() AND (
              (is_prisoner_letters_staff() AND pl.submitted_by = auth.uid())
              OR is_supervisor_or_above()
            ))
            OR (pl.to_org_id = get_my_org_id() AND (
              (is_prisoner_letters_staff() AND pl.assigned_to = auth.uid())
              OR is_supervisor_or_above()
            ))
          )
      ))
      OR (record_type = 'prisoner_reply' AND EXISTS (
        SELECT 1 FROM prisoner_replies pr JOIN prisoner_letters pl ON pl.id = pr.letter_id
        WHERE pr.id = record_id
          AND pl.status <> 'delivered'
          AND pl.to_org_id = get_my_org_id()
          AND (
            (is_prisoner_letters_staff() AND pl.assigned_to = auth.uid())
            OR is_supervisor_or_above()
          )
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
