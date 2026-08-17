-- ============================================================
-- UAT correction — Task assignee permission tightening + Draft
-- activation action (docs/107).
--
-- FINDING 1 — update_task() over-grants "manage" authority to plain
-- assignees. Its authorization check has always included:
--
--   OR EXISTS (SELECT 1 FROM task_assignments ta WHERE ta.task_id = t.id
--              AND ta.user_id = auth.uid() AND ta.is_active)
--
-- alongside creator/supervisor-in-scope/admin. This was a deliberate,
-- documented decision at the time (docs/47 §Permissions, T3C) --
-- the frontend's _canEdit() was written specifically to "under-mirror"
-- avoidance, matching this RPC's actual (broad) authorization exactly.
-- Live UAT now shows the real-world consequence: a plain assignee
-- (e.g. a "Room manager" assigned to a task) can redefine the task's
-- title/description/priority/owning section/visibility -- fields the
-- ORIGINAL creator or an in-scope manager set, not the assignee's own
-- work product. This is inconsistent with the rest of this same
-- foundation file's own established pattern: cancel_task() and
-- assign_task() (both structural/manage-tier actions) have never
-- included an assignee branch; only complete_task() (marking your own
-- assigned work done -- a genuine contribute-tier action) and
-- unassign_task() (and there, ONLY for p_user_id = self -- a narrow,
-- self-service exception, unchanged by this patch) do.
--
-- Correction: update_task() is restated with the assignee branch
-- removed, matching cancel_task()'s exact authorization shape
-- (is_super_admin() OR creator OR supervisor-in-scope). No other
-- function changes. complete_task()/assign_task()/unassign_task()/
-- can_view_task() are already correct and are NOT touched.
--
-- Out of scope, deliberately: the task-attachment RLS policy
-- (attachments_insert/attachments_delete's 'task' branch, most
-- recently restated in patch-attachments-authorization-restoration.sql)
-- mirrors this SAME broad "creator OR active assignee OR supervisor"
-- shape by its own separate, explicit design (docs/48 §Permissions --
-- "losing edit access ... revokes delete on your own past uploads
-- too"). Attachments were not part of the UAT finding this patch
-- addresses, and narrowing that policy would remove an assignee's
-- ability to attach files to their own assigned work -- a genuine
-- contribute-tier capability nobody has flagged as wrong. It is
-- intentionally left unchanged; the frontend correction below
-- introduces a SEPARATE predicate for it so it keeps mirroring this
-- unchanged RLS policy rather than being narrowed along with Edit.
--
-- FINDING 2 — self-unassign is deliberate, not a defect.
-- unassign_task()'s `OR p_user_id = v_actor` branch only ever lets a
-- caller remove THEIR OWN assignment (never someone else's) and
-- already writes an audit_logs row. This is architecturally distinct
-- from, and much narrower than, "an assignee can remove any
-- assignment" -- there is no evidence anywhere in this repository of a
-- broader or different intended behavior, and no existing
-- "decline/return assignment with reason" workflow to reuse. Per this
-- correction's own instruction to prefer the narrowest fix and not
-- invent new workflows, this is NOT changed here.
--
-- FINDING 3 — no "task_access_level()"/"assign_task_user()"/
-- "revoke_task_assignment()"/"set_task_dates()" function exists
-- anywhere in this schema, and task_assignments has no
-- "assignment_role" column (only one undifferentiated assignee role
-- exists structurally) -- confirmed by direct search of every
-- supabase/*.sql file. Reviewer/Approver personas and a "Request
-- Review" action have no backing capability in the current
-- architecture and are correctly out of scope for this correction.
--
-- FINDING 4 — Draft -> Open activation gap. create_task() always
-- starts a task at status = 'draft'. valid_task_status_transition()
-- already permits ('draft','open'), and update_task()'s own status
-- guard only blocks setting 'completed'/'cancelled' directly (those
-- require complete_task()/cancel_task()) -- 'open' was never blocked.
-- docs/47 itself already names this exact gap under "Known
-- limitations"/"Future enhancements": T3C's own scope was Complete/
-- Cancel only, and other transitions the same allow-list permits were
-- "intentionally not exposed ... though nothing about the backend
-- prevents adding them in a future, separately-scoped milestone." No
-- backend change is needed to close it -- update_task() already
-- supports the transition once its authorization is narrowed above;
-- only a frontend "Start Task" action (creator/supervisor/admin only,
-- matching the now-manage-only update_task()) is added, calling
-- update_task() exactly as it already exists. The remainder of the
-- lifecycle chain (open -> in_progress, needed before Complete becomes
-- available) is a separate, still out-of-scope gap docs/47 already
-- flagged and is NOT addressed here -- see docs/107.
--
-- Idempotent (CREATE OR REPLACE) -- safe to run more than once.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION update_task(
  p_task_id UUID,
  p_title TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_priority TEXT DEFAULT NULL,
  p_visibility TEXT DEFAULT NULL,
  p_due_date DATE DEFAULT NULL,
  p_start_date DATE DEFAULT NULL,
  p_owning_section_id UUID DEFAULT NULL,
  p_status TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'update_task requires an authenticated caller';
  END IF;

  SELECT * INTO v_task FROM tasks WHERE id = p_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Task not found';
  END IF;

  -- Manage-tier only (creator / in-scope supervisor / admin) -- matches
  -- cancel_task()'s exact shape. The assignee branch that previously
  -- lived here is removed; see this file's header comment for why.
  IF NOT (
    is_super_admin()
    OR v_task.created_by = v_actor
    OR (is_supervisor_or_above() AND v_task.organization_id = get_my_org_id()
        AND (v_task.owning_section_id IS NULL OR v_task.owning_section_id IN (SELECT my_section_ids())))
  ) THEN
    RAISE EXCEPTION 'Not authorized to update this task';
  END IF;

  IF p_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'Use complete_task() or cancel_task() to close a task';
  END IF;

  IF p_owning_section_id IS NOT NULL AND NOT is_super_admin()
     AND p_owning_section_id NOT IN (SELECT my_section_ids()) THEN
    RAISE EXCEPTION 'Cannot move a task to a section you do not belong to';
  END IF;

  UPDATE tasks SET
    title = COALESCE(p_title, title),
    description = COALESCE(p_description, description),
    priority = COALESCE(p_priority, priority),
    visibility = COALESCE(p_visibility, visibility),
    due_date = COALESCE(p_due_date, due_date),
    start_date = COALESCE(p_start_date, start_date),
    owning_section_id = COALESCE(p_owning_section_id, owning_section_id),
    status = COALESCE(p_status, status)
  WHERE id = p_task_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'edited', 'task', p_task_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMIT;
