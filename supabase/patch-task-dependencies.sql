-- CorLink — T3F.1 Task Dependency Backend Foundation
-- Apply after patch-task-relationships-hardening.sql.
BEGIN;

CREATE TABLE IF NOT EXISTS task_dependencies (
  id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  dependent_task_id    UUID        NOT NULL REFERENCES tasks(id) ON DELETE RESTRICT,
  prerequisite_task_id UUID        NOT NULL REFERENCES tasks(id) ON DELETE RESTRICT,
  organization_id      UUID        NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
  created_by           UUID        NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  removed_by           UUID        REFERENCES users(id) ON DELETE RESTRICT,
  removed_at           TIMESTAMPTZ,
  CONSTRAINT task_dependencies_no_self CHECK (dependent_task_id <> prerequisite_task_id),
  CONSTRAINT task_dependencies_removal_pair CHECK (
    (removed_at IS NULL AND removed_by IS NULL)
    OR (removed_at IS NOT NULL AND removed_by IS NOT NULL)
  )
);

-- Architecture §Architecture/§Supervisor override: persistence only in T3F.1.
-- No authenticated waiver mutation exists until the separately approved lifecycle milestone.
CREATE TABLE IF NOT EXISTS task_dependency_waivers (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  dependency_id UUID        NOT NULL UNIQUE REFERENCES task_dependencies(id) ON DELETE RESTRICT,
  waived_by     UUID        NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  waived_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  reason        TEXT        NOT NULL CHECK (btrim(reason) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_task_dependencies_active_pair
  ON task_dependencies(dependent_task_id, prerequisite_task_id)
  WHERE removed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_task_dependencies_dependent_active
  ON task_dependencies(dependent_task_id, created_at DESC, id DESC)
  WHERE removed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_task_dependencies_prerequisite_active
  ON task_dependencies(prerequisite_task_id, created_at DESC, id DESC)
  WHERE removed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_task_dependencies_org_graph_active
  ON task_dependencies(organization_id, dependent_task_id, prerequisite_task_id)
  WHERE removed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_task_dependency_waivers_dependency
  ON task_dependency_waivers(dependency_id, waived_at DESC);
CREATE INDEX IF NOT EXISTS idx_tasks_dependency_picker_number
  ON tasks(organization_id, lower(task_number) text_pattern_ops);
CREATE INDEX IF NOT EXISTS idx_tasks_dependency_picker_title
  ON tasks(organization_id, lower(title) text_pattern_ops);

-- Cross-row invariants cannot be CHECK constraints. This trigger is defense in
-- depth for owner/service operations; authenticated writes remain RPC-only.
CREATE OR REPLACE FUNCTION enforce_task_dependency_endpoints()
RETURNS TRIGGER AS $$
DECLARE
  v_dependent_org UUID;
  v_prerequisite_org UUID;
BEGIN
  SELECT organization_id INTO v_dependent_org FROM tasks WHERE id = NEW.dependent_task_id;
  SELECT organization_id INTO v_prerequisite_org FROM tasks WHERE id = NEW.prerequisite_task_id;
  IF v_dependent_org IS NULL OR v_prerequisite_org IS NULL THEN
    RAISE EXCEPTION 'Both dependency endpoint tasks are required';
  END IF;
  IF v_dependent_org <> v_prerequisite_org OR NEW.organization_id <> v_dependent_org THEN
    RAISE EXCEPTION 'Task dependency endpoints and organization must match';
  END IF;
  IF TG_OP = 'UPDATE' AND (
    NEW.dependent_task_id <> OLD.dependent_task_id
    OR NEW.prerequisite_task_id <> OLD.prerequisite_task_id
    OR NEW.organization_id <> OLD.organization_id
    OR NEW.created_by <> OLD.created_by
    OR NEW.created_at <> OLD.created_at
  ) THEN
    RAISE EXCEPTION 'Task dependency endpoints and creation metadata are immutable';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS task_dependency_endpoint_guard ON task_dependencies;
CREATE TRIGGER task_dependency_endpoint_guard
  BEFORE INSERT OR UPDATE ON task_dependencies
  FOR EACH ROW EXECUTE FUNCTION enforce_task_dependency_endpoints();

-- Private helper. Proposed dependent->prerequisite closes a cycle when the
-- prerequisite already reaches the dependent by following active depends_on edges.
CREATE OR REPLACE FUNCTION task_dependency_would_cycle(
  p_dependent_task_id UUID,
  p_prerequisite_task_id UUID
) RETURNS BOOLEAN AS $$
  WITH RECURSIVE prerequisites(task_id) AS (
    SELECT p_prerequisite_task_id
    UNION
    SELECT td.prerequisite_task_id
    FROM task_dependencies td
    JOIN prerequisites p ON p.task_id = td.dependent_task_id
    WHERE td.removed_at IS NULL
  )
  SELECT EXISTS (
    SELECT 1 FROM prerequisites WHERE task_id = p_dependent_task_id
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- Private future-lifecycle helper. Cancelled prerequisites remain unresolved;
-- a completed prerequisite or explicit persisted waiver is resolved.
CREATE OR REPLACE FUNCTION get_task_dependency_state(p_task_id UUID)
RETURNS TABLE (
  active_prerequisite_count BIGINT,
  unresolved_prerequisite_count BIGINT,
  is_blocked BOOLEAN
) AS $$
  SELECT
    count(*)::BIGINT,
    count(*) FILTER (
      WHERE prerequisite.status <> 'completed' AND waiver.id IS NULL
    )::BIGINT,
    (count(*) FILTER (
      WHERE prerequisite.status <> 'completed' AND waiver.id IS NULL
    ) > 0)
  FROM task_dependencies td
  JOIN tasks prerequisite ON prerequisite.id = td.prerequisite_task_id
  LEFT JOIN task_dependency_waivers waiver ON waiver.dependency_id = td.id
  WHERE td.dependent_task_id = p_task_id AND td.removed_at IS NULL;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

ALTER TABLE task_dependencies ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "task_dependencies_select" ON task_dependencies;
CREATE POLICY "task_dependencies_select" ON task_dependencies
  FOR SELECT TO authenticated
  USING (
    can_view_task(dependent_task_id)
    AND can_view_task(prerequisite_task_id)
  );

ALTER TABLE task_dependency_waivers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "task_dependency_waivers_select" ON task_dependency_waivers;
CREATE POLICY "task_dependency_waivers_select" ON task_dependency_waivers
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM task_dependencies td
    WHERE td.id = dependency_id
      AND can_view_task(td.dependent_task_id)
      AND can_view_task(td.prerequisite_task_id)
  ));

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

  -- Serialize removal with create/recreate and cycle checks in this graph.
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

-- list_tasks() is bounded but has no number/title query, so the future picker
-- needs a bounded server-side prefix search instead of client-side filtering.
CREATE OR REPLACE FUNCTION search_tasks_for_dependency(
  p_task_id UUID,
  p_query TEXT,
  p_limit INTEGER DEFAULT 20
) RETURNS TABLE (
  id UUID,
  task_number TEXT,
  title TEXT,
  status TEXT,
  priority TEXT,
  due_date DATE
) AS $$
  SELECT candidate.id, candidate.task_number, candidate.title,
         candidate.status, candidate.priority, candidate.due_date
  FROM tasks current_task
  JOIN tasks candidate
    ON candidate.organization_id = current_task.organization_id
   AND candidate.id <> current_task.id
  WHERE current_task.id = p_task_id
    AND can_view_task(current_task.id)
    AND can_view_task(candidate.id)
    AND btrim(COALESCE(p_query, '')) <> ''
    AND (
      lower(candidate.task_number) LIKE lower(btrim(p_query)) || '%'
      OR lower(candidate.title) LIKE lower(btrim(p_query)) || '%'
    )
    AND NOT EXISTS (
      SELECT 1 FROM task_dependencies td
      WHERE td.removed_at IS NULL
        AND (
          (td.dependent_task_id = current_task.id AND td.prerequisite_task_id = candidate.id)
          OR (td.dependent_task_id = candidate.id AND td.prerequisite_task_id = current_task.id)
        )
    )
  ORDER BY
    CASE WHEN lower(candidate.task_number) = lower(btrim(p_query)) THEN 0 ELSE 1 END,
    candidate.task_number, candidate.title, candidate.id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_record_type_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_record_type_check
  CHECK (record_type IN (
    'request', 'response', 'internal_request', 'prisoner_letter', 'deadline_extension',
    'user', 'organization', 'section', 'session', 'attachment', 'external_correspondence',
    'meeting_room', 'meeting_room_block', 'meeting_room_booking', 'meeting', 'meeting_group', 'meeting_series',
    'task', 'task_relationship', 'task_dependency'
  ));

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

DROP POLICY IF EXISTS "audit_select_task_dependencies" ON audit_logs;
CREATE POLICY "audit_select_task_dependencies" ON audit_logs
  FOR SELECT TO authenticated
  USING (
    record_type = 'task_dependency'
    AND EXISTS (
      SELECT 1 FROM task_dependencies td
      WHERE td.id = record_id
        AND can_view_task(td.dependent_task_id)
        AND can_view_task(td.prerequisite_task_id)
    )
  );

REVOKE ALL ON TABLE task_dependencies, task_dependency_waivers FROM PUBLIC, anon;
GRANT SELECT ON TABLE task_dependencies, task_dependency_waivers TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE task_dependencies, task_dependency_waivers FROM authenticated;

REVOKE ALL ON FUNCTION create_task_dependency(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION remove_task_dependency(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION list_task_dependencies(UUID, INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION get_task_dependency_capabilities(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION search_tasks_for_dependency(UUID, TEXT, INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION task_dependency_would_cycle(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION get_task_dependency_state(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION enforce_task_dependency_endpoints() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION create_task_dependency(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION remove_task_dependency(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION list_task_dependencies(UUID, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION get_task_dependency_capabilities(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION search_tasks_for_dependency(UUID, TEXT, INTEGER) TO authenticated;

COMMIT;
