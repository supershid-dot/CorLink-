-- ============================================================
-- CorLink — Rollback: Task Search and Linking Candidates
-- Reverses supabase/patch-task-search-and-linking-candidates.sql
--
-- Restores search_tasks_for_dependency() to its exact pre-correction
-- state (prefix-only matching, as it was in patch-task-dependency-
-- candidate-management.sql), drops search_tasks_for_relationship()
-- entirely (it did not exist before the forward patch), drops the two
-- trigram indexes, and restores the two prefix (`text_pattern_ops`)
-- indexes the forward patch dropped.
--
-- pg_trgm itself is left installed rather than dropped. It is inert
-- read-only infrastructure with no write path and nothing else in
-- this schema depends on it at the time this rollback is written; a
-- future migration is free to DROP EXTENSION pg_trgm separately if it
-- is confirmed unused, but doing so here — as a side effect of an
-- unrelated function/index rollback — is out of this rollback's own
-- narrow scope. Matches this project's own established rollback
-- convention of restoring the exact prior functional state, not
-- reaching further to also undo infrastructure that isn't itself
-- broken.
-- ============================================================

\set ON_ERROR_STOP on

BEGIN;

DROP FUNCTION IF EXISTS search_tasks_for_relationship(UUID, TEXT, INTEGER);

-- Reverting the forward patch's added assignee_names output column is
-- itself a return-shape change, so DROP FUNCTION is required here too.
DROP FUNCTION IF EXISTS search_tasks_for_dependency(UUID, TEXT, INTEGER);

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
    AND can_manage_task(current_task.id)
    AND can_view_task(candidate.id)
    AND can_manage_task(candidate.id)
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

DROP INDEX IF EXISTS idx_tasks_search_number_trgm;
DROP INDEX IF EXISTS idx_tasks_search_title_trgm;

CREATE INDEX IF NOT EXISTS idx_tasks_dependency_picker_number
  ON tasks(organization_id, lower(task_number) text_pattern_ops);
CREATE INDEX IF NOT EXISTS idx_tasks_dependency_picker_title
  ON tasks(organization_id, lower(title) text_pattern_ops);

COMMIT;
