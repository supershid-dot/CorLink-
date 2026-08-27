-- ============================================================
-- CorLink — UAT correction: Task relationship structural authority
-- + human-readable Activity history (docs/114)
--
-- Apply after patch-task-dependency-authority-and-activity-history.sql
-- (the immediately preceding Task UAT correction). Idempotent
-- (CREATE OR REPLACE / DROP+ADD CONSTRAINT) — safe to run more than
-- once.
--
-- ISSUE — RELATIONSHIP AUTHORITY (live UAT finding)
-- --------------------------------------------------------------
-- Root cause: identical shape to the prior Task Dependency UAT
-- correction (docs/113). can_manage_task() (patch-request-task-
-- integration.sql) is TRUE for a task's active assignee by design.
-- create_task_relationship(), remove_task_relationship(),
-- list_related_tasks()'s can_remove column, and get_task_relationship_
-- capabilities() all gated on can_manage_task() for both endpoint
-- tasks — so an assignee with no other manage-tier standing already
-- had, and could exercise, Add/Remove Relationship. Root cause B
-- (backend). The frontend (js/views/task-detail.js) already renders
-- both controls purely from _relationshipCapabilities.can_create /
-- per-row can_remove — once the RPCs return the right capability, no
-- frontend authorization change is needed at all (only the Activity
-- wording extension below touches the frontend).
--
-- Fix: can_manage_task_relationship() is a new helper — NOT a reuse
-- of docs/113's can_manage_task_dependency(), and NOT a rename of it
-- either. Both would have required touching already-UAT-passed
-- Dependency code, which this milestone's own instructions (Step 21)
-- explicitly forbid absent a regression-verification need that
-- doesn't exist here. can_manage_task_relationship() is therefore a
-- deliberate, explicitly-authorized twin (Step 5's own suggested
-- name) with the identical body: creator / supervisor-in-scope /
-- super-admin only, no active-assignee branch. Every dependency
-- function this milestone does not touch remains byte-for-byte as
-- docs/113 left it.
--
-- ISSUE — ACTIVITY HISTORY (identified during inspection; a prior
-- checkpoint had already flagged the gap)
-- --------------------------------------------------------------
-- Root cause: create_task_relationship()/remove_task_relationship()
-- already wrote 'task_linked'/'task_unlinked' audit rows, but with
-- record_type = 'task_relationship' and record_id = the relationship
-- row's own id — not record_type = 'task' / record_id = a task's id,
-- which is what TasksAPI.fetchTaskAuditTrail() actually queries. So
-- relationship add/remove rendered NOTHING on either task's own
-- Activity timeline — the exact same defect shape docs/113 found and
-- fixed for dependencies.
--
-- Fix:
--   1. create_task_relationship() ADDS a second audit_logs row —
--      record_type = 'task', record_id = the ORIGINAL p_source_task_id
--      (the task the caller was viewing when they clicked Add
--      Relationship — NOT the LEAST/GREATEST-canonicalized storage
--      source, which has no relation to "who initiated this" for the
--      symmetric related/duplicate types) — action = new code
--      'task_relationship_added'. notes stores 'related_task_id=<uuid>
--      ;relationship_type=<related|duplicate|child>' — for 'parent'
--      type the viewer (source) is always the parent by this
--      function's own unchanged direction rule, so the OTHER task's
--      role from the viewer's perspective is 'child' (the exact same
--      synthetic label list_related_tasks() already computes for
--      display — not a new stored relationship_type, only a notes
--      label). "Inspect actual directionality" (Step 14) is satisfied
--      by this, not by copying the prompt's illustrative wording
--      verbatim regardless of which side initiated.
--   2. remove_task_relationship() gains a new optional parameter,
--      p_viewer_task_id UUID DEFAULT NULL, so the new record_type=
--      'task' audit row (below) can be attached to whichever side the
--      caller was actually viewing when they clicked Remove
--      Relationship (falling back to the relationship's stored source
--      side if omitted or invalid). Adding a parameter changes this
--      function's argument-type identity even with a DEFAULT, so the
--      old single-argument overload is explicitly DROPped first (see
--      block 3 below) rather than left stranded alongside the new
--      one with its un-narrowed authorization — the frontend
--      (js/data/tasks-api.js, js/views/task-detail.js) is updated in
--      the same commit to always pass both arguments. notes stores
--      only 'related_task_id=<uuid>' — removal
--      wording is type-agnostic ("removed the relationship with
--      {task}"), matching the correction's own example.
--   3. Existing 'task_linked'/'task_unlinked' record_type='task_
--      relationship' rows are left untouched (same "don't touch what
--      nothing else consumes" call docs/113 made for dependencies).
--
-- Historical rows are never rewritten. Old relationship mutations
-- before this patch simply have no Activity-timeline row (same as
-- today) — not retroactively fabricated.
--
-- Explicitly OUT OF SCOPE for this milestone: search_tasks_for_
-- relationship()'s own candidate-search authorization (still
-- can_manage_task()-gated) is untouched. It is unreachable by a
-- non-manage-tier user through the UI (the Add Relationship button
-- that opens that search is already omitted per §authority above),
-- and Section 9's "do not restate unrelated functions" instruction
-- applies — this was not a live UAT finding. Also untouched, per
-- Step 21: every Task Dependency function docs/113 already fixed.
--
-- SECURITY
-- --------------------------------------------------------------
-- Same design as docs/113: the new record_type='task' rows are read
-- through the existing audit_select_own_records -> can_view_case_
-- audit_record('task', record_id) RLS path, unchanged — visible only
-- to someone who can already view that task. The other task's title/
-- number is never baked into `notes` — only its bare id — so
-- visibility is re-evaluated at render time via the frontend's
-- existing RLS-filtered TasksAPI.fetchTasksByIds() batch call (built
-- for docs/113, reused here unchanged). An unauthorized related task
-- is simply absent from that result; the timeline falls back to safe
-- generic wording. No RLS policy changes; no new grants beyond
-- can_manage_task_relationship()'s own GRANT EXECUTE TO authenticated.
-- ============================================================

