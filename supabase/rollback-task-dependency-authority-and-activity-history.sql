-- ============================================================
-- CorLink — Rollback: Task Dependency Authority + Activity History
-- Reverses supabase/patch-task-dependency-authority-and-activity-history.sql
--
-- Restores every restated function to its exact pre-correction body
-- (can_manage_task() dependency gates, generic 'edited' lifecycle
-- audit action, raw-UUID assignment notes, no dependency-on-task
-- audit rows), drops can_manage_task_dependency() entirely (it did
-- not exist before the forward patch), and restores
-- audit_logs_action_check to its patch-task-dependencies.sql shape
-- (drops 'task_started'/'task_work_started').
--
-- Does not delete any audit_logs rows the forward patch's new code
-- path wrote while live (record_type='task' dependency-activity rows,
-- or rows using the two new action codes) — those are historical data,
-- not schema, and this rollback (like every other in this repository)
-- restores function/constraint behavior going forward without
-- touching data already written. If 'task_started'/'task_work_started'
-- rows exist, this rollback's tightened CHECK constraint would refuse
-- to apply against them only if the constraint were re-validated
-- against existing data — ALTER TABLE ... ADD CONSTRAINT always
-- validates existing rows, so this rollback correctly and safely
-- refuses (raises a constraint-violation error) rather than silently
-- stranding historical rows outside the restored vocabulary. Resolve
-- by not rolling back once those actions have been written in
-- practice, same convention as rollback-notification-target-
-- expansion.sql's explicit strand-refusal for target_type values.
-- ============================================================

\set ON_ERROR_STOP on

BEGIN;

DROP FUNCTION IF EXISTS can_manage_task_dependency(UUID);

