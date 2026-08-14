-- CAP-003 Phase 1.9B behavioral test suite. Disposable local
-- PostgreSQL only. Fixtures use the '99000000-' UUID prefix
-- convention. Runs entirely as the connecting superuser -- each RPC's
-- own auth.uid()-driven authorization check (via request.jwt.claims)
-- is what's being exercised here, not RLS (see the dedicated RLS
-- suite, test-prisoner-letters-notification-integration-rls.sql, for
-- direct-role enforcement proofs).
\set ON_ERROR_STOP on
SET search_path = public;

DO $$
DECLARE
  v_org_p UUID := '99000000-0000-0000-0000-000000000001'; -- MCS prison org
  v_org_q UUID := '99000000-0000-0000-0000-000000000002'; -- authority org (destination)
  v_cmd_p UUID := '99000000-0001-0000-0000-000000000001';
  v_cmd_q UUID := '99000000-0001-0000-0000-000000000002';
  v_dept_p UUID := '99000000-0002-0000-0000-000000000001';
  v_dept_q UUID := '99000000-0002-0000-0000-000000000002';
  v_sec_p UUID := '99000000-0003-0000-0000-000000000001';
  v_sec_q UUID := '99000000-0003-0000-0000-000000000002';
  v_mcs_staff UUID := '99000000-0004-0000-0000-000000000001'; -- submitter
  v_auth_super UUID := '99000000-0004-0000-0000-000000000002'; -- authority-org supervisor (org_admins/section_leadership target)
  v_auth_staff_x UUID := '99000000-0004-0000-0000-000000000003'; -- authority staff, NOT the assignee, NOT a supervisor
  v_assignee UUID := '99000000-0004-0000-0000-000000000004'; -- flagged authority staffer, becomes assigned_to
  v_prisoner_id UUID := '99000000-0005-0000-0000-000000000001';
  v_letter_id UUID;
  v_letter2_id UUID;
  v_n INT;
  v_payload JSONB;
