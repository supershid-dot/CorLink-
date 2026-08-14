-- CAP-003 Phase 1.8B RLS/security test suite. Disposable local
-- PostgreSQL only. Fixtures use the '98100000-' UUID prefix convention.
\set ON_ERROR_STOP on
SET search_path = public;

DO $$
DECLARE
  v_org UUID := '98100000-0000-0000-0000-000000000001';
  v_org2 UUID := '98100000-0000-0000-0000-000000000002'; -- unrelated org
  v_cmd UUID := '98100000-0001-0000-0000-000000000001';
  v_dept UUID := '98100000-0002-0000-0000-000000000001';
  v_sec_a UUID := '98100000-0003-0000-0000-000000000001';
  v_sec_b UUID := '98100000-0003-0000-0000-000000000002';
  v_sec_other_org UUID := '98100000-0003-0000-0000-000000000003';
  v_user_a UUID := '98100000-0004-0000-0000-000000000001'; -- section A member (from_section)
  v_user_sup UUID := '98100000-0004-0000-0000-000000000002'; -- org-wide supervisor
  v_user_plain_staff UUID := '98100000-0004-0000-0000-000000000003'; -- unrelated plain staff, same org, no section overlap
  v_user_other_org UUID := '98100000-0004-0000-0000-000000000004'; -- member of an unrelated org
  v_request_id UUID := '98100000-0005-0000-0000-000000000001';
  v_ir_id UUID;
  v_authorized BOOLEAN;
