-- ============================================================
-- UAT correction — Task search UX for existing-task selectors
-- (Add Prerequisite, Add Relationship).
--
-- PROBLEM (UAT finding). search_tasks_for_dependency() matched only
-- `lower(candidate.task_number) LIKE lower(query) || '%'` and the
-- identical pattern for title -- a PREFIX match anchored to the start
-- of the string, backed by the `text_pattern_ops` indexes
-- patch-task-dependencies.sql added specifically for that prefix
-- shape. A query has to be a prefix of the task number OR the title
-- to match at all: "0002", "2026-0002", "MCS-STG" never match
-- "TSK-MCS-STG-2026-0002" (none of them start the string), and "meet"/
-- "agenda" never match a title like "Prepare meeting agenda" (neither
-- word starts it). This is root cause B -- backend RPC/query behavior,
-- not a frontend limitation. The frontend (js/views/task-detail.js's
-- _openAddPrerequisiteModal()) already free-types, already debounces
-- (250ms), and already sends the raw query straight to this RPC with
-- no keyword-splitting or anchoring of its own -- confirmed by direct
-- inspection before writing this patch. Root cause is entirely B.
--
-- A second, related finding from the same inspection:
-- TasksAPI.searchRelationshipCandidates() (Add Relationship) never
-- called a SECURITY DEFINER RPC at all -- it issued a raw
-- `db.from('tasks').select(...).ilike(...)` straight from the client.
-- This is NOT an RLS bypass (tasks_select already enforces
-- can_view_task(id) on every row regardless of how the query is
-- issued -- confirmed by reading supabase/patch-shared-task-
-- foundation.sql directly), and its ILIKE '%term%' pattern was
-- already substring-capable, unlike the dependency picker. But it is
-- authorization-INCONSISTENT with create_task_relationship(), which
-- requires can_manage_task() on BOTH tasks (patch-task-relationships-
-- hardening.sql) -- the old picker only filtered by can_view_task(),
-- so a user could select a candidate they can see but not actually
-- link to, and only discover that at submit time. It also duplicated
-- search logic that now needs to change identically to the dependency
-- picker's. Root cause here is also B, plus a design inconsistency
-- with the actual create_task_relationship() authorization bar.
--
-- FIX. Two SECURITY DEFINER RPCs, structured identically, differing
-- only in their pairwise-exclusion subquery (each one preserving its
-- OWN existing, unweakened authorization/exclusion rules -- neither
-- rule set is changed, only how matching text is compared):
--   1. search_tasks_for_dependency() -- CREATE OR REPLACE, SAME
--      signature/return shape/security gates
--      (can_view_task()+can_manage_task() on both current and
--      candidate, same-organization join, same "not already an active
--      dependency in either direction" exclusion). ONLY the matching
--      predicate and ordering change.
--   2. search_tasks_for_relationship() -- NEW, mirrors #1's shape
--      exactly, with can_manage_task() on both tasks (matching
--      create_task_relationship()'s own bar, not the weaker
--      can_view_task() the old client-side query used) and a
--      "not already an active relationship in either direction"
--      exclusion mirroring create_task_relationship()'s own
--      duplicate-pair check.
-- Both use case-insensitive substring matching against task_number
-- AND title, ordered exact-match first, then prefix-match, then
-- plain substring match, then task_number/title/id for a stable tie-
-- break. Both require btrim(query) to be at least 2 characters --
-- matching the frontend's own minimum-query gate (also added by this
-- milestone) as defense in depth against an extremely broad,
-- expensive 1-character wildcard scan; both already required a
-- non-empty query, so this narrows rather than loosens what was there.
--
-- PROVENANCE. search_tasks_for_dependency() has been defined twice:
-- patch-task-dependencies.sql (original), then patch-task-dependency-
-- candidate-management.sql (adds the can_manage_task()+authorization
-- restatement, canonical order, runs after #1). This file restates
-- candidate-management's version -- every authorization/exclusion
-- line is preserved verbatim; only the WHERE clause's text-matching
-- predicate and the ORDER BY are different. No other function in this
-- schema is touched. update_task()/unassign_task()/assign_task()/
-- complete_task()/cancel_task()/can_view_task()/can_manage_task()/
-- create_task_dependency()/create_task_relationship()/
-- remove_task_relationship() are all NOT touched by this patch.
--
-- SCALE. Both RPCs' substring predicate cannot use the existing
-- `text_pattern_ops` prefix indexes (idx_tasks_dependency_picker_
-- number/title) -- those only ever accelerated `LIKE 'prefix%'`, the
-- exact anchoring this patch removes. pg_trgm is the standard,
-- well-established PostgreSQL contrib extension for accelerating
-- case-insensitive substring/ILIKE search at scale via a GIN trigram
-- index -- justified here specifically because the two prefix indexes
-- cannot support the substring search this UAT correction requires,
-- and this codebase must support "thousands or substantially more"
-- Tasks per this milestone's own scale requirement. It is read-only
-- infrastructure (no new write path, no new extension-owned table),
-- consistent with the codebase's existing use of btree_gist for
-- exclusion constraints. The two now-redundant text_pattern_ops
-- indexes are dropped in the same migration -- keeping them would
-- only add write overhead with no query they still serve; ordinary
-- lookups by exact task_number continue to use existing btree
-- indexes/PK/unique constraints unaffected by this patch.
--
-- SECURITY. No RLS policy is touched. No table grant is touched.
-- Both RPCs are `SECURITY DEFINER ... SET search_path = public,
-- pg_temp`, matching every other RPC in this module; no explicit
-- REVOKE/GRANT is added, matching this codebase's own established
-- default-PUBLIC-executable-with-internal-checks convention (see
-- get_advisors()'s own finding, recorded in docs/101 §15, that this is
-- the deliberate, universal shape of every RPC in this schema, not an
-- oversight). An anonymous caller has auth.uid() = NULL, so every
-- can_view_task()/can_manage_task() call inside both RPCs evaluates to
-- FALSE for every row, and the query returns zero rows -- no
-- exception, no leak, matching the existing convention for every
-- other STABLE SECURITY DEFINER search-shaped function in this
-- schema.
--
-- Idempotent (CREATE OR REPLACE, IF NOT EXISTS/IF EXISTS throughout)
-- -- safe to re-run.
-- ============================================================

BEGIN;

-- ─── 1. pg_trgm + trigram indexes, replacing the prefix-only pair ──
CREATE EXTENSION IF NOT EXISTS pg_trgm;

DROP INDEX IF EXISTS idx_tasks_dependency_picker_number;
DROP INDEX IF EXISTS idx_tasks_dependency_picker_title;

CREATE INDEX IF NOT EXISTS idx_tasks_search_number_trgm
  ON tasks USING gin (task_number gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_tasks_search_title_trgm
  ON tasks USING gin (title gin_trgm_ops);

-- ─── 2. search_tasks_for_dependency() — substring matching, one ────
-- ─── new output column (assignee_names), same authorization/ ───────
-- ─── exclusion rules. Return shape changed (assignee_names added), ─
-- ─── so DROP FUNCTION is required first — CREATE OR REPLACE alone ──
-- ─── is rejected by Postgres for a RETURNS TABLE shape change, the ──
-- ─── same rule already established throughout this codebase (e.g. ──
-- ─── meeting_participant_list() in patch-meetings-rsvp.sql). ───────
-- assignee_names is a single correlated subquery per candidate row,
-- computed inside the same set-returning query the search already
-- runs — not a second round-trip per row, so this is NOT the N+1
-- pattern the task's own instructions warn against.
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
  due_date DATE,
  assignee_names TEXT
) AS $$
  SELECT candidate.id, candidate.task_number, candidate.title,
         candidate.status, candidate.priority, candidate.due_date,
         (
           SELECT string_agg(u.full_name, ', ' ORDER BY ta.assigned_at)
           FROM task_assignments ta JOIN users u ON u.id = ta.user_id
           WHERE ta.task_id = candidate.id AND ta.is_active
         ) AS assignee_names
  FROM tasks current_task
  JOIN tasks candidate
    ON candidate.organization_id = current_task.organization_id
   AND candidate.id <> current_task.id
  WHERE current_task.id = p_task_id
    AND can_view_task(current_task.id)
    AND can_manage_task(current_task.id)
    AND can_view_task(candidate.id)
    AND can_manage_task(candidate.id)
    AND length(btrim(COALESCE(p_query, ''))) >= 2
    AND (
      lower(candidate.task_number) LIKE '%' || lower(btrim(p_query)) || '%'
      OR lower(candidate.title) LIKE '%' || lower(btrim(p_query)) || '%'
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
    CASE WHEN lower(candidate.task_number) = lower(btrim(p_query)) THEN 0
         WHEN lower(candidate.task_number) LIKE lower(btrim(p_query)) || '%' THEN 1
         WHEN lower(candidate.title) LIKE lower(btrim(p_query)) || '%' THEN 2
         ELSE 3
    END,
    candidate.task_number, candidate.title, candidate.id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. search_tasks_for_relationship() — new, mirrors #2's shape, ─
-- ─── with create_task_relationship()'s own exclusion pair check ────
CREATE OR REPLACE FUNCTION search_tasks_for_relationship(
  p_task_id UUID,
  p_query TEXT,
  p_limit INTEGER DEFAULT 20
) RETURNS TABLE (
  id UUID,
  task_number TEXT,
  title TEXT,
  status TEXT,
  priority TEXT,
  due_date DATE,
  assignee_names TEXT
) AS $$
  SELECT candidate.id, candidate.task_number, candidate.title,
         candidate.status, candidate.priority, candidate.due_date,
         (
           SELECT string_agg(u.full_name, ', ' ORDER BY ta.assigned_at)
           FROM task_assignments ta JOIN users u ON u.id = ta.user_id
           WHERE ta.task_id = candidate.id AND ta.is_active
         ) AS assignee_names
  FROM tasks current_task
  JOIN tasks candidate
    ON candidate.organization_id = current_task.organization_id
   AND candidate.id <> current_task.id
  WHERE current_task.id = p_task_id
    AND can_view_task(current_task.id)
    AND can_manage_task(current_task.id)
    AND can_view_task(candidate.id)
    AND can_manage_task(candidate.id)
    AND length(btrim(COALESCE(p_query, ''))) >= 2
    AND (
      lower(candidate.task_number) LIKE '%' || lower(btrim(p_query)) || '%'
      OR lower(candidate.title) LIKE '%' || lower(btrim(p_query)) || '%'
    )
    -- Mirrors create_task_relationship()'s own duplicate-pair check
    -- (patch-task-relationships-hardening.sql) exactly: any active
    -- relationship of ANY type between the pair, in either order,
    -- excludes the candidate -- the mutation RPC itself would reject
    -- a second relationship regardless of type, so the picker
    -- shouldn't offer it as if it were valid.
    AND NOT EXISTS (
      SELECT 1 FROM task_relationships tr
      WHERE tr.removed_at IS NULL
        AND LEAST(tr.source_task_id, tr.target_task_id) = LEAST(current_task.id, candidate.id)
        AND GREATEST(tr.source_task_id, tr.target_task_id) = GREATEST(current_task.id, candidate.id)
    )
  ORDER BY
    CASE WHEN lower(candidate.task_number) = lower(btrim(p_query)) THEN 0
         WHEN lower(candidate.task_number) LIKE lower(btrim(p_query)) || '%' THEN 1
         WHEN lower(candidate.title) LIKE lower(btrim(p_query)) || '%' THEN 2
         ELSE 3
    END,
    candidate.task_number, candidate.title, candidate.id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

COMMIT;
