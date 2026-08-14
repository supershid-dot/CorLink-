-- CAP-003 Phase 1.8B behavioral test suite. Disposable local
-- PostgreSQL only. Fixtures use the '98000000-' UUID prefix convention.
\set ON_ERROR_STOP on
SET search_path = public;

DO $$
DECLARE
  v_org UUID := '98000000-0000-0000-0000-000000000001';
  v_org2 UUID := '98000000-0000-0000-0000-000000000002'; -- unrelated org
  v_cmd UUID := '98000000-0001-0000-0000-000000000001';
  v_dept UUID := '98000000-0002-0000-0000-000000000001';
  v_sec_a UUID := '98000000-0003-0000-0000-000000000001'; -- from-section
  v_sec_b UUID := '98000000-0003-0000-0000-000000000002'; -- to-section (first)
  v_sec_c UUID := '98000000-0003-0000-0000-000000000003'; -- to-section (reroute target)
  v_user_a UUID := '98000000-0004-0000-0000-000000000001'; -- creator, section A
  v_user_b UUID := '98000000-0004-0000-0000-000000000002'; -- staff of section B
  v_user_c UUID := '98000000-0004-0000-0000-000000000003'; -- staff of section C
  v_user_sup UUID := '98000000-0004-0000-0000-000000000004'; -- org-wide supervisor
  v_user_outsider UUID := '98000000-0004-0000-0000-000000000005'; -- section A staff (not the creator), for reply_sent test
  v_user_c_sup UUID := '98000000-0004-0000-0000-000000000006'; -- section-C-scoped supervisor (NOT a section-A member), for S7b
  v_request_id UUID := '98000000-0005-0000-0000-000000000001';
  v_entry_id UUID := '98000000-0005-0000-0000-000000000002';
  v_ir_id UUID;
  v_ir2_id UUID;
  v_reply_id UUID;
  v_n INT;
  v_payload JSONB;
  v_event RECORD;
