-- CAP-003 Phase 1.9B RLS/security test suite. Disposable local
-- PostgreSQL only. Fixtures use the '99100000-' UUID prefix
-- convention.
\set ON_ERROR_STOP on
SET search_path = public;

DO $$
DECLARE
  v_org_p UUID := '99100000-0000-0000-0000-000000000001'; -- MCS prison org
  v_org_q UUID := '99100000-0000-0000-0000-000000000002'; -- authority org (destination)
  v_org_r UUID := '99100000-0000-0000-0000-000000000003'; -- unrelated authority org
  v_cmd_p UUID := '99100000-0001-0000-0000-000000000001';
  v_cmd_q UUID := '99100000-0001-0000-0000-000000000002';
  v_cmd_r UUID := '99100000-0001-0000-0000-000000000003';
  v_dept_p UUID := '99100000-0002-0000-0000-000000000001';
  v_dept_q UUID := '99100000-0002-0000-0000-000000000002';
  v_dept_r UUID := '99100000-0002-0000-0000-000000000003';
  v_sec_p UUID := '99100000-0003-0000-0000-000000000001';
  v_sec_q UUID := '99100000-0003-0000-0000-000000000002';
  v_sec_r UUID := '99100000-0003-0000-0000-000000000003';
  v_mcs_submitter UUID := '99100000-0004-0000-0000-000000000001'; -- submitted_by
  v_mcs_other UUID := '99100000-0004-0000-0000-000000000002'; -- same org, flagged, NOT the submitter, NOT a supervisor
  v_mcs_super UUID := '99100000-0004-0000-0000-000000000003'; -- MCS-side supervisor, NOT flagged
  v_assignee UUID := '99100000-0004-0000-0000-000000000004'; -- assigned_to
  v_auth_other UUID := '99100000-0004-0000-0000-000000000005'; -- same authority org, flagged, NOT the assignee, NOT a supervisor
  v_auth_super UUID := '99100000-0004-0000-0000-000000000006'; -- authority-side supervisor, NOT flagged
  v_other_org_user UUID := '99100000-0004-0000-0000-000000000007'; -- unrelated authority org R, flagged
  v_prisoner_id UUID := '99100000-0005-0000-0000-000000000001';
  v_letter_id UUID;
  v_authorized BOOLEAN;
