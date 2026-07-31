-- ============================================================
-- CorLink — Shared Task Foundation
--
-- Creates the core Task engine as an independent business object:
-- tasks, task_assignments, task_watchers, task_comments, and a
-- task_number_sequences numbering table, plus the foundation RPCs
-- that create/mutate them, RLS, audit integration, and notification
-- type registration.
--
-- A task may later be linked to a Request, Meeting, Entry, Internal
-- Collaboration case, or Prisoner Letter — or to nothing at all. This
-- patch deliberately does NOT create task_links or any module-specific
-- RPC/UI; those are separate milestones layered on top of this
-- foundation. Task lifecycle here never depends on, or references,
-- any parent module.
--
-- Mutation model follows the Rooms/Meetings precedent (see
-- patch-rooms-booking-foundation.sql): tasks/task_assignments/
-- task_watchers/task_comments get SELECT-only RLS policies (via the
-- shared can_view_task() helper below, same pattern as
-- can_view_request_or_response()/can_view_case_audit_record()); every
-- INSERT/UPDATE/DELETE goes exclusively through the SECURITY DEFINER
-- RPCs in this file, which re-derive authorization from auth.uid()
-- and never accept a client-supplied actor identity.
--
-- get_task() and list_tasks() are the exception: they are plain
-- SECURITY INVOKER functions with no elevated privilege of their own,
-- so ordinary SELECT-RLS on `tasks` (via can_view_task()) filters
-- their results automatically — this avoids re-implementing the same
-- visibility predicate a second time inside those two functions.
--
-- Idempotent — safe to run more than once.
-- ============================================================

BEGIN;

-- ─── 1. Numbering ──────────────────────────────────────────────
-- Same shape as entry_reference_sequences (schema.sql) — org+year,
-- generated at creation time. Locking comes from the single atomic
-- INSERT ... ON CONFLICT ... RETURNING statement, same as every other
-- numbering sequence in this codebase; no explicit FOR UPDATE needed.
CREATE TABLE IF NOT EXISTS task_number_sequences (
  org_id        UUID    NOT NULL REFERENCES organizations(id),
  year          INTEGER NOT NULL,
  next_sequence INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (org_id, year)
);

CREATE OR REPLACE FUNCTION generate_task_number(p_org_id UUID)
RETURNS TEXT AS $$
DECLARE
  v_year INTEGER := EXTRACT(YEAR FROM NOW());
  v_seq  INTEGER;
  v_code TEXT;
BEGIN
  INSERT INTO task_number_sequences (org_id, year, next_sequence)
  VALUES (p_org_id, v_year, 2)
  ON CONFLICT (org_id, year)
  DO UPDATE SET next_sequence = task_number_sequences.next_sequence + 1
  RETURNING next_sequence - 1 INTO v_seq;

  SELECT code INTO v_code FROM organizations WHERE id = p_org_id;
  RETURN 'TSK-' || COALESCE(v_code, 'ORG') || '-' || v_year || '-' || LPAD(v_seq::TEXT, 4, '0');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 2. Core tables ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tasks (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  task_number       TEXT        NOT NULL,
  title             TEXT        NOT NULL CHECK (btrim(title) <> ''),
  description       TEXT,
  status            TEXT        NOT NULL DEFAULT 'draft' CHECK (status IN (
                       'draft', 'open', 'in_progress', 'waiting', 'completed', 'cancelled'
                     )),
  priority          TEXT        NOT NULL DEFAULT 'normal' CHECK (priority IN (
                       'low', 'normal', 'high', 'critical'
                     )),
  due_date          DATE,
  start_date        DATE,
  completed_at      TIMESTAMPTZ,
  completed_by      UUID        REFERENCES users(id),
  created_by        UUID        NOT NULL REFERENCES users(id),
  organization_id   UUID        NOT NULL REFERENCES organizations(id),
  owning_section_id UUID        REFERENCES sections(id),
  visibility        TEXT        NOT NULL DEFAULT 'section' CHECK (visibility IN (
                       'private', 'section', 'organization'
                     )),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, task_number)
);

CREATE INDEX IF NOT EXISTS idx_tasks_org ON tasks(organization_id);
CREATE INDEX IF NOT EXISTS idx_tasks_section ON tasks(owning_section_id);
CREATE INDEX IF NOT EXISTS idx_tasks_created_by ON tasks(created_by);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_due_date ON tasks(due_date);

