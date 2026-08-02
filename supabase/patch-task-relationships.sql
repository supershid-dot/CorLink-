-- CorLink — T3E Task-to-Task Relationships
-- Apply after patch-request-task-integration.sql (can_manage_task()).

CREATE TABLE IF NOT EXISTS task_relationships (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  source_task_id    UUID        NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  target_task_id    UUID        NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  relationship_type TEXT        NOT NULL CHECK (relationship_type IN (
                      'related', 'blocked_by', 'blocks', 'duplicate', 'parent', 'child'
                    )),
  created_by        UUID        NOT NULL REFERENCES users(id),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  removed_by        UUID        REFERENCES users(id),
  removed_at        TIMESTAMPTZ,
  CONSTRAINT task_relationships_no_self CHECK (source_task_id <> target_task_id)
);

CREATE INDEX IF NOT EXISTS idx_task_relationships_source_active
  ON task_relationships(source_task_id, created_at DESC) WHERE removed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_task_relationships_target_active
  ON task_relationships(target_task_id, created_at DESC) WHERE removed_at IS NULL;
-- One active relationship of any type per unordered task pair. This also
-- prevents inverse duplicates such as A blocks B plus B blocked_by A.
CREATE UNIQUE INDEX IF NOT EXISTS idx_task_relationships_active_pair
  ON task_relationships(
    LEAST(source_task_id, target_task_id),
    GREATEST(source_task_id, target_task_id)
  ) WHERE removed_at IS NULL;

ALTER TABLE task_relationships ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "task_relationships_select" ON task_relationships;
CREATE POLICY "task_relationships_select" ON task_relationships
  FOR SELECT TO authenticated
  USING (can_view_task(source_task_id) AND can_view_task(target_task_id));
-- No INSERT/UPDATE/DELETE policies: all writes use the RPCs below.

