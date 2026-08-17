-- ============================================================
-- UAT correction — Task assignee permission tightening + Draft
-- activation action (docs/107, corrected per docs/109).
--
-- PROVENANCE (corrected — see docs/109 for the full reconciliation).
-- update_task() has been redefined three times, in this exact
-- canonical order:
--   1. patch-shared-task-foundation.sql — the original, simple version.
--   2. patch-task-dependency-lifecycle-enforcement.sql (canonical order,
--      runs BEFORE this file) — adds the entire p_status = 'in_progress'
--      branch: validates the transition via
--      valid_task_status_transition(), takes an organization-scoped
--      pg_advisory_xact_lock, re-reads the row FOR UPDATE, revalidates
--      authorization and the transition under that lock, then calls
--      get_task_dependency_state(p_task_id) and rejects the call if
--      is_blocked. That file's own comment: "update_task() is the
--      repository's only start path: open/waiting -> in_progress."
--   3. This file.
-- An earlier version of this file (docs/107, commit 70fffd5) was
-- authored against file 1's body, NOT file 2's — its own
-- canonical-migration-order.txt comment incorrectly named
-- patch-shared-task-foundation.sql as the predecessor. Applying it as
-- originally written would have used CREATE OR REPLACE to silently
-- delete the entire in_progress/dependency-enforcement branch file 2
-- already shipped and already validated on staging — caught by a
-- staging pre-flight check (docs/108) before any write occurred. This
-- version is rebased onto file 2's actual body: every line of it is
-- preserved verbatim except the one authorization change described
-- below.
--
-- FINDING 1 — update_task() over-grants "manage" authority to plain
-- assignees for STRUCTURAL edits. Its authorization check (both the
-- initial one, and the revalidation under FOR UPDATE inside the
-- in_progress branch) has always included:
--
--   OR EXISTS (SELECT 1 FROM task_assignments ta WHERE ta.task_id = t.id
--              AND ta.user_id = auth.uid() AND ta.is_active)
--
-- unconditionally alongside creator/supervisor-in-scope/admin — i.e.
-- the same grant applied whether the call was changing
-- title/description/priority/section/visibility, or purely
-- transitioning status. This was a deliberate, documented decision at
-- the time (docs/47 §Permissions, T3C) -- the frontend's _canEdit()
-- was written specifically to avoid "under-mirroring", matching this
-- RPC's actual (broad) authorization exactly. Live UAT now shows the
-- real-world consequence: a plain assignee (e.g. a "Room manager"
-- assigned to a task) can redefine the task's structural fields --
-- fields the ORIGINAL creator or an in-scope manager set, not the
-- assignee's own work product.
--
-- FINDING 1b (discovered reconciling this correction against
-- patch-task-dependency-lifecycle-enforcement.sql's own pre-existing
-- regression suite, test-task-dependency-lifecycle-enforcement.sql
-- scenario 20) -- a plain assignee starting their OWN assigned task
-- (the Open -> In Progress transition specifically) is EXISTING,
-- already-shipped, already-tested backend behavior, not part of the
-- UAT finding, and explicitly called out as something this
-- reconciliation must not delete (see docs/109's own governing
-- instructions, "IMPORTANT DISCOVERY: OPEN -> IN_PROGRESS" -- "the
-- backend ALREADY supports a dependency-aware Open -> In Progress
-- transition... this checkpoint only ensures the existing backend
-- behavior is not accidentally deleted"). This mirrors
-- complete_task()'s own already-correct, already-unchanged assignee
-- grant for finishing your own assigned work -- starting it is the
-- same class of contribute-tier action, not a structural edit.
--
-- Correction (the ONE authorization change this file makes, applied
-- identically to both the initial check and the in_progress-path
-- revalidation under row lock): the unconditional assignee branch is
-- replaced with a NARROWLY-SCOPED one that only fires for a genuine,
-- unbundled start request -- p_status = 'in_progress' AND every other
-- parameter left NULL (no structural field is being changed in the
-- same call). A call that bundles a structural change with
-- p_status:='in_progress' does NOT match this narrower condition and
-- falls through to the manage-tier-only checks, exactly like any other
-- structural edit -- there is no side channel back into the removed
-- authority. Every other line -- the in_progress/advisory-lock/
-- get_task_dependency_state() enforcement, the COALESCE update, the
-- audit insert, the status/section guards -- is preserved byte-for-
-- byte from file 2. No other function changes. complete_task()/
-- assign_task()/unassign_task()/can_view_task()/create_task_dependency()/
-- get_task_dependency_state() are already correct and are NOT touched.
--
-- Out of scope, deliberately: the task-attachment RLS policy
-- (attachments_insert/attachments_delete's 'task' branch, most
-- recently restated in patch-attachments-authorization-restoration.sql)
-- mirrors the ORIGINAL, unconditional "creator OR active assignee OR
-- supervisor" shape by its own separate, explicit design (docs/48
-- §Permissions -- "losing edit access ... revokes delete on your own
-- past uploads too"). Attachments were not part of the UAT finding
-- this patch addresses, and narrowing that policy would remove an
-- assignee's ability to attach files to their own assigned work -- a
-- genuine contribute-tier capability nobody has flagged as wrong. It
-- is intentionally left unchanged; the frontend correction (js/views/
-- task-detail.js's _canManageOwnAttachments()) introduces a SEPARATE
-- predicate for it so it keeps mirroring this unchanged RLS policy
-- rather than being narrowed along with Edit.
--
-- FINDING 2 — self-unassign is deliberate, not a defect.
-- unassign_task()'s `OR p_user_id = v_actor` branch only ever lets a
-- caller remove THEIR OWN assignment (never someone else's) and
-- already writes an audit_logs row. This is architecturally distinct
-- from, and much narrower than, "an assignee can remove any
-- assignment" -- there is no evidence anywhere in this repository of a
-- broader or different intended behavior, and no existing
-- "decline/return assignment with reason" workflow to reuse. Per this
-- correction's own instruction to prefer the narrowest fix and not
-- invent new workflows, this is NOT changed here.
--
-- FINDING 3 — no "task_access_level()"/"assign_task_user()"/
-- "revoke_task_assignment()"/"set_task_dates()" function exists
-- anywhere in this schema, and task_assignments has no
-- "assignment_role" column (only one undifferentiated assignee role
-- exists structurally) -- confirmed by direct search of every
-- supabase/*.sql file. Reviewer/Approver personas and a "Request
-- Review" action have no backing capability in the current
-- architecture and are correctly out of scope for this correction.
--
-- FINDING 4 — Draft -> Open activation gap. create_task() always
-- starts a task at status = 'draft'. valid_task_status_transition()
-- already permits ('draft','open'), and update_task()'s own status
-- guard only blocks setting 'completed'/'cancelled' directly (those
-- require complete_task()/cancel_task()) -- 'open' was never blocked.
-- Draft -> Open remains MANAGE-TIER ONLY (the narrow assignee
-- exception above only ever matches p_status = 'in_progress', never
-- 'open') -- docs/107's persona matrix explicitly lists "manage-tier
-- Start Task" as something an assignee must not gain, and this
-- correction preserves that. docs/47 itself already names the
-- Draft->Open gap under "Known limitations"/"Future enhancements":
-- T3C's own scope was Complete/Cancel only, and other transitions the
-- same allow-list permits were "intentionally not exposed ... though
-- nothing about the backend prevents adding them in a future,
-- separately-scoped milestone." No backend change is needed to close
-- it -- update_task() already supports the transition for the manage
-- tier; only a frontend "Start Task" action (creator/supervisor/admin
-- only) is added, calling update_task() exactly as it already exists.
-- Open -> in_progress itself already has full backend support
-- including dependency blocking (file 2, preserved here, now correctly
-- available to the assignee too for a pure transition) -- no frontend
-- action for THAT transition is added by this milestone; it is
-- evaluated separately during UAT. See docs/107/docs/109.
--
-- Idempotent (CREATE OR REPLACE) -- safe to run more than once.
-- ============================================================

BEGIN;

-- Byte-for-byte identical to patch-task-dependency-lifecycle-
-- enforcement.sql's update_task() except: the unconditional
-- active-assignee authorization branch is replaced, in both the
-- initial check and the in_progress-path revalidation under row lock,
-- with one that only matches a genuine, unbundled Open -> In Progress
-- start request. Nothing else differs.
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
  -- v_is_pure_start_request above and this file's header comment for
  -- why this is narrower than the branch that previously lived here).
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
  VALUES (v_actor, 'edited', 'task', p_task_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMIT;
