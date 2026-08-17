-- ============================================================
-- CorLink — Rollback: Task Start Work + Assignment Accountability
-- Reverses supabase/patch-task-start-work-and-assignment-
-- accountability.sql
--
-- Restores unassign_task() to its EXACT immediate predecessor: the
-- body patch-shared-task-foundation.sql shipped and that has never
-- been restated since (`OR p_user_id = v_actor` re-added as a third,
-- independent authorization branch, unconditionally alongside
-- creator/supervisor-in-scope/admin). Every other line is unchanged.
--
-- The frontend "Start Work" action (js/views/task-detail.js) calls
-- update_task() exactly as it already existed -- no RPC, table,
-- column, or RLS policy was added or changed by the forward patch for
-- that action, so there is nothing else to reverse for it here. After
-- this rollback, the frontend's Start Work button (if still deployed)
-- continues to work identically -- it never depended on anything this
-- rollback touches -- but the "Unassign Me" UI (also removed by the
-- paired frontend change, tracked outside this SQL file) would need
-- its own separate revert if a full behavioral rollback is desired.
--
-- Matches every other rollback in this project: restores the exact
-- prior state, not a "better" intermediate one.
-- ============================================================

\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION unassign_task(p_task_id UUID, p_user_id UUID)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
  v_rows INTEGER;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'unassign_task requires an authenticated caller';
  END IF;

  SELECT * INTO v_task FROM tasks WHERE id = p_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Task not found';
  END IF;

  IF NOT (
    is_super_admin()
    OR v_task.created_by = v_actor
    OR p_user_id = v_actor
    OR (is_supervisor_or_above() AND v_task.organization_id = get_my_org_id()
        AND (v_task.owning_section_id IS NULL OR v_task.owning_section_id IN (SELECT my_section_ids())))
  ) THEN
    RAISE EXCEPTION 'Not authorized to unassign this task';
  END IF;

  UPDATE task_assignments
  SET is_active = FALSE, unassigned_at = NOW()
  WHERE task_id = p_task_id AND user_id = p_user_id AND is_active = TRUE;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RETURN; -- nothing active to unassign; idempotent no-op
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'unassigned', 'task', p_task_id, 'Unassigned user ' || p_user_id || ' from task');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMIT;