DROP TRIGGER IF EXISTS set_updated_at ON tasks;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON tasks
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- Server-enforced lifecycle — same defense-in-depth pattern as
-- valid_request_status_transition()/trigger_check_request_status()
-- (schema.sql): the RPCs below decide WHEN to transition a task, this
-- trigger independently vetoes any transition not on the allow-list,
-- regardless of which code path attempted it.
CREATE OR REPLACE FUNCTION valid_task_status_transition(old_status TEXT, new_status TEXT)
RETURNS BOOLEAN AS $$
  SELECT old_status = new_status OR (old_status, new_status) IN (
    ('draft', 'open'),
    ('draft', 'cancelled'),
    ('open', 'in_progress'),
    ('open', 'waiting'),
    ('open', 'cancelled'),
    ('in_progress', 'waiting'),
    ('in_progress', 'completed'),
    ('in_progress', 'cancelled'),
    ('waiting', 'in_progress'),
    ('waiting', 'completed'),
    ('waiting', 'cancelled')
  );
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION trigger_check_task_status()
RETURNS TRIGGER AS $$
BEGIN
  IF NOT valid_task_status_transition(OLD.status, NEW.status) THEN
    RAISE EXCEPTION 'Invalid task status transition: % -> %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS task_status_transition ON tasks;
CREATE TRIGGER task_status_transition
  BEFORE UPDATE OF status ON tasks
  FOR EACH ROW EXECUTE FUNCTION trigger_check_task_status();