CREATE OR REPLACE FUNCTION create_task_dependency(
  p_dependent_task_id UUID,
  p_prerequisite_task_id UUID
) RETURNS task_dependencies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_dependent tasks;
  v_prerequisite tasks;
  v_dependency task_dependencies;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_task_dependency requires an authenticated caller';
  END IF;
  IF p_dependent_task_id IS NULL OR p_prerequisite_task_id IS NULL THEN
    RAISE EXCEPTION 'Both dependency endpoint tasks are required';
  END IF;
  IF p_dependent_task_id = p_prerequisite_task_id THEN
    RAISE EXCEPTION 'A task cannot depend on itself';
  END IF;
  IF NOT can_manage_task(p_dependent_task_id)
     OR NOT can_manage_task(p_prerequisite_task_id) THEN
    RAISE EXCEPTION 'Not authorized to manage both dependency endpoint tasks';
  END IF;

  SELECT * INTO v_dependent FROM tasks WHERE id = p_dependent_task_id;
  SELECT * INTO v_prerequisite FROM tasks WHERE id = p_prerequisite_task_id;
  IF NOT FOUND OR v_dependent.id IS NULL OR v_prerequisite.id IS NULL THEN
    RAISE EXCEPTION 'Dependency endpoint task not found';
  END IF;
  IF v_dependent.organization_id <> v_prerequisite.organization_id THEN
    RAISE EXCEPTION 'Task dependencies require two tasks in the same organization';
  END IF;
  IF v_dependent.status NOT IN ('draft', 'open', 'waiting') THEN
    RAISE EXCEPTION 'Dependencies may only be added to draft, open, or waiting tasks';
  END IF;
  IF v_prerequisite.status = 'cancelled' THEN
    RAISE EXCEPTION 'A cancelled task cannot be added as a prerequisite';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('task_dependencies:' || v_dependent.organization_id::TEXT, 0)
  );

  PERFORM 1 FROM tasks
  WHERE id IN (p_dependent_task_id, p_prerequisite_task_id)
  ORDER BY id
  FOR UPDATE;
  SELECT * INTO v_dependent FROM tasks WHERE id = p_dependent_task_id;
  SELECT * INTO v_prerequisite FROM tasks WHERE id = p_prerequisite_task_id;

  IF NOT FOUND OR v_dependent.id IS NULL OR v_prerequisite.id IS NULL THEN
    RAISE EXCEPTION 'Dependency endpoint task not found';
  END IF;
  IF NOT can_manage_task(p_dependent_task_id)
     OR NOT can_manage_task(p_prerequisite_task_id) THEN
    RAISE EXCEPTION 'Not authorized to manage both dependency endpoint tasks';
  END IF;
  IF v_dependent.organization_id <> v_prerequisite.organization_id THEN
    RAISE EXCEPTION 'Task dependencies require two tasks in the same organization';
  END IF;
  IF v_dependent.status NOT IN ('draft', 'open', 'waiting') THEN
    RAISE EXCEPTION 'Dependencies may only be added to draft, open, or waiting tasks';
  END IF;
  IF v_prerequisite.status = 'cancelled' THEN
    RAISE EXCEPTION 'A cancelled task cannot be added as a prerequisite';
  END IF;

  IF EXISTS (
    SELECT 1 FROM task_dependencies td
    WHERE td.dependent_task_id = p_dependent_task_id
      AND td.prerequisite_task_id = p_prerequisite_task_id
      AND td.removed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'An active dependency already exists between these tasks';
  END IF;
  IF EXISTS (
    SELECT 1 FROM task_dependencies td
    WHERE td.dependent_task_id = p_prerequisite_task_id
      AND td.prerequisite_task_id = p_dependent_task_id
      AND td.removed_at IS NULL
  ) OR task_dependency_would_cycle(p_dependent_task_id, p_prerequisite_task_id) THEN
    RAISE EXCEPTION 'This dependency would create a circular chain';
  END IF;

  INSERT INTO task_dependencies (
    dependent_task_id, prerequisite_task_id, organization_id, created_by
  ) VALUES (
    p_dependent_task_id, p_prerequisite_task_id,
    v_dependent.organization_id, v_actor
  ) RETURNING * INTO v_dependency;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (
    v_actor, 'task_dependency_added', 'task_dependency', v_dependency.id,
    'dependent=' || p_dependent_task_id || ';prerequisite=' || p_prerequisite_task_id
  );
  RETURN v_dependency;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'An active dependency already exists between these tasks';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION remove_task_dependency(p_dependency_id UUID)
RETURNS task_dependencies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_dependency task_dependencies;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'remove_task_dependency requires an authenticated caller';
  END IF;
  SELECT * INTO v_dependency FROM task_dependencies
  WHERE id = p_dependency_id AND removed_at IS NULL;
  IF NOT FOUND
     OR NOT can_view_task(v_dependency.dependent_task_id)
     OR NOT can_view_task(v_dependency.prerequisite_task_id) THEN
    RAISE EXCEPTION 'Task dependency not found';
  END IF;
  IF NOT can_manage_task(v_dependency.dependent_task_id)
     OR NOT can_manage_task(v_dependency.prerequisite_task_id) THEN
    RAISE EXCEPTION 'Not authorized to manage both dependency endpoint tasks';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('task_dependencies:' || v_dependency.organization_id::TEXT, 0)
  );

  UPDATE task_dependencies
  SET removed_by = v_actor, removed_at = NOW()
  WHERE id = p_dependency_id AND removed_at IS NULL
  RETURNING * INTO v_dependency;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (
    v_actor, 'task_dependency_removed', 'task_dependency', v_dependency.id,
    'dependent=' || v_dependency.dependent_task_id ||
    ';prerequisite=' || v_dependency.prerequisite_task_id
  );
  RETURN v_dependency;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION list_task_dependencies(
  p_task_id UUID,
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
) RETURNS TABLE (
  dependency_id UUID,
  direction TEXT,
  related_task_id UUID,
  task_number TEXT,
  title TEXT,
  status TEXT,
  priority TEXT,
  due_date DATE,
  created_at TIMESTAMPTZ,
  can_remove BOOLEAN
) AS $$
  SELECT
    td.id,
    CASE WHEN td.dependent_task_id = p_task_id THEN 'depends_on' ELSE 'blocks' END,
    related.id,
    related.task_number,
    related.title,
    related.status,
    related.priority,
    related.due_date,
    td.created_at,
    can_manage_task(td.dependent_task_id)
      AND can_manage_task(td.prerequisite_task_id)
  FROM task_dependencies td
  JOIN tasks related ON related.id = CASE
    WHEN td.dependent_task_id = p_task_id THEN td.prerequisite_task_id
    ELSE td.dependent_task_id
  END
  WHERE td.removed_at IS NULL
    AND p_task_id IN (td.dependent_task_id, td.prerequisite_task_id)
    AND can_view_task(td.dependent_task_id)
    AND can_view_task(td.prerequisite_task_id)
  ORDER BY td.created_at DESC, td.id DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION get_task_dependency_capabilities(p_task_id UUID)
