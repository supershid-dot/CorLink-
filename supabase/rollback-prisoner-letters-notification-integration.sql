-- CAP-003 Phase 1.9B rollback. Reverses patch-prisoner-letters-
-- notification-integration.sql exactly, restoring:
--   (a) the 3 modified RPCs (create_prisoner_letter, route_prisoner_
--       letter, create_prisoner_letter_reply) to their exact Phase
--       1.9A production bodies, spliced byte-for-byte from patch-
--       prisoner-letters-server-mutation-foundation.sql;
--   (b) create_notification_intent()/resolve_notification_intent() to
--       their exact Phase 1.8B production bodies, spliced byte-for-byte
--       from patch-internal-collaboration-notification-integration.sql;
--   (c) the notification_intents_source_record_type_check CHECK
--       constraint to its exact Phase 1.8B allowlist;
-- and additionally:
--   (d) DROP FUNCTION intent_user_can_view_prisoner_letter(uuid,uuid);
--   (e) DELETE the 4 platform_event_type_registry rows this milestone
--       added (event_type LIKE 'prisoner_letter.%').
--
-- ─── What this rollback does NOT touch ──────────────────────────
-- Every prisoner_letters/prisoner_replies/audit_logs/platform_outbox_
-- events/notification_intents/user_notifications row this milestone's
-- RPCs ever wrote remains exactly as committed -- rollback removes the
-- EVENT-INTEGRATION BOUNDARY, never the business data or history it
-- already produced. Phase 1.9A's mutation foundation (the narrowed
-- access model, state-transition rules, direct-write closure,
-- attachment finalization lock, reply immutability) is untouched by
-- this rollback (it was never modified by the forward patch beyond the
-- enqueue additions this rollback strips back out). Requests (1.6A/
-- 1.6B), Entry (1.7A/1.7B), and Internal Collaboration (1.8A/1.8B)
-- notification integration remain completely untouched -- their own
-- adapters/dispatch branches are preserved exactly.
--
-- Per the governing instruction, this rollback REFUSES to run (rather
-- than silently discarding evidence) if any prisoner_letter.* event has
-- already been enqueued, resolved into a notification_intent, or
-- delivered as a user_notification -- persisted CAP-003 evidence is
-- never silently thrown away. If that guard fires, the operator must
-- explicitly decide (out of band) whether to accept the loss of that
-- audit trail before re-running.
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM platform_outbox_events WHERE event_type LIKE 'prisoner_letter.%')
     OR EXISTS (SELECT 1 FROM notification_intents WHERE notification_type LIKE 'prisoner_letter.%')
     OR EXISTS (SELECT 1 FROM user_notifications WHERE notification_type LIKE 'prisoner_letter.%')
  THEN
    RAISE EXCEPTION 'Rollback refused: persisted prisoner_letter.* CAP-003 evidence exists (platform_outbox_events/notification_intents/user_notifications). Rolling back would silently discard it. Resolve out of band before re-running this rollback.';
  END IF;
END $$;

BEGIN;