\set ON_ERROR_STOP on

BEGIN;

-- ─── 1. Relationship structural-authority predicate ────────────────
-- Deliberate twin of can_manage_task_dependency() (docs/113) — see
-- this file's header comment for why it is not a reuse/rename of
-- that function. Creator / supervisor-in-scope / super-admin only.
CREATE OR REPLACE FUNCTION can_manage_task_relationship(p_task_id UUID)
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

REVOKE ALL ON FUNCTION can_manage_task_relationship(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION can_manage_task_relationship(UUID) TO authenticated;

-- ─── 2. create_task_relationship() ──────────────────────────────────
-- True current predecessor: patch-task-relationships-hardening.sql
-- (the only later restatement of patch-task-relationships.sql's
-- original; confirmed against live staging before writing this).
-- Only change: both can_manage_task(...) gates become
-- can_manage_task_relationship(...); plus one new audit_logs row so
-- the add is visible on the initiating task's own Activity timeline.
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
  IF NOT can_manage_task_relationship(p_source_task_id) OR NOT can_manage_task_relationship(p_target_task_id) THEN
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

  -- Second row so this shows on the initiating task's own Activity
  -- timeline. Uses the ORIGINAL p_source_task_id (the task the caller
  -- was viewing), not v_source (which, for related/duplicate, is
  -- LEAST/GREATEST-canonicalized and unrelated to who initiated this).
  -- relationship_type in notes is the OTHER task's role from the
  -- viewer's perspective: unchanged for related/duplicate (symmetric),
  -- 'child' for parent (this function's own unchanged direction rule
  -- means p_source_task_id is always the parent, so p_target_task_id
  -- is always the child) -- the exact synthetic label list_related_
  -- tasks() already computes for display, not a new stored type.
  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (
    v_actor, 'task_relationship_added', 'task', p_source_task_id,
    'related_task_id=' || p_target_task_id || ';relationship_type=' ||
    (CASE WHEN p_relationship_type = 'parent' THEN 'child' ELSE p_relationship_type END)
  );

  RETURN v_relationship_id;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'An active relationship already exists between these tasks';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. remove_task_relationship() ──────────────────────────────────
-- True current predecessor: patch-task-relationships-hardening.sql
-- (only later restatement). Changes: the can_manage_task(...) gate
-- becomes can_manage_task_relationship(...); a new optional
-- p_viewer_task_id parameter lets the caller say which side's
-- timeline the removal should appear on; plus one new audit_logs row.
--
-- Adding a parameter changes this function's argument-type identity
-- (uuid) -> (uuid, uuid) even with a DEFAULT — CREATE OR REPLACE only
-- replaces a function whose full argument-type list already matches,
-- so without this DROP the OLD single-argument overload would remain
-- live (and un-narrowed: still can_manage_task()-gated) alongside the
-- new one, exploitable by any caller still invoking it with one
-- argument. Same "stale second overload" trap as this program's
-- established DROP-before-CREATE-OR-REPLACE rule for return-shape
-- changes, applied here to a parameter-list change instead.
DROP FUNCTION IF EXISTS remove_task_relationship(UUID);

CREATE OR REPLACE FUNCTION remove_task_relationship(
  p_relationship_id UUID,
  p_viewer_task_id UUID DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_relationship task_relationships;
  v_viewer UUID;
  v_other UUID;
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
  IF NOT can_manage_task_relationship(v_relationship.source_task_id)
     OR NOT can_manage_task_relationship(v_relationship.target_task_id) THEN
    RAISE EXCEPTION 'Not authorized to remove this task relationship';
  END IF;
  UPDATE task_relationships SET removed_at = NOW(), removed_by = v_actor
  WHERE id = p_relationship_id AND removed_at IS NULL;
  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_unlinked', 'task_relationship', p_relationship_id,
          'type=' || v_relationship.relationship_type);

  -- Second row so this shows on a task's own Activity timeline.
  -- Attaches to whichever endpoint the caller says it was viewing
  -- (p_viewer_task_id must be one of the two endpoints; anything else
  -- -- including NULL from an older caller -- falls back to the
  -- relationship's stored source side).
  v_viewer := CASE WHEN p_viewer_task_id IN (v_relationship.source_task_id, v_relationship.target_task_id)
                THEN p_viewer_task_id ELSE v_relationship.source_task_id END;
  v_other := CASE WHEN v_viewer = v_relationship.source_task_id
               THEN v_relationship.target_task_id ELSE v_relationship.source_task_id END;
  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_relationship_removed', 'task', v_viewer, 'related_task_id=' || v_other);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. list_related_tasks() ────────────────────────────────────────
-- True current predecessor: patch-task-relationships-hardening.sql
-- (only later restatement). Only change: the can_remove column's two
-- can_manage_task(...) calls become can_manage_task_relationship(...).
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
    can_manage_task_relationship(tr.source_task_id) AND can_manage_task_relationship(tr.target_task_id)
  FROM task_relationships tr
  JOIN tasks related ON related.id = CASE WHEN tr.source_task_id = p_task_id THEN tr.target_task_id ELSE tr.source_task_id END
  WHERE tr.removed_at IS NULL
    AND p_task_id IN (tr.source_task_id, tr.target_task_id)
    AND can_view_task(tr.source_task_id)
    AND can_view_task(tr.target_task_id)
  ORDER BY tr.created_at DESC;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 5. get_task_relationship_capabilities() ────────────────────────
-- True current predecessor: patch-task-relationships.sql (never
-- restated since — confirmed by grep across every patch file and
-- against live staging). Only change: can_manage_task(p_task_id)
-- becomes can_manage_task_relationship(p_task_id) for both columns.
CREATE OR REPLACE FUNCTION get_task_relationship_capabilities(p_task_id UUID)
RETURNS TABLE (can_create BOOLEAN, can_remove BOOLEAN) AS $$
  SELECT
    can_view_task(p_task_id) AND can_manage_task_relationship(p_task_id),
    can_view_task(p_task_id) AND can_manage_task_relationship(p_task_id);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- Signature changed (new trailing DEFAULT parameter) — grant must be
-- re-stated for the new overload signature Postgres now resolves to;
-- the old single-argument call shape still resolves to this same
-- function via the DEFAULT.
REVOKE ALL ON FUNCTION remove_task_relationship(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION remove_task_relationship(UUID, UUID) TO authenticated;

-- ─── 6. Audit action vocabulary ─────────────────────────────────────
-- True current latest predecessor: patch-task-dependency-authority-
-- and-activity-history.sql (docs/113) — the most recent file to touch
-- audit_logs_action_check, adding 'task_started'/'task_work_started'.
-- Confirmed by re-checking every ALTER of this constraint against
-- canonical-migration-order.txt positions; nothing between that file
-- and this one touches it. Adds exactly the two new codes this file's
-- functions now write; every previously-allowed value (including
-- docs/113's two) is preserved verbatim.
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
    'task_started', 'task_work_started',
    'task_relationship_added', 'task_relationship_removed'
  ));

COMMIT;
