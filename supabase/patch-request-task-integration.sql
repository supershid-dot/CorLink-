-- ============================================================
-- CorLink — Requests ↔ Shared Tasks Integration
--
-- Establishes the reusable generic module-linking pattern
-- (`task_links`) and wires up its first consumer, Requests. Later
-- milestones (Meetings, Entry, Internal Collaboration, Prisoner
-- Letters) add their own `module_key` value to the same table and
-- their own capability RPCs — nothing here is Requests-specific at
-- the schema level except the CHECK constraint restricting
-- `module_key` to 'request' for now.
--
-- Requests and Tasks remain fully independent business objects, same
-- as R3 established for Tasks generally: `task_links.record_id` has
-- no foreign key (a deliberate polymorphic-column choice, matching
-- the existing `cc_recipients`/`audit_logs` record_type+record_id
-- precedent in this codebase) — so deleting a request cannot cascade
-- into tasks, and there is no code path anywhere in this patch that
-- writes `requests.status` or reads it to drive `tasks.status`, or
-- vice versa. Closing/cancelling/responding/routing/returning/
-- approving a Request never touches a linked Task; completing a Task
-- never touches its linked Request.
--
-- Idempotent — safe to run more than once.
-- ============================================================

BEGIN;

-- ─── 1. Generic task_links table ───────────────────────────────
CREATE TABLE IF NOT EXISTS task_links (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id         UUID        NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  module_key      TEXT        NOT NULL CHECK (module_key IN ('request')),
  record_id       UUID        NOT NULL,
  organization_id UUID        NOT NULL REFERENCES organizations(id),
  created_by      UUID        NOT NULL REFERENCES users(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  removed_at      TIMESTAMPTZ,
  removed_by      UUID        REFERENCES users(id)
);

-- task_id cascades (a task_link is meaningless once its task is gone,
-- same as task_assignments/task_watchers/task_comments in R3) but
-- record_id is deliberately NOT a foreign key — task_links must stay
-- generic across future module_key values, and this also means a
-- Request row can be deleted (if that ever happens) without touching
-- this table or the tasks it references at all.
CREATE INDEX IF NOT EXISTS idx_task_links_task ON task_links(task_id);
CREATE INDEX IF NOT EXISTS idx_task_links_module_record ON task_links(module_key, record_id);
CREATE INDEX IF NOT EXISTS idx_task_links_org ON task_links(organization_id);

-- At most one ACTIVE link between a given task and a given module
-- record — soft-removed links don't count, so a task can be unlinked
-- and relinked to the same request later.
CREATE UNIQUE INDEX IF NOT EXISTS idx_task_links_active_unique
  ON task_links(task_id, module_key, record_id) WHERE removed_at IS NULL;

-- Covering indexes for the two list RPCs' exact filter+sort shape.
CREATE INDEX IF NOT EXISTS idx_task_links_record_active_created
  ON task_links(module_key, record_id, created_at DESC) WHERE removed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_task_links_task_active_created
  ON task_links(task_id, created_at DESC) WHERE removed_at IS NULL;

-- ─── 2. Authorization helpers ───────────────────────────────────

-- "Can this user actively work on / manage this request" — reuses
-- can_view_request_or_response() (patch-narrow-supervisor-visibility.sql)
-- rather than re-deriving Request visibility by hand. That predicate
-- already requires org membership on the correct side (from/to) PLUS
-- section membership/admin/creator/receiver — never bare org
-- membership alone — so it satisfies "do not grant access merely
-- because a user belongs to either organization" as-is. Deliberately
-- narrower than full requests_select visibility: CC recipients,
-- internal-collaboration looped-in sections, and the unrouted-pool
-- assigned-receiver grant can all SEE a request without this
-- returning true, since none of those represent "actively working on
-- it" in the sense this milestone means for creating/linking work.
CREATE OR REPLACE FUNCTION can_manage_request_task_link(p_request_id UUID)
RETURNS BOOLEAN AS $$
  SELECT can_view_request_or_response('request', p_request_id);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- "Can this user manage (edit/assign/link) this task" — same
-- predicate update_task()/assign_task()/cancel_task()/complete_task()
-- each already inline in patch-shared-task-foundation.sql, factored
-- out here since R4 needs it a 6th time and R4 must not modify the
-- R3 file. Not a duplicate of can_view_task() — view rights there are
-- broader (include watchers, section/org visibility) than manage
-- rights here (creator, active assignee, or scoped supervisor/admin).
CREATE OR REPLACE FUNCTION can_manage_task(p_task_id UUID)
RETURNS BOOLEAN AS $$
  SELECT is_super_admin() OR EXISTS (
    SELECT 1 FROM tasks t
    WHERE t.id = p_task_id
      AND t.organization_id = get_my_org_id()
      AND (
        t.created_by = auth.uid()
        OR EXISTS (
          SELECT 1 FROM task_assignments ta
          WHERE ta.task_id = t.id AND ta.user_id = auth.uid() AND ta.is_active
        )
        OR (is_supervisor_or_above() AND (t.owning_section_id IS NULL OR t.owning_section_id IN (SELECT my_section_ids())))
      )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- Generic "can this user see this link" — both sides must be visible.
-- A user must never learn a hidden Task is linked to a visible
-- Request, or that a visible Task is linked to a hidden Request; this
-- single AND expression is the only place that decision is made.
-- Future module_key values add a branch here, not a parallel
-- predicate elsewhere.
CREATE OR REPLACE FUNCTION can_view_task_link(p_task_id UUID, p_module_key TEXT, p_record_id UUID)
RETURNS BOOLEAN AS $$
  SELECT can_view_task(p_task_id) AND (
    (p_module_key = 'request' AND can_view_request_or_response('request', p_record_id))
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. RLS ─────────────────────────────────────────────────────
ALTER TABLE task_links ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "task_links_select" ON task_links;
CREATE POLICY "task_links_select" ON task_links
  FOR SELECT USING (can_view_task_link(task_id, module_key, record_id));
-- No INSERT/UPDATE/DELETE policy — every mutation goes exclusively
-- through the SECURITY DEFINER RPCs in §4. Note this policy does NOT
-- itself filter removed_at — a removed link stays visible to anyone
-- who could see the active link (supporting a future audit/history
-- view with no new RLS needed); list_request_supporting_tasks() and
-- list_task_request_links() are what filter to "active only" for
-- normal UI listings.

-- ─── 4. RPCs ────────────────────────────────────────────────────
-- Actor identity always from auth.uid(), never a client-supplied
-- parameter, matching every RPC in patch-shared-task-foundation.sql.

CREATE OR REPLACE FUNCTION create_request_supporting_task(
  p_request_id UUID,
  p_title TEXT,
  p_description TEXT DEFAULT NULL,
  p_owning_section_id UUID DEFAULT NULL,
  p_priority TEXT DEFAULT 'normal',
  p_visibility TEXT DEFAULT 'section',
  p_due_date DATE DEFAULT NULL,
  p_start_date DATE DEFAULT NULL,
  p_assignee_ids UUID[] DEFAULT NULL
) RETURNS TABLE (task_id UUID, task_number TEXT, link_id UUID) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_actor_org UUID;
  v_request requests;
  v_task_id UUID;
  v_link_id UUID;
  v_assignee UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_request_supporting_task requires an authenticated caller';
  END IF;

  SELECT * INTO v_request FROM requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;

  IF NOT can_manage_request_task_link(p_request_id) THEN
    RAISE EXCEPTION 'Not authorized to create supporting work for this request';
  END IF;

  SELECT org_id INTO v_actor_org FROM users WHERE id = v_actor AND is_active = TRUE;
  IF v_actor_org IS NULL OR v_actor_org NOT IN (v_request.from_org_id, v_request.to_org_id) THEN
    RAISE EXCEPTION 'Supporting tasks must belong to an organization party to the request';
  END IF;

  -- Reuse the Task foundation's own create_task() (numbering,
  -- validation, audit) rather than duplicating it.
  v_task_id := create_task(
    v_actor_org, p_title, p_description, p_owning_section_id,
    p_priority, p_visibility, p_due_date, p_start_date
  );

  IF p_assignee_ids IS NOT NULL THEN
    FOREACH v_assignee IN ARRAY p_assignee_ids LOOP
      -- Reuses assign_task()'s own validation, audit row, and
      -- task_assigned notification — nothing duplicated here.
      PERFORM assign_task(v_task_id, v_assignee);
    END LOOP;
  END IF;

  INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by)
  VALUES (v_task_id, 'request', p_request_id, v_actor_org, v_actor)
  RETURNING id INTO v_link_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_linked', 'request', p_request_id, 'Created and linked supporting task ' || v_task_id);

  RETURN QUERY SELECT v_task_id, (SELECT tk.task_number FROM tasks tk WHERE tk.id = v_task_id), v_link_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION link_existing_task_to_request(p_task_id UUID, p_request_id UUID)
RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
  v_request requests;
  v_link_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'link_existing_task_to_request requires an authenticated caller';
  END IF;

  SELECT * INTO v_task FROM tasks WHERE id = p_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Task not found';
  END IF;
  SELECT * INTO v_request FROM requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;

  IF NOT can_manage_task(p_task_id) THEN
    RAISE EXCEPTION 'Not authorized to link this task';
  END IF;
  IF NOT can_manage_request_task_link(p_request_id) THEN
    RAISE EXCEPTION 'Not authorized to link supporting work to this request';
  END IF;
  IF v_task.organization_id NOT IN (v_request.from_org_id, v_request.to_org_id) THEN
    RAISE EXCEPTION 'Task and request must share an organization';
  END IF;

  INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by)
  VALUES (p_task_id, 'request', p_request_id, v_task.organization_id, v_actor)
  ON CONFLICT (task_id, module_key, record_id) WHERE removed_at IS NULL DO NOTHING
  RETURNING id INTO v_link_id;

  IF v_link_id IS NULL THEN
    RAISE EXCEPTION 'This task is already linked to this request';
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_linked', 'request', p_request_id, 'Linked existing task ' || p_task_id);

  RETURN v_link_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION unlink_task_from_request(p_link_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_link task_links;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'unlink_task_from_request requires an authenticated caller';
  END IF;

  SELECT * INTO v_link FROM task_links
  WHERE id = p_link_id AND module_key = 'request' AND removed_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active task link not found';
  END IF;

  IF NOT (can_manage_task(v_link.task_id) OR can_manage_request_task_link(v_link.record_id)) THEN
    RAISE EXCEPTION 'Not authorized to unlink this task';
  END IF;

  -- Soft removal only — never touches tasks.status or requests.status.
  UPDATE task_links SET removed_at = NOW(), removed_by = v_actor WHERE id = p_link_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_unlinked', 'request', v_link.record_id, COALESCE(p_reason, 'Unlinked task ' || v_link.task_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- list_request_supporting_tasks/list_task_request_links follow the
-- same SECURITY INVOKER (non-DEFINER) shape as get_task()/list_tasks()
-- in R3: ordinary RLS (task_links_select, via can_view_task_link())
-- filters their output, so the visibility predicate is not
-- re-implemented a third time. total_count is returned in the same
-- row via COUNT(*) OVER() so the frontend's "Load More" can know
-- whether more pages exist without a second round trip.
-- assignees/owning_section_name are included directly (rather than
-- left for the frontend to N+1-fetch per card) the same way get_task()
-- in R3 already inlines an `assignees` jsonb aggregate.
-- DROP first: CREATE OR REPLACE cannot change a RETURNS TABLE
-- function's output columns, so this stays re-runnable even if this
-- function's shape changes again later.
DROP FUNCTION IF EXISTS list_request_supporting_tasks(UUID, TEXT, BOOLEAN, INTEGER, INTEGER);
CREATE OR REPLACE FUNCTION list_request_supporting_tasks(
  p_request_id UUID,
  p_status TEXT DEFAULT NULL,
  p_assigned_to_me BOOLEAN DEFAULT FALSE,
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
) RETURNS TABLE (
  link_id UUID, task_id UUID, task_number TEXT, title TEXT, status TEXT, priority TEXT,
  due_date DATE, start_date DATE, owning_section_id UUID, owning_section_name TEXT, visibility TEXT,
  assignees JSONB, linked_at TIMESTAMPTZ, total_count BIGINT
) AS $$
  SELECT
    tl.id, t.id, t.task_number, t.title, t.status, t.priority,
    t.due_date, t.start_date, t.owning_section_id, s.name,
    t.visibility,
    COALESCE((
      SELECT jsonb_agg(jsonb_build_object('user_id', u.id, 'full_name', u.full_name))
      FROM task_assignments ta JOIN users u ON u.id = ta.user_id
      WHERE ta.task_id = t.id AND ta.is_active
    ), '[]'::jsonb) AS assignees,
    tl.created_at,
    COUNT(*) OVER() AS total_count
  FROM task_links tl
  JOIN tasks t ON t.id = tl.task_id
  LEFT JOIN sections s ON s.id = t.owning_section_id
  WHERE tl.module_key = 'request' AND tl.record_id = p_request_id AND tl.removed_at IS NULL
    AND (p_status IS NULL OR t.status = p_status)
    AND (NOT p_assigned_to_me OR EXISTS (
      SELECT 1 FROM task_assignments ta
      WHERE ta.task_id = t.id AND ta.user_id = auth.uid() AND ta.is_active
    ))
  ORDER BY tl.created_at DESC, tl.id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$$ LANGUAGE sql STABLE SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION list_task_request_links(
  p_task_id UUID,
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
) RETURNS TABLE (
  link_id UUID, request_id UUID, subject TEXT, status TEXT, reference_number TEXT,
  linked_at TIMESTAMPTZ, total_count BIGINT
) AS $$
  SELECT
    tl.id, r.id, r.subject, r.status, r.reference_number,
    tl.created_at,
    COUNT(*) OVER() AS total_count
  FROM task_links tl
  JOIN requests r ON r.id = tl.record_id
  WHERE tl.module_key = 'request' AND tl.task_id = p_task_id AND tl.removed_at IS NULL
  ORDER BY tl.created_at DESC, tl.id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$$ LANGUAGE sql STABLE SET search_path = public, pg_temp;

-- Narrow capability RPC for the frontend — booleans only, no role or
-- permission internals exposed. Fails closed: unauthenticated caller
-- or a request the actor cannot even find both resolve to all-false.
CREATE OR REPLACE FUNCTION get_request_task_capabilities(p_request_id UUID)
RETURNS TABLE (
  can_create_task BOOLEAN, can_link_existing BOOLEAN, can_unlink BOOLEAN, can_view_tasks BOOLEAN
) AS $$
DECLARE
  v_can_manage BOOLEAN := FALSE;
  v_can_view BOOLEAN := FALSE;
BEGIN
  IF auth.uid() IS NOT NULL AND EXISTS (SELECT 1 FROM requests WHERE id = p_request_id) THEN
    v_can_manage := can_manage_request_task_link(p_request_id);
    v_can_view := v_can_manage OR can_view_request_or_response('request', p_request_id);
  END IF;

  RETURN QUERY SELECT v_can_manage, v_can_manage, v_can_manage, v_can_view;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 5. Audit registration ──────────────────────────────────────
-- Minimum new action values needed; no new record_type (task_links
-- rows are audited under record_type='request', matching how e.g.
-- 'routed'/'assigned' already log against the request they act on —
-- request-detail.js's timeline renderer explicitly opts into a fixed
-- action allow-list (['routed', 'assigned', 'returned_to_sender']),
-- so these two new actions do NOT appear there, consistent with "do
-- not merge Task activity into the Request conversation timeline in
-- R4" without any extra filtering work needed here).
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
    'completed', 'commented',
    'task_linked', 'task_unlinked'
  ));

-- No notification type added for this milestone — see docs/33
-- "Notification decision" for the reasoning (create_request_supporting_
-- task already fans out task_assigned via the reused assign_task()
-- calls; linking/unlinking is a lightweight cross-reference, not new
-- work, and spamming every request participant on every link/unlink
-- was explicitly out of scope).

COMMIT;