BEGIN
  INSERT INTO organizations (id, name, type, code, is_active) VALUES (v_org, 'Test Org', 'mcs', 'TO98', TRUE);
  INSERT INTO organizations (id, name, type, code, is_active) VALUES (v_org2, 'Other Org', 'mcs', 'OO98', TRUE);
  INSERT INTO commands (id, org_id, name, is_active) VALUES (v_cmd, v_org, 'Cmd', TRUE);
  INSERT INTO departments (id, command_id, name, is_active) VALUES (v_dept, v_cmd, 'Dept', TRUE);
  INSERT INTO sections (id, department_id, org_id, name, code, is_active) VALUES (v_sec_a, v_dept, v_org, 'Sec A', 'SA', TRUE);
  INSERT INTO sections (id, department_id, org_id, name, code, is_active) VALUES (v_sec_b, v_dept, v_org, 'Sec B', 'SB', TRUE);
  INSERT INTO sections (id, department_id, org_id, name, code, is_active) VALUES (v_sec_c, v_dept, v_org, 'Sec C', 'SC', TRUE);

  INSERT INTO auth.users (id, email) VALUES (v_user_a, 'a@t.test'), (v_user_b, 'b@t.test'), (v_user_c, 'c@t.test'), (v_user_sup, 'sup@t.test'), (v_user_outsider, 'out@t.test'), (v_user_c_sup, 'csup@t.test');
  INSERT INTO users (id, org_id, full_name, email, service_number, is_active, is_super_admin)
    VALUES (v_user_a, v_org, 'User A', 'a@t.test', 'SN-A', TRUE, FALSE),
           (v_user_b, v_org, 'User B', 'b@t.test', 'SN-B', TRUE, FALSE),
           (v_user_c, v_org, 'User C', 'c@t.test', 'SN-C', TRUE, FALSE),
           (v_user_sup, v_org, 'User Sup', 'sup@t.test', 'SN-S', TRUE, FALSE),
           (v_user_outsider, v_org, 'User Outsider', 'out@t.test', 'SN-O', TRUE, FALSE),
           (v_user_c_sup, v_org, 'User C Sup', 'csup@t.test', 'SN-CS', TRUE, FALSE);
  INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_active) VALUES
    (v_user_a, 'section', v_sec_a, 'staff', TRUE),
    (v_user_b, 'section', v_sec_b, 'staff', TRUE),
    (v_user_c, 'section', v_sec_c, 'staff', TRUE),
    (v_user_outsider, 'section', v_sec_a, 'staff', TRUE),
    (v_user_sup, 'organization', v_org, 'supervisor', TRUE),
    (v_user_c_sup, 'section', v_sec_c, 'supervisor', TRUE);

  INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, subject, body, status, created_by, reference_number)
    VALUES (v_request_id, v_org, v_org, v_sec_a, 'Parent request', 'body', 'sent', v_user_a, 'REQ-98-1');
  INSERT INTO external_correspondence (id, org_id, subject, subject_language, body, language, status, entered_by, reference_number, source_channel, sender_category, sender_name)
    VALUES (v_entry_id, v_org, 'Parent entry', 'en', 'body', 'en', 'logged', v_user_a, 'ENT-98-1', 'email', 'public', 'Test Sender');

  -- ── Scenario 1: create_internal_request -> internal_collaboration.
  -- routed.v1 -> section(to_section_id) recipient (v_user_b) notified.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text)::text, TRUE);
  SELECT id INTO v_ir_id FROM create_internal_request(v_sec_a, v_sec_b, 'MARKER-SUBJECT-1', 'MARKER-BODY-1', v_request_id, NULL, 'en', 'en', NULL);
  PERFORM process_platform_outbox_batch(50, NULL);

  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='internal_request' AND source_record_id=v_ir_id AND recipient_user_id=v_user_b AND notification_type='internal_collaboration.routed.v1';
  IF v_n <> 1 THEN RAISE EXCEPTION 'S1 FAILED: expected 1 routed.v1 notification for section-B user, got %', v_n; END IF;
  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='internal_request' AND source_record_id=v_ir_id AND recipient_user_id=v_user_c;
  IF v_n <> 0 THEN RAISE EXCEPTION 'S1 FAILED: section-C user should not be notified for a thread routed to section B'; END IF;
  RAISE NOTICE 'S1 PASSED: create_internal_request -> routed.v1 -> section(to) notified';

  -- ── Scenario 2 (safe payload): no marker subject/body text anywhere
  -- in platform_outbox_events.payload, notification_intents.
  -- template_params, or user_notifications.template_params.
  IF EXISTS (SELECT 1 FROM platform_outbox_events WHERE source_record_id=v_ir_id AND payload::text ILIKE '%MARKER-SUBJECT-1%') THEN
    RAISE EXCEPTION 'S2 FAILED: subject leaked into platform_outbox_events.payload';
  END IF;
  IF EXISTS (SELECT 1 FROM platform_outbox_events WHERE source_record_id=v_ir_id AND payload::text ILIKE '%MARKER-BODY-1%') THEN
    RAISE EXCEPTION 'S2 FAILED: body leaked into platform_outbox_events.payload';
  END IF;
  IF EXISTS (SELECT 1 FROM notification_intents WHERE source_record_id=v_ir_id AND template_params::text ILIKE '%MARKER-%') THEN
    RAISE EXCEPTION 'S2 FAILED: marker text leaked into notification_intents.template_params';
  END IF;
  IF EXISTS (SELECT 1 FROM user_notifications WHERE source_record_id=v_ir_id AND template_params::text ILIKE '%MARKER-%') THEN
    RAISE EXCEPTION 'S2 FAILED: marker text leaked into user_notifications.template_params';
  END IF;
  RAISE NOTICE 'S2 PASSED: safe payload discipline (no subject/body leakage)';

  -- ── Scenario 3: reroute_internal_request (supervisor, from a
  -- different section than either A or B) -> internal_collaboration.
  -- routed.v1 -> section(new to) recipient (v_user_c) notified,
  -- section-B user (v_user_b, no longer to_section member post-reroute)
  -- NOT notified for this second event -- dynamic, not snapshotted.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_sup::text)::text, TRUE);
  PERFORM reroute_internal_request(v_ir_id, v_sec_c);
  PERFORM process_platform_outbox_batch(50, NULL);

  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='internal_request' AND source_record_id=v_ir_id AND recipient_user_id=v_user_c AND notification_type='internal_collaboration.routed.v1';
  IF v_n <> 1 THEN RAISE EXCEPTION 'S3 FAILED: expected 1 routed.v1 notification for section-C user after reroute, got %', v_n; END IF;
  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='internal_request' AND source_record_id=v_ir_id AND recipient_user_id=v_user_b AND notification_type='internal_collaboration.routed.v1';
  IF v_n <> 1 THEN RAISE EXCEPTION 'S3 FAILED: section-B user should have exactly 1 routed.v1 (from the original create), not %', v_n; END IF;
  RAISE NOTICE 'S3 PASSED: reroute_internal_request -> routed.v1 -> new section notified, old section not re-notified';

  -- ── Scenario 4: return_internal_request_to_sender -> internal_
  -- collaboration.returned.v1 -> section(origin) recipient (v_user_a)
  -- notified. Caller must be current to_section (v_user_c).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_c::text)::text, TRUE);
  PERFORM return_internal_request_to_sender(v_ir_id, 'MARKER-COMMENT-1');
  PERFORM process_platform_outbox_batch(50, NULL);

  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='internal_request' AND source_record_id=v_ir_id AND recipient_user_id=v_user_a AND notification_type='internal_collaboration.returned.v1';
  IF v_n <> 1 THEN RAISE EXCEPTION 'S4 FAILED: expected 1 returned.v1 notification for origin-section user, got %', v_n; END IF;
  IF EXISTS (SELECT 1 FROM platform_outbox_events WHERE source_record_id=v_ir_id AND payload::text ILIKE '%MARKER-COMMENT-1%') THEN
    RAISE EXCEPTION 'S4 FAILED: comment text leaked into payload';
  END IF;
  RAISE NOTICE 'S4 PASSED: return_internal_request_to_sender -> returned.v1 -> origin section notified, comment excluded from payload';

  -- ── Scenario 5: assign_internal_request(user) -> internal_
  -- collaboration.assigned.v1 -> specific_users([assignee]).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text)::text, TRUE);
  PERFORM assign_internal_request(v_ir_id, v_user_a);
  PERFORM process_platform_outbox_batch(50, NULL);

  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='internal_request' AND source_record_id=v_ir_id AND recipient_user_id=v_user_a AND notification_type='internal_collaboration.assigned.v1';
  IF v_n <> 1 THEN RAISE EXCEPTION 'S5 FAILED: expected 1 assigned.v1 notification for the assignee, got %', v_n; END IF;
  RAISE NOTICE 'S5 PASSED: assign_internal_request(user) -> assigned.v1 -> specific_users(assignee) notified';

  -- ── Scenario 6: assign_internal_request(NULL) (unassignment) fires NO
  -- event -- mirrors the legacy `if (userId)` guard exactly.
  SELECT count(*) INTO v_n FROM platform_outbox_events WHERE source_record_id=v_ir_id AND event_type='internal_collaboration.assigned.v1';
  PERFORM assign_internal_request(v_ir_id, NULL);
  IF (SELECT count(*) FROM platform_outbox_events WHERE source_record_id=v_ir_id AND event_type='internal_collaboration.assigned.v1') <> v_n THEN
    RAISE EXCEPTION 'S6 FAILED: unassignment unexpectedly enqueued an assigned.v1 event';
  END IF;
  RAISE NOTICE 'S6 PASSED: unassignment fires no event';

  -- ── Fresh thread for the reply lifecycle (Scenarios 7-9), created by
  -- v_user_a from section A to section C (v_user_c is the approver's
  -- section-C supervisor equivalent -- reuse v_user_sup, org-wide).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text)::text, TRUE);
  SELECT id INTO v_ir2_id FROM create_internal_request(v_sec_a, v_sec_c, 'Thread 2', 'Body 2', v_request_id, NULL, 'en', 'en', NULL);
  PERFORM process_platform_outbox_batch(50, NULL);

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_c::text)::text, TRUE);
  SELECT id INTO v_reply_id FROM draft_internal_request_reply(v_ir2_id, 'MARKER-REPLY-BODY-1', 'en');
  PERFORM submit_internal_request_reply(v_reply_id, v_user_sup);

  -- ── Scenario 7: approve_internal_request_reply -> internal_
  -- collaboration.reply_sent.v1 TWO-DESCRIPTOR fan-out: section(from_
  -- section_id=A) members (v_user_a, v_user_outsider). The thread
  -- creator here (v_user_a) is ALSO a section-A member -- the second
  -- (specific_users) descriptor must be SKIPPED for this occurrence
  -- (mirroring the legacy askingSide Set's own single-notification-per-
  -- person guarantee), so v_user_a must receive exactly ONE
  -- notification, not two.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_sup::text)::text, TRUE);
  PERFORM approve_internal_request_reply(v_reply_id);
  PERFORM process_platform_outbox_batch(50, NULL);

  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='internal_request' AND source_record_id=v_ir2_id AND recipient_user_id=v_user_outsider AND notification_type='internal_collaboration.reply_sent.v1';
  IF v_n <> 1 THEN RAISE EXCEPTION 'S7 FAILED: expected 1 reply_sent.v1 for section-A member (outsider), got %', v_n; END IF;
  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='internal_request' AND source_record_id=v_ir2_id AND recipient_user_id=v_user_a AND notification_type='internal_collaboration.reply_sent.v1';
  IF v_n <> 1 THEN RAISE EXCEPTION 'S7 FAILED: expected exactly 1 reply_sent.v1 for the thread creator (second descriptor skipped since already a from_section member -- no double notification), got %', v_n; END IF;
  SELECT count(*) INTO v_n FROM notification_intents WHERE source_record_type='internal_request' AND source_record_id=v_ir2_id AND notification_type='internal_collaboration.reply_sent.v1' AND target_type='specific_users';
  IF v_n <> 0 THEN RAISE EXCEPTION 'S7 FAILED: specific_users descriptor should not have been enqueued when the creator is already a from_section member, found %', v_n; END IF;
  IF EXISTS (SELECT 1 FROM platform_outbox_events WHERE source_record_id=v_ir2_id AND payload::text ILIKE '%MARKER-REPLY-BODY-1%') THEN
    RAISE EXCEPTION 'S7 FAILED: reply body leaked into payload';
  END IF;
  RAISE NOTICE 'S7 PASSED: approve_internal_request_reply -> reply_sent.v1 two-descriptor fan-out, second descriptor correctly skipped for an already-covered creator, reply body excluded from payload';

  -- ── Scenario 7b: when the thread creator is NOT a from_section
  -- member (a section-C-scoped supervisor creates a thread on section
  -- A's behalf via the is_supervisor_or_above() bypass, then later
  -- approves a reply routed back to their own section C), the second
  -- (specific_users) descriptor DOES fire and the creator IS notified
  -- -- proving the fan-out is conditional, not simply removed.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_c_sup::text)::text, TRUE);
  DECLARE
    v_ir3_id UUID;
    v_reply3_id UUID;
  BEGIN
    SELECT id INTO v_ir3_id FROM create_internal_request(v_sec_a, v_sec_c, 'Thread 3', 'Body 3', v_request_id, NULL, 'en', 'en', NULL);
    PERFORM process_platform_outbox_batch(50, NULL);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_c::text)::text, TRUE);
    SELECT id INTO v_reply3_id FROM draft_internal_request_reply(v_ir3_id, 'Reply 3 body', 'en');
    PERFORM submit_internal_request_reply(v_reply3_id, v_user_c_sup);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_c_sup::text)::text, TRUE);
    PERFORM approve_internal_request_reply(v_reply3_id);
    PERFORM process_platform_outbox_batch(50, NULL);

    SELECT count(*) INTO v_n FROM notification_intents WHERE source_record_type='internal_request' AND source_record_id=v_ir3_id AND notification_type='internal_collaboration.reply_sent.v1' AND target_type='specific_users';
    IF v_n <> 1 THEN RAISE EXCEPTION 'S7b FAILED: expected the specific_users descriptor to be enqueued when the creator (section-C supervisor) is not a from_section(A) member, got %', v_n; END IF;
    SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='internal_request' AND source_record_id=v_ir3_id AND recipient_user_id=v_user_c_sup AND notification_type='internal_collaboration.reply_sent.v1';
    IF v_n <> 1 THEN RAISE EXCEPTION 'S7b FAILED: expected the non-member creator to be notified via the specific_users descriptor, got %', v_n; END IF;
  END;
  RAISE NOTICE 'S7b PASSED: specific_users descriptor fires when the creator is genuinely not a from_section member';

  -- ── Scenario 8: idempotent replay -- re-running process_platform_
  -- outbox_batch again does not create duplicate user_notifications
  -- (events already 'completed').
  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='internal_request' AND source_record_id=v_ir2_id AND notification_type='internal_collaboration.reply_sent.v1';
  PERFORM process_platform_outbox_batch(50, NULL);
  IF (SELECT count(*) FROM user_notifications WHERE source_record_type='internal_request' AND source_record_id=v_ir2_id AND notification_type='internal_collaboration.reply_sent.v1') <> v_n THEN
    RAISE EXCEPTION 'S8 FAILED: replaying the outbox batch duplicated notifications';
  END IF;
  RAISE NOTICE 'S8 PASSED: idempotent replay (no duplicate notifications on re-drain)';

  -- ── Scenario 9: return_internal_request_reply -> internal_
  -- collaboration.reply_returned.v1 -> specific_users([reply creator]).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_c::text)::text, TRUE);
  SELECT id INTO v_reply_id FROM draft_internal_request_reply(v_ir2_id, 'Second reply body', 'en');
  PERFORM submit_internal_request_reply(v_reply_id, v_user_sup);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_sup::text)::text, TRUE);
  PERFORM return_internal_request_reply(v_reply_id);
  PERFORM process_platform_outbox_batch(50, NULL);

  SELECT count(*) INTO v_n FROM user_notifications WHERE source_record_type='internal_request' AND source_record_id=v_ir2_id AND recipient_user_id=v_user_c AND notification_type='internal_collaboration.reply_returned.v1';
  IF v_n <> 1 THEN RAISE EXCEPTION 'S9 FAILED: expected 1 reply_returned.v1 for the reply drafter, got %', v_n; END IF;
  RAISE NOTICE 'S9 PASSED: return_internal_request_reply -> reply_returned.v1 -> reply creator notified';

  -- ── Scenario 10: deferred RPCs (mark_received, close,
  -- draft/update reply draft, submit_internal_request_reply) fire NO
  -- CAP-003 event.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text)::text, TRUE);
  SELECT count(*) INTO v_n FROM platform_outbox_events;
  PERFORM close_internal_request(v_ir_id);
  IF (SELECT count(*) FROM platform_outbox_events) <> v_n THEN
    RAISE EXCEPTION 'S10 FAILED: a deferred RPC unexpectedly enqueued an event';
  END IF;
  RAISE NOTICE 'S10 PASSED: deferred RPCs (mark_received/close) fire no event';

  -- ── Scenario 11: polymorphic parents (Request vs Entry) don't
  -- collide -- an Internal Collaboration thread anchored to an Entry
  -- case enqueues its own independent event, distinguishable by its own
  -- source_record_id (the thread's own id), never the parent's id.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text)::text, TRUE);
  SELECT id INTO v_ir2_id FROM create_internal_request(v_sec_a, v_sec_b, 'Entry-anchored thread', 'Body', NULL, v_entry_id, 'en', 'en', NULL);
  PERFORM process_platform_outbox_batch(50, NULL);
  SELECT count(*) INTO v_n FROM platform_outbox_events WHERE source_record_type='internal_request' AND source_record_id=v_ir2_id;
  IF v_n <> 1 THEN RAISE EXCEPTION 'S11 FAILED: Entry-anchored thread did not enqueue its own independent event'; END IF;
  IF EXISTS (SELECT 1 FROM platform_outbox_events WHERE source_record_id = v_entry_id) THEN
    RAISE EXCEPTION 'S11 FAILED: an event was unexpectedly enqueued against the PARENT entry id instead of the thread id';
  END IF;
  RAISE NOTICE 'S11 PASSED: Entry-anchored (polymorphic) thread sourced correctly from its own thread id, never the parent id';

  RAISE NOTICE 'ALL BEHAVIORAL SCENARIOS (S1-S11) PASSED';
END $$;
