-- CAP-003 Phase 1.6B rollback. Restores approve_request()/
-- return_request()/route_request()/assign_request()/approve_response()
-- to their exact, byte-for-byte pre-1.6B bodies (the true Phase 1.6A
-- bodies, spliced in verbatim from patch-requests-server-mutation-
-- foundation.sql -- not reconstructed from memory), restores
-- create_notification_intent()/resolve_notification_intent() to their
-- exact pre-1.6B (Phase 1.4A) bodies, drops
-- intent_user_can_view_request(), restores the source_record_type
-- CHECK constraint to its exact Phase 1.4A form, removes the 5
-- event-type registry rows this milestone added, and refuses (raises,
-- never silently discards evidence) if any persisted
-- platform_outbox_events/notification_intents/user_notifications row
-- still uses one of the 5 event types or source_record_type='request'.
-- Preserves every Phase 1.0-1.5/1.6A object completely untouched.
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM platform_outbox_events
    WHERE event_type IN ('requests.sent.v1','requests.returned.v1','requests.routed.v1','requests.assigned.v1','requests.response_sent.v1');
  IF v_count > 0 THEN
    RAISE EXCEPTION 'Rollback refused: % platform_outbox_events row(s) use one of the five Phase 1.6B event types. Restoring the pre-1.6B function bodies would strand this evidence (docs/78 Sec19 -- immutable business evidence, never silently discarded). Resolve/archive these rows first if you intend to proceed.', v_count;
  END IF;
  SELECT count(*) INTO v_count FROM notification_intents WHERE source_record_type = 'request';
  IF v_count > 0 THEN
    RAISE EXCEPTION 'Rollback refused: % notification_intents row(s) use source_record_type=''request''. Restoring the pre-1.6B source_record_type CHECK constraint would strand this evidence. Resolve/archive these rows first if you intend to proceed.', v_count;
  END IF;
  SELECT count(*) INTO v_count FROM user_notifications
    WHERE notification_type IN ('requests.sent.v1','requests.returned.v1','requests.routed.v1','requests.assigned.v1','requests.response_sent.v1');
  IF v_count > 0 THEN
    RAISE EXCEPTION 'Rollback refused: % user_notifications row(s) use one of the five Phase 1.6B event types. Restoring the pre-1.6B function bodies would strand this evidence. Resolve/archive these rows first if you intend to proceed.', v_count;
  END IF;
END $$;

