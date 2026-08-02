-- CorLink - rollback T3F.2 to the exact T3F.1 lifecycle definitions.
\set ON_ERROR_STOP on
BEGIN;

DROP FUNCTION IF EXISTS get_task_dependency_lifecycle_state(UUID);

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

  -- Exact key: hashtextextended('task_dependencies:' || organization_id, 0).
  -- Every create in one organization takes exactly one transaction lock. There
  -- is no multi-key acquisition order, so advisory-lock deadlocks cannot form;
  -- concurrent inserts see the prior committed graph before cycle validation.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('task_dependencies:' || v_dependent.organization_id::TEXT, 0)
  );

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

CREATE OR REPLACE FUNCTION complete_task(p_task_id UUID, p_notes TEXT DEFAULT NULL)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'complete_task requires an authenticated caller';
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
    RAISE EXCEPTION 'Not authorized to complete this task';
  END IF;

  UPDATE tasks
  SET status = 'completed', completed_at = NOW(), completed_by = v_actor
  WHERE id = p_task_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'completed', 'task', p_task_id, p_notes);

  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  SELECT uid, 'task_completed', 'task', p_task_id,
         'Task "' || v_task.title || '" was marked completed'
  FROM (
    SELECT v_task.created_by AS uid
    UNION
    SELECT user_id FROM task_watchers WHERE task_id = p_task_id
  ) recipients
  WHERE uid IS NOT NULL AND uid <> v_actor;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMIT;
