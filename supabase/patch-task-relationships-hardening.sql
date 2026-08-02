-- CorLink — T3E.1 relationship scope, authorization, and concurrency hardening
-- Apply after patch-task-relationships.sql. Idempotent after a successful run.
BEGIN;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM task_relationships
    WHERE relationship_type NOT IN ('related', 'duplicate', 'parent')
  ) THEN
    RAISE EXCEPTION 'T3E.1 refused: explicitly migrate rows outside the approved relationship vocabulary before hardening';
  END IF;
END $$;

-- Symmetric relationships have no direction. Normalize the original T3E rows
-- before enforcing canonical UUID order. Parent rows retain parent -> child.
UPDATE task_relationships
SET source_task_id = target_task_id,
    target_task_id = source_task_id
WHERE relationship_type IN ('related', 'duplicate')
  AND source_task_id > target_task_id;

ALTER TABLE task_relationships DROP CONSTRAINT IF EXISTS task_relationships_relationship_type_check;
ALTER TABLE task_relationships DROP CONSTRAINT IF EXISTS task_relationships_type_check;
ALTER TABLE task_relationships ADD CONSTRAINT task_relationships_type_check
  CHECK (relationship_type IN ('related', 'duplicate', 'parent'));
ALTER TABLE task_relationships DROP CONSTRAINT IF EXISTS task_relationships_canonical_direction;
ALTER TABLE task_relationships ADD CONSTRAINT task_relationships_canonical_direction
  CHECK (relationship_type = 'parent' OR source_task_id < target_task_id);

CREATE OR REPLACE FUNCTION can_view_task_relationship(p_relationship_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM task_relationships tr
    WHERE tr.id = p_relationship_id
      AND can_view_task(tr.source_task_id)
      AND can_view_task(tr.target_task_id)
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_record_type_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_record_type_check
  CHECK (record_type IN (
    'request', 'response', 'internal_request', 'prisoner_letter', 'deadline_extension',
    'user', 'organization', 'section', 'session', 'attachment', 'external_correspondence',
    'meeting_room', 'meeting_room_block', 'meeting_room_booking', 'meeting', 'meeting_group', 'meeting_series',
    'task', 'task_relationship'
  ));

DROP POLICY IF EXISTS "audit_select_task_relationships" ON audit_logs;
CREATE POLICY "audit_select_task_relationships" ON audit_logs
  FOR SELECT TO authenticated
  USING (record_type = 'task_relationship' AND can_view_task_relationship(record_id));

CREATE OR REPLACE FUNCTION create_task_relationship(
  p_source_task_id UUID,
  p_target_task_id UUID,
  p_relationship_type TEXT
) RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_relationship_id UUID;
  v_source UUID;
  v_target UUID;
  v_source_org UUID;
  v_target_org UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_task_relationship requires an authenticated caller';
  END IF;
  IF p_source_task_id IS NULL OR p_target_task_id IS NULL THEN
    RAISE EXCEPTION 'Both tasks are required';
  END IF;
  IF p_source_task_id = p_target_task_id THEN
    RAISE EXCEPTION 'A task cannot be related to itself';
  END IF;
  IF p_relationship_type IS NULL OR p_relationship_type NOT IN ('related', 'duplicate', 'parent') THEN
    RAISE EXCEPTION 'Invalid task relationship type';
  END IF;
  IF NOT can_manage_task(p_source_task_id) OR NOT can_manage_task(p_target_task_id) THEN
    RAISE EXCEPTION 'Not authorized to manage relationships for both tasks';
  END IF;

  SELECT organization_id INTO v_source_org FROM tasks WHERE id = p_source_task_id;
  SELECT organization_id INTO v_target_org FROM tasks WHERE id = p_target_task_id;
  IF v_source_org IS NULL OR v_target_org IS NULL OR v_source_org <> v_target_org THEN
    RAISE EXCEPTION 'Task relationships require two tasks in the same organization';
  END IF;

  -- One organization-scoped lock per transaction. All create operations for
  -- that organization's graph serialize behind the same key, so duplicate,
  -- reverse, contradictory-parent, and recursive-cycle checks see the last
  -- committed graph. Because an operation takes only one lock, there is no
  -- multi-key acquisition order and no advisory-lock deadlock cycle.
  PERFORM pg_advisory_xact_lock(hashtextextended('task_relationships:' || v_source_org::text, 0));

  IF p_relationship_type IN ('related', 'duplicate') THEN
    v_source := LEAST(p_source_task_id, p_target_task_id);
    v_target := GREATEST(p_source_task_id, p_target_task_id);
  ELSE
    v_source := p_source_task_id;
    v_target := p_target_task_id;
  END IF;

  IF EXISTS (
    SELECT 1 FROM task_relationships tr
    WHERE tr.removed_at IS NULL
      AND LEAST(tr.source_task_id, tr.target_task_id) = LEAST(v_source, v_target)
      AND GREATEST(tr.source_task_id, tr.target_task_id) = GREATEST(v_source, v_target)
  ) THEN
    RAISE EXCEPTION 'An active relationship already exists between these tasks';
  END IF;

  IF p_relationship_type = 'parent' AND EXISTS (
    WITH RECURSIVE descendants(task_id) AS (
      SELECT v_target
      UNION
      SELECT tr.target_task_id
      FROM task_relationships tr
      JOIN descendants d ON d.task_id = tr.source_task_id
      WHERE tr.removed_at IS NULL AND tr.relationship_type = 'parent'
    )
    SELECT 1 FROM descendants WHERE task_id = v_source
  ) THEN
    RAISE EXCEPTION 'This parent relationship would create a circular chain';
  END IF;

  INSERT INTO task_relationships (source_task_id, target_task_id, relationship_type, created_by)
  VALUES (v_source, v_target, p_relationship_type, v_actor)
  RETURNING id INTO v_relationship_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_linked', 'task_relationship', v_relationship_id,
          'type=' || p_relationship_type);
  RETURN v_relationship_id;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'An active relationship already exists between these tasks';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION remove_task_relationship(p_relationship_id UUID)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_relationship task_relationships;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'remove_task_relationship requires an authenticated caller';
  END IF;
  SELECT * INTO v_relationship FROM task_relationships
  WHERE id = p_relationship_id AND removed_at IS NULL;
  IF NOT FOUND OR NOT can_view_task(v_relationship.source_task_id)
     OR NOT can_view_task(v_relationship.target_task_id) THEN
    RAISE EXCEPTION 'Task relationship not found';
  END IF;
  IF NOT can_manage_task(v_relationship.source_task_id)
     OR NOT can_manage_task(v_relationship.target_task_id) THEN
    RAISE EXCEPTION 'Not authorized to remove this task relationship';
  END IF;
  UPDATE task_relationships SET removed_at = NOW(), removed_by = v_actor
  WHERE id = p_relationship_id AND removed_at IS NULL;
  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_unlinked', 'task_relationship', p_relationship_id,
          'type=' || v_relationship.relationship_type);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION list_related_tasks(p_task_id UUID)
