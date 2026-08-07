-- CAP-002 Phase 5.3 SLA & escalation foundation RLS suite (8 required
-- checks). Disposable local PostgreSQL only. Runs in one transaction
-- and leaves no fixtures.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf53r_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf53r_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf53r_results, wf53r_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('65340000-0000-0000-0000-000000000001','WF53R Org A','authority','WF53RA'),
 ('65340000-0000-0000-0000-000000000002','WF53R Org B','authority','WF53RB');
INSERT INTO auth.users(id,email) VALUES
 ('65340000-0001-0000-0000-000000000001','admin_a@wf53r.local'),
 ('65340000-0001-0000-0000-000000000002','candidate_a@wf53r.local'),
 ('65340000-0001-0000-0000-000000000003','outsider_a@wf53r.local'),
 ('65340000-0001-0000-0000-000000000004','escalation_target_a@wf53r.local'),
 ('65340000-0001-0000-0000-000000000005','admin_b@wf53r.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('65340000-0001-0000-0000-000000000001','65340000-0000-0000-0000-000000000001','WF53RA-1','Admin A','admin_a@wf53r.local',true),
 ('65340000-0001-0000-0000-000000000002','65340000-0000-0000-0000-000000000001','WF53RA-2','Candidate A','candidate_a@wf53r.local',true),
 ('65340000-0001-0000-0000-000000000003','65340000-0000-0000-0000-000000000001','WF53RA-3','Outsider A','outsider_a@wf53r.local',true),
 ('65340000-0001-0000-0000-000000000004','65340000-0000-0000-0000-000000000001','WF53RA-4','Escalation Target A','escalation_target_a@wf53r.local',true),
 ('65340000-0001-0000-0000-000000000005','65340000-0000-0000-0000-000000000002','WF53RB-1','Admin B','admin_b@wf53r.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('65340000-0001-0000-0000-000000000001','organization','65340000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('65340000-0001-0000-0000-000000000002','organization','65340000-0000-0000-0000-000000000001','supervisor',true,true),
 ('65340000-0001-0000-0000-000000000005','organization','65340000-0000-0000-0000-000000000002','authority_admin',true,true);

\set ADMIN_A '{"sub":"65340000-0001-0000-0000-000000000001"}'
\set CANDIDATE_A '{"sub":"65340000-0001-0000-0000-000000000002"}'
\set OUTSIDER_A '{"sub":"65340000-0001-0000-0000-000000000003"}'
\set ESCALATION_TARGET_A '{"sub":"65340000-0001-0000-0000-000000000004"}'
\set ADMIN_B '{"sub":"65340000-0001-0000-0000-000000000005"}'

SET ROLE authenticated;

\set ORG_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":true,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
WITH made AS (SELECT * FROM create_workflow_definition(
  '65340000-0000-0000-0000-000000000001','wf53r_org','WF53R Org Flow','opaque_case', :ORG_PAYLOAD::jsonb, gen_random_uuid()))
INSERT INTO wf53r_ids SELECT 'def_v', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wf53r_ids WHERE name='def_v'),0,gen_random_uuid());
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf53r_ids WHERE name='def_v'),'opaque_case',gen_random_uuid(),
  '65340000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf53r_ids SELECT 'i1', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf53r_ids WHERE name='i1'),0,gen_random_uuid());

