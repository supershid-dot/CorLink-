-- CAP-003 Phase 1.7B rollback. Restores route_entry()/assign_entry()/
-- approve_entry_reply()/return_entry_reply() to their exact,
-- byte-for-byte pre-1.7B bodies (the true Phase 1.7A bodies, spliced in
-- verbatim from patch-entry-server-mutation-foundation.sql -- not
-- reconstructed from memory), restores create_notification_intent()/
-- resolve_notification_intent() to their exact pre-1.7B (Phase 1.6B)
-- bodies (spliced in verbatim from
-- patch-requests-notification-integration.sql, since Requests 1.6B was
-- the immediately-preceding milestone to modify these two functions),
-- drops intent_user_can_view_entry(), restores the source_record_type
-- CHECK constraint to its exact Phase 1.6B form (workflow_instance/
-- platform/task/meeting/request -- WITHOUT external_correspondence),
-- removes the 4 event-type registry rows this milestone added, and
-- refuses (raises, never silently discards evidence) if any persisted
-- platform_outbox_events/notification_intents/user_notifications row
-- still uses one of the 4 event types or
-- source_record_type='external_correspondence'. Preserves every Phase
-- 1.0-1.6B/1.7A object, and all Entry business data, completely
-- untouched.
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM platform_outbox_events
    WHERE event_type IN ('entry.routed.v1','entry.assigned.v1','entry.reply_sent.v1','entry.reply_returned.v1');
  IF v_count > 0 THEN
    RAISE EXCEPTION 'Rollback refused: % platform_outbox_events row(s) use one of the four Phase 1.7B event types. Restoring the pre-1.7B function bodies would strand this evidence (docs/78 Sec19 -- immutable business evidence, never silently discarded). Resolve/archive these rows first if you intend to proceed.', v_count;
  END IF;
  SELECT count(*) INTO v_count FROM notification_intents WHERE source_record_type = 'external_correspondence';
  IF v_count > 0 THEN
    RAISE EXCEPTION 'Rollback refused: % notification_intents row(s) use source_record_type=''external_correspondence''. Restoring the pre-1.7B source_record_type CHECK constraint would strand this evidence. Resolve/archive these rows first if you intend to proceed.', v_count;
  END IF;
  SELECT count(*) INTO v_count FROM user_notifications
    WHERE notification_type IN ('entry.routed.v1','entry.assigned.v1','entry.reply_sent.v1','entry.reply_returned.v1');
  IF v_count > 0 THEN
    RAISE EXCEPTION 'Rollback refused: % user_notifications row(s) use one of the four Phase 1.7B event types. Restoring the pre-1.7B function bodies would strand this evidence. Resolve/archive these rows first if you intend to proceed.', v_count;
  END IF;
END $$;