-- ─── 1. approve_request(): restore to the exact Phase 1.6A body. ──
CREATE OR REPLACE FUNCTION approve_request(
  p_request_id UUID,
  p_comment TEXT DEFAULT NULL
) RETURNS SETOF requests AS $$
DECLARE
  v_actor    UUID := auth.uid();
  v_row      requests;
  v_ref      TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'approve_request requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;
  IF NOT (v_row.from_org_id = get_my_org_id() OR v_row.to_org_id = get_my_org_id()) OR NOT is_supervisor_or_above() THEN
    RAISE EXCEPTION 'Not authorized to approve this request';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This request is not awaiting approval. Refresh and try again.';
  END IF;

  v_ref := generate_reference_number(v_row.from_section_id, 'request');

  UPDATE requests SET status = 'sent', is_locked = TRUE, reference_number = v_ref
  WHERE id = p_request_id RETURNING * INTO v_row;

  INSERT INTO approvals (record_type, record_id, reviewed_by, decision, comment)
  VALUES ('request', p_request_id, v_actor, 'approved', p_comment);

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'approved', 'request', p_request_id, 'Approved and sent request');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 2. return_request(): restore to the exact Phase 1.6A body. ───
CREATE OR REPLACE FUNCTION return_request(
  p_request_id UUID,
  p_comment TEXT DEFAULT NULL
) RETURNS SETOF requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'return_request requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;
  IF NOT (v_row.from_org_id = get_my_org_id() OR v_row.to_org_id = get_my_org_id()) OR NOT is_supervisor_or_above() THEN
    RAISE EXCEPTION 'Not authorized to return this request';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This request is not awaiting approval. Refresh and try again.';
  END IF;

  UPDATE requests SET status = 'draft' WHERE id = p_request_id RETURNING * INTO v_row;

  INSERT INTO approvals (record_type, record_id, reviewed_by, decision, comment)
  VALUES ('request', p_request_id, v_actor, 'returned', p_comment);

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'returned', 'request', p_request_id, 'Returned request for changes');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. route_request(): restore to the exact Phase 1.6A body. ────
CREATE OR REPLACE FUNCTION route_request(
  p_request_id UUID,
  p_to_section_id UUID
) RETURNS SETOF requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   requests;
  v_authorized BOOLEAN;
  v_section_org UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'route_request requires an authenticated caller';
  END IF;
  IF p_to_section_id IS NULL THEN
    RAISE EXCEPTION 'to_section_id is required';
  END IF;

  SELECT * INTO v_row FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;

  SELECT org_id INTO v_section_org FROM sections WHERE id = p_to_section_id;
  IF v_section_org IS DISTINCT FROM v_row.to_org_id THEN
    RAISE EXCEPTION 'That section does not belong to the receiving organization';
  END IF;

  v_authorized := (
    (v_row.to_org_id = get_my_org_id() AND v_row.to_section_id IS NULL AND is_default_section_receiver(v_row.to_org_id))
    OR ((v_row.from_org_id = get_my_org_id() OR v_row.to_org_id = get_my_org_id()) AND is_supervisor_or_above())
    OR (v_row.to_section_id IS NOT NULL AND has_role_in_section(v_row.to_section_id, 'assigned_receiver'))
  );
  IF NOT v_authorized THEN
    RAISE EXCEPTION 'Not authorized to route this request';
  END IF;

  UPDATE requests SET to_section_id = p_to_section_id, status = 'in_progress', assigned_to = NULL
  WHERE id = p_request_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'routed', 'request', p_request_id, 'Routed to ' || COALESCE((SELECT name FROM sections WHERE id = p_to_section_id), 'a section'));

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. assign_request(): restore to the exact Phase 1.6A body. ───
CREATE OR REPLACE FUNCTION assign_request(
  p_request_id UUID,
  p_user_id UUID DEFAULT NULL
) RETURNS SETOF requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   requests;
  v_authorized BOOLEAN;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'assign_request requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;
  IF p_user_id IS NOT NULL AND NOT COALESCE((SELECT is_active FROM users WHERE id = p_user_id), FALSE) THEN
    RAISE EXCEPTION 'Cannot assign to an inactive user';
  END IF;

  v_authorized := (
    (v_row.to_section_id IS NOT NULL AND has_role_in_section(v_row.to_section_id, 'assigned_receiver'))
    OR ((v_row.from_org_id = get_my_org_id() OR v_row.to_org_id = get_my_org_id()) AND is_supervisor_or_above())
  );
  IF NOT v_authorized THEN
    RAISE EXCEPTION 'Not authorized to assign this request';
  END IF;

  UPDATE requests SET assigned_to = p_user_id WHERE id = p_request_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'assigned', 'request', p_request_id,
    CASE WHEN p_user_id IS NULL THEN 'Unassigned'
      ELSE 'Assigned to ' || COALESCE((SELECT full_name FROM users WHERE id = p_user_id), 'a staff member') END);

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 5. approve_response(): restore to the exact Phase 1.6A body. ─
CREATE OR REPLACE FUNCTION approve_response(
  p_response_id UUID,
  p_comment TEXT DEFAULT NULL
) RETURNS SETOF responses AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   responses;
  v_req   requests;
  v_ref   TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'approve_response requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM responses WHERE id = p_response_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Response not found';
  END IF;
  SELECT * INTO v_req FROM requests WHERE id = v_row.request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent request not found';
  END IF;
  IF NOT (v_req.from_org_id = get_my_org_id() OR v_req.to_org_id = get_my_org_id()) OR NOT is_supervisor_or_above() OR v_req.status = 'cancelled' THEN
    RAISE EXCEPTION 'Not authorized to approve this response';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This response is not awaiting approval. Refresh and try again.';
  END IF;

  v_ref := generate_reference_number(v_req.to_section_id, 'response');

  UPDATE responses SET status = 'sent', is_locked = TRUE, reference_number = v_ref
  WHERE id = p_response_id RETURNING * INTO v_row;

  UPDATE requests SET status = 'responded' WHERE id = v_req.id;

  INSERT INTO approvals (record_type, record_id, reviewed_by, decision, comment)
  VALUES ('response', p_response_id, v_actor, 'approved', p_comment);

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'approved', 'response', p_response_id, 'Approved and sent response');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 6. create_notification_intent(): restore to the exact Phase
-- 1.4A body (source_record_type guard without 'request'). ──────────
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

-- ─── 7. resolve_notification_intent(): restore to the exact Phase
-- 1.4A body (no 'request' dispatch branch). ─────────────────────────
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

-- ─── 8. Drop the Phase 1.6B-only authorization adapter. ────────────
DROP FUNCTION IF EXISTS intent_user_can_view_request(UUID, UUID);

-- ─── 9. Restore the source_record_type CHECK constraint to its exact
-- Phase 1.4A form (drops 'request'). ────────────────────────────────
ALTER TABLE notification_intents DROP CONSTRAINT notification_intents_source_record_type_check;
ALTER TABLE notification_intents ADD CONSTRAINT notification_intents_source_record_type_check
  CHECK (source_record_type IN ('workflow_instance', 'platform', 'task', 'meeting'));

-- ─── 10. Remove the 5 Phase 1.6B registry rows only. ───────────────
DELETE FROM platform_event_type_registry
WHERE event_type IN ('requests.sent.v1','requests.returned.v1','requests.routed.v1','requests.assigned.v1','requests.response_sent.v1');

COMMIT;