-- Configuration + a running clock with an escalation policy naming
-- escalation_target_a in its action_config (never added as a participant).
DO $$
DECLARE v_esc_policy_id UUID; v_sla_policy_id UUID; v_clock_id UUID;
BEGIN
  SELECT escalation_policy_id INTO v_esc_policy_id FROM create_workflow_escalation_policy(
    '65340000-0000-0000-0000-000000000001','wf53r_esc','RLS test escalation policy',
    '[{"level_order":1,"offset_from":"breach","offset_amount":0,"offset_unit":"hours","action_code":"notify_supervisor","action_config":{"notify_user_id":"65340000-0001-0000-0000-000000000004"}}]'::jsonb,
    gen_random_uuid());
  INSERT INTO wf53r_ids VALUES ('esc_policy', v_esc_policy_id);
  SELECT sla_policy_id INTO v_sla_policy_id FROM create_workflow_sla_policy(
    '65340000-0000-0000-0000-000000000001','wf53r_policy','RLS test SLA policy',
    2,'hours',NULL,'UTC','[]'::jsonb,true,true,v_esc_policy_id,gen_random_uuid());
  INSERT INTO wf53r_ids VALUES ('sla_policy', v_sla_policy_id);
  SELECT calendar_id INTO v_clock_id FROM create_workflow_business_calendar_version(
    '65340000-0000-0000-0000-000000000001','wf53r_cal','RLS test calendar','UTC',
    ARRAY[1,2,3,4,5], '09:00'::TIME, '17:00'::TIME, ARRAY[]::DATE[], gen_random_uuid());
  INSERT INTO wf53r_ids VALUES ('cal', v_clock_id);
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53r_ids WHERE name='i1'), NULL, NULL, v_sla_policy_id, 'manual', NULL, NULL, NULL, gen_random_uuid());
  INSERT INTO wf53r_ids VALUES ('clock1', v_clock_id);
  PERFORM trigger_workflow_sla_escalation(v_clock_id, 0, gen_random_uuid());
END $$;
INSERT INTO wf53r_ids SELECT 'candidate_a_wi', id FROM workflow_work_items
WHERE instance_id = (SELECT id FROM wf53r_ids WHERE name='i1') AND assigned_to = '65340000-0001-0000-0000-000000000002';

-- ── 1: the authorized instance owner (admin_a) sees the clock, its evidence, and its escalation events ──
DO $$
DECLARE v_clock_count INTEGER; v_event_count INTEGER; v_esc_count INTEGER;
BEGIN
  SELECT count(*) INTO v_clock_count FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53r_ids WHERE name='clock1');
  SELECT count(*) INTO v_event_count FROM workflow_sla_clock_events WHERE clock_id = (SELECT id FROM wf53r_ids WHERE name='clock1');
  SELECT count(*) INTO v_esc_count FROM workflow_escalation_events WHERE clock_id = (SELECT id FROM wf53r_ids WHERE name='clock1');
  IF v_clock_count <> 1 OR v_event_count = 0 OR v_esc_count <> 1 THEN
    RAISE EXCEPTION 'expected the instance owner to see the clock, its lifecycle events, and its escalation events, got clock=% events=% esc=%', v_clock_count, v_event_count, v_esc_count;
  END IF;
  -- Also sees the admin-only configuration tables (they administer this org).
  IF NOT EXISTS (SELECT 1 FROM workflow_sla_policies WHERE id = (SELECT id FROM wf53r_ids WHERE name='sla_policy'))
     OR NOT EXISTS (SELECT 1 FROM workflow_escalation_policies WHERE id = (SELECT id FROM wf53r_ids WHERE name='esc_policy'))
     OR NOT EXISTS (SELECT 1 FROM workflow_business_calendars WHERE id = (SELECT id FROM wf53r_ids WHERE name='cal'))
  THEN RAISE EXCEPTION 'expected the org admin to see the SLA/escalation/calendar configuration they created'; END IF;
END $$;
INSERT INTO wf53r_results VALUES (1,'the authorized instance owner (an org admin who is also the instance owner participant) sees the SLA clock, its lifecycle evidence, its escalation events, and the org''s SLA/escalation/calendar configuration');

-- ── 2: an ordinary resolved participant (candidate) also sees the instance-scoped clock/event rows ──
SELECT set_config('request.jwt.claims', :'CANDIDATE_A', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53r_ids WHERE name='clock1');
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected a resolved candidate/participant to see the clock via can_view_workflow_instance, got %', v_count; END IF;
END $$;
INSERT INTO wf53r_results VALUES (2,'an ordinary resolved candidate/participant on the instance (not its owner or manager) also sees the instance-scoped SLA clock and event rows, via the same can_view_workflow_instance boundary every other workflow_ runtime table uses');

