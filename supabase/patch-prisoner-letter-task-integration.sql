-- ============================================================
-- CorLink — Prisoner Letters ↔ Shared Tasks Integration
--
-- Fifth and final consumer of task_links (R4 Requests, R5 Meetings, R6
-- Internal Collaboration, R7 Entry). module_key widens from ('request',
-- 'meeting', 'internal_request', 'external_correspondence') to also
-- allow 'prisoner_letter' — the canonical value this codebase already
-- uses for this concept everywhere else (audit_logs.record_type,
-- cc_recipients/attachments.record_type, PrisonerLettersAPI's own
-- logAudit() calls). No alias was invented — 'prisoner_letters' (the
-- table name) was deliberately NOT used; 'prisoner_letter' (singular)
-- is the value already established by every other reference to this
-- concept.
--
-- Prisoner Letters and Tasks remain fully independent business
-- objects, same as R4/R5/R6/R7: task_links.record_id has no foreign
-- key (deliberate, matching the existing cc_recipients/audit_logs
-- precedent) — no code path in this patch reads or writes
-- prisoner_letters.status from a Task RPC, or the reverse. Submitting,
-- marking received, routing, replying, or marking delivered never
-- touches a linked Task; completing/cancelling a Task never touches
-- its linked letter.
--
-- Idempotent — safe to run more than once.
-- ============================================================

BEGIN;

-- ─── 1. Widen task_links.module_key ────────────────────────────
-- Preserves 'request' (R4), 'meeting' (R5), 'internal_request' (R6),
-- and 'external_correspondence' (R7) exactly as they were; adds
-- 'prisoner_letter' only. This is the final module_key value for the
-- Shared Task Foundation program.
ALTER TABLE task_links DROP CONSTRAINT IF EXISTS task_links_module_key_check;
ALTER TABLE task_links ADD CONSTRAINT task_links_module_key_check
  CHECK (module_key IN ('request', 'meeting', 'internal_request', 'external_correspondence', 'prisoner_letter'));

-- No new indexes needed: idx_task_links_module_record,
-- idx_task_links_active_unique, idx_task_links_record_active_created,
-- and idx_task_links_task_active_created (all from R4) are already
-- generic composite indexes keyed on (module_key, record_id) / task_id
-- — 'prisoner_letter' is just another value in the same leading
-- column. Confirmed by EXPLAIN during testing (see docs/37
-- "Performance").

-- ─── 2. Authorization helpers ───────────────────────────────────

