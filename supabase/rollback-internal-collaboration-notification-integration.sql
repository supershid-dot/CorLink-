-- CAP-003 Phase 1.8B rollback. Reverses patch-internal-collaboration-
-- notification-integration.sql exactly, restoring:
--   (a) the 6 modified RPCs (create_internal_request, reroute_
--       internal_request, return_internal_request_to_sender, assign_
--       internal_request, approve_internal_request_reply, return_
--       internal_request_reply) to their exact Phase 1.8A production
--       bodies, spliced byte-for-byte from patch-internal-collaboration-
--       server-mutation-foundation.sql;
--   (b) create_notification_intent()/resolve_notification_intent() to
--       their exact Phase 1.7B production bodies, spliced byte-for-byte
--       from patch-entry-notification-integration.sql;
--   (c) the notification_intents_source_record_type_check CHECK
--       constraint to its exact Phase 1.7B allowlist;
-- and additionally:
--   (d) DROP FUNCTION intent_user_can_view_internal_request(uuid,uuid);
--   (e) DELETE the 5 platform_event_type_registry rows this milestone
--       added (event_type LIKE 'internal_collaboration.%').
--
-- ─── What this rollback does NOT touch ──────────────────────────
-- Every internal_requests/internal_request_replies/audit_logs/
-- platform_outbox_events/notification_intents/user_notifications row
-- this milestone's RPCs ever wrote remains exactly as committed --
-- rollback removes the EVENT-INTEGRATION BOUNDARY, never the business
-- data or history it already produced. Phase 1.8A's mutation foundation
-- (authorization, status-transition rules, direct-write closure) is
-- untouched by this rollback (it was never modified by the forward
-- patch beyond the enqueue additions this rollback strips back out).
-- Requests (1.6A/1.6B) and Entry (1.7A/1.7B) notification integration
-- remain completely untouched -- their own adapters/dispatch branches
-- are preserved exactly.
--
-- Per the governing instruction, this rollback REFUSES to run (rather
-- than silently discarding evidence) if any internal_collaboration.*
-- event has already been enqueued, resolved into a notification_intent,
-- or delivered as a user_notification -- persisted CAP-003 evidence is
-- never silently thrown away. If that guard fires, the operator must
-- explicitly decide (out of band) whether to accept the loss of that
-- audit trail before re-running.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM platform_outbox_events WHERE event_type LIKE 'internal_collaboration.%')
     OR EXISTS (SELECT 1 FROM notification_intents WHERE notification_type LIKE 'internal_collaboration.%')
     OR EXISTS (SELECT 1 FROM user_notifications WHERE notification_type LIKE 'internal_collaboration.%')
  THEN
    RAISE EXCEPTION 'Rollback refused: persisted internal_collaboration.* CAP-003 evidence exists (platform_outbox_events/notification_intents/user_notifications). Rolling back would silently discard it. Resolve out of band before re-running this rollback.';
  END IF;
END $$;

BEGIN;