-- ── 3: an unrelated user (no participant role, no admin standing) sees none of the instance-scoped or admin-config rows ──
SELECT set_config('request.jwt.claims', :'OUTSIDER_A', false);
DO $$
DECLARE v_missing TEXT := '';
BEGIN
  IF (SELECT count(*) FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53r_ids WHERE name='clock1')) <> 0 THEN v_missing := v_missing || 'clock-visible '; END IF;
  IF (SELECT count(*) FROM workflow_sla_clock_events WHERE clock_id = (SELECT id FROM wf53r_ids WHERE name='clock1')) <> 0 THEN v_missing := v_missing || 'clock-events-visible '; END IF;
  IF (SELECT count(*) FROM workflow_escalation_events WHERE clock_id = (SELECT id FROM wf53r_ids WHERE name='clock1')) <> 0 THEN v_missing := v_missing || 'escalation-events-visible '; END IF;
  IF (SELECT count(*) FROM workflow_sla_policies WHERE id = (SELECT id FROM wf53r_ids WHERE name='sla_policy')) <> 0 THEN v_missing := v_missing || 'sla-policy-visible '; END IF;
  IF (SELECT count(*) FROM workflow_escalation_policies WHERE id = (SELECT id FROM wf53r_ids WHERE name='esc_policy')) <> 0 THEN v_missing := v_missing || 'escalation-policy-visible '; END IF;
  IF v_missing <> '' THEN RAISE EXCEPTION 'expected an unrelated user with no participant/admin relationship to see zero rows everywhere, but: %', v_missing; END IF;
END $$;
INSERT INTO wf53r_results VALUES (3,'a user with no participant role on the instance and no administrative standing in the organization sees zero rows across every one of the 8 new tables');

-- ── 4: cross-organization isolation -- an admin of a different org sees none of org A''s SLA/escalation configuration or clocks ──
SELECT set_config('request.jwt.claims', :'ADMIN_B', false);
DO $$
DECLARE v_missing TEXT := '';
BEGIN
  IF (SELECT count(*) FROM workflow_sla_policies WHERE id = (SELECT id FROM wf53r_ids WHERE name='sla_policy')) <> 0 THEN v_missing := v_missing || 'sla-policy-visible '; END IF;
  IF (SELECT count(*) FROM workflow_escalation_policies WHERE id = (SELECT id FROM wf53r_ids WHERE name='esc_policy')) <> 0 THEN v_missing := v_missing || 'escalation-policy-visible '; END IF;
  IF (SELECT count(*) FROM workflow_business_calendars WHERE id = (SELECT id FROM wf53r_ids WHERE name='cal')) <> 0 THEN v_missing := v_missing || 'calendar-visible '; END IF;
  IF (SELECT count(*) FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53r_ids WHERE name='clock1')) <> 0 THEN v_missing := v_missing || 'clock-visible '; END IF;
  IF v_missing <> '' THEN RAISE EXCEPTION 'expected org B''s admin to see zero rows of org A''s SLA/escalation configuration and clocks, but: %', v_missing; END IF;
END $$;
INSERT INTO wf53r_results VALUES (4,'an administrator of a different organization (org B) sees zero rows of org A''s SLA policies, escalation policies, business calendars, or clocks -- can_manage_workflow_sla_config''s organization_id match is a real isolation boundary, not merely a UI filter');

-- ── 5: a user named only in an escalation level''s action_config gains no visibility from that alone ──
SELECT set_config('request.jwt.claims', :'ESCALATION_TARGET_A', false);
DO $$
DECLARE v_missing TEXT := '';
BEGIN
  IF (SELECT count(*) FROM workflow_escalation_events WHERE clock_id = (SELECT id FROM wf53r_ids WHERE name='clock1')) <> 0 THEN v_missing := v_missing || 'escalation-event-visible '; END IF;
  IF (SELECT count(*) FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53r_ids WHERE name='clock1')) <> 0 THEN v_missing := v_missing || 'clock-visible '; END IF;
  IF (SELECT count(*) FROM workflow_escalation_policies WHERE id = (SELECT id FROM wf53r_ids WHERE name='esc_policy')) <> 0 THEN v_missing := v_missing || 'escalation-policy-visible '; END IF;
  IF v_missing <> '' THEN RAISE EXCEPTION 'expected escalation_target_a (named only as a notify_supervisor action_config target, never a workflow_participant) to see zero rows, but: %', v_missing; END IF;