BEGIN
  INSERT INTO organizations (id, name, type, code, is_active) VALUES
    (v_org_p, 'RLS Prison Org', 'mcs', 'RP99', TRUE),
    (v_org_q, 'RLS Authority Org', 'authority', 'RQ99', TRUE),
    (v_org_r, 'RLS Unrelated Authority Org', 'authority', 'RR99', TRUE);
  INSERT INTO commands (id, org_id, name, is_active) VALUES (v_cmd_p, v_org_p, 'Cmd P', TRUE), (v_cmd_q, v_org_q, 'Cmd Q', TRUE), (v_cmd_r, v_org_r, 'Cmd R', TRUE);
  INSERT INTO departments (id, command_id, name, is_active) VALUES (v_dept_p, v_cmd_p, 'Dept P', TRUE), (v_dept_q, v_cmd_q, 'Dept Q', TRUE), (v_dept_r, v_cmd_r, 'Dept R', TRUE);
  INSERT INTO sections (id, department_id, org_id, name, code, is_active) VALUES
    (v_sec_p, v_dept_p, v_org_p, 'Sec P', 'SP', TRUE),
    (v_sec_q, v_dept_q, v_org_q, 'Sec Q', 'SQ', TRUE),
    (v_sec_r, v_dept_r, v_org_r, 'Sec R', 'SR', TRUE);

  INSERT INTO auth.users (id, email) VALUES
    (v_mcs_submitter, 'pl99sub@rls.test'), (v_mcs_other, 'pl99mcsother@rls.test'), (v_mcs_super, 'pl99mcssup@rls.test'),
    (v_assignee, 'pl99assignee@rls.test'), (v_auth_other, 'pl99authother@rls.test'), (v_auth_super, 'pl99authsup@rls.test'),
    (v_other_org_user, 'pl99other@rls.test');
  INSERT INTO users (id, org_id, full_name, email, service_number, is_active, is_super_admin, is_prisoner_letters_staff)
    VALUES
      (v_mcs_submitter, v_org_p, 'MCS Submitter', 'pl99sub@rls.test', 'SN-1', TRUE, FALSE, TRUE),
      (v_mcs_other, v_org_p, 'MCS Other', 'pl99mcsother@rls.test', 'SN-2', TRUE, FALSE, TRUE),
      (v_mcs_super, v_org_p, 'MCS Supervisor', 'pl99mcssup@rls.test', 'SN-3', TRUE, FALSE, FALSE),
      (v_assignee, v_org_q, 'Assignee', 'pl99assignee@rls.test', 'SN-4', TRUE, FALSE, TRUE),
      (v_auth_other, v_org_q, 'Authority Other', 'pl99authother@rls.test', 'SN-5', TRUE, FALSE, TRUE),
      (v_auth_super, v_org_q, 'Authority Supervisor', 'pl99authsup@rls.test', 'SN-6', TRUE, FALSE, FALSE),
      (v_other_org_user, v_org_r, 'Other Org User', 'pl99other@rls.test', 'SN-7', TRUE, FALSE, TRUE);
  INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_active) VALUES
    (v_mcs_submitter, 'section', v_sec_p, 'staff', TRUE),
    (v_mcs_other, 'section', v_sec_p, 'staff', TRUE),
    (v_mcs_super, 'organization', v_org_p, 'supervisor', TRUE),
    (v_assignee, 'section', v_sec_q, 'staff', TRUE),
    (v_auth_other, 'section', v_sec_q, 'staff', TRUE),
    (v_auth_super, 'organization', v_org_q, 'supervisor', TRUE),
    (v_other_org_user, 'section', v_sec_r, 'staff', TRUE);

  INSERT INTO prisoners (id, org_id, file_number, id_card_number, full_name, address, prison) VALUES
    (v_prisoner_id, v_org_p, 'FILE-RLS-1', 'RLS-INMATE-1', 'RLS Test Inmate', 'Test Address', 'Maafushi Prison');

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_mcs_submitter::text)::text, TRUE);
  SELECT id INTO v_letter_id FROM create_prisoner_letter(v_prisoner_id, v_org_p, v_org_q, 'RLS test body');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_auth_super::text)::text, TRUE);
  PERFORM route_prisoner_letter(v_letter_id, v_sec_q, v_assignee);

  -- ── R1: the submitter (MCS side) can view. ───────────────────────────
  SELECT intent_user_can_view_prisoner_letter(v_letter_id, v_mcs_submitter) INTO v_authorized;
  IF NOT v_authorized THEN RAISE EXCEPTION 'R1 FAILED: the submitter should be authorized to view'; END IF;
  RAISE NOTICE 'R1 PASSED: submitter authorized via submitted_by branch';

  -- ── R2: the assignee (authority side) can view. ──────────────────────
  SELECT intent_user_can_view_prisoner_letter(v_letter_id, v_assignee) INTO v_authorized;
  IF NOT v_authorized THEN RAISE EXCEPTION 'R2 FAILED: the assignee should be authorized to view'; END IF;
  RAISE NOTICE 'R2 PASSED: assignee authorized via assigned_to branch';

  -- ── R3: MCS-side supervisor/admin oversight bypass IS present --
  -- independent of the is_prisoner_letters_staff flag, matching the NEW
  -- (Phase 1.9A / docs/96) narrowed access model exactly. ──────────────
  SELECT intent_user_can_view_prisoner_letter(v_letter_id, v_mcs_super) INTO v_authorized;
  IF NOT v_authorized THEN RAISE EXCEPTION 'R3 FAILED: MCS-side supervisor oversight bypass should authorize'; END IF;
  RAISE NOTICE 'R3 PASSED: MCS-side supervisor/admin oversight bypass present, independent of the staff flag';

  -- ── R4: authority-side supervisor/admin oversight bypass IS present. ──
  SELECT intent_user_can_view_prisoner_letter(v_letter_id, v_auth_super) INTO v_authorized;
  IF NOT v_authorized THEN RAISE EXCEPTION 'R4 FAILED: authority-side supervisor oversight bypass should authorize'; END IF;
  RAISE NOTICE 'R4 PASSED: authority-side supervisor/admin oversight bypass present';

  -- ── R5: a flagged MCS staffer who is NOT the submitter and NOT a
  -- supervisor must be denied -- this is the exact narrowing Decision A
  -- introduced (the old model would have authorized this). ─────────────
  SELECT intent_user_can_view_prisoner_letter(v_letter_id, v_mcs_other) INTO v_authorized;
  IF v_authorized THEN RAISE EXCEPTION 'R5 FAILED: a flagged non-submitter, non-supervisor MCS staffer must NOT be authorized'; END IF;
  RAISE NOTICE 'R5 PASSED: non-submitter, non-supervisor MCS staffer correctly denied';

  -- ── R6: a flagged authority staffer who is NOT the assignee and NOT a
  -- supervisor must be denied (same narrowing, authority side). ────────
  SELECT intent_user_can_view_prisoner_letter(v_letter_id, v_auth_other) INTO v_authorized;
  IF v_authorized THEN RAISE EXCEPTION 'R6 FAILED: a flagged non-assignee, non-supervisor authority staffer must NOT be authorized'; END IF;
  RAISE NOTICE 'R6 PASSED: non-assignee, non-supervisor authority staffer correctly denied';

  -- ── R7: cross-org isolation -- an unrelated authority org (org R) has
  -- zero visibility, even though its member holds the staff flag. ──────
  SELECT intent_user_can_view_prisoner_letter(v_letter_id, v_other_org_user) INTO v_authorized;
  IF v_authorized THEN RAISE EXCEPTION 'R7 FAILED: an unrelated organization''s member must NOT be authorized'; END IF;
  RAISE NOTICE 'R7 PASSED: cross-org isolation preserved';

  -- ── R8: adapter is not directly invocable by ordinary roles. ─────────
  IF has_function_privilege('authenticated', 'intent_user_can_view_prisoner_letter(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'R8 FAILED: intent_user_can_view_prisoner_letter should not be EXECUTE-granted to authenticated';
  END IF;
  IF has_function_privilege('anon', 'intent_user_can_view_prisoner_letter(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'R8 FAILED: intent_user_can_view_prisoner_letter should not be EXECUTE-granted to anon';
  END IF;
  RAISE NOTICE 'R8 PASSED: adapter not directly invocable by ordinary roles';

  -- ── R9: no direct authenticated write path to platform_outbox_events/
  -- notification_intents/user_notifications was opened by this milestone. ─
  IF has_table_privilege('authenticated', 'public.platform_outbox_events', 'INSERT') THEN
    RAISE EXCEPTION 'R9 FAILED: authenticated should not have direct INSERT on platform_outbox_events';
  END IF;
  IF has_table_privilege('authenticated', 'public.notification_intents', 'INSERT') THEN
    RAISE EXCEPTION 'R9 FAILED: authenticated should not have direct INSERT on notification_intents';
  END IF;
  IF has_table_privilege('authenticated', 'public.user_notifications', 'INSERT') THEN
    RAISE EXCEPTION 'R9 FAILED: authenticated should not have direct INSERT on user_notifications';
  END IF;
  RAISE NOTICE 'R9 PASSED: no direct authenticated write path to outbox/intents/notifications tables';

  -- ── R10: worker not directly executable by ordinary roles. ───────────
  IF has_function_privilege('authenticated', 'process_platform_outbox_batch(integer,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'R10 FAILED: process_platform_outbox_batch should not be EXECUTE-granted to authenticated';
  END IF;
  RAISE NOTICE 'R10 PASSED: worker not directly invocable by ordinary roles';

  -- ── R11: authority side cannot create a prisoner letter (Phase 1.9A's
  -- own directionality, untouched by this milestone). ──────────────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_assignee::text)::text, TRUE);
  BEGIN
    PERFORM create_prisoner_letter(v_prisoner_id, v_org_q, v_org_q, 'sneaky');
    RAISE EXCEPTION 'R11 FAILED: authority side should not be able to create a prisoner letter';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%Not authorized%' AND SQLERRM NOT ILIKE '%MCS organization%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'R11 PASSED: authority side correctly denied letter creation (Phase 1.9A directionality intact)';

  -- ── R12: Prisoner Letters direct table writes remain closed
  -- (Phase 1.9A's own closure, untouched by this milestone). ───────────
  IF has_table_privilege('authenticated', 'public.prisoner_letters', 'INSERT') THEN
    RAISE EXCEPTION 'R12 FAILED: authenticated should not have direct INSERT on prisoner_letters';
  END IF;
  IF has_table_privilege('authenticated', 'public.prisoner_letters', 'UPDATE') THEN
    RAISE EXCEPTION 'R12 FAILED: authenticated should not have direct UPDATE on prisoner_letters';
  END IF;
  IF has_table_privilege('authenticated', 'public.prisoner_replies', 'INSERT') THEN
    RAISE EXCEPTION 'R12 FAILED: authenticated should not have direct INSERT on prisoner_replies';
  END IF;
  RAISE NOTICE 'R12 PASSED: Prisoner Letters direct-write closure intact';

  -- ── R13: end-to-end late-authorization revalidation -- resolve_
  -- notification_intent() re-checks the adapter per candidate at
  -- resolution time. A synthetic outbox event whose target includes both
  -- an authorized (assignee) and an unauthorized (unrelated org R)
  -- candidate must resolve to exactly one delivered notification. ──────
  DECLARE
    v_event_id UUID;
    v_intent_id UUID;
    v_resolved INT;
    v_skipped INT;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_assignee::text)::text, TRUE);
    v_event_id := platform_enqueue_outbox_event(
      'prisoner_letter.assigned.v1', 'prisoner_letters', 'prisoner_letter', v_letter_id, v_org_q, v_assignee,
      gen_random_uuid(), NULL, NOW(),
      jsonb_build_object(
        'notification_type', 'prisoner_letter.assigned.v1', 'title_template_key', 'prisoner_letter.assigned',
        'template_params', '{}'::jsonb, 'priority', 'normal',
        'target_type', 'specific_users', 'target_user_ids', jsonb_build_array(v_assignee, v_other_org_user)
      ),
      gen_random_uuid()
    );
    v_intent_id := create_notification_intent(
      v_event_id, 'prisoner_letter.assigned.v1', 'prisoner_letter.assigned', '{}'::jsonb, 'normal',
      'specific_users', ARRAY[v_assignee, v_other_org_user]::uuid[], NULL, NULL, NULL, NULL, NULL, NULL
    );
    SELECT r.resolved_count, r.skipped_count INTO v_resolved, v_skipped FROM resolve_notification_intent(v_intent_id) r;
    IF v_resolved <> 1 OR v_skipped <> 1 THEN
      RAISE EXCEPTION 'R13 FAILED: expected exactly 1 resolved (authorized assignee) and 1 skipped (unauthorized cross-org candidate), got resolved=%, skipped=%', v_resolved, v_skipped;
    END IF;
    IF EXISTS (SELECT 1 FROM user_notifications WHERE recipient_user_id = v_other_org_user AND source_record_id = v_letter_id) THEN
      RAISE EXCEPTION 'R13 FAILED: unauthorized cross-org candidate must never receive a user_notifications row';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM user_notifications WHERE recipient_user_id = v_assignee AND source_record_id = v_letter_id AND outbox_event_id = v_event_id) THEN
      RAISE EXCEPTION 'R13 FAILED: authorized assignee should have received a user_notifications row';
    END IF;
  END;
  RAISE NOTICE 'R13 PASSED: late-authorization revalidation filters an unauthorized cross-org candidate out of a mixed target list';

  RAISE NOTICE 'ALL RLS/SECURITY SCENARIOS (R1-R13) PASSED';
END $$;