-- Multiple assignees; at most one ACTIVE assignment per (task, user)
-- enforced by a partial unique index, not a plain UNIQUE, so a user
-- can be unassigned and later reassigned without deleting history.
CREATE TABLE IF NOT EXISTS task_assignments (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id       UUID        NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  user_id       UUID        NOT NULL REFERENCES users(id),
  assigned_by   UUID        NOT NULL REFERENCES users(id),
  assigned_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  unassigned_at TIMESTAMPTZ,
  is_active     BOOLEAN     NOT NULL DEFAULT TRUE
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_task_assignments_active_unique
  ON task_assignments(task_id, user_id) WHERE is_active;
CREATE INDEX IF NOT EXISTS idx_task_assignments_task ON task_assignments(task_id);
CREATE INDEX IF NOT EXISTS idx_task_assignments_user ON task_assignments(user_id) WHERE is_active;

-- Optional followers — notification-ready: add_task_comment() and
-- complete_task() below already fan out to every row here.
CREATE TABLE IF NOT EXISTS task_watchers (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id    UUID        NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  user_id    UUID        NOT NULL REFERENCES users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (task_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_task_watchers_task ON task_watchers(task_id);
CREATE INDEX IF NOT EXISTS idx_task_watchers_user ON task_watchers(user_id);

-- Threaded comments and edit history are explicitly not required for
-- this milestone. No attachment column yet either — attachments are
-- "supported later" per spec, meaning a future patch, not a nullable
-- column sitting unused here.
CREATE TABLE IF NOT EXISTS task_comments (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id    UUID        NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  author_id  UUID        NOT NULL REFERENCES users(id),
  body       TEXT        NOT NULL CHECK (btrim(body) <> ''),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_task_comments_task ON task_comments(task_id);

-- ─── 3. Shared visibility predicate ────────────────────────────
-- Single source of truth for "can this user see this task", reused
-- by the tasks_select RLS policy, the three child tables' SELECT
-- policies, and the mutating RPCs that need a view-check (add_task_
-- comment, watch_task, unwatch_task) — same reuse pattern as
-- can_view_request_or_response()/can_view_case_audit_record().
-- SECURITY DEFINER so its internal SELECT FROM tasks bypasses RLS
-- (avoiding recursion when called from the tasks RLS policy itself),
-- exactly like those two existing helpers.
CREATE OR REPLACE FUNCTION can_view_task(p_task_id UUID)
RETURNS BOOLEAN AS $$
  SELECT is_super_admin() OR EXISTS (
    SELECT 1 FROM tasks t
    WHERE t.id = p_task_id
      AND t.organization_id = get_my_org_id()
      AND (
        t.created_by = auth.uid()
        OR t.completed_by = auth.uid()
        OR EXISTS (
          SELECT 1 FROM task_assignments ta
          WHERE ta.task_id = t.id AND ta.user_id = auth.uid() AND ta.is_active
        )
        OR EXISTS (
          SELECT 1 FROM task_watchers tw
          WHERE tw.task_id = t.id AND tw.user_id = auth.uid()
        )
        OR t.visibility = 'organization'
        OR (t.visibility = 'section' AND t.owning_section_id IN (SELECT my_section_ids()))
        OR (is_supervisor_or_above() AND (t.owning_section_id IS NULL OR t.owning_section_id IN (SELECT my_section_ids())))
        OR is_admin()
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. RLS ─────────────────────────────────────────────────────
ALTER TABLE task_number_sequences ENABLE ROW LEVEL SECURITY;
-- No policies — this table is only ever touched by generate_task_number(),
-- a SECURITY DEFINER function, so no direct client access is needed
-- (deny-by-default, same posture as reference_sequences/entry_reference_sequences).

ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "tasks_select" ON tasks;
CREATE POLICY "tasks_select" ON tasks
  FOR SELECT USING (can_view_task(id));
-- No INSERT/UPDATE/DELETE policy — every mutation goes exclusively
-- through the SECURITY DEFINER RPCs in §5 below.

ALTER TABLE task_assignments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "task_assignments_select" ON task_assignments;
CREATE POLICY "task_assignments_select" ON task_assignments
  FOR SELECT USING (can_view_task(task_id));

ALTER TABLE task_watchers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "task_watchers_select" ON task_watchers;
CREATE POLICY "task_watchers_select" ON task_watchers
  FOR SELECT USING (can_view_task(task_id));

ALTER TABLE task_comments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "task_comments_select" ON task_comments;
CREATE POLICY "task_comments_select" ON task_comments
  FOR SELECT USING (can_view_task(task_id));

-- ─── 5. Foundation RPCs ─────────────────────────────────────────
-- Actor identity always comes from auth.uid() server-side, never a
-- client-supplied parameter, matching create_booking_hold() and every
-- other mutating RPC in patch-rooms-booking-foundation.sql.

CREATE OR REPLACE FUNCTION create_task(
  p_organization_id UUID,
  p_title TEXT,
  p_description TEXT DEFAULT NULL,
  p_owning_section_id UUID DEFAULT NULL,
  p_priority TEXT DEFAULT 'normal',
  p_visibility TEXT DEFAULT 'section',
  p_due_date DATE DEFAULT NULL,
  p_start_date DATE DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_actor_org UUID;
  v_task_id UUID;
  v_task_number TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_task requires an authenticated caller';
  END IF;
  IF btrim(COALESCE(p_title, '')) = '' THEN
    RAISE EXCEPTION 'Task title is required';
  END IF;

  SELECT org_id INTO v_actor_org FROM users WHERE id = v_actor AND is_active = TRUE;
  IF v_actor_org IS NULL THEN
    RAISE EXCEPTION 'Caller account not found or inactive';
  END IF;
  IF NOT is_super_admin() AND v_actor_org <> p_organization_id THEN
    RAISE EXCEPTION 'Cannot create a task outside your own organization';
  END IF;
  IF p_owning_section_id IS NOT NULL
     AND NOT is_super_admin()
     AND p_owning_section_id NOT IN (SELECT my_section_ids()) THEN
    RAISE EXCEPTION 'Cannot assign a task to a section you do not belong to';
  END IF;

  v_task_number := generate_task_number(p_organization_id);

  INSERT INTO tasks (
    task_number, title, description, status, priority, due_date, start_date,
    created_by, organization_id, owning_section_id, visibility
  ) VALUES (
    v_task_number, p_title, p_description, 'draft', COALESCE(p_priority, 'normal'),
    p_due_date, p_start_date, v_actor, p_organization_id, p_owning_section_id,
    COALESCE(p_visibility, 'section')
  ) RETURNING id INTO v_task_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'created', 'task', v_task_id, 'Created task "' || p_title || '"');

  RETURN v_task_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

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

CREATE OR REPLACE FUNCTION cancel_task(p_task_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'cancel_task requires an authenticated caller';
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
    RAISE EXCEPTION 'Not authorized to cancel this task';
  END IF;

  UPDATE tasks SET status = 'cancelled' WHERE id = p_task_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'cancelled', 'task', p_task_id, p_reason);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION complete_task(p_task_id UUID, p_notes TEXT DEFAULT NULL)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
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

CREATE OR REPLACE FUNCTION assign_task(p_task_id UUID, p_user_id UUID)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
  v_assignment_id UUID;
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

  IF NOT EXISTS (
    SELECT 1 FROM users WHERE id = p_user_id AND org_id = v_task.organization_id AND is_active = TRUE
  ) THEN
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
  VALUES (v_actor, 'assigned', 'task', p_task_id, 'Assigned task to user ' || p_user_id);

  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  VALUES (p_user_id, 'task_assigned', 'task', p_task_id,
          'You were assigned to task "' || v_task.title || '"');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION unassign_task(p_task_id UUID, p_user_id UUID)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
  v_rows INTEGER;
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
    OR p_user_id = v_actor
    OR (is_supervisor_or_above() AND v_task.organization_id = get_my_org_id()
        AND (v_task.owning_section_id IS NULL OR v_task.owning_section_id IN (SELECT my_section_ids())))
  ) THEN
    RAISE EXCEPTION 'Not authorized to unassign this task';
  END IF;

  UPDATE task_assignments
  SET is_active = FALSE, unassigned_at = NOW()
  WHERE task_id = p_task_id AND user_id = p_user_id AND is_active = TRUE;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RETURN; -- nothing active to unassign; idempotent no-op
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'unassigned', 'task', p_task_id, 'Unassigned user ' || p_user_id || ' from task');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION add_task_comment(p_task_id UUID, p_body TEXT)
RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
  v_comment_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'add_task_comment requires an authenticated caller';
  END IF;
  IF btrim(COALESCE(p_body, '')) = '' THEN
    RAISE EXCEPTION 'Comment body is required';
  END IF;
  IF NOT can_view_task(p_task_id) THEN
    RAISE EXCEPTION 'Not authorized to comment on this task';
  END IF;

  SELECT * INTO v_task FROM tasks WHERE id = p_task_id;

  INSERT INTO task_comments (task_id, author_id, body)
  VALUES (p_task_id, v_actor, p_body)
  RETURNING id INTO v_comment_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'commented', 'task', p_task_id);

  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  SELECT uid, 'task_comment_added', 'task', p_task_id,
         'New comment on task "' || v_task.title || '"'
  FROM (
    SELECT v_task.created_by AS uid
    UNION
    SELECT user_id FROM task_assignments WHERE task_id = p_task_id AND is_active
    UNION
    SELECT user_id FROM task_watchers WHERE task_id = p_task_id
  ) recipients
  WHERE uid IS NOT NULL AND uid <> v_actor;

  RETURN v_comment_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Not in the original RPC list but required for task_watchers to be
-- usable at all under a SELECT-only RLS model: a user can only ever
-- toggle their OWN watch status (no p_user_id parameter), so this
-- carries no extra authorization surface beyond can_view_task().
CREATE OR REPLACE FUNCTION watch_task(p_task_id UUID)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'watch_task requires an authenticated caller';
  END IF;
  IF NOT can_view_task(p_task_id) THEN
    RAISE EXCEPTION 'Not authorized to watch this task';
  END IF;

  INSERT INTO task_watchers (task_id, user_id)
  VALUES (p_task_id, v_actor)
  ON CONFLICT (task_id, user_id) DO NOTHING;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION unwatch_task(p_task_id UUID)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'unwatch_task requires an authenticated caller';
  END IF;

  DELETE FROM task_watchers WHERE task_id = p_task_id AND user_id = v_actor;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- get_task/list_tasks are plain (non-DEFINER) functions — ordinary
-- SELECT-RLS on `tasks` (tasks_select, via can_view_task()) filters
-- their output for the calling session automatically, so visibility
-- logic is not duplicated a second time here.
CREATE OR REPLACE FUNCTION get_task(p_task_id UUID)
RETURNS TABLE (
  id UUID, task_number TEXT, title TEXT, description TEXT, status TEXT, priority TEXT,
  due_date DATE, start_date DATE, completed_at TIMESTAMPTZ, completed_by UUID,
  created_by UUID, organization_id UUID, owning_section_id UUID, visibility TEXT,
  created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ,
  assignees JSONB, watchers JSONB, comment_count BIGINT
) AS $$
  SELECT
    t.id, t.task_number, t.title, t.description, t.status, t.priority,
    t.due_date, t.start_date, t.completed_at, t.completed_by,
    t.created_by, t.organization_id, t.owning_section_id, t.visibility,
    t.created_at, t.updated_at,
    COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'user_id', ta.user_id, 'assigned_at', ta.assigned_at, 'assigned_by', ta.assigned_by
      ))
      FROM task_assignments ta WHERE ta.task_id = t.id AND ta.is_active
    ), '[]'::jsonb) AS assignees,
    COALESCE((
      SELECT jsonb_agg(jsonb_build_object('user_id', tw.user_id, 'created_at', tw.created_at))
      FROM task_watchers tw WHERE tw.task_id = t.id
    ), '[]'::jsonb) AS watchers,
    (SELECT COUNT(*) FROM task_comments tc WHERE tc.task_id = t.id) AS comment_count
  FROM tasks t
  WHERE t.id = p_task_id;