-- ─── (a) Restore the 6 modified RPCs to their exact Phase 1.8A bodies ──
CREATE OR REPLACE FUNCTION create_internal_request(
  p_from_section_id UUID,
  p_to_section_id UUID,
  p_subject TEXT,
  p_body TEXT,
  p_parent_request_id UUID DEFAULT NULL,
  p_parent_entry_id UUID DEFAULT NULL,
  p_subject_language TEXT DEFAULT 'en',
  p_language TEXT DEFAULT 'en',
  p_deadline TIMESTAMPTZ DEFAULT NULL
) RETURNS SETOF internal_requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_internal_request requires an authenticated caller';
  END IF;
  IF p_subject IS NULL OR btrim(p_subject) = '' OR p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'subject and body are required';
  END IF;
  IF (p_parent_request_id IS NULL) = (p_parent_entry_id IS NULL) THEN
    RAISE EXCEPTION 'Exactly one of parent_request_id or parent_entry_id is required';
  END IF;

  IF NOT (
    p_from_section_id IN (SELECT my_section_ids())
    OR (is_supervisor_or_above() AND scope_org_id('section', p_from_section_id) = get_my_org_id())
  ) THEN
    RAISE EXCEPTION 'Not authorized to loop in a section on behalf of the sending section';
  END IF;
  IF scope_org_id('section', p_to_section_id) IS DISTINCT FROM get_my_org_id() THEN
    RAISE EXCEPTION 'That section does not belong to your organization';
  END IF;
  IF NOT internal_requests_parent_startable(p_parent_request_id, p_parent_entry_id) THEN
    RAISE EXCEPTION 'The parent case cannot accept a new internal collaboration thread right now';
  END IF;
  IF NOT internal_requests_parent_deadline_ok(p_parent_request_id, p_parent_entry_id, p_deadline) THEN
    RAISE EXCEPTION 'Deadline cannot be later than the parent case''s own deadline';
  END IF;

  INSERT INTO internal_requests (
    parent_request_id, parent_entry_id, from_section_id, to_section_id, created_by,
    subject, subject_language, body, language, deadline
  ) VALUES (
    p_parent_request_id, p_parent_entry_id, p_from_section_id, p_to_section_id, v_actor,
    p_subject, COALESCE(p_subject_language, 'en'), p_body, COALESCE(p_language, 'en'), p_deadline
  ) RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'created', 'internal_request', v_row.id, 'Created internal request "' || p_subject || '"');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION reroute_internal_request(
  p_internal_request_id UUID,
  p_to_section_id UUID
) RETURNS SETOF internal_requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'reroute_internal_request requires an authenticated caller';
  END IF;
  IF p_to_section_id IS NULL THEN
    RAISE EXCEPTION 'to_section_id is required';
  END IF;

  SELECT * INTO v_row FROM internal_requests WHERE id = p_internal_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Internal request not found';
  END IF;
  IF NOT (
    (
      v_row.to_section_id IN (SELECT my_section_ids())
      OR v_row.from_section_id IN (SELECT my_section_ids())
      OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', v_row.to_section_id))
    )
    AND internal_requests_parent_not_frozen(v_row.parent_request_id, v_row.parent_entry_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to reroute this internal request';
  END IF;
  IF scope_org_id('section', p_to_section_id) IS DISTINCT FROM get_my_org_id() THEN
    RAISE EXCEPTION 'That section does not belong to your organization';
  END IF;

  UPDATE internal_requests SET
    to_section_id = p_to_section_id, status = 'sent',
    received_by = NULL, received_at = NULL, assigned_to = NULL
  WHERE id = p_internal_request_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'routed', 'internal_request', p_internal_request_id,
    'Re-routed internal request to ' || COALESCE((SELECT name FROM sections WHERE id = p_to_section_id), 'another section'));

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION return_internal_request_to_sender(
  p_internal_request_id UUID,
  p_comment TEXT DEFAULT NULL
) RETURNS SETOF internal_requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_requests;
  v_note  TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'return_internal_request_to_sender requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM internal_requests WHERE id = p_internal_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Internal request not found';
  END IF;
  IF NOT (
    v_row.to_section_id IN (SELECT my_section_ids())
    AND internal_requests_parent_not_frozen(v_row.parent_request_id, v_row.parent_entry_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to return this internal request to its sending section';
  END IF;
  IF v_row.status NOT IN ('sent', 'received', 'in_progress') THEN
    RAISE EXCEPTION 'This internal request can no longer be returned to its sending section. Refresh and try again.';
  END IF;

  UPDATE internal_requests SET
    to_section_id = v_row.from_section_id, status = 'sent',
    received_by = NULL, received_at = NULL, assigned_to = NULL
  WHERE id = p_internal_request_id RETURNING * INTO v_row;

  v_note := regexp_replace(COALESCE(p_comment, ''), '<[^>]+>', '', 'g');
  v_note := left(btrim(v_note), 200);

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'returned_to_sender', 'internal_request', p_internal_request_id,
    'Sent back to originating section' || CASE WHEN v_note <> '' THEN ': ' || v_note ELSE '' END);

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION assign_internal_request(
  p_internal_request_id UUID,
  p_user_id UUID DEFAULT NULL
) RETURNS SETOF internal_requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'assign_internal_request requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM internal_requests WHERE id = p_internal_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Internal request not found';
  END IF;
  IF NOT (
    (
      v_row.to_section_id IN (SELECT my_section_ids())
      OR v_row.from_section_id IN (SELECT my_section_ids())
      OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', v_row.to_section_id))
    )
    AND internal_requests_parent_not_frozen(v_row.parent_request_id, v_row.parent_entry_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to assign this internal request';
  END IF;
  IF p_user_id IS NOT NULL AND NOT COALESCE((SELECT is_active FROM users WHERE id = p_user_id), FALSE) THEN
    RAISE EXCEPTION 'Cannot assign to an inactive user';
  END IF;

  UPDATE internal_requests SET
    assigned_to = p_user_id, status = CASE WHEN p_user_id IS NOT NULL THEN 'in_progress' ELSE 'received' END
  WHERE id = p_internal_request_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'assigned', 'internal_request', p_internal_request_id,
    CASE WHEN p_user_id IS NULL THEN 'Unassigned'
      ELSE 'Assigned to ' || COALESCE((SELECT full_name FROM users WHERE id = p_user_id), 'a staff member') END);

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION approve_internal_request_reply(
  p_reply_id UUID
) RETURNS SETOF internal_request_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_request_replies;
  v_ir    internal_requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'approve_internal_request_reply requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM internal_request_replies WHERE id = p_reply_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reply not found';
  END IF;
  SELECT * INTO v_ir FROM internal_requests WHERE id = v_row.internal_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent internal request not found';
  END IF;
  IF NOT (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', v_ir.to_section_id)) THEN
    RAISE EXCEPTION 'Not authorized to approve this reply';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This reply is not awaiting approval. Refresh and try again.';
  END IF;

  UPDATE internal_request_replies SET
    status = 'sent', approved_by = v_actor, approved_at = now()
  WHERE id = p_reply_id RETURNING * INTO v_row;

  UPDATE internal_requests SET status = 'responded' WHERE id = v_ir.id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'approved', 'internal_request', v_ir.id, 'Approved and sent internal reply');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION return_internal_request_reply(
  p_reply_id UUID
) RETURNS SETOF internal_request_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_request_replies;
  v_ir    internal_requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'return_internal_request_reply requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM internal_request_replies WHERE id = p_reply_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reply not found';
  END IF;
  SELECT * INTO v_ir FROM internal_requests WHERE id = v_row.internal_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent internal request not found';
  END IF;
  IF NOT (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', v_ir.to_section_id)) THEN
    RAISE EXCEPTION 'Not authorized to return this reply';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This reply is not awaiting approval. Refresh and try again.';
  END IF;

  UPDATE internal_request_replies SET
    status = 'draft', pending_approval_by = NULL
  WHERE id = p_reply_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'returned', 'internal_request', v_ir.id, 'Returned internal reply for changes');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── (b) Restore create_notification_intent()/resolve_notification_
--    intent() to their exact Phase 1.7B bodies ───────────────────────
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

  IF v_event.source_record_type NOT IN ('workflow_instance', 'platform', 'task', 'meeting', 'request', 'external_correspondence') THEN
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
      SELECT array_agg(DISTINCT tw.user_id) INTO v_candidates
        FROM task_watchers tw WHERE tw.task_id = v_intent.target_task_id;
    WHEN 'meeting_participants' THEN
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

      IF v_intent.source_record_type = 'workflow_instance' THEN
        v_authorized := intent_user_can_view_workflow_instance(v_intent.source_record_id, v_candidate);
      ELSIF v_intent.source_record_type = 'platform' THEN
        v_authorized := TRUE;
      ELSIF v_intent.source_record_type = 'task' THEN
        v_authorized := intent_user_can_view_task(v_intent.source_record_id, v_candidate);
      ELSIF v_intent.source_record_type = 'meeting' THEN
        v_authorized := intent_user_can_view_meeting(v_intent.source_record_id, v_candidate);
      ELSIF v_intent.source_record_type = 'request' THEN
        v_authorized := intent_user_can_view_request(v_intent.source_record_id, v_candidate);
      ELSIF v_intent.source_record_type = 'external_correspondence' THEN
        v_authorized := intent_user_can_view_entry(v_intent.source_record_id, v_candidate);
      ELSE
        v_authorized := FALSE;
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

-- ─── (c) Restore the closed source_record_type allowlist to its exact
--    Phase 1.7B set (drops 'internal_request') ─────────────────────
ALTER TABLE notification_intents DROP CONSTRAINT notification_intents_source_record_type_check;
ALTER TABLE notification_intents ADD CONSTRAINT notification_intents_source_record_type_check
  CHECK (source_record_type IN ('workflow_instance', 'platform', 'task', 'meeting', 'request', 'external_correspondence'));

-- ─── (d) Drop the new authorization adapter ──────────────────────────
DROP FUNCTION IF EXISTS intent_user_can_view_internal_request(UUID, UUID);

-- ─── (e) Delete the 5 registry rows this milestone added ────────────
DELETE FROM platform_event_type_registry WHERE event_type LIKE 'internal_collaboration.%';

COMMIT;
