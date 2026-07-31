-- ============================================================
-- CorLink — Meetings ↔ Shared Tasks Integration
--
-- Second consumer of the generic task_links infrastructure
-- (patch-request-task-integration.sql, "R4"). Widens task_links'
-- module_key CHECK to also allow 'meeting' and extends the shared
-- can_view_task_link() helper with a meeting-visibility branch — this
-- is the exact "future module_key values add a branch here" extension
-- point docs/33 described, not a redesign of task_links itself.
--
-- Meeting lifecycle and Task lifecycle remain fully independent, same
-- promise as R4 made for Requests: no code path in this patch reads
-- or writes meetings.status from a Task RPC, or tasks.status from a
-- Meeting RPC. A meeting's "completed" state is a computed read-time
-- value anyway (meeting_effective_status(), never a stored status), so
-- there is nothing to accidentally couple to in the first place;
-- cancelling a meeting (a real status write) is likewise never
-- touched here.
--
-- Meeting Decisions (new, minimal): the existing Meetings schema has
-- no decision/action-item concept — confirmed by inspecting every
-- patch-meetings-*.sql file before writing this (minutes is a single
-- free-text column on `meetings`, nothing structured). Per this
-- milestone's own instruction to implement only the smallest model
-- needed, `meeting_decisions` is a plain business record (title,
-- description, which meeting, who logged it) with no status or
-- lifecycle of its own — Tasks link to a decision, a decision belongs
-- to a meeting, and task_links.record_id (module_key='meeting') points
-- at the decision, not the meeting directly, matching "A Meeting
-- Decision may have zero/one/many Tasks."
--
-- Idempotent — safe to run more than once.
-- ============================================================

BEGIN;