BEGIN
  INSERT INTO organizations (id, name, type, code, is_active) VALUES
    (v_org_p, 'Test Prison Org', 'mcs', 'TP99', TRUE),
    (v_org_q, 'Test Authority Org', 'authority', 'TQ99', TRUE);
  INSERT INTO commands (id, org_id, name, is_active) VALUES (v_cmd_p, v_org_p, 'Cmd P', TRUE), (v_cmd_q, v_org_q, 'Cmd Q', TRUE);
  INSERT INTO departments (id, command_id, name, is_active) VALUES (v_dept_p, v_cmd_p, 'Dept P', TRUE), (v_dept_q, v_cmd_q, 'Dept Q', TRUE);
  INSERT INTO sections (id, department_id, org_id, name, code, is_active) VALUES
    (v_sec_p, v_dept_p, v_org_p, 'Sec P', 'SP', TRUE),
    (v_sec_q, v_dept_q, v_org_q, 'Sec Q', 'SQ', TRUE);

  INSERT INTO auth.users (id, email) VALUES
    (v_mcs_staff, 'mcs@t.test'), (v_auth_super, 'authsup@t.test'), (v_auth_staff_x, 'authx@t.test'), (v_assignee, 'assignee@t.test');
  INSERT INTO users (id, org_id, full_name, email, service_number, is_active, is_super_admin, is_prisoner_letters_staff)
    VALUES
      (v_mcs_staff, v_org_p, 'MCS Staff', 'mcs@t.test', 'SN-M', TRUE, FALSE, TRUE),
      (v_auth_super, v_org_q, 'Authority Supervisor', 'authsup@t.test', 'SN-AS', TRUE, FALSE, FALSE),
      (v_auth_staff_x, v_org_q, 'Authority Staff X', 'authx@t.test', 'SN-AX', TRUE, FALSE, TRUE),
      (v_assignee, v_org_q, 'Assignee', 'assignee@t.test', 'SN-AY', TRUE, FALSE, TRUE);
  INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_active) VALUES
    (v_mcs_staff, 'section', v_sec_p, 'staff', TRUE),
    (v_auth_super, 'section', v_sec_q, 'supervisor', TRUE),
    (v_auth_staff_x, 'section', v_sec_q, 'staff', TRUE),
    (v_assignee, 'section', v_sec_q, 'staff', TRUE);

  INSERT INTO prisoners (id, org_id, file_number, id_card_number, full_name, address, prison) VALUES
    (v_prisoner_id, v_org_p, 'FILE-99-1', 'MARKER-PRISONER-ID-99', 'MARKER-PRISONER-NAME-99', 'Test Address', 'Maafushi Prison');

  -- ── Scenario 1: create_prisoner_letter -> prisoner_letter.sent.v1 ->
  -- org_admins(to_org_id) recipient (v_auth_super, the destination
  -- org's supervisor) notified; an ordinary flagged staffer at that org
  -- (v_auth_staff_x, not a supervisor/admin) is NOT notified by this
  -- event, matching org_admins' own resolution (org_supervisor_user_ids). ──
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_mcs_staff::text)::text, TRUE);
  SELECT id INTO v_letter_id FROM create_prisoner_letter(v_prisoner_id, v_org_p, v_org_q, 'MARKER-BODY-1');
  PERFORM process_platform_outbox_batch(50, NULL);

  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='prisoner_letter' AND source_record_id=v_letter_id AND recipient_user_id=v_auth_super AND notification_type='prisoner_letter.sent.v1';
  IF v_n <> 1 THEN RAISE EXCEPTION 'S1 FAILED: expected 1 sent.v1 notification for the destination org supervisor, got %', v_n; END IF;
  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='prisoner_letter' AND source_record_id=v_letter_id AND recipient_user_id=v_auth_staff_x;
  IF v_n <> 0 THEN RAISE EXCEPTION 'S1 FAILED: an ordinary (non-supervisor) authority staffer should not be notified by org_admins targeting'; END IF;
  RAISE NOTICE 'S1 PASSED: create_prisoner_letter -> sent.v1 -> org_admins(to_org_id) notified';

  -- ── Scenario 2: safe payload discipline -- no prisoner identity or
  -- letter content anywhere in the outbox/intent/notification payloads. ──
  SELECT payload INTO v_payload FROM platform_outbox_events WHERE event_type='prisoner_letter.sent.v1' AND source_record_id=v_letter_id ORDER BY created_at DESC LIMIT 1;
  IF v_payload::text ILIKE '%MARKER-PRISONER-NAME-99%' OR v_payload::text ILIKE '%MARKER-PRISONER-ID-99%' OR v_payload::text ILIKE '%MARKER-BODY-1%' THEN
    RAISE EXCEPTION 'S2 FAILED: prisoner identity or letter content leaked into platform_outbox_events.payload';
  END IF;
  IF EXISTS (SELECT 1 FROM notification_intents WHERE source_record_id=v_letter_id AND template_params::text ILIKE '%MARKER-PRISONER%') THEN
    RAISE EXCEPTION 'S2 FAILED: marker text leaked into notification_intents.template_params';
  END IF;
  IF EXISTS (SELECT 1 FROM user_notifications WHERE source_record_id=v_letter_id AND template_params::text ILIKE '%MARKER-PRISONER%') THEN
    RAISE EXCEPTION 'S2 FAILED: marker text leaked into user_notifications.template_params';
  END IF;
  IF (SELECT reference_number FROM prisoner_letters WHERE id = v_letter_id) IS NOT NULL
     AND v_payload::text ILIKE '%' || (SELECT reference_number FROM prisoner_letters WHERE id = v_letter_id) || '%'
  THEN RAISE EXCEPTION 'S2 FAILED: reference_number unexpectedly present in the payload (this milestone deliberately omits it)'; END IF;
  RAISE NOTICE 'S2 PASSED: safe payload discipline (no prisoner identity/content/reference_number leakage)';

  -- ── Scenario 3: route_prisoner_letter with NO assignee ->
  -- prisoner_letter.routed.v1 -> section_leadership(to_section_id) --
  -- the supervisor is notified, the ordinary staffer is NOT. ──────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_auth_super::text)::text, TRUE);
  PERFORM route_prisoner_letter(v_letter_id, v_sec_q, NULL);
  PERFORM process_platform_outbox_batch(50, NULL);

  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='prisoner_letter' AND source_record_id=v_letter_id AND recipient_user_id=v_auth_super AND notification_type='prisoner_letter.routed.v1';
  IF v_n <> 1 THEN RAISE EXCEPTION 'S3 FAILED: expected 1 routed.v1 notification for the section supervisor, got %', v_n; END IF;
  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='prisoner_letter' AND source_record_id=v_letter_id AND recipient_user_id=v_auth_staff_x AND notification_type='prisoner_letter.routed.v1';
  IF v_n <> 0 THEN RAISE EXCEPTION 'S3 FAILED: an ordinary (non-leadership) staffer should not be notified by section_leadership targeting'; END IF;
  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='prisoner_letter' AND source_record_id=v_letter_id AND notification_type='prisoner_letter.assigned.v1';
  IF v_n <> 0 THEN RAISE EXCEPTION 'S3 FAILED: an unassigned route should never fire assigned.v1'; END IF;
  RAISE NOTICE 'S3 PASSED: route_prisoner_letter (no assignee) -> routed.v1 -> section_leadership(to_section_id) notified, assigned.v1 not fired';

  -- ── Scenario 4: route_prisoner_letter WITH an assignee ->
  -- prisoner_letter.assigned.v1 -> specific_users([assigned_to]) only --
  -- mutually exclusive with routed.v1 for this SAME call. ─────────────
  PERFORM route_prisoner_letter(v_letter_id, v_sec_q, v_assignee);
  PERFORM process_platform_outbox_batch(50, NULL);

  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='prisoner_letter' AND source_record_id=v_letter_id AND recipient_user_id=v_assignee AND notification_type='prisoner_letter.assigned.v1';
  IF v_n <> 1 THEN RAISE EXCEPTION 'S4 FAILED: expected 1 assigned.v1 notification for the new assignee, got %', v_n; END IF;
  -- routed.v1 count should still be exactly 1 (from Scenario 3's own
  -- unassigned call) -- this second, assigned call must not have added
  -- a second routed.v1.
  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='prisoner_letter' AND source_record_id=v_letter_id AND recipient_user_id=v_auth_super AND notification_type='prisoner_letter.routed.v1';
  IF v_n <> 1 THEN RAISE EXCEPTION 'S4 FAILED: an assigned route call should not additionally fire routed.v1, routed.v1 count is %', v_n; END IF;
  RAISE NOTICE 'S4 PASSED: route_prisoner_letter (with assignee) -> assigned.v1 -> specific_users([assigned_to]) only, routed.v1 not double-fired';

  -- ── Scenario 5: create_prisoner_letter_reply -> prisoner_letter.
  -- reply_sent.v1 -> specific_users([submitted_by]) -- the original MCS
  -- submitter is notified. ─────────────────────────────────────────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_auth_super::text)::text, TRUE);
  PERFORM mark_prisoner_letter_received(v_letter_id);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_assignee::text)::text, TRUE);
  PERFORM create_prisoner_letter_reply(v_letter_id, 'MARKER-REPLY-BODY-1');
  PERFORM process_platform_outbox_batch(50, NULL);

  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='prisoner_letter' AND source_record_id=v_letter_id AND recipient_user_id=v_mcs_staff AND notification_type='prisoner_letter.reply_sent.v1';
  IF v_n <> 1 THEN RAISE EXCEPTION 'S5 FAILED: expected 1 reply_sent.v1 notification for the original submitter, got %', v_n; END IF;
  SELECT payload INTO v_payload FROM platform_outbox_events WHERE event_type='prisoner_letter.reply_sent.v1' AND source_record_id=v_letter_id ORDER BY created_at DESC LIMIT 1;
  IF v_payload::text ILIKE '%MARKER-REPLY-BODY-1%' THEN
    RAISE EXCEPTION 'S5 FAILED: reply body leaked into payload';
  END IF;
  RAISE NOTICE 'S5 PASSED: create_prisoner_letter_reply -> reply_sent.v1 -> specific_users([submitted_by]) notified, reply body excluded from payload';

  -- ── Scenario 6: mark_prisoner_letter_delivered (a deferred RPC) fires
  -- no event, even on a real, successful transition. ──────────────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_mcs_staff::text)::text, TRUE);
  PERFORM mark_prisoner_letter_delivered(v_letter_id);
  PERFORM process_platform_outbox_batch(50, NULL);
  SELECT count(*) INTO v_n FROM platform_outbox_events WHERE source_record_id=v_letter_id AND event_type ILIKE 'prisoner_letter.delivered%';
  IF v_n <> 0 THEN RAISE EXCEPTION 'S6 FAILED: mark_prisoner_letter_delivered (deferred) unexpectedly enqueued an event'; END IF;
  RAISE NOTICE 'S6 PASSED: deferred RPC (mark_prisoner_letter_delivered) fires no event';

  -- ── Scenario 7: idempotent replay -- re-draining the outbox batch
  -- does not duplicate any notification already delivered. ────────────
  PERFORM process_platform_outbox_batch(50, NULL);
  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='prisoner_letter' AND source_record_id=v_letter_id AND recipient_user_id=v_auth_super AND notification_type='prisoner_letter.sent.v1';
  IF v_n <> 1 THEN RAISE EXCEPTION 'S7 FAILED: replaying the outbox batch duplicated the sent.v1 notification, count now %', v_n; END IF;
  RAISE NOTICE 'S7 PASSED: idempotent replay (no duplicate notifications on re-drain)';

  -- ── Scenario 8: a second, independent letter's events are entirely
  -- independent of the first (no cross-letter interference). ──────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_mcs_staff::text)::text, TRUE);
  SELECT id INTO v_letter2_id FROM create_prisoner_letter(v_prisoner_id, v_org_p, v_org_q, 'MARKER-BODY-2');
  PERFORM process_platform_outbox_batch(50, NULL);
  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='prisoner_letter' AND source_record_id=v_letter2_id AND recipient_user_id=v_auth_super AND notification_type='prisoner_letter.sent.v1';
  IF v_n <> 1 THEN RAISE EXCEPTION 'S8 FAILED: expected the second, independent letter to also fire its own sent.v1, got %', v_n; END IF;
  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='prisoner_letter' AND source_record_id=v_letter_id AND recipient_user_id=v_auth_super AND notification_type='prisoner_letter.sent.v1';
  IF v_n <> 1 THEN RAISE EXCEPTION 'S8 FAILED: the first letter''s own sent.v1 notification count should remain exactly 1, got %', v_n; END IF;
  RAISE NOTICE 'S8 PASSED: two independent letters produce independent, non-interfering notification sets';

  RAISE NOTICE 'ALL BEHAVIORAL SCENARIOS (S1-S8) PASSED';
END $$;