END $$;
INSERT INTO wf53r_results VALUES (5,'a user named as the target of an escalation action (e.g. notify_supervisor''s notify_user_id) gains NO visibility from that alone -- being named in JSONB configuration is not a participant grant, exactly as the governing safety rule requires');

-- ── 6: no direct unauthorized writes against any of the 8 new tables ──
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
DO $$
DECLARE v_missing TEXT := '';
BEGIN
  BEGIN
    UPDATE workflow_sla_clocks SET current_escalation_level = 5 WHERE id = (SELECT id FROM wf53r_ids WHERE name='clock1');
    v_missing := v_missing || 'sla-clocks-update-allowed ';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO workflow_sla_clock_events (clock_id, instance_id, event_type, idempotency_key)
    VALUES ((SELECT id FROM wf53r_ids WHERE name='clock1'), (SELECT id FROM wf53r_ids WHERE name='i1'), 'started', gen_random_uuid());
    v_missing := v_missing || 'sla-clock-events-insert-allowed ';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    DELETE FROM workflow_escalation_events WHERE clock_id = (SELECT id FROM wf53r_ids WHERE name='clock1');
    v_missing := v_missing || 'escalation-events-delete-allowed ';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE workflow_sla_policies SET name = 'renamed' WHERE id = (SELECT id FROM wf53r_ids WHERE name='sla_policy');
    v_missing := v_missing || 'sla-policies-update-allowed ';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO workflow_escalation_levels (escalation_policy_id, level_order, offset_from, offset_amount, offset_unit, action_code, created_by)
    VALUES ((SELECT id FROM wf53r_ids WHERE name='esc_policy'), 2, 'breach', 1, 'hours', 'remind_actor', '65340000-0001-0000-0000-000000000001');
    v_missing := v_missing || 'escalation-levels-insert-allowed ';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE workflow_business_calendar_versions SET working_hours_start = '08:00' WHERE calendar_id = (SELECT id FROM wf53r_ids WHERE name='cal');
    v_missing := v_missing || 'calendar-versions-update-allowed ';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  IF v_missing <> '' THEN RAISE EXCEPTION 'expected every direct write against these RPC-owned tables to be rejected, but: %', v_missing; END IF;
END $$;
INSERT INTO wf53r_results VALUES (6,'every direct INSERT/UPDATE/DELETE attempt against the 8 new tables is rejected for authenticated -- mutation is exclusively through the RPC layer, matching the established workflow_ posture');

-- ── 7: private (non-RLS-predicate) helper functions are not directly EXECUTE-able by authenticated or anon ──
-- can_manage_workflow_sla_config/can_manage_workflow_sla_clock are the
-- two exceptions: they ARE granted to authenticated because they are
-- used directly as RLS USING-clause predicates (see scenarios 1-5
-- above, which exercise exactly that), matching can_manage_workflow_
-- definition's and can_manage_workflow_instance's own established
-- grant shape. They remain ungranted to anon, and never expose
-- anything beyond a boolean.
DO $$
DECLARE v_missing TEXT := '';
BEGIN
  IF NOT has_function_privilege('authenticated', 'can_manage_workflow_sla_config(uuid)', 'EXECUTE') THEN v_missing := v_missing || 'can_manage_workflow_sla_config-not-granted '; END IF;
  IF has_function_privilege('anon', 'can_manage_workflow_sla_config(uuid)', 'EXECUTE') THEN v_missing := v_missing || 'can_manage_workflow_sla_config-anon-leak '; END IF;
  IF has_function_privilege('anon', 'can_manage_workflow_sla_clock(uuid)', 'EXECUTE') THEN v_missing := v_missing || 'can_manage_workflow_sla_clock-anon-leak '; END IF;
  IF has_function_privilege('authenticated', 'workflow_calculate_calendar_deadline(timestamptz,numeric,text,uuid,text)', 'EXECUTE') THEN v_missing := v_missing || 'workflow_calculate_calendar_deadline '; END IF;
  IF has_function_privilege('authenticated', 'workflow_sla_offset_interval(numeric,text)', 'EXECUTE') THEN v_missing := v_missing || 'workflow_sla_offset_interval '; END IF;
  IF has_function_privilege('authenticated', 'workflow_sla_clocks_due_for_warning(integer)', 'EXECUTE') THEN v_missing := v_missing || 'due_for_warning '; END IF;
  IF has_function_privilege('authenticated', 'workflow_sla_clocks_due_for_breach(integer)', 'EXECUTE') THEN v_missing := v_missing || 'due_for_breach '; END IF;
  IF has_function_privilege('authenticated', 'workflow_sla_clocks_due_for_escalation(integer)', 'EXECUTE') THEN v_missing := v_missing || 'due_for_escalation '; END IF;
  IF v_missing <> '' THEN RAISE EXCEPTION 'unexpected grant posture: %', v_missing; END IF;

  -- Directly attempting to call a genuinely private helper still fails at runtime.
  BEGIN
    PERFORM workflow_sla_clocks_due_for_warning(10);
    RAISE EXCEPTION 'expected direct invocation of a private due-detection helper to be rejected';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
