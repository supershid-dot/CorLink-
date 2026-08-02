-- CorLink - T3F.2 Task Dependency Lifecycle Enforcement
-- Apply after patch-task-dependencies.sql.
BEGIN;

-- T3F.2 closes the lifecycle/create race by refreshing both endpoints after
-- the graph lock. The storage model, signature, audit, and cycle rules remain
-- unchanged from T3F.1.
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

  -- Graph lock first, then both endpoint rows in stable UUID order. Lifecycle
  -- paths use graph lock then one Task row, so no reverse ordering exists.
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

-- update_task() is the repository's only start path: open/waiting -> in_progress.
-- All other update behavior remains byte-for-byte equivalent to the foundation.
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

CREATE OR REPLACE FUNCTION complete_task(p_task_id UUID, p_notes TEXT DEFAULT NULL)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
  v_dependency_state RECORD;
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
  IF NOT valid_task_status_transition(v_task.status, 'completed') THEN
    RAISE EXCEPTION 'Invalid task status transition: % -> %', v_task.status, 'completed';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('task_dependencies:' || v_task.organization_id::TEXT, 0)
  );
  SELECT * INTO v_task FROM tasks WHERE id = p_task_id FOR UPDATE;

  IF NOT (
    is_super_admin()
    OR v_task.created_by = v_actor
    OR EXISTS (SELECT 1 FROM task_assignments ta WHERE ta.task_id = v_task.id AND ta.user_id = v_actor AND ta.is_active)
    OR (is_supervisor_or_above() AND v_task.organization_id = get_my_org_id()
        AND (v_task.owning_section_id IS NULL OR v_task.owning_section_id IN (SELECT my_section_ids())))
  ) THEN
    RAISE EXCEPTION 'Not authorized to complete this task';
  END IF;
  IF NOT valid_task_status_transition(v_task.status, 'completed') THEN
    RAISE EXCEPTION 'Invalid task status transition: % -> %', v_task.status, 'completed';
  END IF;

  SELECT * INTO v_dependency_state FROM get_task_dependency_state(p_task_id);
  IF v_dependency_state.is_blocked THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'Task cannot be completed because one or more prerequisites are unresolved.';
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

-- Read-only Task Detail state. Counts are withheld when any active endpoint
-- is hidden; the lifecycle booleans remain fail-closed and server-authoritative.
CREATE OR REPLACE FUNCTION get_task_dependency_lifecycle_state(p_task_id UUID)
RETURNS TABLE (
  active_prerequisite_count BIGINT,
  unresolved_prerequisite_count BIGINT,
  is_blocked BOOLEAN,
  can_start BOOLEAN,
  can_complete BOOLEAN
) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
  v_state RECORD;
  v_all_dependencies_visible BOOLEAN;
  v_can_manage BOOLEAN;
BEGIN
  IF v_actor IS NULL OR NOT can_view_task(p_task_id) THEN
    RETURN;
  END IF;

  SELECT * INTO v_task FROM tasks WHERE id = p_task_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT * INTO v_state FROM get_task_dependency_state(p_task_id);
  SELECT NOT EXISTS (
    SELECT 1 FROM task_dependencies td
    WHERE td.dependent_task_id = p_task_id
      AND td.removed_at IS NULL
      AND NOT (
        can_view_task(td.dependent_task_id)
        AND can_view_task(td.prerequisite_task_id)
      )
  ) INTO v_all_dependencies_visible;
  v_can_manage := can_manage_task(p_task_id);

  RETURN QUERY SELECT
    CASE WHEN v_all_dependencies_visible THEN v_state.active_prerequisite_count ELSE NULL::BIGINT END,
    CASE WHEN v_all_dependencies_visible THEN v_state.unresolved_prerequisite_count ELSE NULL::BIGINT END,
    COALESCE(v_state.is_blocked, FALSE),
    v_can_manage AND v_task.status IN ('open', 'waiting') AND NOT COALESCE(v_state.is_blocked, FALSE),
    v_can_manage AND v_task.status IN ('in_progress', 'waiting') AND NOT COALESCE(v_state.is_blocked, FALSE);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION get_task_dependency_lifecycle_state(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION get_task_dependency_lifecycle_state(UUID) TO authenticated;

COMMIT;