-- ─── 1. Meeting Decisions (minimal business-record model) ───────
CREATE TABLE IF NOT EXISTS meeting_decisions (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  meeting_id      UUID        NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  organization_id UUID        NOT NULL REFERENCES organizations(id),
  title           TEXT        NOT NULL CHECK (btrim(title) <> ''),
  description     TEXT,
  created_by      UUID        NOT NULL REFERENCES users(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_meeting_decisions_meeting ON meeting_decisions(meeting_id);
CREATE INDEX IF NOT EXISTS idx_meeting_decisions_org ON meeting_decisions(organization_id);

ALTER TABLE meeting_decisions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "meeting_decisions_select" ON meeting_decisions;
CREATE POLICY "meeting_decisions_select" ON meeting_decisions
  FOR SELECT USING (current_user_module_enabled('meetings') AND can_view_meeting(meeting_id));
-- No INSERT/UPDATE/DELETE policy — rows are only ever created inside
-- create_meeting_task()/link_existing_task_to_meeting() below (both
-- SECURITY DEFINER), same RPC-only-writes posture as task_links itself.

-- ─── 2. Extend task_links for module_key = 'meeting' ─────────────
ALTER TABLE task_links DROP CONSTRAINT IF EXISTS task_links_module_key_check;
ALTER TABLE task_links ADD CONSTRAINT task_links_module_key_check
  CHECK (module_key IN ('request', 'meeting'));
-- Future modules (Entry, Internal Collaboration, Prisoner Letters)
-- remain unsupported until their own migration widens this further —
-- not done here, matching "do not widen further" for this milestone.

-- Adds the meeting branch alongside the existing request branch —
-- CREATE OR REPLACE on a function originally declared in
-- patch-request-task-integration.sql, the same technique R2's
-- search-path patch used on functions from schema.sql/rls.sql, so R4's
-- file is never touched. A user can never learn a hidden Task is
-- linked to a visible Meeting Decision, or vice versa, for the same
-- reason as the request branch: can_view_task() AND the module-
-- specific check are both required by the same AND.
CREATE OR REPLACE FUNCTION can_view_task_link(p_task_id UUID, p_module_key TEXT, p_record_id UUID)
RETURNS BOOLEAN AS $$
  SELECT can_view_task(p_task_id) AND (
    (p_module_key = 'request' AND can_view_request_or_response('request', p_record_id))
    OR (p_module_key = 'meeting' AND EXISTS (
      SELECT 1 FROM meeting_decisions md
      WHERE md.id = p_record_id
        AND current_user_module_enabled('meetings')
        AND can_view_meeting(md.meeting_id)
    ))
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. Authorization helper ──────────────────────────────────────
-- "Can this user actively manage this meeting's supporting work" —
-- reuses can_manage_meeting() (patch-meetings-foundation.sql) exactly
-- as-is, plus the same module-enablement check meetings_select's own
-- RLS policy composes (current_user_module_enabled('meetings') AND
-- can_view_meeting(id)) — can_manage_meeting() alone does not check
-- module-enablement, so this adds it rather than silently relying on
-- an already-narrower predicate.
CREATE OR REPLACE FUNCTION can_manage_meeting_task_link(p_meeting_id UUID)
RETURNS BOOLEAN AS $$
  SELECT current_user_module_enabled('meetings') AND can_manage_meeting(p_meeting_id);
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- Resolves an existing decision (verified to belong to the meeting) or
-- creates a new one — shared by create_meeting_task() and
-- link_existing_task_to_meeting() below so "attach a second task to a
-- decision that already has one" and "log a new decision" are both a
-- single code path, not duplicated in both RPCs.
CREATE OR REPLACE FUNCTION resolve_or_create_meeting_decision(
  p_meeting_id UUID,
  p_organization_id UUID,
  p_actor UUID,
  p_decision_id UUID,
  p_decision_title TEXT,
  p_decision_description TEXT
) RETURNS UUID AS $$
DECLARE
  v_decision_id UUID;
BEGIN
  IF p_decision_id IS NOT NULL THEN
    SELECT id INTO v_decision_id FROM meeting_decisions
    WHERE id = p_decision_id AND meeting_id = p_meeting_id;
    IF v_decision_id IS NULL THEN
      RAISE EXCEPTION 'Decision not found on this meeting';
    END IF;
    RETURN v_decision_id;
  END IF;

  IF btrim(COALESCE(p_decision_title, '')) = '' THEN
    RAISE EXCEPTION 'A decision_id or a decision_title is required';
  END IF;

  INSERT INTO meeting_decisions (meeting_id, organization_id, title, description, created_by)
  VALUES (p_meeting_id, p_organization_id, p_decision_title, p_decision_description, p_actor)
  RETURNING id INTO v_decision_id;

  RETURN v_decision_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. RPCs ────────────────────────────────────────────────────
-- Actor identity always from auth.uid(), never a client-supplied
-- parameter, matching every RPC in R3/R4.

CREATE OR REPLACE FUNCTION create_meeting_task(
  p_meeting_id UUID,
  p_title TEXT,
  p_description TEXT DEFAULT NULL,
  p_owning_section_id UUID DEFAULT NULL,
  p_priority TEXT DEFAULT 'normal',
  p_visibility TEXT DEFAULT 'section',
  p_due_date DATE DEFAULT NULL,
  p_start_date DATE DEFAULT NULL,
  p_assignee_ids UUID[] DEFAULT NULL,
  p_decision_id UUID DEFAULT NULL,
  p_decision_title TEXT DEFAULT NULL,
  p_decision_description TEXT DEFAULT NULL
) RETURNS TABLE (task_id UUID, task_number TEXT, decision_id UUID, link_id UUID) AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
  v_decision_id UUID;
  v_task_id UUID;
  v_link_id UUID;
  v_assignee UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_meeting_task requires an authenticated caller';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF NOT can_manage_meeting_task_link(p_meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to create supporting work for this meeting';
  END IF;

  v_decision_id := resolve_or_create_meeting_decision(
    p_meeting_id, v_meeting.organization_id, v_actor, p_decision_id, p_decision_title, p_decision_description
  );

  -- Reuses create_task() (numbering, validation, audit) exactly as R4
  -- reused it for Requests — nothing duplicated here.
  v_task_id := create_task(
    v_meeting.organization_id, p_title, p_description, p_owning_section_id,
    p_priority, p_visibility, p_due_date, p_start_date
  );

  IF p_assignee_ids IS NOT NULL THEN
    FOREACH v_assignee IN ARRAY p_assignee_ids LOOP
      PERFORM assign_task(v_task_id, v_assignee);
    END LOOP;
  END IF;

  INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by)
  VALUES (v_task_id, 'meeting', v_decision_id, v_meeting.organization_id, v_actor)
  RETURNING id INTO v_link_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_linked', 'meeting', p_meeting_id, 'Created and linked supporting task ' || v_task_id);

  RETURN QUERY SELECT v_task_id, (SELECT tk.task_number FROM tasks tk WHERE tk.id = v_task_id), v_decision_id, v_link_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION link_existing_task_to_meeting(
  p_task_id UUID,
  p_meeting_id UUID,
  p_decision_id UUID DEFAULT NULL,
  p_decision_title TEXT DEFAULT NULL,
  p_decision_description TEXT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
  v_meeting meetings;
  v_decision_id UUID;
  v_link_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'link_existing_task_to_meeting requires an authenticated caller';
  END IF;

  SELECT * INTO v_task FROM tasks WHERE id = p_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Task not found';
  END IF;
  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;

  IF NOT can_manage_task(p_task_id) THEN
    RAISE EXCEPTION 'Not authorized to link this task';
  END IF;
  IF NOT can_manage_meeting_task_link(p_meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to link supporting work to this meeting';
  END IF;
  IF v_task.organization_id <> v_meeting.organization_id THEN
    RAISE EXCEPTION 'Task and meeting must belong to the same organization';
  END IF;

  v_decision_id := resolve_or_create_meeting_decision(
    p_meeting_id, v_meeting.organization_id, v_actor, p_decision_id, p_decision_title, p_decision_description
  );

  INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by)
  VALUES (p_task_id, 'meeting', v_decision_id, v_meeting.organization_id, v_actor)
  ON CONFLICT (task_id, module_key, record_id) WHERE removed_at IS NULL DO NOTHING
  RETURNING id INTO v_link_id;

  IF v_link_id IS NULL THEN
    RAISE EXCEPTION 'This task is already linked to this decision';
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_linked', 'meeting', p_meeting_id, 'Linked existing task ' || p_task_id);

  RETURN v_link_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION unlink_task_from_meeting(p_link_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_link task_links;
  v_meeting_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'unlink_task_from_meeting requires an authenticated caller';
  END IF;

  SELECT * INTO v_link FROM task_links
  WHERE id = p_link_id AND module_key = 'meeting' AND removed_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active task link not found';
  END IF;

  SELECT meeting_id INTO v_meeting_id FROM meeting_decisions WHERE id = v_link.record_id;

  IF NOT (can_manage_task(v_link.task_id) OR can_manage_meeting_task_link(v_meeting_id)) THEN
    RAISE EXCEPTION 'Not authorized to unlink this task';
  END IF;

  -- Soft removal only — never touches tasks.status or meetings.status.
  UPDATE task_links SET removed_at = NOW(), removed_by = v_actor WHERE id = p_link_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'task_unlinked', 'meeting', v_meeting_id, COALESCE(p_reason, 'Unlinked task ' || v_link.task_id));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- list_meeting_tasks/list_task_meeting_links are plain (non-DEFINER)
-- functions, same choice R4 made for their Requests equivalents:
-- ordinary RLS on task_links/meeting_decisions/tasks (via
-- can_view_task_link()/meeting_decisions_select/tasks_select) filters
-- their output, so visibility isn't re-implemented a further time.
CREATE OR REPLACE FUNCTION list_meeting_tasks(
  p_meeting_id UUID,
  p_status TEXT DEFAULT NULL,
  p_assigned_to_me BOOLEAN DEFAULT FALSE,
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
) RETURNS TABLE (
  link_id UUID, task_id UUID, task_number TEXT, title TEXT, status TEXT, priority TEXT,
  due_date DATE, start_date DATE, owning_section_id UUID, owning_section_name TEXT, visibility TEXT,
  decision_id UUID, decision_title TEXT, assignees JSONB, linked_at TIMESTAMPTZ, total_count BIGINT
) AS $$
  SELECT
    tl.id, t.id, t.task_number, t.title, t.status, t.priority,
    t.due_date, t.start_date, t.owning_section_id, s.name,
    t.visibility, md.id, md.title,
    COALESCE((
      SELECT jsonb_agg(jsonb_build_object('user_id', u.id, 'full_name', u.full_name))
      FROM task_assignments ta JOIN users u ON u.id = ta.user_id
      WHERE ta.task_id = t.id AND ta.is_active
    ), '[]'::jsonb) AS assignees,
    tl.created_at,
    COUNT(*) OVER() AS total_count
  FROM task_links tl
  JOIN meeting_decisions md ON md.id = tl.record_id
  JOIN tasks t ON t.id = tl.task_id
  LEFT JOIN sections s ON s.id = t.owning_section_id
  WHERE tl.module_key = 'meeting' AND md.meeting_id = p_meeting_id AND tl.removed_at IS NULL
    AND (p_status IS NULL OR t.status = p_status)
    AND (NOT p_assigned_to_me OR EXISTS (
      SELECT 1 FROM task_assignments ta
      WHERE ta.task_id = t.id AND ta.user_id = auth.uid() AND ta.is_active
    ))
  ORDER BY tl.created_at DESC, tl.id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$$ LANGUAGE sql STABLE SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION list_task_meeting_links(
  p_task_id UUID,
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
) RETURNS TABLE (
  link_id UUID, meeting_id UUID, meeting_title TEXT, decision_id UUID, decision_title TEXT,
  linked_at TIMESTAMPTZ, total_count BIGINT
) AS $$
  SELECT
    tl.id, m.id, m.title, md.id, md.title,
    tl.created_at,
    COUNT(*) OVER() AS total_count
  FROM task_links tl
  JOIN meeting_decisions md ON md.id = tl.record_id
  JOIN meetings m ON m.id = md.meeting_id
  WHERE tl.module_key = 'meeting' AND tl.task_id = p_task_id AND tl.removed_at IS NULL
  ORDER BY tl.created_at DESC, tl.id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$$ LANGUAGE sql STABLE SET search_path = public, pg_temp;

-- Narrow capability RPC — booleans only, fails closed, same shape as
-- get_request_task_capabilities().
CREATE OR REPLACE FUNCTION get_meeting_task_capabilities(p_meeting_id UUID)
RETURNS TABLE (
  can_create_task BOOLEAN, can_link_existing BOOLEAN, can_unlink BOOLEAN, can_view_tasks BOOLEAN
) AS $$
DECLARE
  v_can_manage BOOLEAN := FALSE;
  v_can_view BOOLEAN := FALSE;
BEGIN
  IF auth.uid() IS NOT NULL AND EXISTS (SELECT 1 FROM meetings WHERE id = p_meeting_id) THEN
    v_can_manage := can_manage_meeting_task_link(p_meeting_id);
    v_can_view := v_can_manage OR (current_user_module_enabled('meetings') AND can_view_meeting(p_meeting_id));
  END IF;

  RETURN QUERY SELECT v_can_manage, v_can_manage, v_can_manage, v_can_view;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 5. Audit ───────────────────────────────────────────────────
-- No new action values needed — 'task_linked'/'task_unlinked' already
-- exist (added by patch-request-task-integration.sql) and are reused
-- as-is under record_type='meeting'. 'meeting' was already a valid
-- audit_logs.record_type (patch-meetings-foundation.sql), so no
-- constraint widening is needed here at all.

-- No new notification type — create_meeting_task() already fans out
-- task_assigned via its reused assign_task() calls, same reasoning as
-- R4's Requests integration (see docs/34's "Notification decision").

COMMIT;