-- ─── 1. route_entry(): restore to the exact Phase 1.7A body. ──────
CREATE OR REPLACE FUNCTION route_entry(
  p_entry_id UUID,
  p_to_section_id UUID,
  p_assigned_to UUID DEFAULT NULL
) RETURNS SETOF external_correspondence AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence;
  v_section_org UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'route_entry requires an authenticated caller';
  END IF;
  IF p_to_section_id IS NULL THEN
    RAISE EXCEPTION 'to_section_id is required';
  END IF;

  SELECT * INTO v_row FROM external_correspondence WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entry not found';
  END IF;
  IF NOT is_entry_staff(v_row.org_id) THEN
    RAISE EXCEPTION 'Not authorized to route this entry';
  END IF;

  SELECT org_id INTO v_section_org FROM sections WHERE id = p_to_section_id;
  IF v_section_org IS DISTINCT FROM v_row.org_id THEN
    RAISE EXCEPTION 'That section does not belong to this organization';
  END IF;

  IF p_assigned_to IS NOT NULL AND NOT COALESCE((SELECT is_active FROM users WHERE id = p_assigned_to), FALSE) THEN
    RAISE EXCEPTION 'Cannot assign to an inactive user';
  END IF;

  UPDATE external_correspondence SET
    to_section_id = p_to_section_id, status = 'routed', assigned_to = p_assigned_to
  WHERE id = p_entry_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'routed', 'external_correspondence', p_entry_id,
    'Routed to ' || COALESCE((SELECT name FROM sections WHERE id = p_to_section_id), 'a section'));

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 2. assign_entry(): restore to the exact Phase 1.7A body. ─────
CREATE OR REPLACE FUNCTION assign_entry(
  p_entry_id UUID,
  p_user_id UUID DEFAULT NULL,
  p_deadline DATE DEFAULT NULL
) RETURNS SETOF external_correspondence AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'assign_entry requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM external_correspondence WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entry not found';
  END IF;
  IF NOT (is_entry_staff(v_row.org_id) OR v_row.to_section_id IN (SELECT my_section_ids())) THEN
    RAISE EXCEPTION 'Not authorized to assign this entry';
  END IF;
  IF p_user_id IS NOT NULL AND NOT COALESCE((SELECT is_active FROM users WHERE id = p_user_id), FALSE) THEN
    RAISE EXCEPTION 'Cannot assign to an inactive user';
  END IF;

  UPDATE external_correspondence SET assigned_to = p_user_id, deadline = p_deadline
  WHERE id = p_entry_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'assigned', 'external_correspondence', p_entry_id,
    CASE WHEN p_user_id IS NULL THEN 'Unassigned'
      ELSE 'Assigned to ' || COALESCE((SELECT full_name FROM users WHERE id = p_user_id), 'a staff member') END);

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. approve_entry_reply(): restore to the exact Phase 1.7A body. ─
CREATE OR REPLACE FUNCTION approve_entry_reply(
  p_reply_id UUID
) RETURNS SETOF external_correspondence_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence_replies;
  v_entry external_correspondence;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'approve_entry_reply requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM external_correspondence_replies WHERE id = p_reply_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reply not found';
  END IF;
  SELECT * INTO v_entry FROM external_correspondence WHERE id = v_row.entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent entry not found';
  END IF;
  IF NOT (
    is_supervisor_or_above() AND v_entry.to_section_id IS NOT NULL
    AND get_my_org_id() = scope_org_id('section', v_entry.to_section_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to approve this reply';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This reply is not awaiting approval. Refresh and try again.';
  END IF;

  UPDATE external_correspondence_replies SET
    status = 'sent', approved_by = v_actor, approved_at = now()
  WHERE id = p_reply_id RETURNING * INTO v_row;

  UPDATE external_correspondence SET status = 'responded' WHERE id = v_entry.id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'approved', 'external_correspondence', v_entry.id, 'Approved reply to external correspondence');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. return_entry_reply(): restore to the exact Phase 1.7A body. ──
CREATE OR REPLACE FUNCTION return_entry_reply(
  p_reply_id UUID,
  p_comment TEXT DEFAULT NULL
) RETURNS SETOF external_correspondence_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence_replies;
  v_entry external_correspondence;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'return_entry_reply requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM external_correspondence_replies WHERE id = p_reply_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reply not found';
  END IF;
  SELECT * INTO v_entry FROM external_correspondence WHERE id = v_row.entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent entry not found';
  END IF;
  IF NOT (
    is_supervisor_or_above() AND v_entry.to_section_id IS NOT NULL
    AND get_my_org_id() = scope_org_id('section', v_entry.to_section_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to return this reply';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This reply is not awaiting approval. Refresh and try again.';
  END IF;

  UPDATE external_correspondence_replies SET
    status = 'draft', pending_approval_by = NULL
  WHERE id = p_reply_id RETURNING * INTO v_row;

  INSERT INTO approvals (record_type, record_id, reviewed_by, decision, comment)
  VALUES ('external_correspondence_reply', p_reply_id, v_actor, 'returned', p_comment);

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'returned', 'external_correspondence', v_entry.id, 'Returned reply for changes');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 5. create_notification_intent(): restore to the exact Phase
-- 1.6B body (source_record_type guard with 'request' but WITHOUT
-- 'external_correspondence'). ───────────────────────────────────────
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

  IF v_event.source_record_type NOT IN ('workflow_instance', 'platform', 'task', 'meeting', 'request') THEN
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

-- ─── 6. resolve_notification_intent(): restore to the exact Phase
-- 1.6B body (dispatch includes 'request' but WITHOUT
-- 'external_correspondence'). ───────────────────────────────────────
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

-- ─── 7. Drop the Phase 1.7B-only authorization adapter. ────────────
DROP FUNCTION IF EXISTS intent_user_can_view_entry(UUID, UUID);

-- ─── 8. Restore the source_record_type CHECK constraint to its exact
-- Phase 1.6B form (drops 'external_correspondence'). ────────────────
ALTER TABLE notification_intents DROP CONSTRAINT notification_intents_source_record_type_check;
ALTER TABLE notification_intents ADD CONSTRAINT notification_intents_source_record_type_check
  CHECK (source_record_type IN ('workflow_instance', 'platform', 'task', 'meeting', 'request'));

-- ─── 9. Remove the 4 Phase 1.7B registry rows only. ────────────────
DELETE FROM platform_event_type_registry
WHERE event_type IN ('entry.routed.v1','entry.assigned.v1','entry.reply_sent.v1','entry.reply_returned.v1');

COMMIT;