-- "Can this user even SEE this Prisoner Letter" — mirrors
-- prisoner_letters_select verbatim (patch-prisoner-letters-staff-
-- flag.sql, the file that actually governs this table's current
-- policy — confirmed by tracing chain order: it runs AFTER patch-
-- prisoner-registry-section.sql, so its policy bodies are the live
-- ones). Deliberately coarse, matching the real predicate exactly:
-- is_prisoner_letters_staff() (a per-user flag, granted individually
-- via Admin > Manage User — "deliberately with NO automatic bypass
-- for supervisors/admins", per that file's own comment) AND either
-- party org matches the caller's own org. No section/assignee
-- narrowing exists in the real RLS for this table, so none is added
-- here either. SECURITY DEFINER so it can be called from
-- can_view_task_link() below without recursing back through
-- prisoner_letters' own RLS.
CREATE OR REPLACE FUNCTION can_view_prisoner_letter(p_letter_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM prisoner_letters pl
    WHERE pl.id = p_letter_id
      AND is_prisoner_letters_staff()
      AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- "Can this user actively manage (create/link/unlink) supporting work
-- on this letter" — reuses can_view_prisoner_letter() directly, same
-- technique R4's can_manage_request_task_link() and R7's can_manage_
-- entry_task_link() used. The real prisoner_letters_update RLS policy
-- is exactly as coarse as prisoner_letters_select (same is_prisoner_
-- letters_staff() + party-org predicate, no assigned_to/supervisor
-- narrowing at the RLS layer) — js/data/prisoner-letters-api.js's own
-- top-of-file comment describes a narrower intended actor set
-- ("assigned staff member, submitter, or supervisor"), but that is
-- enforced only client-side (prisoner-letter-detail.js's button
-- gating), not by the database. Reusing the real, currently-enforced
-- predicate — not the aspirational UI-only one — is the correct
-- "reuse existing authorization" choice; inventing a narrower DB-level
-- check here that doesn't exist anywhere else on this table would be
-- new authorization design, not reuse.
CREATE OR REPLACE FUNCTION can_manage_prisoner_letter_task_link(p_letter_id UUID)
RETURNS BOOLEAN AS $$
  SELECT can_view_prisoner_letter(p_letter_id);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- Generic "can this user see this link" — extended via CREATE OR
-- REPLACE (never touching R4/R5/R6/R7's own files) with a fifth and
-- final branch. Both the Task and the Prisoner Letter must
-- independently pass visibility for the link to be visible — a user
-- can never learn a hidden Task is linked to a visible letter, or that
-- a visible Task is linked to a hidden letter, and (since can_view_
-- prisoner_letter() requires the specific is_prisoner_letters_staff
-- flag PLUS org membership, never bare org membership alone) never a
-- cross-org letter, and never any letter at all for a user without the
-- flag — this is the strongest confidentiality gate of any module_key
-- value in task_links.
CREATE OR REPLACE FUNCTION can_view_task_link(p_task_id UUID, p_module_key TEXT, p_record_id UUID)
RETURNS BOOLEAN AS $$
  SELECT can_view_task(p_task_id) AND (
    (p_module_key = 'request' AND can_view_request_or_response('request', p_record_id))
    OR (p_module_key = 'meeting' AND EXISTS (
      SELECT 1 FROM meeting_decisions md
      WHERE md.id = p_record_id
        AND current_user_module_enabled('meetings')
        AND can_view_meeting(md.meeting_id)
    ))
    OR (p_module_key = 'internal_request' AND can_view_internal_request(p_record_id))
    OR (p_module_key = 'external_correspondence' AND can_view_entry(p_record_id))
    OR (p_module_key = 'prisoner_letter' AND can_view_prisoner_letter(p_record_id))
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. RPCs ────────────────────────────────────────────────────
-- Actor identity always from auth.uid(), never a client-supplied
-- parameter, matching every RPC in R3/R4/R5/R6/R7.

-- Business rule matrix (see docs/37 for the full write-up):
--   submitted / received / replied -> create + link allowed (to any
--     is_prisoner_letters_staff-flagged user at either party org)
--   delivered                      -> create + link BLOCKED (terminal
--     status — prisoner-letter-detail.js's own _renderActions() shows
--     zero action buttons once delivered, and locks attachment upload
--     on both sides, matching every other "closed"-equivalent status
--     across R4-R7)
--   any status                     -> unlink always allowed (soft
--     removal only, never new work, same posture as R4/R5/R6/R7's own
--     unlink RPCs)

CREATE OR REPLACE FUNCTION create_prisoner_letter_supporting_task(
  p_letter_id UUID,
  p_title TEXT,
  p_description TEXT DEFAULT NULL,
  p_owning_section_id UUID DEFAULT NULL,
  p_priority TEXT DEFAULT 'normal',
  p_visibility TEXT DEFAULT 'section',
  p_due_date DATE DEFAULT NULL,
  p_start_date DATE DEFAULT NULL,
  p_assignee_ids UUID[] DEFAULT NULL
) RETURNS TABLE (task_id UUID, task_number TEXT, link_id UUID) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_actor_org UUID;
  v_letter prisoner_letters;
  v_task_id UUID;
  v_link_id UUID;
  v_assignee UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_prisoner_letter_supporting_task requires an authenticated caller';
  END IF;

  SELECT * INTO v_letter FROM prisoner_letters WHERE id = p_letter_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prisoner letter not found';
  END IF;

  IF NOT can_manage_prisoner_letter_task_link(p_letter_id) THEN
    RAISE EXCEPTION 'Not authorized to create supporting work for this prisoner letter';
  END IF;

  IF v_letter.status = 'delivered' THEN
    RAISE EXCEPTION 'Cannot create a supporting task on a delivered prisoner letter';
  END IF;

  SELECT org_id INTO v_actor_org FROM users WHERE id = v_actor AND is_active = TRUE;
  IF v_actor_org IS NULL OR v_actor_org NOT IN (v_letter.from_prison_id, v_letter.to_org_id) THEN
    RAISE EXCEPTION 'Supporting tasks must belong to an organization party to the prisoner letter';
  END IF;

  -- Reuse create_task()/assign_task() (R3) rather than duplicating
  -- numbering, validation, or audit/notification behavior.
  v_task_id := create_task(
    v_actor_org, p_title, p_description, p_owning_section_id,
    p_priority, p_visibility, p_due_date, p_start_date
  );

  IF p_assignee_ids IS NOT NULL THEN
    FOREACH v_assignee IN ARRAY p_assignee_ids LOOP
      PERFORM assign_task(v_task_id, v_assignee);
    END LOOP;
  END IF;

  INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by)
  VALUES (v_task_id, 'prisoner_letter', p_letter_id, v_actor_org, v_actor)
  RETURNING id INTO v_link_id;

  -- record_type='prisoner_letter' — already a valid audit_logs value
  -- (present since long before this milestone). Visibility of these
  -- specific rows is NOT covered by can_view_case_audit_record() (it
  -- has no prisoner_letter branch — a pre-existing gap, same shape R5
  -- found for 'meeting' — so only org admins see them via the base
  -- audit_select policy; see docs/37 "Audit" for the full disclosure).
  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_linked', 'prisoner_letter', p_letter_id, 'Created and linked supporting task ' || v_task_id);

  RETURN QUERY SELECT v_task_id, (SELECT tk.task_number FROM tasks tk WHERE tk.id = v_task_id), v_link_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION link_existing_task_to_prisoner_letter(p_task_id UUID, p_letter_id UUID)
RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
  v_letter prisoner_letters;
  v_link_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'link_existing_task_to_prisoner_letter requires an authenticated caller';
  END IF;

  SELECT * INTO v_task FROM tasks WHERE id = p_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Task not found';
  END IF;
  SELECT * INTO v_letter FROM prisoner_letters WHERE id = p_letter_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prisoner letter not found';
  END IF;

  IF NOT can_manage_task(p_task_id) THEN
    RAISE EXCEPTION 'Not authorized to link this task';
  END IF;
  IF NOT can_manage_prisoner_letter_task_link(p_letter_id) THEN
    RAISE EXCEPTION 'Not authorized to link supporting work to this prisoner letter';
  END IF;
  IF v_letter.status = 'delivered' THEN
    RAISE EXCEPTION 'Cannot link a task to a delivered prisoner letter';
  END IF;
  IF v_task.organization_id NOT IN (v_letter.from_prison_id, v_letter.to_org_id) THEN
    RAISE EXCEPTION 'Task and prisoner letter must share an organization';
  END IF;

  INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by)
  VALUES (p_task_id, 'prisoner_letter', p_letter_id, v_task.organization_id, v_actor)
  ON CONFLICT (task_id, module_key, record_id) WHERE removed_at IS NULL DO NOTHING
  RETURNING id INTO v_link_id;

  IF v_link_id IS NULL THEN
    RAISE EXCEPTION 'This task is already linked to this prisoner letter';
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_linked', 'prisoner_letter', p_letter_id, 'Linked existing task ' || p_task_id);

  RETURN v_link_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION unlink_task_from_prisoner_letter(p_link_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_link task_links;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'unlink_task_from_prisoner_letter requires an authenticated caller';
  END IF;

  SELECT * INTO v_link FROM task_links
  WHERE id = p_link_id AND module_key = 'prisoner_letter' AND removed_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active task link not found';
  END IF;

  -- No delivered-letter gate here (deliberately) — unlinking is always
  -- available to whoever can manage either side, even after delivery,
  -- same as R4/R5/R6/R7's own unlink RPCs.
  IF NOT (can_manage_task(v_link.task_id) OR can_manage_prisoner_letter_task_link(v_link.record_id)) THEN
    RAISE EXCEPTION 'Not authorized to unlink this task';
  END IF;

  -- Soft removal only — never touches tasks.status or
  -- prisoner_letters.status.
  UPDATE task_links SET removed_at = NOW(), removed_by = v_actor WHERE id = p_link_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_unlinked', 'prisoner_letter', v_link.record_id, COALESCE(p_reason, 'Unlinked task ' || v_link.task_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- list_prisoner_letter_tasks/list_task_prisoner_letter_links follow
-- the same SECURITY INVOKER (non-DEFINER) shape as R4/R5/R6/R7's own
-- list functions: ordinary RLS (task_links_select, via can_view_task_
-- link()) filters the base rows, so the confidentiality predicate is
-- never re-implemented a further time — a user without the
-- is_prisoner_letters_staff flag gets zero rows from either, not a
-- permission error that would confirm a letter's existence.
-- DROP first: CREATE OR REPLACE cannot change a RETURNS TABLE
-- function's output columns, matching R4's own note.
DROP FUNCTION IF EXISTS list_prisoner_letter_tasks(UUID, TEXT, BOOLEAN, INTEGER, INTEGER);
CREATE OR REPLACE FUNCTION list_prisoner_letter_tasks(
  p_letter_id UUID,
  p_status TEXT DEFAULT NULL,
  p_assigned_to_me BOOLEAN DEFAULT FALSE,
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
) RETURNS TABLE (
  link_id UUID, task_id UUID, task_number TEXT, title TEXT, status TEXT, priority TEXT,
  due_date DATE, start_date DATE, owning_section_id UUID, owning_section_name TEXT, visibility TEXT,
  assignees JSONB, linked_at TIMESTAMPTZ, total_count BIGINT
) AS $$
  SELECT
    tl.id, t.id, t.task_number, t.title, t.status, t.priority,
    t.due_date, t.start_date, t.owning_section_id, s.name,
    t.visibility,
    COALESCE((
      SELECT jsonb_agg(jsonb_build_object('user_id', u.id, 'full_name', u.full_name))
      FROM task_assignments ta JOIN users u ON u.id = ta.user_id
      WHERE ta.task_id = t.id AND ta.is_active
    ), '[]'::jsonb) AS assignees,
    tl.created_at,
    COUNT(*) OVER() AS total_count
  FROM task_links tl
  JOIN tasks t ON t.id = tl.task_id
  LEFT JOIN sections s ON s.id = t.owning_section_id
  WHERE tl.module_key = 'prisoner_letter' AND tl.record_id = p_letter_id AND tl.removed_at IS NULL
    AND (p_status IS NULL OR t.status = p_status)
    AND (NOT p_assigned_to_me OR EXISTS (
      SELECT 1 FROM task_assignments ta
      WHERE ta.task_id = t.id AND ta.user_id = auth.uid() AND ta.is_active
    ))
  ORDER BY tl.created_at DESC, tl.id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$$ LANGUAGE sql STABLE SET search_path = public, pg_temp;

DROP FUNCTION IF EXISTS list_task_prisoner_letter_links(UUID, INTEGER, INTEGER);
CREATE OR REPLACE FUNCTION list_task_prisoner_letter_links(
  p_task_id UUID,
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
) RETURNS TABLE (
  link_id UUID, letter_id UUID, prisoner_name TEXT, status TEXT, reference_number TEXT,
  linked_at TIMESTAMPTZ, total_count BIGINT
) AS $$
  SELECT
    tl.id, pl.id, pl.prisoner_name, pl.status, pl.reference_number,
    tl.created_at,
    COUNT(*) OVER() AS total_count
  FROM task_links tl
  JOIN prisoner_letters pl ON pl.id = tl.record_id
  WHERE tl.module_key = 'prisoner_letter' AND tl.task_id = p_task_id AND tl.removed_at IS NULL
  ORDER BY tl.created_at DESC, tl.id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$$ LANGUAGE sql STABLE SET search_path = public, pg_temp;

-- Narrow capability RPC for the frontend — booleans only, no role,
-- flag, or permission internals exposed, and no confirmation that a
-- given letter id even exists to a caller without the confidentiality
-- flag. Fails closed: unauthenticated caller, a non-flagged caller, or
-- a letter the actor cannot even find all resolve to all-false.
-- can_unlink is intentionally NOT gated on the letter's 'delivered'
-- status (unlink stays available even then); can_create_task/
-- can_link_existing are.
CREATE OR REPLACE FUNCTION get_prisoner_letter_task_capabilities(p_letter_id UUID)
RETURNS TABLE (
  can_view_tasks BOOLEAN, can_create_task BOOLEAN, can_link_existing BOOLEAN, can_unlink BOOLEAN
) AS $$
DECLARE
  v_status TEXT;
  v_can_view BOOLEAN := FALSE;
  v_can_manage BOOLEAN := FALSE;
BEGIN
  IF auth.uid() IS NOT NULL THEN
    SELECT status INTO v_status FROM prisoner_letters WHERE id = p_letter_id;
    IF FOUND THEN
      v_can_view := can_view_prisoner_letter(p_letter_id);
      v_can_manage := can_manage_prisoner_letter_task_link(p_letter_id);
    END IF;
  END IF;

  RETURN QUERY SELECT
    v_can_view,
    (v_can_manage AND v_status <> 'delivered'),
    (v_can_manage AND v_status <> 'delivered'),
    v_can_manage;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. Audit / notifications ───────────────────────────────────
-- No audit_logs CHECK constraint changes: record_type='prisoner_letter'
-- and action IN ('task_linked', 'task_unlinked') both already exist
-- (the former since long before this milestone, the latter added by
-- R4) — genuinely reused as-is, nothing to widen. Third milestone in a
-- row (after R6, R7) needing zero audit schema changes.
--
-- No new notification type. create_prisoner_letter_supporting_task()
-- already fans out task_assigned via its reused assign_task() calls;
-- linking/unlinking is a lightweight cross-reference, not new work —
-- identical reasoning to R4/R5/R6/R7. Task activity is NOT merged into
-- the letter's own thread/audit view — prisoner-letter-detail.js has
-- no equivalent of _renderAuditEvents()/_renderProcessEvents() at all
-- (its own thread just shows the letter + replies, no separate audit-
-- trail rendering), so there is nothing to exclude task_linked/
-- task_unlinked from — they simply have no rendering surface there.

COMMIT;
