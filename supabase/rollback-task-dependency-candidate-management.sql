-- CorLink — rollback T3F.2A candidate management authorization only.

BEGIN;

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

COMMIT;