$$ LANGUAGE sql STABLE SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION list_tasks(
  p_organization_id UUID DEFAULT NULL,
  p_owning_section_id UUID DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_assigned_to_me BOOLEAN DEFAULT FALSE,
  p_limit INTEGER DEFAULT 1000
) RETURNS TABLE (
  id UUID, task_number TEXT, title TEXT, status TEXT, priority TEXT,
  due_date DATE, start_date DATE, completed_at TIMESTAMPTZ,
  created_by UUID, organization_id UUID, owning_section_id UUID, visibility TEXT,
  created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ
) AS $$
  SELECT
    t.id, t.task_number, t.title, t.status, t.priority,
    t.due_date, t.start_date, t.completed_at,
    t.created_by, t.organization_id, t.owning_section_id, t.visibility,
    t.created_at, t.updated_at
  FROM tasks t
  WHERE (p_organization_id IS NULL OR t.organization_id = p_organization_id)
    AND (p_owning_section_id IS NULL OR t.owning_section_id = p_owning_section_id)
    AND (p_status IS NULL OR t.status = p_status)
    AND (NOT p_assigned_to_me OR EXISTS (
      SELECT 1 FROM task_assignments ta
      WHERE ta.task_id = t.id AND ta.user_id = auth.uid() AND ta.is_active
    ))
  ORDER BY t.created_at DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 1000), 1), 1000);
