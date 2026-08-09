-- ============================================================
-- CorLink — CAP-003 Phase 1.4B: Task & Meeting Notification Event
-- Integration
-- ============================================================
-- Scope, precisely: this patch wires exactly THREE additional real
-- business events through the CAP-003 pipeline built in Phases
-- 1.0-1.4A, atomically enqueued inside their own already-existing,
-- server-authoritative mutation RPCs:
--
--   1. task.completed.v1      -- complete_task()
--   2. meetings.rescheduled.v1 -- update_meeting() (time-change only)
--   3. meetings.cancelled.v1   -- cancel_meeting()
--
-- This is recipient-event integration, not a redesign. It adds ZERO
-- new target-descriptor kinds, ZERO new source_record_type values,
-- ZERO new authorization adapters, and does NOT touch
-- create_notification_intent()/resolve_notification_intent()/
-- process_platform_outbox_batch() at all -- Phase 1.4A's 13-argument
-- create_notification_intent() and its task_watchers/meeting_participants
-- target kinds, plus Phase 1.4's intent_user_can_view_task() and Phase
-- 1.4A's intent_user_can_view_meeting(), already cover every recipient/
-- authorization need these three events have. Every modified RPC's own
-- authorization, status-transition rules, locking, and existing legacy
-- INSERT INTO notifications call are preserved byte-for-byte; the only
-- addition in each is one (or two) atomic
-- platform_enqueue_outbox_event() calls as the last statement(s)
-- before COMMIT, exactly matching Phase 1.4's assign_task() precedent.
--
-- ─── Candidate evaluation (full reasoning) ────────────────────────
-- task.review_requested.v1 / task.returned.v1 -- DEFERRED. Exhaustive
-- repository search (grep across supabase/*.sql for
-- request_task_review/return_task_for_correction/review_requested/
-- request_review/return_for_correction) found NO such RPC anywhere in
-- this codebase. Tasks have no review/approval workflow at all today
-- (only create/update/assign/unassign/complete/cancel/watch/comment).
-- Implementing either event would require inventing new Task lifecycle
-- behavior from nothing -- exactly the "STOP for that event" case the
-- governing instruction requires when the only safe implementation
-- requires redesigning the source module. Deferred, not worked around.
--
-- meetings.scheduled.v1 -- DEFERRED. Two structurally different
-- mutation call sites both produce a "scheduled" meeting status, with
-- INCONSISTENT existing legacy notification behavior between them:
--   (a) create_meeting(p_status := 'scheduled') -- a meeting created
--       directly in scheduled status (a valid, explicitly allowed
--       call shape) fires NO legacy notification at all (confirmed by
--       direct inspection of patch-meetings-foundation.sql's
--       create_meeting() body -- only an audit_logs INSERT).
--   (b) update_meeting() transitioning draft -> scheduled (v_publishing)
--       DOES fire a legacy 'meeting_created' notification to every
--       participant.
-- There is no single, consistent authoritative business intent to
-- mirror without INVENTING a new, more consistent notification policy
-- CorLink's own existing code never actually implements -- exactly what
-- the governing instruction's "do not guess recipient policy... do not
-- invent new notification requirements" prohibits. Deferred with this
-- exact, evidenced reason; task.assigned.v1-style single-RPC clarity
-- does not exist here the way it does for the three implemented events
-- below.
--
-- task.completed.v1 -- IMPLEMENTED. complete_task()
-- (patch-task-dependency-lifecycle-enforcement.sql's body -- the true
-- latest version, confirmed by direct inspection, NOT the superseded
-- patch-shared-task-foundation.sql body) is the sole, unambiguous
-- authoritative mutation RPC. Its own existing legacy notification
-- already targets exactly created_by UNION task_watchers (excluding
-- the actor) -- confirmed by direct inspection of its own
-- `INSERT INTO notifications ... SELECT uid, ... FROM (SELECT
-- v_task.created_by AS uid UNION SELECT user_id FROM task_watchers
-- WHERE task_id = p_task_id) recipients WHERE uid IS NOT NULL AND uid
-- <> v_actor` statement -- so the CAP-003 target mapping mirrors
-- existing, evidenced business intent rather than inventing a new one:
-- one specific_users(created_by) event (conditional -- only when
-- created_by is not the actor, mirroring the legacy self-exclusion)
-- plus one task_watchers(task_id) event (unconditional -- task_watchers
-- resolution has no actor-exclusion parameter at the Phase 1.4A target-
-- descriptor layer; see Limitations).
--
-- meetings.rescheduled.v1 -- IMPLEMENTED. update_meeting() (true latest
-- 14-parameter body, from patch-meetings-recurring-phase2-preserve-
-- series-membership.sql) is the sole authoritative mutation RPC for a
-- meeting's own start/end/timezone changing. Scoped NARROWLY to a
-- genuine reschedule of an ALREADY-scheduled meeting
-- (v_time_changed AND NOT v_publishing AND v_new_status = 'scheduled'),
-- deliberately narrower than the legacy 'meeting_updated' notification's
-- own broader v_meaningful_change condition (which also fires for
-- title/location-only edits with no time change at all) -- a title or
-- location edit is not "rescheduled." Explicitly respects the
-- EXISTING p_suppress_notification flag (added by patch-meetings-
-- recurring-phase2-notification-suppression.sql specifically so bulk
-- recurring-series operations can update many occurrences without
-- spamming one notification per occurrence) -- CAP-003's new channel
-- must honor the exact same suppression semantics the legacy channel
-- already does, or a bulk series-wide reschedule that deliberately
-- suppresses legacy notifications would silently start spamming
-- through the new CAP-003 channel instead, directly undermining why
-- that flag exists. This is a genuine, non-obvious finding from direct
-- inspection of update_entire_series()/update_series_this_and_future()
-- (both call update_meeting() with p_suppress_notification := TRUE for
-- every per-occurrence mutation), not something the governing
-- instruction's candidate list mentioned explicitly.
--
-- meetings.cancelled.v1 -- IMPLEMENTED. cancel_meeting() (true latest
-- 3-parameter body, from patch-meetings-recurring-phase2-notification-
-- suppression.sql) is the sole authoritative mutation RPC, single clean
-- transition (any non-cancelled, non-draft status -> cancelled), fits
-- the existing meeting_participants target kind exactly as legacy
-- already does (meeting_participant_recipient_ids(), excluding the
-- actor at the legacy-notification call site -- same actor-exclusion
-- caveat as above). Also respects the same p_suppress_notification flag.
--
-- ─── Target mapping (no new target kinds) ─────────────────────────
-- task.completed.v1: specific_users(created_by) [conditional] +
--   task_watchers(task_id) [unconditional] -- both existing kinds.
-- meetings.rescheduled.v1 / meetings.cancelled.v1: meeting_participants
--   (target_meeting_id) -- existing kind, Phase 1.4A.
--
-- ─── Authorization (no new adapters) ──────────────────────────────
-- All three events use source_record_type IN ('task', 'meeting'),
-- both already-supported dispatch branches in resolve_notification_intent()
-- (Phase 1.4 / 1.4A). intent_user_can_view_task() already has explicit
-- `t.created_by = p_user` and task_watchers EXISTS branches (confirmed
-- by direct inspection) -- covers BOTH task.completed.v1 recipient
-- kinds with zero changes. intent_user_can_view_meeting() (Phase 1.4A)
-- is reused unchanged for both meeting events. Neither function is
-- modified by this patch.
--
-- ─── Idempotency ───────────────────────────────────────────────────
-- Each event's idempotency_key is derived from a fresh audit_logs.id
-- captured via RETURNING at the exact moment of the real mutation --
-- never a timestamp, never invented. complete_task()'s own status-
-- transition rule (valid_task_status_transition: old_status = new_status
-- is always allowed) means complete_task() CAN legitimately be
-- re-invoked on an already-completed task without error -- this is
-- PRE-EXISTING, unmodified behavior (confirmed by direct inspection of
-- valid_task_status_transition()'s own `SELECT old_status = new_status
-- OR (...)` clause), and the existing legacy notification already
-- re-fires on every such re-invocation today. Each genuine execution of
-- complete_task()'s mutation body (reached only after the authorization/
-- transition/dependency-lock gates pass) produces its own fresh
-- audit_logs row and is therefore its own legitimate, distinguishable
-- occurrence -- exactly the "some events may happen multiple times
-- legitimately" case the governing instruction warns about, resolved
-- here by reusing the audit trail's own natural per-occurrence identity
-- rather than inventing a fragile key. task.completed.v1's second event
-- (specific_users(created_by)) needs a DISTINCT idempotency_key from
-- the first (task_watchers) since both share the same (source_module,
-- source_record_type, source_record_id, event_type) tuple and
-- platform_outbox_events' own uniqueness constraint is keyed on all
-- five columns together -- a deterministic md5-based UUID derivation
-- from the same audit_logs.id (pgcrypto's md5() is already an enabled
-- extension; this is the same md5(...)::uuid deterministic-UUID idiom,
-- not a new dependency) keeps it reproducible under retry while still
-- distinct from the first event's own raw-id key.
--
-- ─── Correlation/causation ─────────────────────────────────────────
-- Each mutation generates ONE fresh gen_random_uuid() correlation_id,
-- shared across every outbox event that single mutation call enqueues
-- (task.completed.v1's two events share one correlation_id -- both are
-- notification fan-outs of the SAME completion act). causation_id is
-- NULL for all three events -- no upstream CAP-003 event caused these;
-- identical to task.assigned.v1's own precedent (Phase 1.4).
--
-- ─── Safe payload ──────────────────────────────────────────────────
-- template_params carries only structural identifiers/timestamps/actor
-- ids, matching task.assigned.v1's own established shape: task_id,
-- task_title, completed_by (task.completed.v1); meeting_id,
-- meeting_title, new_start_at, new_end_at, rescheduled_by
-- (meetings.rescheduled.v1); meeting_id, meeting_title, cancelled_by
-- (meetings.cancelled.v1). p_notes (complete_task) and
-- p_cancellation_reason (cancel_meeting) are DELIBERATELY EXCLUDED --
-- both are free-text user input, the same "unrestricted user text"
-- category as Task comments/Meeting notes the governing instruction
-- explicitly prohibits carrying into notification payloads.
--
-- ─── What this patch does NOT do ──────────────────────────────────
-- No task.review_requested.v1/task.returned.v1/meetings.scheduled.v1
-- (deferred above, with exact reasons). No Requests/Entry/Internal
-- Collaboration/Prisoner Letters integration. No CAP-002/SLA producer.
-- No new mutation RPC. No Realtime cutover. No legacy-table migration.
-- No notification preferences. No email/push/SMS. No frontend change.
-- No change to Task/Meeting authorization, status-transition rules,
-- locking, room-booking semantics, participant semantics, or dependency
-- enforcement -- every non-enqueue line of every modified function is
-- byte-for-byte unchanged from its true current production body. No
-- change to create_notification_intent()/resolve_notification_intent()/
-- process_platform_outbox_batch() -- the worker remains fully generic
-- and unmodified; these three new event_types are registered exactly
-- like task.assigned.v1 was (uses_generic_notification_envelope = TRUE),
-- requiring zero worker code changes to be processed.
--
-- Idempotent -- safe to re-run (DROP FUNCTION before each CREATE OR
-- REPLACE whose parameter list is unchanged is unnecessary here, since
-- none of the three modified functions' own parameter lists change --
-- only their bodies gain new trailing statements).
-- ============================================================

BEGIN;

-- ─── 1. Register the three implemented event types ────────────────
-- Registry-driven dispatch (Phase 1.4) means zero worker code changes
-- are needed for any of these -- uses_generic_notification_envelope
-- TRUE routes them through the exact same generic passthrough path
-- task.assigned.v1 and platform.generic_notification_request.v1 already
-- use. task.review_requested.v1/task.returned.v1/meetings.scheduled.v1
-- are deliberately NOT registered here (deferred, see header).
INSERT INTO platform_event_type_registry
  (event_type, owning_module, is_mandatory, requires_acknowledgement, description, uses_generic_notification_envelope)
VALUES
  (
    'task.completed.v1', 'tasks', FALSE, FALSE,
    'A task was marked completed (complete_task()). Recipients mirror the existing legacy notification''s own recipient set exactly: the task''s creator (specific_users, conditional on creator <> actor) plus every current task_watchers row (task_watchers target kind) -- CAP-003 Phase 1.4B.',
    TRUE
  ),
  (
    'meetings.rescheduled.v1', 'meetings', FALSE, FALSE,
    'An already-scheduled meeting''s start_at/end_at/timezone actually changed (update_meeting(), scoped narrower than the legacy meeting_updated notification -- title/location-only edits do not fire this). Recipients: meeting_participants target kind. Respects the existing p_suppress_notification flag used by bulk recurring-series operations. CAP-003 Phase 1.4B.',
    TRUE
  ),
  (
    'meetings.cancelled.v1', 'meetings', FALSE, FALSE,
    'A meeting was cancelled (cancel_meeting()). Recipients: meeting_participants target kind, mirroring the existing legacy notification exactly. Respects the existing p_suppress_notification flag. CAP-003 Phase 1.4B.',
    TRUE
  )
ON CONFLICT (event_type) DO NOTHING;

-- ─── 2. complete_task(): atomic task.completed.v1 enqueue ─────────
-- True latest body (patch-task-dependency-lifecycle-enforcement.sql,
-- 2026-08-02 -- confirmed the sole/final redefinition by repository-
-- wide search) reproduced byte-for-byte, with ONLY these additions:
--   (a) `RETURNING id INTO v_audit_id` appended to the existing
--       audit_logs INSERT (was a bare INSERT before);
--   (b) two new DECLARE variables (v_audit_id, v_correlation_id);
--   (c) two new platform_enqueue_outbox_event() calls as the final
--       statements before COMMIT, after the existing, unmodified
--       legacy `INSERT INTO notifications` dual-write.
-- Every other line -- authorization, the dependency-lock/status-
-- transition/dependency-blocked checks, the tasks UPDATE, the audit
-- INSERT's own action/record_type/record_id/notes values, and the
-- legacy notification INSERT -- is unchanged.
CREATE OR REPLACE FUNCTION complete_task(p_task_id UUID, p_notes TEXT DEFAULT NULL)
RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_task tasks;
  v_dependency_state RECORD;
  v_audit_id UUID;
  v_correlation_id UUID;
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
  IF NOT valid_task_status_transition(v_task.status, 'completed') THEN
    RAISE EXCEPTION 'Invalid task status transition: % -> %', v_task.status, 'completed';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('task_dependencies:' || v_task.organization_id::TEXT, 0)
  );
  SELECT * INTO v_task FROM tasks WHERE id = p_task_id FOR UPDATE;

  IF NOT (
    is_super_admin()
    OR v_task.created_by = v_actor
    OR EXISTS (SELECT 1 FROM task_assignments ta WHERE ta.task_id = v_task.id AND ta.user_id = v_actor AND ta.is_active)
    OR (is_supervisor_or_above() AND v_task.organization_id = get_my_org_id()
        AND (v_task.owning_section_id IS NULL OR v_task.owning_section_id IN (SELECT my_section_ids())))
  ) THEN
    RAISE EXCEPTION 'Not authorized to complete this task';
  END IF;
  IF NOT valid_task_status_transition(v_task.status, 'completed') THEN
    RAISE EXCEPTION 'Invalid task status transition: % -> %', v_task.status, 'completed';
  END IF;

  SELECT * INTO v_dependency_state FROM get_task_dependency_state(p_task_id);
  IF v_dependency_state.is_blocked THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'Task cannot be completed because one or more prerequisites are unresolved.';
  END IF;

  UPDATE tasks
  SET status = 'completed', completed_at = NOW(), completed_by = v_actor
  WHERE id = p_task_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'completed', 'task', p_task_id, p_notes)
  RETURNING id INTO v_audit_id;

  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  SELECT uid, 'task_completed', 'task', p_task_id,
         'Task "' || v_task.title || '" was marked completed'
  FROM (
    SELECT v_task.created_by AS uid
    UNION
    SELECT user_id FROM task_watchers WHERE task_id = p_task_id
  ) recipients
  WHERE uid IS NOT NULL AND uid <> v_actor;

  -- CAP-003 Phase 1.4B: atomic outbox enqueue, same transaction as the
  -- domain mutation above. Two events -- task_watchers is unconditional
  -- (the target kind's own resolution already filters to current
  -- watchers), specific_users(created_by) is conditional on the creator
  -- not being the actor, mirroring the legacy notification's own
  -- `uid <> v_actor` exclusion for that exact recipient.
  v_correlation_id := gen_random_uuid();

  PERFORM platform_enqueue_outbox_event(
    'task.completed.v1', 'tasks', 'task', p_task_id, v_task.organization_id, v_actor,
    v_correlation_id, NULL, NOW(),
    jsonb_build_object(
      'notification_type', 'task.completed.v1',
      'title_template_key', 'task.completed',
      'template_params', jsonb_build_object('task_id', p_task_id, 'task_title', v_task.title, 'completed_by', v_actor),
      'priority', 'normal',
      'target_type', 'task_watchers',
      'target_task_id', p_task_id
    ),
    v_audit_id
  );

  IF v_task.created_by IS NOT NULL AND v_task.created_by <> v_actor THEN
    PERFORM platform_enqueue_outbox_event(
      'task.completed.v1', 'tasks', 'task', p_task_id, v_task.organization_id, v_actor,
      v_correlation_id, NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'task.completed.v1',
        'title_template_key', 'task.completed',
        'template_params', jsonb_build_object('task_id', p_task_id, 'task_title', v_task.title, 'completed_by', v_actor),
        'priority', 'normal',
        'target_type', 'specific_users',
        'target_user_ids', jsonb_build_array(v_task.created_by)
      ),
      md5(v_audit_id::TEXT || ':task_completed_owner')::UUID
    );
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. update_meeting(): atomic meetings.rescheduled.v1 enqueue ──
-- True latest body (patch-meetings-recurring-phase2-preserve-series-
-- membership.sql, 14 parameters -- confirmed the sole/final
-- redefinition by repository-wide search) reproduced byte-for-byte,
-- with ONLY these additions:
--   (a) `RETURNING id INTO v_audit_id` appended to the existing
--       audit_logs INSERT;
--   (b) one new DECLARE variable (v_audit_id);
--   (c) one new platform_enqueue_outbox_event() call, gated on
--       (NOT p_suppress_notification AND v_time_changed AND NOT
--       v_publishing AND v_new_status = 'scheduled') -- narrower than
--       the legacy meeting_updated branch's own v_meaningful_change
--       condition on purpose (a title/location-only edit is not a
--       reschedule), and respecting the SAME p_suppress_notification
--       flag the legacy branch already checks, for the exact reason
--       explained in this file's header (bulk recurring-series
--       operations rely on this flag to avoid one notification per
--       occurrence -- CAP-003 must not silently reopen that spam
--       vector through a new channel).
-- Every other line -- authorization, lock/status-transition checks,
-- the meetings UPDATE (including series_detached bookkeeping, byte-
-- for-byte unchanged), the booking-reschedule propagation, the audit
-- INSERT's own values, and both legacy notification branches -- is
-- unchanged.
CREATE OR REPLACE FUNCTION update_meeting(
  p_meeting_id UUID,
  p_title TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_meeting_type TEXT DEFAULT NULL,
  p_visibility TEXT DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_start_at TIMESTAMPTZ DEFAULT NULL,
  p_end_at TIMESTAMPTZ DEFAULT NULL,
  p_timezone TEXT DEFAULT NULL,
  p_location_mode TEXT DEFAULT NULL,
  p_external_location TEXT DEFAULT NULL,
  p_virtual_link TEXT DEFAULT NULL,
  p_suppress_notification BOOLEAN DEFAULT FALSE,
  p_preserve_series_membership BOOLEAN DEFAULT FALSE
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
  v_booking meeting_room_bookings;
  v_new_status TEXT;
  v_publishing BOOLEAN;
  v_time_changed BOOLEAN;
  v_meaningful_change BOOLEAN;
  v_new_start TIMESTAMPTZ;
  v_new_end TIMESTAMPTZ;
  v_new_tz TEXT;
  v_new_location_mode TEXT;
  v_new_external_location TEXT;
  v_new_virtual_link TEXT;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'update_meeting requires an authenticated caller';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot update a cancelled meeting';
  END IF;
  IF v_meeting.is_locked AND NOT is_meeting_lock_overridable(p_meeting_id) THEN
    RAISE EXCEPTION 'This meeting is locked; only its creator, an organization administrator (within their own organization), or a super administrator may modify it';
  END IF;
  IF NOT can_manage_meeting(p_meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to update this meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  IF p_status IS NOT NULL THEN
    IF p_status = 'cancelled' THEN
      RAISE EXCEPTION 'Use cancel_meeting to cancel a meeting';
    END IF;
    IF p_status = 'draft' AND v_meeting.status = 'scheduled' THEN
      RAISE EXCEPTION 'A scheduled meeting cannot return to draft';
    END IF;
    IF p_status NOT IN ('draft', 'scheduled') THEN
      RAISE EXCEPTION 'Invalid status for update_meeting: %', p_status;
    END IF;
    v_new_status := p_status;
  ELSE
    v_new_status := v_meeting.status;
  END IF;
  v_publishing := (v_meeting.status = 'draft' AND v_new_status = 'scheduled');

  IF p_title IS NOT NULL AND btrim(p_title) = '' THEN
    RAISE EXCEPTION 'title must not be blank';
  END IF;

  v_new_start := COALESCE(p_start_at, v_meeting.start_at);
  v_new_end := COALESCE(p_end_at, v_meeting.end_at);
  v_new_tz := COALESCE(p_timezone, v_meeting.timezone);
  IF v_new_end <= v_new_start THEN
    RAISE EXCEPTION 'end_at must be after start_at';
  END IF;
  v_time_changed := (p_start_at IS NOT NULL OR p_end_at IS NOT NULL OR p_timezone IS NOT NULL);

  v_new_location_mode := COALESCE(p_location_mode, v_meeting.location_mode);
  v_new_external_location := COALESCE(p_external_location, v_meeting.external_location);
  v_new_virtual_link := COALESCE(p_virtual_link, v_meeting.virtual_link);
  IF v_new_location_mode = 'external' AND v_new_external_location IS NULL THEN
    RAISE EXCEPTION 'external_location is required when location_mode is external';
  END IF;
  IF v_new_location_mode = 'virtual' AND (v_new_virtual_link IS NULL OR v_new_virtual_link !~ '^https://') THEN
    RAISE EXCEPTION 'A valid https:// virtual_link is required when location_mode is virtual';
  END IF;

  v_meaningful_change := (
    p_title IS NOT NULL OR v_time_changed OR p_location_mode IS NOT NULL
    OR p_external_location IS NOT NULL OR p_virtual_link IS NOT NULL
  );

  UPDATE meetings SET
    title = COALESCE(p_title, title),
    description = COALESCE(p_description, description),
    meeting_type = COALESCE(p_meeting_type, meeting_type),
    visibility = COALESCE(p_visibility, visibility),
    status = v_new_status,
    start_at = v_new_start,
    end_at = v_new_end,
    timezone = v_new_tz,
    location_mode = v_new_location_mode,
    external_location = v_new_external_location,
    virtual_link = v_new_virtual_link,
    series_detached = CASE WHEN series_id IS NOT NULL AND NOT p_preserve_series_membership THEN TRUE ELSE series_detached END
  WHERE id = p_meeting_id;

  IF v_time_changed THEN
    SELECT * INTO v_booking FROM meeting_room_bookings
      WHERE meeting_id = p_meeting_id AND status IN ('hold', 'pending', 'confirmed') FOR UPDATE;
    IF FOUND THEN
      PERFORM reschedule_booking(v_booking.id, NULL, v_new_start, v_new_end, v_new_tz, p_suppress_notification := p_suppress_notification);
    END IF;
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'edited', 'meeting', p_meeting_id)
  RETURNING id INTO v_audit_id;

  IF NOT p_suppress_notification THEN
    IF v_publishing THEN
      INSERT INTO notifications (user_id, type, record_type, record_id, message)
      SELECT uid, 'meeting_created', 'meeting', p_meeting_id,
        'You have been invited to a meeting: ' || COALESCE(p_title, v_meeting.title)
      FROM meeting_participant_recipient_ids(p_meeting_id, v_actor) AS uid;
    ELSIF v_meaningful_change AND v_new_status = 'scheduled' THEN
      INSERT INTO notifications (user_id, type, record_type, record_id, message)
      SELECT uid, 'meeting_updated', 'meeting', p_meeting_id, 'A meeting you are part of was updated.'
      FROM meeting_participant_recipient_ids(p_meeting_id, v_actor) AS uid;
    END IF;
  END IF;

  -- CAP-003 Phase 1.4B: atomic outbox enqueue, same transaction as the
  -- domain mutation above. Narrowly scoped to a genuine reschedule of
  -- an already-scheduled meeting -- never on first publish (v_publishing
  -- is a "scheduled" event, deferred, not "rescheduled"), never on a
  -- title/location-only edit with no time change, never when the
  -- caller has suppressed notifications (bulk recurring-series safety).
  IF NOT p_suppress_notification AND v_time_changed AND NOT v_publishing AND v_new_status = 'scheduled' THEN
    PERFORM platform_enqueue_outbox_event(
      'meetings.rescheduled.v1', 'meetings', 'meeting', p_meeting_id, v_meeting.organization_id, v_actor,
      gen_random_uuid(), NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'meetings.rescheduled.v1',
        'title_template_key', 'meetings.rescheduled',
        'template_params', jsonb_build_object(
          'meeting_id', p_meeting_id, 'meeting_title', COALESCE(p_title, v_meeting.title),
          'new_start_at', v_new_start, 'new_end_at', v_new_end, 'rescheduled_by', v_actor
        ),
        'priority', 'normal',
        'target_type', 'meeting_participants',
        'target_meeting_id', p_meeting_id
      ),
      v_audit_id
    );
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. cancel_meeting(): atomic meetings.cancelled.v1 enqueue ────
-- True latest body (patch-meetings-recurring-phase2-notification-
-- suppression.sql, 3 parameters -- confirmed the sole/final
-- redefinition by repository-wide search, since patch-meetings-
-- recurring-phase2-preserve-series-membership.sql explicitly does not
-- touch cancel_meeting()) reproduced byte-for-byte, with ONLY these
-- additions:
--   (a) `RETURNING id INTO v_audit_id` appended to the existing
--       meeting-level audit_logs INSERT (the linked-booking audit
--       INSERT, if any, is untouched);
--   (b) one new DECLARE variable (v_audit_id);
--   (c) one new platform_enqueue_outbox_event() call, gated on NOT
--       p_suppress_notification, matching the existing legacy
--       notification's own gating exactly.
-- Every other line -- authorization, lock/draft/already-cancelled
-- checks, the cancellation-reason requirement, both UPDATE statements,
-- both audit INSERTs' own values, and the legacy notification INSERT
-- -- is unchanged.
CREATE OR REPLACE FUNCTION cancel_meeting(
  p_meeting_id UUID,
  p_cancellation_reason TEXT DEFAULT NULL,
  p_suppress_notification BOOLEAN DEFAULT FALSE
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
  v_booking meeting_room_bookings;
  v_audit_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'cancel_meeting requires an authenticated caller';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Meeting is already cancelled';
  END IF;
  IF v_meeting.status = 'draft' THEN
    RAISE EXCEPTION 'Cannot cancel a draft meeting — delete it instead using delete_draft_meeting';
  END IF;
  IF v_meeting.is_locked AND NOT is_meeting_lock_overridable(p_meeting_id) THEN
    RAISE EXCEPTION 'This meeting is locked; only its creator, an organization administrator (within their own organization), or a super administrator may cancel it';
  END IF;
  IF NOT can_manage_meeting(p_meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to cancel this meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;
  IF v_actor <> v_meeting.created_by AND (p_cancellation_reason IS NULL OR btrim(p_cancellation_reason) = '') THEN
    RAISE EXCEPTION 'A cancellation reason is required';
  END IF;

  SELECT * INTO v_booking FROM meeting_room_bookings
    WHERE meeting_id = p_meeting_id AND status IN ('hold', 'pending', 'confirmed') FOR UPDATE;
  IF FOUND THEN
    UPDATE meeting_room_bookings SET
      status = 'cancelled', cancelled_by = v_actor, cancelled_at = now(),
      cancellation_reason = COALESCE(p_cancellation_reason, 'Meeting cancelled')
      WHERE id = v_booking.id;

    INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
    VALUES (v_actor, 'cancelled', 'meeting_room_booking', v_booking.id, p_cancellation_reason);
  END IF;

  UPDATE meetings SET
    status = 'cancelled', cancelled_by = v_actor, cancelled_at = now(),
    cancellation_reason = p_cancellation_reason
    WHERE id = p_meeting_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'cancelled', 'meeting', p_meeting_id, p_cancellation_reason)
  RETURNING id INTO v_audit_id;

  IF NOT p_suppress_notification THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT uid, 'meeting_cancelled', 'meeting', p_meeting_id, 'A meeting you are part of has been cancelled.'
    FROM meeting_participant_recipient_ids(p_meeting_id, v_actor) AS uid;

    -- CAP-003 Phase 1.4B: atomic outbox enqueue, same transaction as
    -- the domain mutation above. Same gate as the legacy notification
    -- immediately above (NOT p_suppress_notification) -- both channels
    -- share the exact same suppression semantics.
    PERFORM platform_enqueue_outbox_event(
      'meetings.cancelled.v1', 'meetings', 'meeting', p_meeting_id, v_meeting.organization_id, v_actor,
      gen_random_uuid(), NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'meetings.cancelled.v1',
        'title_template_key', 'meetings.cancelled',
        'template_params', jsonb_build_object(
          'meeting_id', p_meeting_id, 'meeting_title', v_meeting.title, 'cancelled_by', v_actor
        ),
        'priority', 'normal',
        'target_type', 'meeting_participants',
        'target_meeting_id', p_meeting_id
      ),
      v_audit_id
    );
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMIT;
