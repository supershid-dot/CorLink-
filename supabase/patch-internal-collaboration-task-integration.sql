-- ============================================================
-- CorLink — Internal Collaboration ↔ Shared Tasks Integration
--
-- Third consumer of task_links (supabase/patch-request-task-
-- integration.sql, "R4"; supabase/patch-meeting-task-integration.sql,
-- "R5"). module_key widens from ('request', 'meeting') to also allow
-- 'internal_request' — the canonical value this codebase already uses
-- for this concept everywhere else (internal_requests table,
-- audit_logs.record_type, cc_recipients.record_type,
-- attachments.record_type, InternalRequestsAPI's own logAudit()). No
-- alias was invented; 'internal_request' is simply reused.
--
-- Tasks attach to the SPECIFIC internal_requests row (the thread), not
-- to its parent Request or Entry — internal_requests.id is the
-- record_id stored in task_links, matching "Thread A must show only
-- Thread A Tasks" exactly, since every RPC below filters/checks
-- against one exact internal_requests.id.
--
-- Internal Collaboration and Tasks remain fully independent business
-- objects, same as R4/R5: task_links.record_id has no foreign key (by
-- design, see docs/33), and no code path in this patch reads or
-- writes internal_requests.status from a Task RPC or tasks.status from
-- an internal-collaboration RPC, or touches the parent Request/Entry
-- at all.
--
-- Idempotent — safe to run more than once.
-- ============================================================

BEGIN;

-- ─── 1. Widen task_links.module_key ────────────────────────────
-- Preserves 'request' (R4) and 'meeting' (R5) exactly as they were;
-- adds 'internal_request' only. Not widened for 'entry' or
-- 'prisoner_letter' — out of scope for this milestone.
ALTER TABLE task_links DROP CONSTRAINT IF EXISTS task_links_module_key_check;
ALTER TABLE task_links ADD CONSTRAINT task_links_module_key_check
  CHECK (module_key IN ('request', 'meeting', 'internal_request'));

-- No new indexes needed: idx_task_links_module_record,
-- idx_task_links_active_unique, idx_task_links_record_active_created,
-- and idx_task_links_task_active_created (all from R4) are already
-- generic composite indexes keyed on (module_key, record_id) / task_id
-- — the 'internal_request' value is just another value in the same
-- leading column, already covered with no schema change. Confirmed by
-- EXPLAIN during testing (see docs/35 "Performance").

-- ─── 2. Authorization helpers ───────────────────────────────────

-- "Can this user even SEE this internal_requests row (thread)" —
-- there is no existing standalone callable predicate for this (unlike
-- can_view_request_or_response()/can_view_meeting(), which R4/R5
-- reused directly); internal_requests_select's own visibility logic
-- has only ever lived inline in that one RLS policy (rls.sql) and in
-- the informational_request branch of can_view_case_audit_record()
-- (rls.sql, ~line 286). This function's body mirrors both of those,
-- with ONE deliberate, disclosed addition beyond a byte-for-byte
-- mirror: an `ir.assigned_to = auth.uid()` branch, which
-- internal_requests_select itself does not have. In the app's existing
-- assignment workflow, assigned_to is always chosen from the receiving
-- section's own staff, so that branch is normally redundant with
-- to_section membership — but this milestone's own can_manage_
-- internal_collab_task_link() below (required to account for "current
-- assigned user" per this milestone's own spec) DOES grant manage
-- authority via assigned_to independent of to_section membership, for
-- defense-in-depth against a future reassignment path that moves
-- assigned_to outside the current to_section. Without this branch here
-- too, such a user could create/link a supporting task via the RPC
-- (SECURITY DEFINER, bypasses this predicate) and then be unable to
-- see the very link they just created (RLS-filtered by this predicate)
-- — a genuinely confusing gap, caught during this milestone's own
-- behavioral testing, not a real report scenario. SECURITY DEFINER so
-- it can be called from can_view_task_link() below without recursing
-- back through internal_requests' own RLS.
CREATE OR REPLACE FUNCTION can_view_internal_request(p_internal_request_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM internal_requests ir
    WHERE ir.id = p_internal_request_id
      AND (
        ir.from_section_id IN (SELECT my_section_ids())
        OR ir.to_section_id IN (SELECT my_section_ids())
        OR ir.previous_section_id IN (SELECT my_section_ids())
        OR ir.created_by = auth.uid()
        OR ir.assigned_to = auth.uid()
        OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- "Can this user actively manage (create/link/unlink) supporting work
-- on this thread" — narrower than can_view_internal_request() above,
-- same "view broader than manage" split R4's can_manage_request_
-- task_link()/can_manage_task() already established. Per repository
-- evidence (js/views/request-detail.js's _renderInternalRequestRow:
-- canReceive/canReply/canAssign are all gated on to_section membership
-- or assigned_to, NEVER on from_section membership beyond creating the
-- thread and — for the literal creator only — closing it once
-- responded), the RECEIVING section is where the actual work happens;
-- the asking side (from_section) has no ongoing "do work on this"
-- role in the existing UI at any stage. This deliberately does NOT
-- grant from_section members manage authority — see docs/35
-- "Authorization matrix" for the explicit decision record.
-- Status (open vs. closed) is intentionally NOT checked here — that
-- business-rule gate is applied per-RPC below (create/link only,
-- never unlink), matching how R5 layered its own module-enablement
-- check in RPC bodies rather than baking it into the bare "manage"
-- predicate.
CREATE OR REPLACE FUNCTION can_manage_internal_collab_task_link(p_internal_request_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM internal_requests ir
    WHERE ir.id = p_internal_request_id
      AND (
        ir.to_section_id IN (SELECT my_section_ids())
        OR ir.assigned_to = auth.uid()
        OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- Generic "can this user see this link" — extended via CREATE OR
-- REPLACE (never touching patch-request-task-integration.sql or
-- patch-meeting-task-integration.sql) with a third branch. Both the
-- Task and the internal_requests thread must independently pass
-- visibility, same single AND expression as R4/R5 — a user can never
-- learn a hidden Task is linked to a visible thread, or that a visible
-- Task is linked to a hidden thread, and (transitively, since
-- can_view_internal_request() requires from/to/previous-section
-- membership or being the creator, all of which are structurally
-- confined to one org) never a cross-org thread either.
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
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. RPCs ────────────────────────────────────────────────────
-- Actor identity always from auth.uid(), never a client-supplied
-- parameter, matching every RPC in R3/R4/R5.

-- Business rule matrix (see docs/35 for the full write-up):
--   sent / received / in_progress / responded -> create + link allowed
--     (to the receiving section / assigned user / scoped supervisor)
--   closed                                    -> create + link BLOCKED
--   any status                                -> unlink always allowed
--     to whoever can manage the Task or the thread (soft removal only,
--     never new work, same posture as R4/R5's own unlink RPCs)
-- No dependency on internal_requests_parent_not_frozen() (parent
-- Request/Entry lifecycle) — matching R4's own precedent of never
-- restricting create_request_supporting_task() by the parent Request's
-- status; only this thread's OWN 'closed' status is checked, because
-- that is the one state where the existing UI (js/views/request-
-- detail.js, js/views/entry-detail.js) shows zero action buttons at
-- all on the row.

CREATE OR REPLACE FUNCTION create_internal_collaboration_supporting_task(
  p_internal_request_id UUID,
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
  v_ir internal_requests;
  v_ir_org UUID;
  v_task_id UUID;
  v_link_id UUID;
  v_assignee UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_internal_collaboration_supporting_task requires an authenticated caller';
  END IF;

  SELECT * INTO v_ir FROM internal_requests WHERE id = p_internal_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Internal collaboration thread not found';
  END IF;

  IF NOT can_manage_internal_collab_task_link(p_internal_request_id) THEN
    RAISE EXCEPTION 'Not authorized to create supporting work for this internal collaboration thread';
  END IF;

  IF v_ir.status = 'closed' THEN
    RAISE EXCEPTION 'Cannot create a supporting task on a closed internal collaboration thread';
  END IF;

  -- internal_requests has no organization_id column of its own — both
  -- from_section_id/to_section_id always resolve to the same org (see
  -- schema.sql's comment on the table), so scope_org_id() on either
  -- gives the thread's one true org.
  v_ir_org := scope_org_id('section', v_ir.to_section_id);

  SELECT org_id INTO v_actor_org FROM users WHERE id = v_actor AND is_active = TRUE;
  IF v_actor_org IS NULL OR v_actor_org <> v_ir_org THEN
    RAISE EXCEPTION 'Supporting tasks must belong to the internal collaboration thread''s own organization';
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
  VALUES (v_task_id, 'internal_request', p_internal_request_id, v_ir_org, v_actor)
  RETURNING id INTO v_link_id;

  -- record_type='internal_request' — already a valid audit_logs value
  -- (added long before this milestone); already visible to the exact
  -- same audience as the thread itself via can_view_case_audit_record()'s
  -- existing internal_request branch (rls.sql), so no audit_logs
  -- CHECK constraint change is needed for this milestone (unlike R5,
  -- which needed no record_type change either but is called out here
  -- since 'internal_request' visibility for audit rows already existed
  -- as a happy accident of R2/pre-existing work).
  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_linked', 'internal_request', p_internal_request_id, 'Created and linked supporting task ' || v_task_id);

  RETURN QUERY SELECT v_task_id, (SELECT tk.task_number FROM tasks tk WHERE tk.id = v_task_id), v_link_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION link_existing_task_to_internal_collaboration(p_task_id UUID, p_internal_request_id UUID)
RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
  v_ir internal_requests;
  v_ir_org UUID;
  v_link_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'link_existing_task_to_internal_collaboration requires an authenticated caller';
  END IF;

  SELECT * INTO v_task FROM tasks WHERE id = p_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Task not found';
  END IF;
  SELECT * INTO v_ir FROM internal_requests WHERE id = p_internal_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Internal collaboration thread not found';
  END IF;

  IF NOT can_manage_task(p_task_id) THEN
    RAISE EXCEPTION 'Not authorized to link this task';
  END IF;
  IF NOT can_manage_internal_collab_task_link(p_internal_request_id) THEN
    RAISE EXCEPTION 'Not authorized to link supporting work to this internal collaboration thread';
  END IF;
  IF v_ir.status = 'closed' THEN
    RAISE EXCEPTION 'Cannot link a task to a closed internal collaboration thread';
  END IF;

  v_ir_org := scope_org_id('section', v_ir.to_section_id);
  IF v_task.organization_id <> v_ir_org THEN
    RAISE EXCEPTION 'Task and internal collaboration thread must share an organization';
  END IF;

  INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by)
  VALUES (p_task_id, 'internal_request', p_internal_request_id, v_ir_org, v_actor)
  ON CONFLICT (task_id, module_key, record_id) WHERE removed_at IS NULL DO NOTHING
  RETURNING id INTO v_link_id;

  IF v_link_id IS NULL THEN
    RAISE EXCEPTION 'This task is already linked to this internal collaboration thread';
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_linked', 'internal_request', p_internal_request_id, 'Linked existing task ' || p_task_id);

  RETURN v_link_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION unlink_task_from_internal_collaboration(p_link_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_link task_links;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'unlink_task_from_internal_collaboration requires an authenticated caller';
  END IF;

  SELECT * INTO v_link FROM task_links
  WHERE id = p_link_id AND module_key = 'internal_request' AND removed_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active task link not found';
  END IF;

  -- No thread-status gate here (deliberately) — unlinking is always
  -- available to whoever can manage either side, even on a closed
  -- thread, same as R4/R5's own unlink RPCs.
  IF NOT (can_manage_task(v_link.task_id) OR can_manage_internal_collab_task_link(v_link.record_id)) THEN
    RAISE EXCEPTION 'Not authorized to unlink this task';
  END IF;

  -- Soft removal only — never touches tasks.status or
  -- internal_requests.status.
  UPDATE task_links SET removed_at = NOW(), removed_by = v_actor WHERE id = p_link_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_unlinked', 'internal_request', v_link.record_id, COALESCE(p_reason, 'Unlinked task ' || v_link.task_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- list_internal_collaboration_tasks/list_task_internal_collaboration_
-- links follow the same SECURITY INVOKER (non-DEFINER) shape as R4/R5's
-- own list functions: ordinary RLS (task_links_select, via
-- can_view_task_link()) filters the base rows, so visibility isn't
-- re-implemented a further time. Filtered to exactly ONE thread id
-- (p_internal_request_id) — Thread A never sees Thread B's tasks,
-- structurally, since record_id is an exact-match predicate, not a
-- parent-id lookup.
-- DROP first: CREATE OR REPLACE cannot change a RETURNS TABLE
-- function's output columns, matching R4's own note on
-- list_request_supporting_tasks.
DROP FUNCTION IF EXISTS list_internal_collaboration_tasks(UUID, TEXT, BOOLEAN, INTEGER, INTEGER);
CREATE OR REPLACE FUNCTION list_internal_collaboration_tasks(
  p_internal_request_id UUID,
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
  WHERE tl.module_key = 'internal_request' AND tl.record_id = p_internal_request_id AND tl.removed_at IS NULL
    AND (p_status IS NULL OR t.status = p_status)
    AND (NOT p_assigned_to_me OR EXISTS (
      SELECT 1 FROM task_assignments ta
      WHERE ta.task_id = t.id AND ta.user_id = auth.uid() AND ta.is_active
    ))
  ORDER BY tl.created_at DESC, tl.id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$$ LANGUAGE sql STABLE SET search_path = public, pg_temp;

-- Future Task Detail navigation source (no Task Detail page built in
-- this milestone). parent_type/parent_id are only populated when the
-- LEFT JOIN below actually returns a row — under RLS (requests_select/
-- requests_select_via_internal_collab or external_correspondence_select/
-- its own looped-in-section policy), a parent the actor cannot
-- independently view comes back NULL, not populated. This is real RLS
-- enforcement (both joined tables keep their own SELECT policies under
-- the invoking role), not a hand-written boolean re-derivation — the
-- safest way to guarantee "never expose this metadata unless the actor
-- can view both the thread and its parent" without maintaining a
-- second, parallel definition of requests_select/external_
-- correspondence_select's own visibility logic here.
DROP FUNCTION IF EXISTS list_task_internal_collaboration_links(UUID, INTEGER, INTEGER);
CREATE OR REPLACE FUNCTION list_task_internal_collaboration_links(
  p_task_id UUID,
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
) RETURNS TABLE (
  link_id UUID, internal_request_id UUID, subject TEXT, status TEXT,
  parent_type TEXT, parent_id UUID,
  linked_at TIMESTAMPTZ, total_count BIGINT
) AS $$
  SELECT
    tl.id, ir.id, ir.subject, ir.status,
    CASE WHEN r.id IS NOT NULL THEN 'request' WHEN ec.id IS NOT NULL THEN 'external_correspondence' ELSE NULL END,
    COALESCE(r.id, ec.id),
    tl.created_at,
    COUNT(*) OVER() AS total_count
  FROM task_links tl
  JOIN internal_requests ir ON ir.id = tl.record_id
  LEFT JOIN requests r ON r.id = ir.parent_request_id
  LEFT JOIN external_correspondence ec ON ec.id = ir.parent_entry_id
  WHERE tl.module_key = 'internal_request' AND tl.task_id = p_task_id AND tl.removed_at IS NULL
  ORDER BY tl.created_at DESC, tl.id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$$ LANGUAGE sql STABLE SET search_path = public, pg_temp;

-- Narrow capability RPC for the frontend — booleans only, no role,
-- section, or permission internals exposed. Fails closed:
-- unauthenticated caller or a thread the actor cannot even find both
-- resolve to all-false. can_unlink is intentionally NOT gated on the
-- thread's 'closed' status (unlink stays available even then);
-- can_create_task/can_link_existing are.
CREATE OR REPLACE FUNCTION get_internal_collaboration_task_capabilities(p_internal_request_id UUID)
RETURNS TABLE (
  can_view_tasks BOOLEAN, can_create_task BOOLEAN, can_link_existing BOOLEAN, can_unlink BOOLEAN
) AS $$
DECLARE
  v_status TEXT;
  v_can_view BOOLEAN := FALSE;
  v_can_manage BOOLEAN := FALSE;
BEGIN
  IF auth.uid() IS NOT NULL THEN
    SELECT status INTO v_status FROM internal_requests WHERE id = p_internal_request_id;
    IF FOUND THEN
      v_can_view := can_view_internal_request(p_internal_request_id);
      v_can_manage := can_manage_internal_collab_task_link(p_internal_request_id);
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
-- No audit_logs CHECK constraint changes: record_type='internal_request'
-- and action IN ('task_linked', 'task_unlinked') both already exist
-- (the former since long before this milestone, the latter added by
-- R4) — genuinely reused as-is, nothing to widen.
--
-- No new notification type. create_internal_collaboration_supporting_
-- task() already fans out task_assigned via its reused assign_task()
-- calls; linking/unlinking is a lightweight cross-reference, not new
-- work for anyone already watching/assigned to that task — identical
-- reasoning to R4/R5. Task activity is NOT merged into the internal-
-- collaboration reply conversation/thread timeline in this milestone —
-- request-detail.js's/entry-detail.js's _renderAuditEvents() calls for
-- 'internal_request' already pass a fixed action allow-list
-- (['received', 'routed', 'assigned', 'returned_to_sender']), so
-- 'task_linked'/'task_unlinked' do not appear there without any extra
-- filtering work needed here, matching R4's identical decision for the
-- Request conversation timeline.

COMMIT;
