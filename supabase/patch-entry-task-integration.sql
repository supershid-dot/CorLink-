-- ============================================================
-- CorLink — Entry ↔ Shared Tasks Integration
--
-- Fourth consumer of task_links (supabase/patch-request-task-
-- integration.sql, "R4"; supabase/patch-meeting-task-integration.sql,
-- "R5"; supabase/patch-internal-collaboration-task-integration.sql,
-- "R6"). module_key widens from ('request', 'meeting',
-- 'internal_request') to also allow 'external_correspondence' — the
-- canonical value this codebase already uses for the Entry module
-- everywhere else (the external_correspondence table itself,
-- audit_logs.record_type, cc_recipients/attachments.record_type,
-- EntryAPI's own logAudit()). No alias was invented.
--
-- Unlike Internal Collaboration (R6), Entry is a first-class primary
-- record, not a satellite thread anchored to a parent — so
-- task_links.record_id here is simply external_correspondence.id, and
-- there is no separate "parent navigation metadata" concern the way
-- R6's list_task_internal_collaboration_links() had.
--
-- Entry and Tasks remain fully independent business objects, same as
-- R4/R5/R6: task_links.record_id has no foreign key (deliberate,
-- matching the existing cc_recipients/audit_logs record_type+record_id
-- precedent) — so deleting an entry cannot cascade into tasks, and no
-- code path in this patch reads or writes external_correspondence.status
-- from a Task RPC, or the reverse. Logging, routing, marking received,
-- assigning, replying, or closing an Entry never touches a linked
-- Task; completing/cancelling a Task never touches its linked Entry.
--
-- Idempotent — safe to run more than once.
-- ============================================================

BEGIN;

-- ─── 1. Widen task_links.module_key ────────────────────────────
-- Preserves 'request' (R4), 'meeting' (R5), and 'internal_request'
-- (R6) exactly as they were; adds 'external_correspondence' only. Not
-- widened for 'prisoner_letter' or any future module — out of scope.
ALTER TABLE task_links DROP CONSTRAINT IF EXISTS task_links_module_key_check;
ALTER TABLE task_links ADD CONSTRAINT task_links_module_key_check
  CHECK (module_key IN ('request', 'meeting', 'internal_request', 'external_correspondence'));

-- No new indexes needed: idx_task_links_module_record,
-- idx_task_links_active_unique, idx_task_links_record_active_created,
-- and idx_task_links_task_active_created (all from R4) are already
-- generic composite indexes keyed on (module_key, record_id) / task_id
-- — 'external_correspondence' is just another value in the same
-- leading column. Confirmed by EXPLAIN during testing (see docs/36
-- "Performance").

-- ─── 2. Authorization helpers ───────────────────────────────────

-- "Can this user even SEE this Entry" — there is no existing
-- standalone callable predicate for this (unlike can_view_request_or_
-- response()/can_view_meeting(), which R4/R5 reused directly);
-- external_correspondence_select's own visibility logic has only ever
-- lived inline in that one RLS policy (rls.sql) and in the
-- external_correspondence branch of can_view_case_audit_record()
-- (rls.sql, ~line 299) — this function's body mirrors both verbatim,
-- reusing is_entry_staff() rather than re-deriving Entry-section
-- membership by hand. Deliberately does NOT also include the
-- looped-in-via-internal-collab grant (external_correspondence_
-- select_via_internal_collab / looped_in_via_internal_collab_entry()):
-- that policy exists to let a section looped in for supporting info
-- see enough of the Entry to give context for its OWN internal_
-- requests thread (R6's own feature) — it was never meant to extend
-- into a different feature (managing the Entry's own supporting
-- tasks). SECURITY DEFINER so it can be called from can_view_task_link()
-- below without recursing back through external_correspondence's own RLS.
CREATE OR REPLACE FUNCTION can_view_entry(p_entry_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM external_correspondence ec
    WHERE ec.id = p_entry_id
      AND ec.org_id = get_my_org_id()
      AND (
        is_entry_staff(ec.org_id)
        OR ec.to_section_id IN (SELECT my_section_ids())
        OR ec.assigned_to = auth.uid()
        OR ec.entered_by = auth.uid()
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- "Can this user actively manage (create/link/unlink) supporting work
-- on this Entry" — reuses can_view_entry() directly, same technique
-- R4's can_manage_request_task_link() used (`= can_view_request_or_
-- response()`). Entry has no clean "asking vs. receiving, only one
-- side ever does work" split the way Internal Collaboration (R6) did:
-- repository evidence (js/views/entry-detail.js's _renderActions) shows
-- Entry staff (is_entry_staff) themselves take substantive lifecycle
-- actions throughout — Edit Draft/Route while logged, Close once
-- responded — not just an initial hand-off, and the receiving section
-- (to_section_id/assigned_to/scoped supervisor) does the routed-through-
-- responded work. Every party can_view_entry() grants visibility to is
-- therefore already a legitimate case worker at some stage of the
-- lifecycle, so "can view" and "can manage" are the same predicate
-- here — narrower than plain org membership (is_entry_staff/to_section/
-- assigned_to/entered_by are all still individually scoped grants, none
-- of them "any org member"), matching "do not authorize by organization
-- alone."
CREATE OR REPLACE FUNCTION can_manage_entry_task_link(p_entry_id UUID)
RETURNS BOOLEAN AS $$
  SELECT can_view_entry(p_entry_id);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- Generic "can this user see this link" — extended via CREATE OR
-- REPLACE (never touching R4/R5/R6's own files) with a fourth branch.
-- Both the Task and the Entry must independently pass visibility for
-- the link to be visible — a user can never learn a hidden Task is
-- linked to a visible Entry, or that a visible Task is linked to a
-- hidden Entry, and (transitively, since can_view_entry() requires
-- org membership on the correct org PLUS a specific role, never bare
-- org membership alone) never a cross-org Entry either.
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
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. RPCs ────────────────────────────────────────────────────
-- Actor identity always from auth.uid(), never a client-supplied
-- parameter, matching every RPC in R3/R4/R5/R6.

-- Business rule matrix (see docs/36 for the full write-up):
--   logged / routed / responded -> create + link allowed (to Entry
--     staff / the receiving section / assigned user / scoped supervisor)
--   closed                      -> create + link BLOCKED
--   any status                  -> unlink always allowed (soft removal
--     only, never new work, same posture as R4/R5/R6's own unlink RPCs)
-- Matches js/views/entry-detail.js's own _renderActions(): zero action
-- buttons render once status='closed'; every earlier status has at
-- least one legitimate next action for someone.

CREATE OR REPLACE FUNCTION create_entry_supporting_task(
  p_entry_id UUID,
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
  v_entry external_correspondence;
  v_task_id UUID;
  v_link_id UUID;
  v_assignee UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_entry_supporting_task requires an authenticated caller';
  END IF;

  SELECT * INTO v_entry FROM external_correspondence WHERE id = p_entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entry not found';
  END IF;

  IF NOT can_manage_entry_task_link(p_entry_id) THEN
    RAISE EXCEPTION 'Not authorized to create supporting work for this entry';
  END IF;

  IF v_entry.status = 'closed' THEN
    RAISE EXCEPTION 'Cannot create a supporting task on a closed entry';
  END IF;

  SELECT org_id INTO v_actor_org FROM users WHERE id = v_actor AND is_active = TRUE;
  IF v_actor_org IS NULL OR v_actor_org <> v_entry.org_id THEN
    RAISE EXCEPTION 'Supporting tasks must belong to the entry''s own organization';
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
  VALUES (v_task_id, 'external_correspondence', p_entry_id, v_actor_org, v_actor)
  RETURNING id INTO v_link_id;

  -- record_type='external_correspondence' — already a valid audit_logs
  -- value (added by patch-entry-module.sql, long before this
  -- milestone); already visible to the exact same audience as the
  -- entry itself via can_view_case_audit_record()'s existing
  -- external_correspondence branch, so no audit_logs CHECK constraint
  -- change is needed (same happy situation as R6's internal_request).
  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_linked', 'external_correspondence', p_entry_id, 'Created and linked supporting task ' || v_task_id);

  RETURN QUERY SELECT v_task_id, (SELECT tk.task_number FROM tasks tk WHERE tk.id = v_task_id), v_link_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION link_existing_task_to_entry(p_task_id UUID, p_entry_id UUID)
RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
  v_entry external_correspondence;
  v_link_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'link_existing_task_to_entry requires an authenticated caller';
  END IF;

  SELECT * INTO v_task FROM tasks WHERE id = p_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Task not found';
  END IF;
  SELECT * INTO v_entry FROM external_correspondence WHERE id = p_entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entry not found';
  END IF;

  IF NOT can_manage_task(p_task_id) THEN
    RAISE EXCEPTION 'Not authorized to link this task';
  END IF;
  IF NOT can_manage_entry_task_link(p_entry_id) THEN
    RAISE EXCEPTION 'Not authorized to link supporting work to this entry';
  END IF;
  IF v_entry.status = 'closed' THEN
    RAISE EXCEPTION 'Cannot link a task to a closed entry';
  END IF;
  IF v_task.organization_id <> v_entry.org_id THEN
    RAISE EXCEPTION 'Task and entry must share an organization';
  END IF;

  INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by)
  VALUES (p_task_id, 'external_correspondence', p_entry_id, v_entry.org_id, v_actor)
  ON CONFLICT (task_id, module_key, record_id) WHERE removed_at IS NULL DO NOTHING
  RETURNING id INTO v_link_id;

  IF v_link_id IS NULL THEN
    RAISE EXCEPTION 'This task is already linked to this entry';
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_linked', 'external_correspondence', p_entry_id, 'Linked existing task ' || p_task_id);

  RETURN v_link_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION unlink_task_from_entry(p_link_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_link task_links;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'unlink_task_from_entry requires an authenticated caller';
  END IF;

  SELECT * INTO v_link FROM task_links
  WHERE id = p_link_id AND module_key = 'external_correspondence' AND removed_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active task link not found';
  END IF;

  -- No closed-entry gate here (deliberately) — unlinking is always
  -- available to whoever can manage either side, even on a closed
  -- entry, same as R4/R5/R6's own unlink RPCs.
  IF NOT (can_manage_task(v_link.task_id) OR can_manage_entry_task_link(v_link.record_id)) THEN
    RAISE EXCEPTION 'Not authorized to unlink this task';
  END IF;

  -- Soft removal only — never touches tasks.status or
  -- external_correspondence.status.
  UPDATE task_links SET removed_at = NOW(), removed_by = v_actor WHERE id = p_link_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_unlinked', 'external_correspondence', v_link.record_id, COALESCE(p_reason, 'Unlinked task ' || v_link.task_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- list_entry_tasks/list_task_entry_links follow the same SECURITY
-- INVOKER (non-DEFINER) shape as R4/R5/R6's own list functions:
-- ordinary RLS (task_links_select, via can_view_task_link()) filters
-- the base rows, so visibility isn't re-implemented a further time.
-- DROP first: CREATE OR REPLACE cannot change a RETURNS TABLE
-- function's output columns, matching R4's own note.
DROP FUNCTION IF EXISTS list_entry_tasks(UUID, TEXT, BOOLEAN, INTEGER, INTEGER);
CREATE OR REPLACE FUNCTION list_entry_tasks(
  p_entry_id UUID,
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
  WHERE tl.module_key = 'external_correspondence' AND tl.record_id = p_entry_id AND tl.removed_at IS NULL
    AND (p_status IS NULL OR t.status = p_status)
    AND (NOT p_assigned_to_me OR EXISTS (
      SELECT 1 FROM task_assignments ta
      WHERE ta.task_id = t.id AND ta.user_id = auth.uid() AND ta.is_active
    ))
  ORDER BY tl.created_at DESC, tl.id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$$ LANGUAGE sql STABLE SET search_path = public, pg_temp;

DROP FUNCTION IF EXISTS list_task_entry_links(UUID, INTEGER, INTEGER);
CREATE OR REPLACE FUNCTION list_task_entry_links(
  p_task_id UUID,
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
) RETURNS TABLE (
  link_id UUID, entry_id UUID, subject TEXT, status TEXT, reference_number TEXT,
  linked_at TIMESTAMPTZ, total_count BIGINT
) AS $$
  SELECT
    tl.id, ec.id, ec.subject, ec.status, ec.reference_number,
    tl.created_at,
    COUNT(*) OVER() AS total_count
  FROM task_links tl
  JOIN external_correspondence ec ON ec.id = tl.record_id
  WHERE tl.module_key = 'external_correspondence' AND tl.task_id = p_task_id AND tl.removed_at IS NULL
  ORDER BY tl.created_at DESC, tl.id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$$ LANGUAGE sql STABLE SET search_path = public, pg_temp;

-- Narrow capability RPC for the frontend — booleans only, no role or
-- permission internals exposed. Fails closed: unauthenticated caller
-- or an entry the actor cannot even find both resolve to all-false.
-- can_unlink is intentionally NOT gated on the entry's 'closed' status
-- (unlink stays available even then); can_create_task/can_link_existing
-- are.
CREATE OR REPLACE FUNCTION get_entry_task_capabilities(p_entry_id UUID)
RETURNS TABLE (
  can_view_tasks BOOLEAN, can_create_task BOOLEAN, can_link_existing BOOLEAN, can_unlink BOOLEAN
) AS $$
DECLARE
  v_status TEXT;
  v_can_view BOOLEAN := FALSE;
  v_can_manage BOOLEAN := FALSE;
BEGIN
  IF auth.uid() IS NOT NULL THEN
    SELECT status INTO v_status FROM external_correspondence WHERE id = p_entry_id;
    IF FOUND THEN
      v_can_view := can_view_entry(p_entry_id);
      v_can_manage := can_manage_entry_task_link(p_entry_id);
    END IF;
  END IF;

  RETURN QUERY SELECT
    v_can_view,
    (v_can_manage AND v_status <> 'closed'),
    (v_can_manage AND v_status <> 'closed'),
    v_can_manage;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. Audit / notifications ───────────────────────────────────
-- No audit_logs CHECK constraint changes: record_type=
-- 'external_correspondence' and action IN ('task_linked',
-- 'task_unlinked') both already exist (the former since patch-entry-
-- module.sql, the latter added by R4) — genuinely reused as-is,
-- nothing to widen. This is the second milestone in a row (after R6)
-- needing zero audit schema changes.
--
-- No new notification type. create_entry_supporting_task() already
-- fans out task_assigned via its reused assign_task() calls; linking/
-- unlinking is a lightweight cross-reference, not new work — identical
-- reasoning to R4/R5/R6. Task activity is NOT merged into Entry's own
-- reply/audit timeline in this milestone — entry-detail.js's
-- _renderAuditEvents()-equivalent (_renderProcessEvents) and
-- listCaseAuditTrail() both already pass a fixed action allow-list
-- (['routed', 'assigned', 'received']) that does not include
-- 'task_linked'/'task_unlinked', so no extra filtering work was needed
-- here either, matching R4's and R6's identical decision.

COMMIT;
