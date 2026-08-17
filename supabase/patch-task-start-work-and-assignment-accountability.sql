-- ============================================================
-- UAT correction — Task "Start Work" action + assignment
-- accountability (self-unassign removal).
--
-- Live staging UAT (docs/110 deployed the reconciled permission fix;
-- this is the next round of findings from manual testing against
-- that deployment) surfaced two issues:
--
-- ISSUE 1 — an assignee opening their own Open task sees "No actions
-- available." even though update_task() ALREADY supports a
-- dependency-aware Open -> In Progress transition for an active
-- assignee (patch-task-dependency-lifecycle-enforcement.sql's
-- p_status = 'in_progress' branch, preserved verbatim by
-- patch-task-assignee-permission-and-activation-fix.sql's
-- v_is_pure_start_request exception — see docs/109). This is a
-- FRONTEND gap only: no button ever called update_task() with a pure
-- { status: 'in_progress' } request. No backend change is needed —
-- confirmed by direct inspection of the current, already-reconciled
-- update_task() body (unchanged by this file) and of
-- get_task_dependency_lifecycle_state() (patch-task-dependency-
-- lifecycle-enforcement.sql), whose can_start column already
-- evaluates `can_manage_task(p_task_id) AND status IN ('open',
-- 'waiting') AND NOT is_blocked` -- and can_manage_task() itself
-- (patch-request-task-integration.sql) already includes an active-
-- assignee branch alongside creator/supervisor-in-scope/admin, so
-- can_start is already true for exactly the same actors update_task()
-- itself would accept for a pure start request. The frontend
-- correction (js/views/task-detail.js) adds a "Start Work" button
-- that reuses this existing RPC and existing capability field --
-- no new RPC, no new column, no update_task() restatement.
--
-- ISSUE 2 — product decision: assignment is now an accountable
-- management action. A plain assignee must no longer be able to
-- silently remove their own assignment; only creator/supervisor-in-
-- scope/admin (the same manage tier that can add/remove ANY
-- assignment) may unassign anyone, including that assignee.
-- unassign_task() (only ever defined once, in patch-shared-task-
-- foundation.sql, never restated since) currently has:
--
--   OR p_user_id = v_actor
--
-- as a THIRD, independent authorization branch alongside creator/
-- supervisor-in-scope/admin -- letting any caller remove their own
-- assignment regardless of manage-tier status. This was a deliberate,
-- narrow design at the time (docs/107 Finding 2: self-only, already
-- audited, no evidence of a broader intended behavior) but the
-- product decision above supersedes it. This file's ONLY change:
-- that branch is removed. Everything else in the function -- the
-- creator/supervisor-in-scope/admin branches, the idempotent no-op on
-- an already-inactive assignment, the audit_logs insert -- is
-- preserved byte-for-byte.
--
-- No reassignment-request/decline/return workflow is introduced here
-- -- no existing RPC supports it, and inventing a new table/workflow
-- engine to replace one authorization branch is out of proportion for
-- this correction (see docs/111 for why "Request Reassignment" is
-- recorded as a future enhancement, not built now).
--
-- Explicitly UNCHANGED by this file: update_task() (no restatement --
-- the existing Open -> In Progress path is already correct),
-- assign_task(), complete_task(), can_view_task(), can_manage_task(),
-- get_task_dependency_state(), get_task_dependency_lifecycle_state(),
-- create_task_dependency(), the attachments RLS policy, and every
-- other Task RPC. Only unassign_task() is redefined below.
--
-- Idempotent (CREATE OR REPLACE) -- safe to run more than once.
-- ============================================================

BEGIN;

-- Byte-for-byte identical to patch-shared-task-foundation.sql's
-- unassign_task() except: the `OR p_user_id = v_actor` authorization
-- branch is removed. Nothing else differs -- same idempotent no-op
-- behavior, same audit_logs insert, same error messages.
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

  -- Manage-tier only (creator / in-scope supervisor / admin), same
  -- shape as assign_task()'s own authorization. The self-unassign
  -- branch that previously lived here (`OR p_user_id = v_actor`) is
  -- removed -- assignment removal is now exclusively a manage-tier
  -- action, for any assignee including the caller themselves.
  IF NOT (
    is_super_admin()
    OR v_task.created_by = v_actor
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
