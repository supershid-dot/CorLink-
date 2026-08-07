-- CAP-002 Phase 5.4 SLA timer dispatch & worker foundation RLS suite
-- (6 required checks). Disposable local PostgreSQL only. Runs in one
-- transaction and leaves no fixtures.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf54r_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf54r_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf54r_results, wf54r_ids TO authenticated, service_role;

INSERT INTO organizations(id,name,type,code) VALUES
 ('65340002-0000-0000-0000-000000000001','WF54R Org A','authority','WF54RA'),
 ('65340002-0000-0000-0000-000000000002','WF54R Org B','authority','WF54RB');
INSERT INTO auth.users(id,email) VALUES
 ('65340002-0001-0000-0000-000000000001','admin_a@wf54r.local'),
 ('65340002-0001-0000-0000-000000000002','worker_a@wf54r.local'),
 ('65340002-0001-0000-0000-000000000003','outsider_a@wf54r.local'),
 ('65340002-0001-0000-0000-000000000004','admin_b@wf54r.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('65340002-0001-0000-0000-000000000001','65340002-0000-0000-0000-000000000001','WF54RA-1','Admin A','admin_a@wf54r.local',true),
 ('65340002-0001-0000-0000-000000000002','65340002-0000-0000-0000-000000000001','WF54RA-2','Worker A','worker_a@wf54r.local',true),
 ('65340002-0001-0000-0000-000000000003','65340002-0000-0000-0000-000000000001','WF54RA-3','Outsider A','outsider_a@wf54r.local',true),
 ('65340002-0001-0000-0000-000000000004','65340002-0000-0000-0000-000000000002','WF54RB-1','Admin B','admin_b@wf54r.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('65340002-0001-0000-0000-000000000001','organization','65340002-0000-0000-0000-000000000001','authority_admin',true,true),
 ('65340002-0001-0000-0000-000000000002','organization','65340002-0000-0000-0000-000000000001','supervisor',true,true),
 ('65340002-0001-0000-0000-000000000004','organization','65340002-0000-0000-0000-000000000002','authority_admin',true,true);

\set ADMIN_A '{"sub":"65340002-0001-0000-0000-000000000001"}'
\set OUTSIDER_A '{"sub":"65340002-0001-0000-0000-000000000003"}'
\set ADMIN_B '{"sub":"65340002-0001-0000-0000-000000000004"}'

SET ROLE authenticated;

\set ORG_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":true,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
WITH made AS (SELECT * FROM create_workflow_definition(
  '65340002-0000-0000-0000-000000000001','wf54r_org','WF54R Org Flow','opaque_case', :ORG_PAYLOAD::jsonb, gen_random_uuid()))
INSERT INTO wf54r_ids SELECT 'def_v', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wf54r_ids WHERE name='def_v'),0,gen_random_uuid());
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf54r_ids WHERE name='def_v'),'opaque_case',gen_random_uuid(),
  '65340002-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf54r_ids SELECT 'i1', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf54r_ids WHERE name='i1'),0,gen_random_uuid());

-- A clock with an absolute deadline already in the past, so it is
-- immediately due for breach when the dispatcher runs.
WITH made AS (SELECT * FROM create_workflow_sla_clock(
  (SELECT id FROM wf54r_ids WHERE name='i1'), NULL, NULL, NULL, 'manual', NULL,
  clock_timestamp() - interval '5 minutes', 'UTC', gen_random_uuid()))
INSERT INTO wf54r_ids SELECT 'clock1', clock_id FROM made;

RESET ROLE;

-- ── 1: an ordinary authenticated user cannot invoke the dispatcher ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
DO $$
BEGIN
  BEGIN
    PERFORM process_workflow_sla_due_batch(10);
    RAISE EXCEPTION 'expected authenticated (even an org admin) to be denied EXECUTE on the dispatcher';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf54r_results VALUES (1,'an ordinary authenticated user -- including an organization admin, the strongest human authority level this milestone reuses -- cannot invoke process_workflow_sla_due_batch: no EXECUTE grant exists for authenticated at all');

-- ── 2: anon cannot invoke the dispatcher ──
SET ROLE anon;
DO $$
BEGIN
  BEGIN
    PERFORM process_workflow_sla_due_batch(10);
    RAISE EXCEPTION 'expected anon to be denied EXECUTE on the dispatcher';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf54r_results VALUES (2,'anon cannot invoke process_workflow_sla_due_batch: no EXECUTE grant exists for anon');