RETURNS TABLE (
  relationship_id UUID, relationship_type TEXT, related_task_id UUID,
  task_number TEXT, title TEXT, status TEXT, priority TEXT,
  assignees JSONB, due_date DATE, created_at TIMESTAMPTZ, can_remove BOOLEAN
) AS $$
  SELECT tr.id,
    CASE WHEN tr.relationship_type = 'parent' AND tr.target_task_id = p_task_id
         THEN 'child' ELSE tr.relationship_type END,
    related.id, related.task_number, related.title, related.status, related.priority,
    COALESCE((
      SELECT jsonb_agg(jsonb_build_object('user_id', ta.user_id, 'full_name', u.full_name) ORDER BY ta.assigned_at)
      FROM task_assignments ta JOIN users u ON u.id = ta.user_id
      WHERE ta.task_id = related.id AND ta.is_active
    ), '[]'::jsonb),
    related.due_date, tr.created_at,
    can_manage_task(tr.source_task_id) AND can_manage_task(tr.target_task_id)
  FROM task_relationships tr
  JOIN tasks related ON related.id = CASE WHEN tr.source_task_id = p_task_id THEN tr.target_task_id ELSE tr.source_task_id END
  WHERE tr.removed_at IS NULL
    AND p_task_id IN (tr.source_task_id, tr.target_task_id)
    AND can_view_task(tr.source_task_id)
    AND can_view_task(tr.target_task_id)
  ORDER BY tr.created_at DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION can_view_task_relationship(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION can_view_task_relationship(UUID) TO authenticated;

COMMIT;