BEGIN
  INSERT INTO organizations (id, name, type, code, is_active) VALUES (v_org, 'RLS Test Org', 'mcs', 'RT98', TRUE);
  INSERT INTO organizations (id, name, type, code, is_active) VALUES (v_org2, 'RLS Other Org', 'mcs', 'RO98', TRUE);
  INSERT INTO commands (id, org_id, name, is_active) VALUES (v_cmd, v_org, 'Cmd', TRUE);
  INSERT INTO departments (id, command_id, name, is_active) VALUES (v_dept, v_cmd, 'Dept', TRUE);
  INSERT INTO sections (id, department_id, org_id, name, code, is_active) VALUES (v_sec_a, v_dept, v_org, 'Sec A', 'SA', TRUE);
  INSERT INTO sections (id, department_id, org_id, name, code, is_active) VALUES (v_sec_b, v_dept, v_org, 'Sec B', 'SB', TRUE);
  INSERT INTO commands (id, org_id, name, is_active) VALUES ('98100000-0001-0000-0000-000000000002', v_org2, 'Cmd2', TRUE);
  INSERT INTO departments (id, command_id, name, is_active) VALUES ('98100000-0002-0000-0000-000000000002', '98100000-0001-0000-0000-000000000002', 'Dept2', TRUE);
  INSERT INTO sections (id, department_id, org_id, name, code, is_active) VALUES (v_sec_other_org, '98100000-0002-0000-0000-000000000002', v_org2, 'Sec Other Org', 'SO', TRUE);

  INSERT INTO auth.users (id, email) VALUES (v_user_a, 'a@rls.test'), (v_user_sup, 'sup@rls.test'), (v_user_plain_staff, 'plain@rls.test'), (v_user_other_org, 'other@rls.test');
  INSERT INTO users (id, org_id, full_name, email, service_number, is_active, is_super_admin)
    VALUES (v_user_a, v_org, 'User A', 'a@rls.test', 'SN-RLS-A', TRUE, FALSE),
           (v_user_sup, v_org, 'User Sup', 'sup@rls.test', 'SN-RLS-S', TRUE, FALSE),
           (v_user_plain_staff, v_org, 'Plain Staff', 'plain@rls.test', 'SN-RLS-P', TRUE, FALSE),
           (v_user_other_org, v_org2, 'Other Org User', 'other@rls.test', 'SN-RLS-O', TRUE, FALSE);
  INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_active) VALUES
    (v_user_a, 'section', v_sec_a, 'staff', TRUE),
    (v_user_sup, 'organization', v_org, 'supervisor', TRUE),
    (v_user_plain_staff, 'section', v_sec_b, 'staff', TRUE), -- section B, unrelated to the thread below
    (v_user_other_org, 'section', v_sec_other_org, 'staff', TRUE);

  INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, subject, body, status, created_by, reference_number)
    VALUES (v_request_id, v_org, v_org, v_sec_a, 'Parent request', 'body', 'sent', v_user_a, 'REQ-RLS-1');

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text)::text, TRUE);
  SELECT id INTO v_ir_id FROM create_internal_request(v_sec_a, v_sec_a, 'RLS thread', 'body', v_request_id, NULL, 'en', 'en', NULL);
  -- (to_section = from_section here deliberately, so only v_user_a/v_user_sup are "in" by direct membership -- the thread never touches section B or the other org.)

  -- ── R1: creator can view (created_by branch). ────────────────────────
  SELECT intent_user_can_view_internal_request(v_ir_id, v_user_a) INTO v_authorized;
  IF NOT v_authorized THEN RAISE EXCEPTION 'R1 FAILED: creator should be authorized to view'; END IF;
  RAISE NOTICE 'R1 PASSED: creator authorized via created_by branch';

  -- ── R2: org-wide admin/supervisor bypass IS present -- matching
  -- internal_requests_select's real RLS (the OPPOSITE of Entry's own
  -- no-bypass adapter). v_user_sup is neither a section member nor the
  -- creator, only an org-wide supervisor. ─────────────────────────────
  SELECT intent_user_can_view_internal_request(v_ir_id, v_user_sup) INTO v_authorized;
  IF NOT v_authorized THEN RAISE EXCEPTION 'R2 FAILED: org-wide supervisor bypass should authorize (matching real internal_requests_select RLS)'; END IF;
  RAISE NOTICE 'R2 PASSED: admin/supervisor bypass present, matching real RLS';

  -- ── R3: plain-staff negative control -- a same-org user with NO
  -- section overlap, not the creator, not a supervisor, must be denied.
  SELECT intent_user_can_view_internal_request(v_ir_id, v_user_plain_staff) INTO v_authorized;
  IF v_authorized THEN RAISE EXCEPTION 'R3 FAILED: unrelated same-org plain staff must NOT be authorized'; END IF;
  RAISE NOTICE 'R3 PASSED: unrelated plain staff correctly denied';

  -- ── R4: cross-org isolation -- a member of a completely different
  -- organization must never be authorized, even indirectly. ───────────
  SELECT intent_user_can_view_internal_request(v_ir_id, v_user_other_org) INTO v_authorized;
  IF v_authorized THEN RAISE EXCEPTION 'R4 FAILED: cross-org user must NOT be authorized'; END IF;
  RAISE NOTICE 'R4 PASSED: cross-org isolation preserved';

  -- ── R5: adapter is not directly invocable by ordinary roles. ─────────
  IF has_function_privilege('authenticated', 'intent_user_can_view_internal_request(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'R5 FAILED: intent_user_can_view_internal_request should not be EXECUTE-granted to authenticated';
  END IF;
  IF has_function_privilege('anon', 'intent_user_can_view_internal_request(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'R5 FAILED: intent_user_can_view_internal_request should not be EXECUTE-granted to anon';
  END IF;
  RAISE NOTICE 'R5 PASSED: adapter not directly invocable by ordinary roles';

  -- ── R6: no direct authenticated write path to platform_outbox_events/
  -- notification_intents/user_notifications was opened by this
  -- milestone (RLS enabled, zero policies, matching every prior CAP-003
  -- table's own posture). ──────────────────────────────────────────────
  IF has_table_privilege('authenticated', 'public.platform_outbox_events', 'INSERT') THEN
    RAISE EXCEPTION 'R6 FAILED: authenticated should not have direct INSERT on platform_outbox_events';
  END IF;
  IF has_table_privilege('authenticated', 'public.notification_intents', 'INSERT') THEN
    RAISE EXCEPTION 'R6 FAILED: authenticated should not have direct INSERT on notification_intents';
  END IF;
  IF has_table_privilege('authenticated', 'public.user_notifications', 'INSERT') THEN
    RAISE EXCEPTION 'R6 FAILED: authenticated should not have direct INSERT on user_notifications';
  END IF;
  RAISE NOTICE 'R6 PASSED: no direct authenticated write path to outbox/intents/notifications tables';

  -- ── R7: worker (process_platform_outbox_batch) not directly
  -- executable by ordinary roles. ──────────────────────────────────────
  IF has_function_privilege('authenticated', 'process_platform_outbox_batch(integer,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'R7 FAILED: process_platform_outbox_batch should not be EXECUTE-granted to authenticated';
  END IF;
  RAISE NOTICE 'R7 PASSED: worker not directly invocable by ordinary roles';

  -- ── R8: unauthorized mutation -- an unrelated plain-staff user cannot
  -- reroute/assign/return this thread (Phase 1.8A's own authorization,
  -- untouched by this milestone). ──────────────────────────────────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_plain_staff::text)::text, TRUE);
  BEGIN
    PERFORM reroute_internal_request(v_ir_id, v_sec_b);
    RAISE EXCEPTION 'R8 FAILED: unrelated plain staff should not be able to reroute this thread';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%Not authorized%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'R8 PASSED: unrelated plain staff correctly denied mutation (Phase 1.8A authorization intact)';

  -- ── R9: end-to-end late-authorization revalidation -- resolve_
  -- notification_intent() re-checks the adapter per candidate at
  -- resolution time (not merely at enqueue time). Directly exercised via
  -- create_notification_intent()/resolve_notification_intent() with a
  -- synthetic outbox event whose target includes both an authorized and
  -- an unauthorized candidate. ─────────────────────────────────────────
  DECLARE
    v_event_id UUID;
    v_intent_id UUID;
    v_resolved INT;
    v_skipped INT;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text)::text, TRUE);
    v_event_id := platform_enqueue_outbox_event(
      'internal_collaboration.routed.v1', 'internal_collaboration', 'internal_request', v_ir_id, v_org, v_user_a,
      gen_random_uuid(), NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'internal_collaboration.routed.v1', 'title_template_key', 'internal_collaboration.routed',
        'template_params', '{}'::jsonb, 'priority', 'normal',
        'target_type', 'specific_users', 'target_user_ids', jsonb_build_array(v_user_a, v_user_plain_staff)
      ),
      gen_random_uuid()
    );
    v_intent_id := create_notification_intent(
      v_event_id, 'internal_collaboration.routed.v1', 'internal_collaboration.routed', '{}'::jsonb, 'normal',
      'specific_users', ARRAY[v_user_a, v_user_plain_staff]::uuid[], NULL, NULL, NULL, NULL, NULL, NULL
    );
    SELECT r.resolved_count, r.skipped_count INTO v_resolved, v_skipped FROM resolve_notification_intent(v_intent_id) r;
    IF v_resolved <> 1 OR v_skipped <> 1 THEN
      RAISE EXCEPTION 'R9 FAILED: expected exactly 1 resolved (authorized creator) and 1 skipped (unauthorized plain staff), got resolved=%, skipped=%', v_resolved, v_skipped;
    END IF;
    IF EXISTS (SELECT 1 FROM user_notifications WHERE recipient_user_id = v_user_plain_staff AND source_record_id = v_ir_id) THEN
      RAISE EXCEPTION 'R9 FAILED: unauthorized candidate must never receive a user_notifications row';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM user_notifications WHERE recipient_user_id = v_user_a AND source_record_id = v_ir_id AND outbox_event_id = v_event_id) THEN
      RAISE EXCEPTION 'R9 FAILED: authorized candidate should have received a user_notifications row';
    END IF;
  END;
  RAISE NOTICE 'R9 PASSED: late-authorization revalidation filters an unauthorized candidate out of a mixed target list, never writes them a notification';

  RAISE NOTICE 'ALL RLS/SECURITY SCENARIOS (R1-R9) PASSED';
END $$;
