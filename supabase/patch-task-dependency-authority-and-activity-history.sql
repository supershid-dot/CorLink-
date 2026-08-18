-- ============================================================
-- CorLink — UAT correction: Task dependency structural authority
-- + human-readable Activity history (docs/113)
--
-- Apply after patch-task-search-and-linking-candidates.sql (the last
-- Task UAT correction). Idempotent (CREATE OR REPLACE / DROP+CREATE
-- INDEX IF NOT EXISTS / DROP+ADD CONSTRAINT) — safe to run more than
-- once.
--
-- ISSUE A — DEPENDENCY AUTHORITY (live UAT finding)
-- --------------------------------------------------------------
-- Root cause: can_manage_task() (patch-request-task-integration.sql)
-- is TRUE for the active assignee of a task (by design — it is the
-- single predicate update_task()/assign_task()/complete_task() all
-- reuse for ordinary task management). create_task_dependency(),
-- remove_task_dependency(), get_task_dependency_capabilities(), and
-- list_task_dependencies()'s can_remove column all gate on
-- can_manage_task() for both dependency endpoints — so an assignee
-- (with no other manage-tier standing) already sees, and can invoke,
-- Add Prerequisite / Remove Dependency. This is entirely a BACKEND
-- defect (root cause B): the frontend (js/views/task-detail.js)
-- already renders those two controls purely from
-- _dependencyCapabilities.can_add_dependency /
-- can_remove_dependency + per-row can_remove, exactly as it should —
-- once the RPCs return the right capability, the frontend needs no
-- change at all.
--
-- Fix: can_manage_task_dependency() is the same predicate as
-- can_manage_task() with the active-assignee OR-branch removed —
-- creator / supervisor-in-scope / super-admin only. Every one of the
-- four dependency functions above is restated from its own true
-- current predecessor (see each block below) with can_manage_task()
-- swapped for can_manage_task_dependency() at the exact call sites
-- that gate dependency ADD/REMOVE. No other authorization in these
-- functions changes. Start Work / complete eligibility
-- (get_task_dependency_lifecycle_state(), patch-task-dependency-
-- lifecycle-enforcement.sql) deliberately keeps can_manage_task() —
-- an assignee legitimately starting/completing their own work is not
-- a structural dependency change and is out of scope for this
-- correction.
--
-- ISSUE B — ACTIVITY HISTORY (live UAT finding)
-- --------------------------------------------------------------
-- Root cause: update_task() is the only path for both Draft -> Open
-- and Open -> In Progress, and always writes the single generic
-- 'edited' audit action regardless of what changed — rendered by
-- task-detail.js's _auditEvent() as "Updated task details" even for a
-- lifecycle transition. Separately, create_task_dependency() /
-- remove_task_dependency() already write 'task_dependency_added' /
-- 'task_dependency_removed' audit rows, but with record_type =
-- 'task_dependency' and record_id = the dependency row's own id — not
-- record_type = 'task' / record_id = the dependent task's id, which
-- is what TasksAPI.fetchTaskAuditTrail() actually queries
-- (.eq('record_type','task').eq('record_id', taskId)). So dependency
-- add/remove currently renders NOTHING on the task's own Activity
-- timeline at all — a bigger gap than the "generic wording" framing,
-- caught by inspection per Step 4's "do not assume" instruction.
--
-- Fix:
--   1. update_task() detects exactly two transitions before writing
--      its audit row: draft -> open now writes 'task_started', open
--      or waiting -> in_progress now writes 'task_work_started'. Any
--      other update (title/description/priority/etc, or a status
--      change other than those two) keeps writing 'edited' — the
--      instructing prompt explicitly allows this fallback ("Updated
--      task details is acceptable only if the system cannot provide
--      more specific information cheaply"); no deep-diff field
--      comparison is added, staying inside this milestone's scope.
--   2. create_task_dependency() / remove_task_dependency() ADD a
--      second audit_logs row — record_type = 'task', record_id = the
--      dependent task's id, action reusing the existing
--      'task_dependency_added' / 'task_dependency_removed' codes —
--      alongside the existing record_type = 'task_dependency' row
--      (left untouched; nothing currently consumes it, so it is kept
--      rather than removed, avoiding any behavior change beyond this
--      fix's scope). notes stores only 'related_task_id=<uuid>', not
--      the other task's title/number — see SECURITY below for why.
--   3. assign_task() / unassign_task() keep their existing 'assigned'
--      / 'unassigned' action codes (already in audit_logs_action_check
--      and already mapped by the frontend) but now write the target
--      user's full_name into notes (one indexed users.id primary-key
--      lookup — not a deep diff) instead of a raw UUID, so the
--      timeline can say "assigned Room manager" / "removed Room
--      manager from the task" without any extra frontend query.
--
-- Historical rows are never rewritten (see rollback file and docs/113
-- for the audit-immutability discussion) — old 'edited' rows for past
-- Draft->Open/Open->In Progress transitions keep rendering as
-- "Updated task details" going forward; only new rows get the
-- specific wording.
--
-- Explicitly OUT OF SCOPE for this milestone (documented as a
-- remaining limitation in docs/113, not implemented here): Task
-- relationship activity (create_task_relationship() /
-- remove_task_relationship() have the identical record_type mismatch
-- as dependencies did, but relationships were not part of either live
-- UAT finding and Section 3's product decision explicitly leaves
-- relationship authorization untouched — "manage task relationships
-- according to existing rules"); task_watchers activity (watch_task()
-- / unwatch_task() write no audit row at all today); and per-field
-- priority/due-date diff wording (Section 12 of the correction
-- explicitly permits the generic fallback). None of these were live
-- UAT defects; adding them now would be exactly the "unrelated
-- improvement" this correction is told not to make.
--
-- SECURITY
-- --------------------------------------------------------------
-- The new record_type='task' dependency-activity rows are read
-- through the SAME audit_select_own_records -> can_view_case_audit_
-- record(record_type, record_id) RLS path every other 'task' audit
-- row already uses (patch-task-audit-visibility.sql's
-- record_type = 'task' branch, unchanged) — the row itself is only
-- visible to someone who can already view the dependent task. The
-- *other* task's title/number is deliberately NOT baked into `notes`
-- at write time: only its bare id is stored
-- ('related_task_id=<uuid>'). Baking the title in at write time would
-- let it survive in the audit trail even if that task's visibility to
-- this viewer changed later — the exact leak Section 16 forbids.
-- Instead, the frontend batch-resolves any related_task_id values
-- through a single `SELECT id, task_number, title FROM tasks WHERE id
-- = ANY(...)` — the ordinary tasks_select RLS policy
-- (can_view_task(id)) already filters that query with no new
-- predicate needed, so an unauthorized related task is simply absent
-- from the result and the timeline falls back to safe generic
-- wording ("added a prerequisite task"). One batched query per
-- Activity panel load, not one per row — no N+1.
--
-- can_manage_task_dependency() is STABLE SECURITY DEFINER with a
-- pinned search_path, identical convention to every other helper in
-- this codebase; no RLS policy changes; no new GRANT/REVOKE surface
-- beyond the functions already granted to `authenticated` (this file
-- changes no grants — every function it restates already carries its
-- correct grant from its own predecessor file).
-- ============================================================

\set ON_ERROR_STOP on

BEGIN;

-- ─── 1. Dependency structural-authority predicate ──────────────────
-- Exact copy of can_manage_task() (patch-request-task-integration.sql)
-- with the active-assignee OR-branch removed. Creator / supervisor-
-- in-scope / super-admin only — an assignee no longer qualifies
-- merely by virtue of being assigned.
CREATE OR REPLACE FUNCTION can_manage_task_dependency(p_task_id UUID)
RETURNS BOOLEAN AS $$
  SELECT is_super_admin() OR EXISTS (
    SELECT 1 FROM tasks t
    WHERE t.id = p_task_id
      AND t.organization_id = get_my_org_id()
      AND (
        t.created_by = auth.uid()
        OR (is_supervisor_or_above() AND (t.owning_section_id IS NULL OR t.owning_section_id IN (SELECT my_section_ids())))
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION can_manage_task_dependency(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION can_manage_task_dependency(UUID) TO authenticated;

-- ─── 2. create_task_dependency() ────────────────────────────────────
-- True current predecessor: patch-task-dependency-lifecycle-
-- enforcement.sql (the only later restatement; adds the post-lock
-- revalidation this version preserves verbatim). Only change: both
-- can_manage_task(...) dependency-endpoint gates become
-- can_manage_task_dependency(...); plus one new audit_logs row so the
-- add is visible on the dependent task's own Activity timeline.
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
  IF NOT can_manage_task_dependency(p_dependent_task_id)
     OR NOT can_manage_task_dependency(p_prerequisite_task_id) THEN
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
  IF NOT can_manage_task_dependency(p_dependent_task_id)
     OR NOT can_manage_task_dependency(p_prerequisite_task_id) THEN
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

  -- Second row so this shows on the dependent task's own Activity
  -- timeline (fetchTaskAuditTrail() queries record_type='task'). Only
  -- the prerequisite's bare id is stored — see this file's SECURITY
  -- header comment for why the title/number is resolved at render
  -- time, not baked in here.
  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (
    v_actor, 'task_dependency_added', 'task', v_dependent.id,
    'related_task_id=' || v_prerequisite.id
  );

  RETURN v_dependency;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'An active dependency already exists between these tasks';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. remove_task_dependency() ────────────────────────────────────
-- True current predecessor: patch-task-dependencies.sql (only ever
-- defined there). Only change: the can_manage_task(...) endpoint gate
-- becomes can_manage_task_dependency(...); plus one new audit_logs row
-- (same rationale as create_task_dependency() above).
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
  IF NOT can_manage_task_dependency(v_dependency.dependent_task_id)
     OR NOT can_manage_task_dependency(v_dependency.prerequisite_task_id) THEN
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

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (
    v_actor, 'task_dependency_removed', 'task', v_dependency.dependent_task_id,
    'related_task_id=' || v_dependency.prerequisite_task_id
  );

  RETURN v_dependency;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. list_task_dependencies() ────────────────────────────────────
-- True current predecessor: patch-task-dependencies.sql (only ever
-- defined there). Only change: the can_remove column's two
-- can_manage_task(...) calls become can_manage_task_dependency(...).
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
    can_manage_task_dependency(td.dependent_task_id)
      AND can_manage_task_dependency(td.prerequisite_task_id)
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

-- ─── 5. get_task_dependency_capabilities() ──────────────────────────
-- True current predecessor: patch-task-dependencies.sql (only ever
-- defined there). Only change: can_manage_task(p_task_id) becomes
-- can_manage_task_dependency(p_task_id) for both add/remove columns.
CREATE OR REPLACE FUNCTION get_task_dependency_capabilities(p_task_id UUID)
RETURNS TABLE (
  can_view_dependencies BOOLEAN,
  can_add_dependency BOOLEAN,
  can_remove_dependency BOOLEAN
) AS $$
  SELECT
    can_view_task(p_task_id),
    can_view_task(p_task_id) AND can_manage_task_dependency(p_task_id),
    can_view_task(p_task_id) AND can_manage_task_dependency(p_task_id);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 6. update_task() — distinct lifecycle-transition actions ──────
-- True current predecessor: patch-task-assignee-permission-and-
-- activation-fix.sql (docs/109/110) — NOT patch-task-dependency-
-- lifecycle-enforcement.sql. Confirmed directly against live staging
-- (vjobntuyzymhcuanyeak) before writing this, per this program's
-- standing "stale baseline" rule: that later file narrowed general
-- update_task() authorization to manage-tier only, carving out
-- v_is_pure_start_request as the one exception letting a plain active
-- assignee call update_task() at all (a bundled { status: 'in_progress',
-- ...anything else } request does NOT qualify — see its own inline
-- comment). This version preserves v_is_pure_start_request and both
-- authorization blocks verbatim. Only change: v_action is computed
-- from the OLD status (already fetched into v_task before the UPDATE)
-- and the requested p_status, used in place of the hardcoded 'edited'
-- literal in the final audit insert.
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
  v_action TEXT := 'edited';
  -- True only for a pure "start my own assigned task" call: p_status
  -- is exactly 'in_progress' and no other field is being changed in
  -- the same call. Computed once and reused by both authorization
  -- checks below so a call cannot slip a structural edit through by
  -- bundling it with a status change -- the assignee branch never
  -- fires unless every other parameter is NULL.
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

  -- Manage-tier (creator / in-scope supervisor / admin) for anything
  -- structural, matching cancel_task()'s exact shape -- OR an active
  -- assignee, but ONLY for a pure, unbundled start request (see
  -- v_is_pure_start_request above and patch-task-assignee-permission-
  -- and-activation-fix.sql's header comment for why this is narrower
  -- than the branch that previously lived here).
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

  -- Draft -> Open and Open/Waiting -> In Progress are the two
  -- lifecycle transitions the UAT correction requires distinct
  -- wording for. Anything else (a details-only edit, or a status
  -- change other than these two) keeps the generic 'edited' action —
  -- update_task() has no other status-transition path today.
  IF p_status = 'open' AND v_task.status = 'draft' THEN
    v_action := 'task_started';
  ELSIF p_status = 'in_progress' AND v_task.status IN ('open', 'waiting') THEN
    v_action := 'task_work_started';
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

    -- Revalidate after any graph-lock or row-lock wait. Same correction
    -- as the initial check above -- manage-tier, or an active assignee
    -- for a pure start request only.
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
  VALUES (v_actor, v_action, 'task', p_task_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 7. assign_task() — name the assignee in the audit trail ───────
-- True current predecessor: patch-notification-module-integration-
-- foundation.sql (the only later restatement; adds the CAP-003
-- outbox enqueue this version preserves verbatim). Only change: notes
-- stores the target user's full_name instead of their raw UUID.
CREATE OR REPLACE FUNCTION assign_task(p_task_id UUID, p_user_id UUID)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
  v_assignment_id UUID;
  v_outbox_event_id UUID;
  v_target_name TEXT;
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

  SELECT full_name INTO v_target_name
  FROM users WHERE id = p_user_id AND org_id = v_task.organization_id AND is_active = TRUE;
  IF v_target_name IS NULL THEN
    RAISE EXCEPTION 'Assignee must be an active user in the task''s organization';
  END IF;

  INSERT INTO task_assignments (task_id, user_id, assigned_by, assigned_at, is_active)
  VALUES (p_task_id, p_user_id, v_actor, NOW(), TRUE)
  ON CONFLICT (task_id, user_id) WHERE is_active DO NOTHING
  RETURNING id INTO v_assignment_id;

  IF v_assignment_id IS NULL THEN
    RETURN; -- already actively assigned; idempotent no-op
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'assigned', 'task', p_task_id, v_target_name);

  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  VALUES (p_user_id, 'task_assigned', 'task', p_task_id,
          'You were assigned to task "' || v_task.title || '"');

  -- CAP-003 Phase 1.4: atomic outbox enqueue, same transaction as the
  -- domain mutation above. p_target_user_ids is a single-element array
  -- since specific_users' target-shape CHECK requires the array form
  -- even for one recipient.
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

-- ─── 8. unassign_task() — name the (former) assignee ────────────────
-- True current predecessor: patch-task-start-work-and-assignment-
-- accountability.sql (removed the self-unassign branch; this version
-- preserves that verbatim). Only change: notes stores the target
-- user's full_name instead of their raw UUID.
CREATE OR REPLACE FUNCTION unassign_task(p_task_id UUID, p_user_id UUID)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
  v_rows INTEGER;
  v_target_name TEXT;
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

  SELECT full_name INTO v_target_name FROM users WHERE id = p_user_id;

  UPDATE task_assignments
  SET is_active = FALSE, unassigned_at = NOW()
  WHERE task_id = p_task_id AND user_id = p_user_id AND is_active = TRUE;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RETURN; -- nothing active to unassign; idempotent no-op
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'unassigned', 'task', p_task_id, COALESCE(v_target_name, 'a user'));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 9. Audit action vocabulary ─────────────────────────────────────
-- True current latest predecessor: patch-task-dependencies.sql (the
-- last file in canonical order to touch audit_logs_action_check —
-- confirmed by inspecting every file that ALTERs this constraint and
-- cross-referencing canonical-migration-order.txt positions). Adds
-- exactly the two new codes this file's update_task() now writes;
-- every previously-allowed value is preserved verbatim.
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
    'task_dependency_added', 'task_dependency_removed', 'task_dependency_waived',
    'task_started', 'task_work_started'
  ));

COMMIT;