CREATE OR REPLACE FUNCTION create_task_relationship(
  p_source_task_id UUID,
  p_target_task_id UUID,
  p_relationship_type TEXT
) RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_relationship_id UUID;
  v_parent UUID;
  v_child UUID;
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
  IF p_relationship_type IS NULL OR p_relationship_type NOT IN (
    'related', 'blocked_by', 'blocks', 'duplicate', 'parent', 'child'
  ) THEN
    RAISE EXCEPTION 'Invalid task relationship type';
  END IF;
  IF NOT can_manage_task(p_source_task_id) THEN
    RAISE EXCEPTION 'Not authorized to manage relationships for this task';
  END IF;
  IF NOT can_view_task(p_target_task_id) THEN
    RAISE EXCEPTION 'Related task not found or not visible';
  END IF;
  IF EXISTS (
    SELECT 1 FROM task_relationships tr
    WHERE tr.removed_at IS NULL
      AND LEAST(tr.source_task_id, tr.target_task_id) = LEAST(p_source_task_id, p_target_task_id)
      AND GREATEST(tr.source_task_id, tr.target_task_id) = GREATEST(p_source_task_id, p_target_task_id)
  ) THEN
    RAISE EXCEPTION 'An active relationship already exists between these tasks';
  END IF;

  IF p_relationship_type IN ('parent', 'child') THEN
    -- Serialize hierarchy checks so two concurrent inserts cannot each pass
    -- against a snapshot that lacks the other's edge and jointly form a cycle.
    PERFORM pg_advisory_xact_lock(hashtext('task_relationships_parent_child'));
    IF p_relationship_type = 'parent' THEN
      v_parent := p_source_task_id;
      v_child := p_target_task_id;
    ELSE
      v_parent := p_target_task_id;
      v_child := p_source_task_id;
    END IF;

    -- Existing parent->child edges are normalized in the recursive CTE.
    -- A path from the proposed child back to the proposed parent would close
    -- a cycle, so reject it before inserting the new edge.
    IF EXISTS (
      WITH RECURSIVE descendants(task_id) AS (
        SELECT v_child
        UNION
        SELECT CASE
          WHEN tr.relationship_type = 'parent' THEN tr.target_task_id
          ELSE tr.source_task_id
        END
        FROM task_relationships tr
        JOIN descendants d ON d.task_id = CASE
          WHEN tr.relationship_type = 'parent' THEN tr.source_task_id
          ELSE tr.target_task_id
        END
        WHERE tr.removed_at IS NULL AND tr.relationship_type IN ('parent', 'child')
      )
      SELECT 1 FROM descendants WHERE task_id = v_parent
    ) THEN
      RAISE EXCEPTION 'This parent/child relationship would create a circular chain';
    END IF;
  END IF;

  INSERT INTO task_relationships (
    source_task_id, target_task_id, relationship_type, created_by
  ) VALUES (
    p_source_task_id, p_target_task_id, p_relationship_type, v_actor
  ) RETURNING id INTO v_relationship_id;

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

  SELECT * INTO v_relationship
  FROM task_relationships
  WHERE id = p_relationship_id AND removed_at IS NULL;

  IF NOT FOUND
     OR NOT can_view_task(v_relationship.source_task_id)
     OR NOT can_view_task(v_relationship.target_task_id) THEN
    RAISE EXCEPTION 'Task relationship not found';
  END IF;
  IF NOT (
    can_manage_task(v_relationship.source_task_id)
    OR can_manage_task(v_relationship.target_task_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to remove this task relationship';
  END IF;

  UPDATE task_relationships
  SET removed_at = NOW(), removed_by = v_actor
  WHERE id = p_relationship_id AND removed_at IS NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION list_related_tasks(p_task_id UUID)
RETURNS TABLE (
  relationship_id UUID,
  relationship_type TEXT,
  related_task_id UUID,
  task_number TEXT,
  title TEXT,
  status TEXT,
  priority TEXT,
  assignees JSONB,
  due_date DATE,
  created_at TIMESTAMPTZ,
  can_remove BOOLEAN
) AS $$
  SELECT
    tr.id,
    CASE
      WHEN tr.source_task_id = p_task_id THEN tr.relationship_type
      WHEN tr.relationship_type = 'blocked_by' THEN 'blocks'
      WHEN tr.relationship_type = 'blocks' THEN 'blocked_by'
      WHEN tr.relationship_type = 'parent' THEN 'child'
      WHEN tr.relationship_type = 'child' THEN 'parent'
      ELSE tr.relationship_type
    END,
    related.id,
    related.task_number,
    related.title,
    related.status,
    related.priority,
    COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'user_id', ta.user_id,
        'full_name', u.full_name
      ) ORDER BY ta.assigned_at)
      FROM task_assignments ta
      JOIN users u ON u.id = ta.user_id
      WHERE ta.task_id = related.id AND ta.is_active
    ), '[]'::jsonb),
    related.due_date,
    tr.created_at,
    can_manage_task(tr.source_task_id) OR can_manage_task(tr.target_task_id)
  FROM task_relationships tr
  JOIN tasks related ON related.id = CASE
    WHEN tr.source_task_id = p_task_id THEN tr.target_task_id
    ELSE tr.source_task_id
  END
  WHERE tr.removed_at IS NULL
    AND p_task_id IN (tr.source_task_id, tr.target_task_id)
    AND can_view_task(tr.source_task_id)
    AND can_view_task(tr.target_task_id)
  ORDER BY tr.created_at DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION get_task_relationship_capabilities(p_task_id UUID)
RETURNS TABLE (can_create BOOLEAN, can_remove BOOLEAN) AS $$
  SELECT
    can_view_task(p_task_id) AND can_manage_task(p_task_id),
    can_view_task(p_task_id) AND can_manage_task(p_task_id);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON TABLE task_relationships FROM PUBLIC, anon;
GRANT SELECT ON TABLE task_relationships TO authenticated;

REVOKE ALL ON FUNCTION create_task_relationship(UUID, UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION remove_task_relationship(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION list_related_tasks(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION get_task_relationship_capabilities(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_task_relationship(UUID, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION remove_task_relationship(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION list_related_tasks(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_task_relationship_capabilities(UUID) TO authenticated;
