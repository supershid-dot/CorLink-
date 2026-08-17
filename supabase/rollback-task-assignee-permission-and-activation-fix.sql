-- ============================================================
-- CorLink — Rollback: Task Assignee Permission + Activation Fix
-- Reverses supabase/patch-task-assignee-permission-and-activation-fix.sql
--
-- Restores update_task() to its EXACT immediate predecessor: the body
-- patch-task-dependency-lifecycle-enforcement.sql shipped (the
-- assignee branch re-added to both authorization checks; the
-- in_progress/advisory-lock/get_task_dependency_state() enforcement
-- was never removed by the forward patch and is reproduced here
-- unchanged, byte-for-byte identical to that file). This is a
-- correction of an earlier version of this rollback (docs/109), which
-- restored the wrong, older predecessor (patch-shared-task-
-- foundation.sql's version, missing the dependency enforcement
-- entirely) — restoring that version would NOT actually undo this
-- patch to its true prior state.
--
-- Matches every other rollback in this project: restores the exact
-- prior state, not a "better" intermediate one.
--
-- No table, column, or RLS policy was changed by the forward patch, so
-- there is nothing else to reverse here.
-- ============================================================

\set ON_ERROR_STOP on

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
  v_dependency_state RECORD;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'update_task requires an authenticated caller';
  END IF;

  SELECT * INTO v_task FROM tasks WHERE id = p_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Task not found';
  END IF;

  IF NOT (
    is_super_admin()
    OR v_task.created_by = v_actor
    OR EXISTS (SELECT 1 FROM task_assignments ta WHERE ta.task_id = v_task.id AND ta.user_id = v_actor AND ta.is_active)
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

  IF p_status = 'in_progress' THEN
    IF NOT valid_task_status_transition(v_task.status, 'in_progress') THEN
      RAISE EXCEPTION 'Invalid task status transition: % -> %', v_task.status, 'in_progress';
    END IF;

    -- Lock order: one organization graph key, dependent Task row, then
    -- prerequisite reads through get_task_dependency_state(). Dependency
    -- create/remove use the same graph key and never take a Task row lock.
    PERFORM pg_advisory_xact_lock(
      hashtextextended('task_dependencies:' || v_task.organization_id::TEXT, 0)
    );
    SELECT * INTO v_task FROM tasks WHERE id = p_task_id FOR UPDATE;

    -- Revalidate after any graph-lock or row-lock wait.
    IF NOT (
      is_super_admin()
      OR v_task.created_by = v_actor
      OR EXISTS (SELECT 1 FROM task_assignments ta WHERE ta.task_id = v_task.id AND ta.user_id = v_actor AND ta.is_active)
      OR (is_supervisor_or_above() AND v_task.organization_id = get_my_org_id()
          AND (v_task.owning_section_id IS NULL OR v_task.owning_section_id IN (SELECT my_section_ids())))
    ) THEN
      RAISE EXCEPTION 'Not authorized to update this task';
    END IF;
    IF NOT valid_task_status_transition(v_task.status, 'in_progress') THEN
      RAISE EXCEPTION 'Invalid task status transition: % -> %', v_task.status, 'in_progress';
    END IF;

    SELECT * INTO v_dependency_state FROM get_task_dependency_state(p_task_id);
    IF v_dependency_state.is_blocked THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'Task cannot be started because one or more prerequisites are unresolved.';
    END IF;
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