-- ─── (a) Restore the 3 modified RPCs to their exact Phase 1.9A bodies ──
CREATE OR REPLACE FUNCTION create_prisoner_letter(
  p_prisoner_ref UUID,
  p_from_prison_id UUID,
  p_to_org_id UUID,
  p_body TEXT
) RETURNS SETOF prisoner_letters AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   prisoner_letters;
  v_prisoner prisoners;
  v_ref   TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_prisoner_letter requires an authenticated caller';
  END IF;
  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'body is required';
  END IF;
  IF p_prisoner_ref IS NULL THEN
    RAISE EXCEPTION 'prisoner_ref is required';
  END IF;

  IF NOT is_prisoner_letters_staff() THEN
    RAISE EXCEPTION 'Not authorized to submit prisoner letters';
  END IF;
  IF p_from_prison_id IS DISTINCT FROM get_my_org_id() THEN
    RAISE EXCEPTION 'You may only submit prisoner letters on behalf of your own organization';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM organizations o WHERE o.id = p_from_prison_id AND o.type = 'mcs') THEN
    RAISE EXCEPTION 'The sending organization must be an MCS organization';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM organizations o WHERE o.id = p_to_org_id AND o.type = 'authority') THEN
    RAISE EXCEPTION 'The destination organization must be an authority organization';
  END IF;

  SELECT * INTO v_prisoner FROM prisoners WHERE id = p_prisoner_ref AND org_id = p_from_prison_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prisoner not found in your organization''s registry';
  END IF;

  v_ref := generate_prisoner_letter_reference(p_from_prison_id);

  INSERT INTO prisoner_letters (
    prisoner_ref, prisoner_id, prisoner_name, from_prison_id, to_org_id, body,
    submitted_by, status, reference_number, slip_generated
  ) VALUES (
    p_prisoner_ref, v_prisoner.id_card_number, v_prisoner.full_name, p_from_prison_id, p_to_org_id, p_body,
    v_actor, 'submitted', v_ref, FALSE
  ) RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'created', 'prisoner_letter', v_row.id, 'Submitted prisoner letter for ' || v_prisoner.full_name);

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION route_prisoner_letter(
  p_letter_id UUID,
  p_to_section_id UUID,
  p_assigned_to UUID DEFAULT NULL
) RETURNS SETOF prisoner_letters AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   prisoner_letters;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'route_prisoner_letter requires an authenticated caller';
  END IF;
  IF p_to_section_id IS NULL THEN
    RAISE EXCEPTION 'to_section_id is required';
  END IF;

  SELECT * INTO v_row FROM prisoner_letters WHERE id = p_letter_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prisoner letter not found';
  END IF;
  IF v_row.status = 'delivered' THEN
    RAISE EXCEPTION 'This prisoner letter has already been delivered and can no longer be routed';
  END IF;
  IF NOT (v_row.to_org_id = get_my_org_id() AND is_supervisor_or_above()) THEN
    RAISE EXCEPTION 'Not authorized to route this prisoner letter';
  END IF;
  IF scope_org_id('section', p_to_section_id) IS DISTINCT FROM v_row.to_org_id THEN
    RAISE EXCEPTION 'That section does not belong to the destination organization';
  END IF;
  IF p_assigned_to IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM users u WHERE u.id = p_assigned_to
      AND u.is_active AND u.org_id = v_row.to_org_id AND u.is_prisoner_letters_staff
  ) THEN
    RAISE EXCEPTION 'Cannot assign to a user who is inactive, in a different organization, or not designated for Prisoner Letters duty';
  END IF;

  UPDATE prisoner_letters SET to_section_id = p_to_section_id, assigned_to = p_assigned_to
  WHERE id = p_letter_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'routed', 'prisoner_letter', p_letter_id, 'Routed prisoner letter to section');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION create_prisoner_letter_reply(
  p_letter_id UUID,
  p_body TEXT
) RETURNS SETOF prisoner_replies AS $$
DECLARE
  v_actor  UUID := auth.uid();
  v_letter prisoner_letters;
  v_reply  prisoner_replies;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_prisoner_letter_reply requires an authenticated caller';
  END IF;
  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'body is required';
  END IF;

  SELECT * INTO v_letter FROM prisoner_letters WHERE id = p_letter_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prisoner letter not found';
  END IF;
  IF NOT (
    v_letter.to_org_id = get_my_org_id()
    AND ((is_prisoner_letters_staff() AND v_letter.assigned_to IS NOT NULL AND v_letter.assigned_to = v_actor) OR is_supervisor_or_above())
  ) THEN
    RAISE EXCEPTION 'Not authorized to reply to this prisoner letter';
  END IF;
  IF v_letter.status NOT IN ('submitted', 'received') THEN
    RAISE EXCEPTION 'This prisoner letter is not awaiting a reply. Refresh and try again.';
  END IF;

  INSERT INTO prisoner_replies (letter_id, body, replied_by)
  VALUES (p_letter_id, p_body, v_actor) RETURNING * INTO v_reply;

  UPDATE prisoner_letters SET status = 'replied' WHERE id = p_letter_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'created', 'prisoner_letter', p_letter_id, 'Replied to prisoner letter');

  RETURN NEXT v_reply;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── (b) Restore create_notification_intent()/resolve_notification_
--    intent() to their exact Phase 1.8B bodies ───────────────────────
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

  IF v_event.source_record_type NOT IN ('workflow_instance', 'platform', 'task', 'meeting', 'request', 'external_correspondence', 'internal_request') THEN
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
      ELSIF v_intent.source_record_type = 'internal_request' THEN
        v_authorized := intent_user_can_view_internal_request(v_intent.source_record_id, v_candidate);
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
--    Phase 1.8B set (drops 'prisoner_letter') ────────────────────────
ALTER TABLE notification_intents DROP CONSTRAINT notification_intents_source_record_type_check;
ALTER TABLE notification_intents ADD CONSTRAINT notification_intents_source_record_type_check
  CHECK (source_record_type IN ('workflow_instance', 'platform', 'task', 'meeting', 'request', 'external_correspondence', 'internal_request'));

-- ─── (d) Drop the new authorization adapter ──────────────────────────
DROP FUNCTION IF EXISTS intent_user_can_view_prisoner_letter(UUID, UUID);

-- ─── (e) Delete the 4 registry rows this milestone added ────────────
DELETE FROM platform_event_type_registry WHERE event_type LIKE 'prisoner_letter.%';

COMMIT;
