-- ============================================================
-- CAP-003 Phase 1.4A -- Task Watcher & Meeting Participant Target
-- Expansion.
--
-- Closes exactly two of docs/82's eight deferred target-descriptor
-- kinds -- task_watchers and meeting_participants -- both generic
-- CAP-003 recipient-resolution concepts, not module event
-- integration. No new domain event is added: task.assigned.v1
-- remains the only Phase 1.4 pilot producer. This milestone only
-- widens WHO a future event could target and HOW that target is
-- resolved/authorized; it adds no new event, no new producer, and
-- changes zero Task/Meeting business behavior.
--
-- ─── Real data models (inspected directly, not from memory --
-- Phase 1.4 already caught one stale-memory reconstruction) ────────
-- task_watchers (patch-shared-task-foundation.sql): id, task_id, user_id,
-- created_at, UNIQUE(task_id,user_id). No is_active/revoked flag --
-- watch_task()/unwatch_task() use INSERT ON CONFLICT DO NOTHING / hard
-- DELETE. Row existence IS "currently watching." can_view_task()
-- already includes an active-watcher branch, so the existing
-- intent_user_can_view_task() adapter (Phase 1.4) already authorizes
-- watchers correctly with zero changes -- task_watchers-targeted
-- intents reuse source_record_type='task' as-is.
--
-- meeting_participants (patch-meetings-foundation.sql): id, meeting_id,
-- user_id (nullable), external_name/email/phone/org (nullable, mutually
-- exclusive with user_id via meeting_participants_identity_check),
-- participant_role, invitation_status, attendance_status, is_organizer,
-- removed_at/removed_by/removal_reason (soft-delete -- "currently a
-- participant" = removed_at IS NULL). The already-shipped
-- meeting_participant_recipient_ids(meeting_id, exclude) helper
-- already implements exactly the correct resolution query (DISTINCT,
-- user_id IS NOT NULL, removed_at IS NULL) -- reused directly, not
-- duplicated. There is NO section/org-level participant type in this
-- data model at all (no scope_type/scope_id columns) -- "section/org
-- participants" is not an ambiguous-but-supported form to resolve,
-- it simply does not exist in this codebase's meeting model, so
-- nothing to implement or STOP for. External participants
-- (user_id IS NULL) are structurally excluded by
-- meeting_participant_recipient_ids() itself -- never a fake
-- user_notifications row for a non-CorLink identity.
--
-- meeting_participants-targeted intents need a NEW source_record_type
-- ('meeting') since none of the three existing values ('workflow_instance',
-- 'platform', 'task') is semantically correct for a meeting-sourced
-- event -- backed by intent_user_can_view_meeting(), a candidate-
-- generalized mirror of the existing can_view_meeting() (patch-
-- meetings-foundation.sql), exactly the same generalization pattern
-- Phase 1.2/1.4 already established twice (workflow_instance, task).
-- This does not add a meeting event producer -- no code calls
-- platform_enqueue_outbox_event with source_record_type='meeting'
-- after this patch, exactly mirroring how Phase 1.2 itself shipped
-- 'workflow_instance' support with zero real CAP-002 producer wired
-- until later.
-- ============================================================
\set ON_ERROR_STOP on
BEGIN;

-- ─── 1. Two new nullable target-identifier columns, following the
--    exact one-column-per-target-kind convention Phase 1.2 already
--    established. ──────────────────────────────────────────────────
ALTER TABLE notification_intents ADD COLUMN IF NOT EXISTS target_task_id UUID REFERENCES tasks(id);
ALTER TABLE notification_intents ADD COLUMN IF NOT EXISTS target_meeting_id UUID REFERENCES meetings(id);

-- ─── 2. Closed target_type allowlist: extended by exactly the two
--    approved kinds. ────────────────────────────────────────────────
ALTER TABLE notification_intents DROP CONSTRAINT notification_intents_target_type_check;
ALTER TABLE notification_intents ADD CONSTRAINT notification_intents_target_type_check
  CHECK (target_type IN (
    'specific_users', 'org_admins', 'section', 'section_leadership',
    'workflow_participants', 'work_item_assignee', 'task_watchers', 'meeting_participants'
  ));

-- ─── 3. Target-shape structural check: two new branches, each
--    requiring exactly its own identifier column and nothing else --
--    same "exactly one target_* field populated" discipline as every
--    existing branch. ───────────────────────────────────────────────
ALTER TABLE notification_intents DROP CONSTRAINT notification_intents_target_shape_check;
ALTER TABLE notification_intents ADD CONSTRAINT notification_intents_target_shape_check CHECK (
  (target_type = 'specific_users' AND target_user_ids IS NOT NULL AND array_length(target_user_ids,1) > 0
    AND target_organization_id IS NULL AND target_section_id IS NULL AND target_workflow_instance_id IS NULL AND target_work_item_id IS NULL
    AND target_task_id IS NULL AND target_meeting_id IS NULL)
  OR (target_type = 'org_admins' AND target_organization_id IS NOT NULL
    AND target_user_ids IS NULL AND target_section_id IS NULL AND target_workflow_instance_id IS NULL AND target_work_item_id IS NULL
    AND target_task_id IS NULL AND target_meeting_id IS NULL)
  OR (target_type IN ('section', 'section_leadership') AND target_section_id IS NOT NULL
    AND target_user_ids IS NULL AND target_organization_id IS NULL AND target_workflow_instance_id IS NULL AND target_work_item_id IS NULL
    AND target_task_id IS NULL AND target_meeting_id IS NULL)
  OR (target_type = 'workflow_participants' AND target_workflow_instance_id IS NOT NULL
    AND target_user_ids IS NULL AND target_organization_id IS NULL AND target_section_id IS NULL AND target_work_item_id IS NULL
    AND target_task_id IS NULL AND target_meeting_id IS NULL)
  OR (target_type = 'work_item_assignee' AND target_work_item_id IS NOT NULL
    AND target_user_ids IS NULL AND target_organization_id IS NULL AND target_section_id IS NULL AND target_workflow_instance_id IS NULL
    AND target_task_id IS NULL AND target_meeting_id IS NULL)
  OR (target_type = 'task_watchers' AND target_task_id IS NOT NULL
    AND target_user_ids IS NULL AND target_organization_id IS NULL AND target_section_id IS NULL
    AND target_workflow_instance_id IS NULL AND target_work_item_id IS NULL AND target_meeting_id IS NULL)
  OR (target_type = 'meeting_participants' AND target_meeting_id IS NOT NULL
    AND target_user_ids IS NULL AND target_organization_id IS NULL AND target_section_id IS NULL
    AND target_workflow_instance_id IS NULL AND target_work_item_id IS NULL AND target_task_id IS NULL)
);

-- ─── 4. Closed source_record_type allowlist: extended by exactly
--    'meeting' (task_watchers reuses the existing 'task' entry --
--    intent_user_can_view_task() already has an active-watcher
--    branch, see header). ────────────────────────────────────────────
ALTER TABLE notification_intents DROP CONSTRAINT notification_intents_source_record_type_check;
ALTER TABLE notification_intents ADD CONSTRAINT notification_intents_source_record_type_check
  CHECK (source_record_type IN ('workflow_instance', 'platform', 'task', 'meeting'));

-- ─── 5. intent_user_can_view_meeting(): candidate-generalized mirror
--    of can_view_meeting() (patch-meetings-foundation.sql). Every
--    branch reuses meetings/meeting_participants/user_assignments/
--    module_enabled_for_org() directly -- module_enabled_for_org()
--    already takes an explicit org_id (not auth.uid()-bound), so it
--    is reused as-is, not generalized. No parallel permission system. ──
CREATE OR REPLACE FUNCTION intent_user_can_view_meeting(p_meeting_id UUID, p_user UUID)
RETURNS BOOLEAN AS $$
  SELECT intent_user_is_super_admin(p_user) OR EXISTS (
    SELECT 1 FROM meetings m WHERE m.id = p_meeting_id AND (
      m.created_by = p_user
      OR EXISTS (
        SELECT 1 FROM meeting_participants mp
        WHERE mp.meeting_id = m.id AND mp.user_id = p_user AND mp.removed_at IS NULL
      )
      OR (m.organization_id = (SELECT org_id FROM users WHERE id = p_user)
          AND EXISTS (
            SELECT 1 FROM user_assignments ua
            WHERE ua.user_id = p_user AND ua.is_active = TRUE
              AND ua.role IN ('mcs_admin', 'authority_admin', 'supervisor')
          ))
      OR (m.visibility = 'organization' AND m.organization_id = (SELECT org_id FROM users WHERE id = p_user)
          AND module_enabled_for_org(m.organization_id, 'meetings'))
    )
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION intent_user_can_view_meeting(UUID, UUID) FROM PUBLIC, anon, authenticated;

-- ─── 6. create_notification_intent(): two new trailing parameters,
--    two new target_key-derivation CASE branches, two new INSERT
--    columns. The old 11-arg signature is explicitly dropped first --
--    CREATE OR REPLACE does NOT replace a function whose parameter
--    list changed; leaving the old signature in place would silently
--    create a second, orphaned overload rather than truly replacing
--    it. ────────────────────────────────────────────────────────────
DROP FUNCTION create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid);

CREATE OR REPLACE FUNCTION create_notification_intent(
  p_outbox_event_id      UUID,
  p_notification_type    TEXT,
  p_title_template_key   TEXT,
  p_template_params      JSONB,
  p_priority              TEXT,
  p_target_type           TEXT,
  p_target_user_ids       UUID[],
  p_target_organization_id UUID,
  p_target_section_id     UUID,
  p_target_workflow_instance_id UUID,
  p_target_work_item_id   UUID,
  p_target_task_id        UUID,
  p_target_meeting_id     UUID
) RETURNS UUID AS $$
DECLARE
  v_event RECORD;
  v_target_key TEXT;
  v_id UUID;
  v_sorted_ids UUID[];
BEGIN
  IF p_outbox_event_id IS NULL OR p_notification_type IS NULL OR p_title_template_key IS NULL
     OR p_target_type IS NULL
  THEN
    RAISE EXCEPTION 'outbox_event_id, notification_type, title_template_key, and target_type are all required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_event FROM platform_outbox_events WHERE id = p_outbox_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'outbox_event_id % does not reference an existing outbox event', p_outbox_event_id USING ERRCODE = '22023';
  END IF;

  -- Closed source_record_type allowlist (CAP-003 Phase 1.4A: extended
  -- with 'meeting', see header). Structural, at creation time, never
  -- a silent fake at resolution time.
  IF v_event.source_record_type NOT IN ('workflow_instance', 'platform', 'task', 'meeting') THEN
    RAISE EXCEPTION 'source_record_type % has no generic authorization dispatch and remains deferred to a future module-adapter phase', v_event.source_record_type USING ERRCODE = '42501';
  END IF;

  CASE p_target_type
    WHEN 'specific_users' THEN
      IF p_target_user_ids IS NULL OR array_length(p_target_user_ids,1) IS NULL THEN
        RAISE EXCEPTION 'target_user_ids is required for target_type=specific_users' USING ERRCODE = '22023';
      END IF;
      SELECT array_agg(DISTINCT u ORDER BY u) INTO v_sorted_ids FROM unnest(p_target_user_ids) AS u;
      v_target_key := array_to_string(v_sorted_ids, ',');
    WHEN 'org_admins' THEN
      IF p_target_organization_id IS NULL THEN RAISE EXCEPTION 'target_organization_id is required for target_type=org_admins' USING ERRCODE = '22023'; END IF;
      v_target_key := p_target_organization_id::TEXT;
    WHEN 'section', 'section_leadership' THEN
      IF p_target_section_id IS NULL THEN RAISE EXCEPTION 'target_section_id is required for target_type=%', p_target_type USING ERRCODE = '22023'; END IF;
      v_target_key := p_target_section_id::TEXT;
    WHEN 'workflow_participants' THEN
      IF p_target_workflow_instance_id IS NULL THEN RAISE EXCEPTION 'target_workflow_instance_id is required for target_type=workflow_participants' USING ERRCODE = '22023'; END IF;
      v_target_key := p_target_workflow_instance_id::TEXT;
    WHEN 'work_item_assignee' THEN
      IF p_target_work_item_id IS NULL THEN RAISE EXCEPTION 'target_work_item_id is required for target_type=work_item_assignee' USING ERRCODE = '22023'; END IF;
      v_target_key := p_target_work_item_id::TEXT;
    WHEN 'task_watchers' THEN
      IF p_target_task_id IS NULL THEN RAISE EXCEPTION 'target_task_id is required for target_type=task_watchers' USING ERRCODE = '22023'; END IF;
      v_target_key := p_target_task_id::TEXT;
    WHEN 'meeting_participants' THEN
      IF p_target_meeting_id IS NULL THEN RAISE EXCEPTION 'target_meeting_id is required for target_type=meeting_participants' USING ERRCODE = '22023'; END IF;
      v_target_key := p_target_meeting_id::TEXT;
    ELSE
      RAISE EXCEPTION 'Unsupported target_type: %', p_target_type USING ERRCODE = '22023';
  END CASE;

  INSERT INTO notification_intents (
    outbox_event_id, organization_id, notification_type, title_template_key, template_params,
    source_module, source_record_type, source_record_id, priority,
    target_type, target_user_ids, target_organization_id, target_section_id,
    target_workflow_instance_id, target_work_item_id, target_task_id, target_meeting_id, target_key
  ) VALUES (
    p_outbox_event_id, v_event.organization_id, p_notification_type, p_title_template_key,
    COALESCE(p_template_params, '{}'::JSONB),
    v_event.source_module, v_event.source_record_type, v_event.source_record_id,
    COALESCE(p_priority, 'normal'),
    p_target_type,
    CASE WHEN p_target_type = 'specific_users' THEN v_sorted_ids ELSE NULL END,
    CASE WHEN p_target_type = 'org_admins' THEN p_target_organization_id ELSE NULL END,
    CASE WHEN p_target_type IN ('section','section_leadership') THEN p_target_section_id ELSE NULL END,
    CASE WHEN p_target_type = 'workflow_participants' THEN p_target_workflow_instance_id ELSE NULL END,
    CASE WHEN p_target_type = 'work_item_assignee' THEN p_target_work_item_id ELSE NULL END,
    CASE WHEN p_target_type = 'task_watchers' THEN p_target_task_id ELSE NULL END,
    CASE WHEN p_target_type = 'meeting_participants' THEN p_target_meeting_id ELSE NULL END,
    v_target_key
  )
  ON CONFLICT (outbox_event_id, target_type, target_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  SELECT id INTO v_id FROM notification_intents
  WHERE outbox_event_id = p_outbox_event_id AND target_type = p_target_type AND target_key = v_target_key;
  RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION create_notification_intent(UUID,TEXT,TEXT,JSONB,TEXT,TEXT,UUID[],UUID,UUID,UUID,UUID,UUID,UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION create_notification_intent(UUID,TEXT,TEXT,JSONB,TEXT,TEXT,UUID[],UUID,UUID,UUID,UUID,UUID,UUID) TO service_role;

-- ─── 7. resolve_notification_intent(): two new candidate-resolution
--    branches (reusing task_watchers directly, and the already-
--    shipped meeting_participant_recipient_ids() helper directly --
--    never duplicating either), one new authorization-dispatch
--    branch ('meeting'). ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION resolve_notification_intent(p_intent_id UUID)
RETURNS TABLE(status TEXT, resolved_count INTEGER, skipped_count INTEGER) AS $$
DECLARE
  v_intent RECORD;
  v_candidate UUID;
  v_candidates UUID[];
  v_resolved INTEGER := 0;
  v_skipped INTEGER := 0;
  v_authorized BOOLEAN;
  v_final_status TEXT;
BEGIN
  IF p_intent_id IS NULL THEN
    RAISE EXCEPTION 'intent_id is required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_intent FROM notification_intents WHERE id = p_intent_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'intent_id % does not reference an existing notification intent', p_intent_id USING ERRCODE = '22023';
  END IF;

  IF v_intent.status <> 'pending' THEN
    RETURN QUERY SELECT v_intent.status, v_intent.resolved_count, v_intent.skipped_count;
    RETURN;
  END IF;

  CASE v_intent.target_type
    WHEN 'specific_users' THEN
      v_candidates := v_intent.target_user_ids;
    WHEN 'org_admins' THEN
      SELECT array_agg(DISTINCT u) INTO v_candidates FROM org_supervisor_user_ids(v_intent.target_organization_id) AS u;
    WHEN 'section' THEN
      SELECT array_agg(DISTINCT u) INTO v_candidates FROM section_user_ids(v_intent.target_section_id, NULL::TEXT[]) AS u;
    WHEN 'section_leadership' THEN
      SELECT array_agg(DISTINCT u) INTO v_candidates
        FROM section_user_ids(v_intent.target_section_id, ARRAY['mcs_admin','authority_admin','supervisor']) AS u;
    WHEN 'workflow_participants' THEN
      SELECT array_agg(DISTINCT p.user_id) INTO v_candidates
        FROM workflow_participants p WHERE p.instance_id = v_intent.target_workflow_instance_id AND p.ended_at IS NULL;
    WHEN 'work_item_assignee' THEN
      SELECT array_agg(DISTINCT w.assigned_to) INTO v_candidates
        FROM workflow_work_items w WHERE w.id = v_intent.target_work_item_id AND w.assigned_to IS NOT NULL;
    WHEN 'task_watchers' THEN
      -- Row existence IS "currently watching" (no is_active column,
      -- see header) -- current membership at processing time, exactly
      -- docs/78 §7.2's late-resolution requirement.
      SELECT array_agg(DISTINCT tw.user_id) INTO v_candidates
        FROM task_watchers tw WHERE tw.task_id = v_intent.target_task_id;
    WHEN 'meeting_participants' THEN
      -- Reuses the already-shipped meeting_participant_recipient_ids()
      -- helper directly (patch-meetings-foundation.sql) -- it already
      -- filters to internal (user_id IS NOT NULL), currently-active
      -- (removed_at IS NULL) participants, never duplicated here.
      SELECT array_agg(DISTINCT u) INTO v_candidates
        FROM meeting_participant_recipient_ids(v_intent.target_meeting_id, NULL) AS u;
  END CASE;

  IF v_candidates IS NOT NULL THEN
    FOREACH v_candidate IN ARRAY v_candidates LOOP
      IF v_candidate IS NULL THEN CONTINUE; END IF;

      IF NOT EXISTS (SELECT 1 FROM users WHERE id = v_candidate AND is_active = TRUE) THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      -- Processing-time authorization revalidation (docs/78 §8) --
      -- closed dispatcher, CAP-003 Phase 1.4A extends it with exactly
      -- one more branch ('meeting') backed by intent_user_can_view_meeting()
      -- above. task_watchers-targeted candidates are revalidated via
      -- the EXISTING 'task' branch (intent_user_can_view_task()
      -- already has an active-watcher OR-branch, see header) -- no
      -- new source-authorization branch was needed for task_watchers
      -- itself. No fallthrough/default branch that could silently
      -- authorize an unrecognized source type.
      IF v_intent.source_record_type = 'workflow_instance' THEN
        v_authorized := intent_user_can_view_workflow_instance(v_intent.source_record_id, v_candidate);
      ELSIF v_intent.source_record_type = 'platform' THEN
        v_authorized := TRUE;
      ELSIF v_intent.source_record_type = 'task' THEN
        v_authorized := intent_user_can_view_task(v_intent.source_record_id, v_candidate);
      ELSIF v_intent.source_record_type = 'meeting' THEN
        v_authorized := intent_user_can_view_meeting(v_intent.source_record_id, v_candidate);
      ELSE
        v_authorized := FALSE; -- structurally unreachable (create_notification_intent already rejects this), fails closed regardless.
      END IF;

      IF NOT v_authorized THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      PERFORM platform_create_user_notification(
        v_candidate, v_intent.organization_id, v_intent.notification_type, v_intent.title_template_key,
        v_intent.template_params, v_intent.source_module, v_intent.source_record_type, v_intent.source_record_id,
        v_intent.outbox_event_id, v_intent.priority, NULL, NULL, NULL
      );
      v_resolved := v_resolved + 1;
    END LOOP;
  END IF;

  v_final_status := CASE
    WHEN v_resolved > 0 AND v_skipped = 0 THEN 'resolved'
    WHEN v_resolved > 0 AND v_skipped > 0 THEN 'partially_resolved'
    ELSE 'failed'
  END;

  UPDATE notification_intents
  SET status = v_final_status, resolved_at = now(), resolved_count = v_resolved, skipped_count = v_skipped
  WHERE id = p_intent_id;

  RETURN QUERY SELECT v_final_status, v_resolved, v_skipped;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 8. process_platform_outbox_batch(): the ONLY change is passing
--    two more NULLIF(...)::UUID extractions to the now-13-arg
--    create_notification_intent() call, following the EXACT SAME
--    generic passthrough pattern already used for every other target
--    field -- never a target-kind-specific branch. Everything else is
--    byte-for-byte unchanged from the live Phase 1.4 body. ──────────
CREATE OR REPLACE FUNCTION process_platform_outbox_batch(p_limit INTEGER DEFAULT 25, p_worker_id TEXT DEFAULT NULL)
RETURNS TABLE (
  event_id        UUID,
  event_type      TEXT,
  outcome         TEXT,
  intent_id       UUID,
  attempt_count   INTEGER,
  next_attempt_at TIMESTAMPTZ,
  final_status    TEXT
) AS $$
DECLARE
  v_limit          INTEGER;
  v_worker_id      TEXT;
  rec              RECORD;
  v_event          platform_outbox_events;
  v_intent_id      UUID;
  v_resolve_status TEXT;
  v_resolve_count  INTEGER;
  v_skip_count     INTEGER;
  v_outcome        TEXT;
  v_new_attempt    INTEGER;
  v_next_attempt   TIMESTAMPTZ;
  v_final_status   TEXT;
  v_error_text     TEXT;
  v_ret_attempts   INTEGER;
BEGIN
  v_limit := LEAST(GREATEST(COALESCE(p_limit, 25), 1), 200);
  v_worker_id := COALESCE(p_worker_id, 'pid:' || pg_backend_pid()::TEXT);

  FOR rec IN SELECT d.id FROM platform_outbox_events_due_for_processing(v_limit) d LOOP
    v_event := NULL;
    v_intent_id := NULL;
    v_outcome := NULL;
    v_next_attempt := NULL;
    v_final_status := NULL;
    v_error_text := NULL;
    v_ret_attempts := NULL;

    BEGIN
      SELECT * INTO v_event FROM platform_outbox_events WHERE id = rec.id FOR UPDATE SKIP LOCKED;

      IF NOT FOUND THEN
        v_outcome := 'skipped_locked';
      ELSIF v_event.status <> 'pending' THEN
        v_outcome := 'already_processed';
        v_ret_attempts := v_event.attempt_count;
      ELSIF v_event.next_attempt_at IS NOT NULL AND v_event.next_attempt_at > clock_timestamp() THEN
        v_outcome := 'skipped_not_due';
        v_ret_attempts := v_event.attempt_count;
      ELSE
        IF NOT EXISTS (
          SELECT 1 FROM platform_event_type_registry r
          WHERE r.event_type = v_event.event_type AND r.uses_generic_notification_envelope = TRUE
        ) THEN
          RAISE EXCEPTION 'unsupported_event_type: % (no platform_event_type_registry row with uses_generic_notification_envelope=TRUE; register the event type before enqueuing it)', v_event.event_type
            USING ERRCODE = 'P0001';
        END IF;

        v_intent_id := create_notification_intent(
          v_event.id,
          v_event.payload ->> 'notification_type',
          v_event.payload ->> 'title_template_key',
          COALESCE(v_event.payload -> 'template_params', '{}'::JSONB),
          v_event.payload ->> 'priority',
          v_event.payload ->> 'target_type',
          CASE WHEN v_event.payload ? 'target_user_ids'
               THEN ARRAY(SELECT jsonb_array_elements_text(v_event.payload -> 'target_user_ids'))::UUID[]
               ELSE NULL END,
          NULLIF(v_event.payload ->> 'target_organization_id', '')::UUID,
          NULLIF(v_event.payload ->> 'target_section_id', '')::UUID,
          NULLIF(v_event.payload ->> 'target_workflow_instance_id', '')::UUID,
          NULLIF(v_event.payload ->> 'target_work_item_id', '')::UUID,
          NULLIF(v_event.payload ->> 'target_task_id', '')::UUID,
          NULLIF(v_event.payload ->> 'target_meeting_id', '')::UUID
        );

        SELECT r.status, r.resolved_count, r.skipped_count
          INTO v_resolve_status, v_resolve_count, v_skip_count
          FROM resolve_notification_intent(v_intent_id) r;

        UPDATE platform_outbox_events
        SET status = 'completed', processed_at = clock_timestamp(),
            claimed_by = v_worker_id, claimed_at = clock_timestamp(),
            last_error = NULL
        WHERE id = v_event.id;

        v_final_status := 'completed';
        v_outcome := CASE WHEN v_resolve_count = 0 THEN 'processed_zero_recipients' ELSE 'processed' END;
        v_ret_attempts := v_event.attempt_count;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      v_error_text := LEFT(SQLERRM, 500);

      IF v_event.id IS NULL OR v_event.id IS DISTINCT FROM rec.id THEN
        v_outcome := 'failed_before_claim: ' || v_error_text;
      ELSE
        v_new_attempt := v_event.attempt_count + 1;
        v_ret_attempts := v_new_attempt;

        IF v_new_attempt >= 5 THEN
          UPDATE platform_outbox_events
          SET status = 'dead_letter', attempt_count = v_new_attempt,
              last_error = v_error_text,
              claimed_by = v_worker_id, claimed_at = clock_timestamp()
          WHERE id = v_event.id;
          v_final_status := 'dead_letter';
          v_outcome := 'dead_lettered';
        ELSE
          v_next_attempt := clock_timestamp() + platform_outbox_worker_backoff_interval(v_new_attempt);
          UPDATE platform_outbox_events
          SET status = 'pending', attempt_count = v_new_attempt, next_attempt_at = v_next_attempt,
              last_error = v_error_text,
              claimed_by = v_worker_id, claimed_at = clock_timestamp()
          WHERE id = v_event.id;
          v_final_status := 'pending';
          v_outcome := 'retry_scheduled';
        END IF;
      END IF;
    END;

    event_id := rec.id;
    event_type := v_event.event_type;
    outcome := v_outcome;
    intent_id := v_intent_id;
    attempt_count := v_ret_attempts;
    next_attempt_at := v_next_attempt;
    final_status := v_final_status;
    RETURN NEXT;
  END LOOP;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION process_platform_outbox_batch(INTEGER, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION process_platform_outbox_batch(INTEGER, TEXT) TO service_role;

COMMIT;