$$ LANGUAGE sql STABLE SET search_path = public, pg_temp;

-- ─── 6. Audit and notification registration ────────────────────
-- Extend the shared CHECK-constraint lists, same mechanism every
-- prior module used (patch-rooms-booking-foundation.sql §9, etc.) —
-- no separate type-registry table exists in this codebase.
ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_record_type_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_record_type_check
  CHECK (record_type IN (
    'request', 'response', 'internal_request', 'prisoner_letter', 'deadline_extension',
    'user', 'organization', 'section', 'session', 'attachment', 'external_correspondence',
    'meeting_room', 'meeting_room_block', 'meeting_room_booking', 'meeting', 'meeting_group', 'meeting_series',
    'task'
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
    'completed', 'commented'
  ));

ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
  CHECK (type IN (
    'new_request', 'new_response', 'approval_requested', 'draft_returned',
    'deadline_warning', 'extension_requested', 'extension_decided',
    'new_prisoner_letter', 'letter_replied',
    'new_external_correspondence', 'external_correspondence_replied',
    'request_cancelled',
    'booking_submitted', 'booking_approved', 'booking_rejected',
    'booking_cancelled', 'booking_changed', 'booking_conflict_attention',
    'meeting_created', 'participant_added', 'meeting_updated', 'room_assigned',
    'meeting_cancelled', 'participant_removed', 'participant_responded',
    'meeting_series_created', 'recurring_booking_submitted', 'meeting_series_updated',
    'meeting_series_split', 'meeting_series_cancelled',
    'task_assigned', 'task_completed', 'task_comment_added'
  ));

COMMIT;