RETURNS TABLE (
  can_view_dependencies BOOLEAN,
  can_add_dependency BOOLEAN,
  can_remove_dependency BOOLEAN
) AS $$
  SELECT
    can_view_task(p_task_id),
    can_view_task(p_task_id) AND can_manage_task(p_task_id),
    can_view_task(p_task_id) AND can_manage_task(p_task_id);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

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
  v_is_pure_start_request BOOLEAN := (
    p_status = 'in_progress'
    AND p_title IS NULL AND p_description IS NULL AND p_priority IS NULL
    AND p_visibility IS NULL AND p_due_date IS NULL AND p_start_date IS NULL
    AND p_owning_section_id IS NULL
  );
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
    OR (is_supervisor_or_above() AND v_task.organization_id = get_my_org_id()
        AND (v_task.owning_section_id IS NULL OR v_task.owning_section_id IN (SELECT my_section_ids())))
    OR (v_is_pure_start_request AND EXISTS (
          SELECT 1 FROM task_assignments ta WHERE ta.task_id = v_task.id AND ta.user_id = v_actor AND ta.is_active
        ))
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

    PERFORM pg_advisory_xact_lock(
      hashtextextended('task_dependencies:' || v_task.organization_id::TEXT, 0)
    );
    SELECT * INTO v_task FROM tasks WHERE id = p_task_id FOR UPDATE;

    IF NOT (
      is_super_admin()
      OR v_task.created_by = v_actor
      OR (is_supervisor_or_above() AND v_task.organization_id = get_my_org_id()
          AND (v_task.owning_section_id IS NULL OR v_task.owning_section_id IN (SELECT my_section_ids())))
      OR (v_is_pure_start_request AND EXISTS (
            SELECT 1 FROM task_assignments ta WHERE ta.task_id = v_task.id AND ta.user_id = v_actor AND ta.is_active
          ))
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

CREATE OR REPLACE FUNCTION assign_task(p_task_id UUID, p_user_id UUID)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
  v_assignment_id UUID;
  v_outbox_event_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'assign_task requires an authenticated caller';
  END IF;

  SELECT * INTO v_task FROM tasks WHERE id = p_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Task not found';
  END IF;

  IF NOT (
    is_super_admin()
    OR v_task.created_by = v_actor
    OR (is_supervisor_or_above() AND v_task.organization_id = get_my_org_id()
        AND (v_task.owning_section_id IS NULL OR v_task.owning_section_id IN (SELECT my_section_ids())))
  ) THEN
    RAISE EXCEPTION 'Not authorized to assign this task';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM users WHERE id = p_user_id AND org_id = v_task.organization_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'Assignee must be an active user in the task''s organization';
  END IF;

  INSERT INTO task_assignments (task_id, user_id, assigned_by, assigned_at, is_active)
  VALUES (p_task_id, p_user_id, v_actor, NOW(), TRUE)
  ON CONFLICT (task_id, user_id) WHERE is_active DO NOTHING
  RETURNING id INTO v_assignment_id;

  IF v_assignment_id IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'assigned', 'task', p_task_id, 'Assigned task to user ' || p_user_id);

  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  VALUES (p_user_id, 'task_assigned', 'task', p_task_id,
          'You were assigned to task "' || v_task.title || '"');

  v_outbox_event_id := platform_enqueue_outbox_event(
    'task.assigned.v1', 'tasks', 'task', p_task_id, v_task.organization_id, v_actor,
    gen_random_uuid(), NULL, NOW(),
    jsonb_build_object(
      'notification_type', 'task.assigned.v1',
      'title_template_key', 'task.assigned',
      'template_params', jsonb_build_object('task_id', p_task_id, 'task_title', v_task.title, 'assigned_by', v_actor),
      'priority', 'normal',
      'target_type', 'specific_users',
      'target_user_ids', jsonb_build_array(p_user_id)
    ),
    v_assignment_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

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
    RETURN;
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'unassigned', 'task', p_task_id, 'Unassigned user ' || p_user_id || ' from task');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_action_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_action_check
  CHECK (action IN (
    'created', 'edited', 'submitted', 'approved', 'returned',
    'sent', 'received', 'routed', 'assigned', 'returned_to_sender', 'cancelled',
    'extension_requested', 'extension_approved', 'extension_denied',
    'viewed', 'login', 'logout', 'login_failed', 'locked',
    'password_changed', 'user_created', 'user_deactivated',
    'rejected', 'rescheduled', 'conflict_overridden', 'unassigned',
    'participant_added', 'participant_removed', 'attachment_added', 'attachment_removed',
    'invitation_responded', 'attendance_marked', 'minutes_updated', 'minutes_finalized',
    'meeting_locked', 'meeting_unlocked', 'meeting_group_created', 'meeting_group_updated',
    'meeting_group_deleted', 'meeting_group_members_updated', 'meeting_series_created',
    'meeting_draft_deleted', 'meeting_series_updated', 'meeting_series_split', 'meeting_series_cancelled',
    'completed', 'commented', 'task_linked', 'task_unlinked',
    'task_dependency_added', 'task_dependency_removed', 'task_dependency_waived'
  ));

COMMIT;
