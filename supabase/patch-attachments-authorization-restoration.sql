-- ============================================================
-- CorLink — Attachments RLS Authorization Restoration
-- Testing-readiness P0-B correction (docs/98 §26, docs/100)
--
-- ROOT CAUSE (independently re-verified this session by inspecting
-- live pg_policy state and every prior patch's own source):
--
-- patch-task-attachments.sql (2026-08-01, T3D) is the last patch to
-- correctly restate all three attachments_select/_insert/_delete
-- policies with the FULL branch set that existed at that point:
-- request, response, internal_request, prisoner_letter, prisoner_reply,
-- internal_reply, external_correspondence, external_correspondence_
-- reply, meeting, task.
--
-- patch-prisoner-letters-server-mutation-foundation.sql (2026-08-14,
-- Phase 1.9A) then performed its own DROP POLICY + CREATE POLICY on
-- all three policies, to narrow prisoner_letter/prisoner_reply to the
-- new Phase 1.9A authorization model (submitted_by/assigned_to +
-- supervisor bypass, plus a `pl.status <> 'delivered'` finalization
-- lock on insert/delete). Its own restated body was evidently derived
-- from an earlier snapshot that predates patch-meetings-foundation.sql
-- (2026-07-22) and patch-task-attachments.sql (2026-08-01) — it does
-- not reference `meeting`, `task` (all three policies), or
-- `external_correspondence`/`external_correspondence_reply`
-- (attachments_select/attachments_insert only; attachments_delete
-- happens to already include those last two). No malicious intent —
-- a narrow patch's own restated policy body silently regressed
-- capability it never intended to touch, because DROP+CREATE POLICY
-- has no partial/incremental form in Postgres.
--
-- Net effect on any environment with the complete, correct patch chain
-- applied (confirmed live, reproduced twice on independent fresh
-- rebuilds): Task attachment upload/view/delete completely broken;
-- Meeting attachment upload/view/delete completely broken; Entry and
-- Entry-reply attachment upload/view broken (delete still worked).
--
-- THIS PATCH is forward-only. It does not edit or rewrite the two
-- patches above (docs/97, the notification-integration milestone
-- layered on top of Phase 1.9A, is already pushed history downstream
-- of the defect and must not be disturbed). It restates all three
-- policies one more time, as the new final word, merging:
--   - request / response / internal_request / internal_reply: carried
--     forward unchanged (identical in both prior sources).
--   - prisoner_letter / prisoner_reply: carried forward EXACTLY as
--     Phase 1.9A defined them — the narrowed model and the
--     `pl.status <> 'delivered'` finalization lock are preserved
--     byte-for-byte. This patch strengthens nothing and weakens
--     nothing about Prisoner Letters' own authorization; it only
--     restores what Phase 1.9A never intended to remove.
--   - external_correspondence / external_correspondence_reply:
--     restored verbatim from patch-task-attachments.sql (attachments_
--     select/attachments_insert only — attachments_delete already had
--     them, carried forward unchanged there).
--   - meeting / task: restored verbatim from
--     patch-task-attachments.sql, unchanged since no patch after it
--     ever touched either branch.
--
-- No new business role, no same-org-is-enough shortcut, no broadening
-- of any existing branch's condition, no frontend workaround. Every
-- condition below is copied verbatim from an already-shipped,
-- already-reviewed patch — nothing here is newly invented.
--
-- Idempotent — safe to run more than once (DROP POLICY IF EXISTS).
-- ============================================================

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
    OR (record_type = 'external_correspondence' AND EXISTS (
      SELECT 1 FROM external_correspondence ec WHERE ec.id = record_id
        AND ec.org_id = get_my_org_id()
        AND (
          is_entry_staff(ec.org_id)
          OR ec.to_section_id IN (SELECT my_section_ids())
          OR ec.assigned_to = auth.uid()
          OR ec.entered_by  = auth.uid()
        )
    ))
    OR (record_type = 'external_correspondence_reply' AND EXISTS (
      SELECT 1 FROM external_correspondence_replies ecr
      JOIN external_correspondence ec ON ec.id = ecr.entry_id
      WHERE ecr.id = record_id
        AND (
          ec.to_section_id IN (SELECT my_section_ids())
          OR ecr.created_by = auth.uid()
          OR (is_supervisor_or_above() AND ec.to_section_id IS NOT NULL AND get_my_org_id() = scope_org_id('section', ec.to_section_id))
          OR (ecr.status = 'sent' AND (is_entry_staff(ec.org_id) OR ec.entered_by = auth.uid()))
        )
    ))
    OR (record_type = 'meeting' AND can_view_meeting(record_id))
    OR (record_type = 'task' AND can_view_task(record_id))
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
      OR (record_type = 'external_correspondence' AND EXISTS (
        SELECT 1 FROM external_correspondence ec WHERE ec.id = record_id
          AND ec.org_id = get_my_org_id() AND is_entry_staff(ec.org_id) AND ec.status != 'closed'
      ))
      OR (record_type = 'external_correspondence_reply' AND EXISTS (
        SELECT 1 FROM external_correspondence_replies ecr WHERE ecr.id = record_id
          AND ecr.created_by = auth.uid() AND ecr.status IN ('draft', 'pending_approval')
      ))
      OR (record_type = 'meeting' AND can_manage_meeting(record_id) AND EXISTS (
        SELECT 1 FROM meetings m WHERE m.id = record_id AND m.status <> 'cancelled'
          AND (m.is_locked = FALSE OR is_meeting_lock_overridable(record_id))
      ))
      OR (record_type = 'task' AND EXISTS (
        SELECT 1 FROM tasks t WHERE t.id = record_id
          AND (
            is_super_admin()
            OR t.created_by = auth.uid()
            OR EXISTS (SELECT 1 FROM task_assignments ta WHERE ta.task_id = t.id AND ta.user_id = auth.uid() AND ta.is_active)
            OR (is_supervisor_or_above() AND t.organization_id = get_my_org_id()
                AND (t.owning_section_id IS NULL OR t.owning_section_id IN (SELECT my_section_ids())))
            OR is_admin()
          )
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
      OR (record_type = 'meeting' AND EXISTS (
        SELECT 1 FROM meetings m WHERE m.id = record_id AND m.status <> 'cancelled'
          AND (m.is_locked = FALSE OR is_meeting_lock_overridable(record_id))
      ))
      OR (record_type = 'task' AND EXISTS (
        SELECT 1 FROM tasks t WHERE t.id = record_id
          AND (
            is_super_admin()
            OR t.created_by = auth.uid()
            OR EXISTS (SELECT 1 FROM task_assignments ta WHERE ta.task_id = t.id AND ta.user_id = auth.uid() AND ta.is_active)
            OR (is_supervisor_or_above() AND t.organization_id = get_my_org_id()
                AND (t.owning_section_id IS NULL OR t.owning_section_id IN (SELECT my_section_ids())))
            OR is_admin()
          )
      ))
    )
  );

COMMIT;
