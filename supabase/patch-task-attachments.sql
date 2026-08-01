-- ============================================================
-- CorLink — Task Attachments (T3D)
--
-- Reuses the EXISTING, already-generic attachments infrastructure
-- (the `attachments` table, the private `attachments` Storage bucket,
-- js/data/attachments-api.js) exactly as it already works for
-- requests/responses/internal requests/prisoner letters/entry/
-- meetings — the same "record_type + record_id" pattern, the same
-- upload/download/remove functions, the same client-side type/size
-- limits. No new table, bucket, or API wrapper was created.
--
-- The genuine gap this file closes: `patch-shared-task-foundation.sql`
-- deliberately shipped with NO attachment support at all (its own
-- comment: "No attachment column yet either — attachments are
-- 'supported later' per spec, meaning a future patch"). 'task' is not
-- a recognized record_type in `attachments_record_type_check`, and no
-- 'task' branch exists in `attachments_select`/`attachments_insert`/
-- `attachments_delete` — a task attachment upload/read/delete would be
-- rejected today. This is that later patch.
--
-- Same convention every prior attachments integration (entry, internal
-- reply, meeting) already used: DROP+CREATE is required to change a
-- policy — there is no incremental ALTER POLICY for adding one branch
-- — so `attachments_select`/`attachments_insert`/`attachments_delete`
-- are restated in full below, every existing branch preserved
-- verbatim, with exactly one new 'task' branch appended to each.
-- `attachments_select_cc` is untouched — CC recipients are a
-- Requests/Responses-only concept, not applicable to tasks.
--
-- Idempotent — safe to run more than once.
-- ============================================================

BEGIN;

-- ─── 1. CHECK constraint ────────────────────────────────────────
ALTER TABLE attachments DROP CONSTRAINT IF EXISTS attachments_record_type_check;
ALTER TABLE attachments ADD CONSTRAINT attachments_record_type_check
  CHECK (record_type IN (
    'request', 'response', 'prisoner_letter', 'internal_request', 'prisoner_reply',
    'internal_reply', 'external_correspondence', 'external_correspondence_reply', 'meeting', 'task'
  ));

-- ─── 2. attachments_select — restated from patch-meetings-
-- foundation.sql (its current, most recent version) + one new 'task'
-- branch. can_view_task() is SECURITY DEFINER (patch-shared-task-
-- foundation.sql), same shape can_view_meeting() already has here —
-- reused directly rather than re-deriving task visibility a second
-- time. ────────────────────────────────────────────────────────────
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

-- ─── 3. attachments_insert — restated from patch-meetings-lock.sql
-- (its current, most recent version) + one new 'task' branch, mirroring
-- update_task()'s/complete_task()'s own authorization exactly (creator/
-- active assignee/supervisor-in-scope/admin — the same predicate
-- js/views/task-detail.js's own _canEdit() mirror uses, see docs/47).
-- Deliberately symmetric with the 'task' branch in §4 below (insert
-- authorization == delete authorization) — matching the majority
-- convention every branch except 'meeting' already uses here; 'meeting'
-- alone has an insert/delete asymmetry (can_manage_meeting() required
-- to insert, not re-checked to delete) that is a meetings-specific
-- nuance, not a pattern to carry over to tasks. No completed/cancelled
-- lock guard is added — update_task() itself has none (see docs/47's
-- own "editing is not status-gated" note); adding one here would be an
-- attachment-specific restriction the task module's real editing
-- authorization doesn't otherwise have. ─────────────────────────────
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

-- ─── 4. attachments_delete — restated from patch-meetings-lock.sql,
-- same new 'task' branch as §3 (symmetric — see the comment above). ──
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

-- Storage bucket policy (attachments_storage_insert's per-record_type
-- allowlist) is NOT restated here — supabase/storage-policies.sql is a
-- directly-maintained, re-runnable setup script (not part of this
-- historical DROP+CREATE patch chain the way the table-level policies
-- above are; its own header already documents at least one prior
-- in-place fix for a missing 'internal_reply' entry), so it is edited
-- directly instead of duplicated/restated here. See that file for the
-- matching 'task' addition, and docs/48 §Known limitations for a
-- pre-existing, unrelated gap found in that same list while making
-- this change ('meeting' was never added there — left as-is, out of
-- this milestone's scope).

COMMIT;