-- ── 3: the intended internal/system execution path (service_role) can invoke the dispatcher and it actually processes due work ──
DO $$
DECLARE v_outcome TEXT;
BEGIN
  SET ROLE service_role;
  SELECT outcome INTO v_outcome FROM process_workflow_sla_due_batch(10)
  WHERE due_category = 'breach' AND clock_id = (SELECT id FROM wf54r_ids WHERE name='clock1');
  RESET ROLE;
  IF v_outcome <> 'processed' THEN
    RAISE EXCEPTION 'expected service_role to successfully invoke the dispatcher and process the due breach, got %', v_outcome;
  END IF;
END $$;
INSERT INTO wf54r_results VALUES (3,'the intended internal/system execution path (service_role) can invoke process_workflow_sla_due_batch and it correctly processes due work -- the EXECUTE grant exists for exactly this one role');

-- ── 4: no new direct write access to any SLA/evidence table was introduced -- authenticated remains SELECT-only, anon has none ──
DO $$
DECLARE v_leak TEXT;
BEGIN
  SELECT string_agg(grantee || ':' || table_name || ':' || privilege_type, ', ') INTO v_leak
  FROM information_schema.role_table_grants
  WHERE table_schema = 'public'
    AND table_name IN ('workflow_sla_clocks','workflow_sla_clock_events','workflow_escalation_events',
                        'workflow_sla_policies','workflow_escalation_policies','workflow_escalation_levels',
                        'workflow_business_calendars','workflow_business_calendar_versions')
    AND grantee IN ('anon','authenticated') AND privilege_type <> 'SELECT';
  IF v_leak IS NOT NULL THEN
    RAISE EXCEPTION 'expected zero direct INSERT/UPDATE/DELETE grants to anon/authenticated on any SLA/evidence table, found: %', v_leak;
  END IF;
END $$;
INSERT INTO wf54r_results VALUES (4,'no new direct write access to any SLA/evidence table was introduced by this phase -- authenticated remains SELECT-only, anon has no access at all, mutation remains exclusively through SECURITY DEFINER RPC bodies');

-- ── 5: existing user SLA read/manage behavior is completely unchanged -- the org admin can still see the clock and still manually record its own warning/breach/escalation RPCs exactly as before ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
DO $$
DECLARE v_visible_count INTEGER; v_manual_outcome RECORD;
BEGIN
  SELECT count(*) INTO v_visible_count FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf54r_ids WHERE name='clock1');
  IF v_visible_count <> 1 THEN
    RAISE EXCEPTION 'expected the instance owner to still see their own clock via the unchanged can_view_workflow_instance RLS policy, got %', v_visible_count;
  END IF;
  -- The manual RPC path (record_workflow_sla_breach) is unaffected --
  -- calling it now on an already-automatically-breached clock is
  -- still the same safe idempotent no-op it always was.
  SELECT * INTO v_manual_outcome FROM record_workflow_sla_breach(
    (SELECT id FROM wf54r_ids WHERE name='clock1'), 0, gen_random_uuid());
  IF NOT v_manual_outcome.replayed AND v_manual_outcome.breached_at IS NULL THEN
    RAISE EXCEPTION 'expected the manual breach RPC to behave exactly as before Phase 5.4 (safe no-op / idempotent against an already-breached clock)';
  END IF;
END $$;
RESET ROLE;
INSERT INTO wf54r_results VALUES (5,'existing user SLA read/manage behavior is completely unchanged by this phase: the instance owner still sees their own clock via the unmodified can_view_workflow_instance RLS policy, and the manual record_workflow_sla_breach RPC still behaves exactly as it did before Phase 5.4 (idempotent no-op against an already-breached clock)');

-- ── 6: cross-organization leakage is not introduced -- an org B admin sees neither the clock nor the automatic dispatch evidence it now carries ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_B', false);
DO $$
DECLARE v_clock_count INTEGER; v_event_count INTEGER;
BEGIN
  SELECT count(*) INTO v_clock_count FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf54r_ids WHERE name='clock1');
  SELECT count(*) INTO v_event_count FROM workflow_sla_clock_events WHERE clock_id = (SELECT id FROM wf54r_ids WHERE name='clock1');
  IF v_clock_count <> 0 OR v_event_count <> 0 THEN
    RAISE EXCEPTION 'expected an org B admin to see neither org A''s clock nor its automatic-dispatch evidence, got clock=% events=%', v_clock_count, v_event_count;
  END IF;
END $$;
RESET ROLE;
INSERT INTO wf54r_results VALUES (6,'cross-organization leakage is not introduced by automatic dispatch: an admin from a different organization sees neither the clock nor the evidence the dispatcher wrote for it -- the same can_view_workflow_instance boundary applies identically to automatically- and manually-fired evidence');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf54r_results;
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'Expected 6 scenarios to record a result, found %', v_count;
  END IF;
  RAISE NOTICE 'Workflow SLA timer dispatch RLS tests PASSED: %/6', v_count;
END $$;

ROLLBACK;