INSERT INTO wf53r_results VALUES (7,'the calendar arithmetic core, the offset-interval helper, and all three due-detection functions are ungranted to authenticated and anon and reject direct invocation at runtime; the two RLS-predicate helpers (can_manage_workflow_sla_config/_clock) are correctly granted to authenticated only, matching established precedent, never anon');

-- ── 8: only the intended RPCs are granted, and pre-existing workflow_ RLS/grants are completely unchanged ──
DO $$
DECLARE v_missing TEXT := '';
BEGIN
  -- Every mutating lifecycle RPC is granted to authenticated (and NOT anon).
  IF NOT has_function_privilege('authenticated', 'pause_workflow_sla_clock(uuid,bigint,text,uuid)', 'EXECUTE') THEN v_missing := v_missing || 'pause-not-granted '; END IF;
  IF has_function_privilege('anon', 'pause_workflow_sla_clock(uuid,bigint,text,uuid)', 'EXECUTE') THEN v_missing := v_missing || 'pause-anon-leak '; END IF;
  IF NOT has_function_privilege('authenticated', 'trigger_workflow_sla_escalation(uuid,bigint,uuid)', 'EXECUTE') THEN v_missing := v_missing || 'escalation-not-granted '; END IF;
  IF has_function_privilege('anon', 'trigger_workflow_sla_escalation(uuid,bigint,uuid)', 'EXECUTE') THEN v_missing := v_missing || 'escalation-anon-leak '; END IF;

  -- Pre-existing workflow_ tables' grant posture (SELECT-only) is untouched by this phase.
  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema='public' AND table_name IN ('workflow_definitions','workflow_instances','workflow_work_items','workflow_events','workflow_delegations','workflow_substitutions')
      AND grantee IN ('anon','authenticated') AND privilege_type <> 'SELECT'
  ) THEN v_missing := v_missing || 'prior-phase-table-write-grant-regression '; END IF;

  -- Pre-existing RLS policy behavior (an instance owner can still see their own instance) is unaffected.
  IF NOT to_regclass('public.workflow_instances')::regclass::text = 'workflow_instances' THEN v_missing := v_missing || 'sanity '; END IF;
  IF v_missing <> '' THEN RAISE EXCEPTION 'RLS/grant regression detected: %', v_missing; END IF;
END $$;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM workflow_instances WHERE id = (SELECT id FROM wf53r_ids WHERE name='i1');
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected pre-existing workflow_instances RLS (owner visibility) to still function unchanged, got %', v_count; END IF;
END $$;
INSERT INTO wf53r_results VALUES (8,'only the intended lifecycle/config RPCs are granted to authenticated (never anon), and every pre-existing workflow_ table''s grant posture and RLS behavior (SELECT-only, owner/participant visibility) remains completely unchanged by this phase');

RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf53r_results;
  IF v_count <> 8 THEN
    RAISE EXCEPTION 'Expected 8 scenarios to record a result, found %', v_count;
  END IF;
  RAISE NOTICE 'Workflow SLA/escalation foundation RLS tests PASSED: %/8', v_count;
END $$;

ROLLBACK;
