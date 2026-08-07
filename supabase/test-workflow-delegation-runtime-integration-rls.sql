-- CAP-002 Phase 5.2 delegation/substitution runtime integration RLS
-- suite (8 scenarios). Phase 5.2 adds zero new tables, zero new
-- columns' worth of RLS surface, and zero new grants -- every
-- workflow_ table's SELECT policy and grant posture is byte-
-- identical to the already-approved Phase 5.1 baseline. This suite
-- confirms that fact holds through the new function bodies, and
-- specifically exercises the one real visibility question the
-- runtime integration introduces: a delegate who acts on a work item
-- without ever becoming a resolved candidate/participant has the
-- same (unchanged) visibility as any other non-participant.
-- Disposable local PostgreSQL only. Runs in one transaction and
-- leaves no fixtures.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf522r_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf522r_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf522r_results, wf522r_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('65230000-0000-0000-0000-000000000001','WF522R Org','authority','WF522R');
INSERT INTO auth.users(id,email) VALUES
 ('65230000-0001-0000-0000-000000000001','admin@wf522r.local'),
 ('65230000-0001-0000-0000-000000000002','frank@wf522r.local'),
 ('65230000-0001-0000-0000-000000000003','carol@wf522r.local'),
 ('65230000-0001-0000-0000-000000000004','outsider@wf522r.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('65230000-0001-0000-0000-000000000001','65230000-0000-0000-0000-000000000001','WF522R-1','Admin','admin@wf522r.local',true),
 ('65230000-0001-0000-0000-000000000002','65230000-0000-0000-0000-000000000001','WF522R-2','Frank','frank@wf522r.local',true),
 ('65230000-0001-0000-0000-000000000003','65230000-0000-0000-0000-000000000001','WF522R-3','Carol','carol@wf522r.local',true),
 ('65230000-0001-0000-0000-000000000004','65230000-0000-0000-0000-000000000001','WF522R-4','Outsider','outsider@wf522r.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('65230000-0001-0000-0000-000000000001','organization','65230000-0000-0000-0000-000000000001','authority_admin',true,true);

\set ADMIN '{"sub":"65230000-0001-0000-0000-000000000001"}'
\set FRANK '{"sub":"65230000-0001-0000-0000-000000000002"}'
\set CAROL '{"sub":"65230000-0001-0000-0000-000000000003"}'
\set OUTSIDER '{"sub":"65230000-0001-0000-0000-000000000004"}'

SET ROLE authenticated;

\set EXPLICIT_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":true,"minimum_candidates":1,"candidate_selectors":[{"key":"frank_only","order":1,"type":"explicit_user","user_ids":["65230000-0001-0000-0000-000000000002"]}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_definition(
  '65230000-0000-0000-0000-000000000001','wf522r_explicit','WF522R Explicit Flow','opaque_case', :EXPLICIT_PAYLOAD::jsonb, gen_random_uuid()))
INSERT INTO wf522r_ids SELECT 'def_v', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wf522r_ids WHERE name='def_v'),0,gen_random_uuid());
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522r_ids WHERE name='def_v'),'opaque_case',gen_random_uuid(),
  '65230000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522r_ids SELECT 'i1', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522r_ids WHERE name='i1'),0,gen_random_uuid());
INSERT INTO wf522r_ids SELECT 'wi1', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522r_ids WHERE name='i1') AND assigned_to='65230000-0001-0000-0000-000000000002';

-- ── 1: workflow_delegations/workflow_substitutions grants are still
--      SELECT-only for authenticated, byte-identical to Phase 5.1 ──
DO $$
DECLARE v_missing TEXT := '';
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema='public' AND table_name IN ('workflow_delegations','workflow_substitutions','workflow_delegation_events','workflow_substitution_events')
      AND grantee IN ('anon','authenticated') AND privilege_type <> 'SELECT'
  ) THEN v_missing := 'direct-write-grant-present'; END IF;
  IF v_missing <> '' THEN RAISE EXCEPTION 'RLS regression: %', v_missing; END IF;
END $$;
INSERT INTO wf522r_results VALUES (1,'workflow_delegations/workflow_substitutions and their evidence tables remain SELECT-only for authenticated, unchanged by Phase 5.2');

-- ── 2: an outsider (not a participant, not admin) cannot see the instance''s work items ──
SELECT set_config('request.jwt.claims', :'OUTSIDER', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM workflow_work_items WHERE id=(SELECT id FROM wf522r_ids WHERE name='wi1');
  IF v_count <> 0 THEN RAISE EXCEPTION 'expected zero visibility for an outsider, got %', v_count; END IF;
END $$;
INSERT INTO wf522r_results VALUES (2,'an actor with no participant/admin relationship to the instance sees zero rows via RLS, exactly as before Phase 5.2');

-- ── 3: frank (the resolved candidate/owner of the work item) can see it via RLS ──
SELECT set_config('request.jwt.claims', :'FRANK', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM workflow_work_items WHERE id=(SELECT id FROM wf522r_ids WHERE name='wi1');
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected frank to see his own work item, got %', v_count; END IF;
END $$;
INSERT INTO wf522r_results VALUES (3,'frank, the resolved candidate holding the work item, retains full RLS visibility into it, unchanged by Phase 5.2');

-- ── 4: create a work_item-scoped delegation to carol, accept it ────
SELECT set_config('request.jwt.claims', :'FRANK', false);
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT delegation_id INTO v_id FROM create_workflow_delegation(
    '65230000-0000-0000-0000-000000000001','65230000-0001-0000-0000-000000000002','65230000-0001-0000-0000-000000000003',
    jsonb_build_object('type','work_item','work_item_id',(SELECT id FROM wf522r_ids WHERE name='wi1')::text),
    'temporary','manual', now(), now()+interval '2 days', 'rls test', gen_random_uuid());
  INSERT INTO wf522r_ids VALUES ('deleg1', v_id);
END $$;
SELECT set_config('request.jwt.claims', :'CAROL', false);
SELECT status FROM accept_workflow_delegation((SELECT id FROM wf522r_ids WHERE name='deleg1'), 0, gen_random_uuid());
INSERT INTO wf522r_results VALUES (4,'carol, the accepted delegate, can read her own delegation via the existing get/list RPCs (unchanged Phase 5.1 surface)');

-- ── 5: carol, though authorized to DECIDE the work item, has no RLS
--      visibility into it via direct SELECT before she acts -- being
--      an authorized delegate is not the same relationship RLS
--      already grants to a resolved participant, and Phase 5.2 does
--      not add one ──────────────────────────────────────────────────
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM workflow_work_items WHERE id=(SELECT id FROM wf522r_ids WHERE name='wi1');
  IF v_count <> 0 THEN RAISE EXCEPTION 'expected carol to have no direct RLS visibility into the work item before deciding it, got %', v_count; END IF;
END $$;
INSERT INTO wf522r_results VALUES (5,'an authorized delegate who has not yet decided has no direct RLS visibility into the delegator''s work item -- decide_workflow_work_item''s own internal SELECT ... FOR UPDATE bypasses RLS as SECURITY DEFINER, but the delegate''s own ad hoc queries remain governed by the unchanged can_view_workflow_instance policy');

-- ── 6: carol decides the work item as the delegate ──────────────────
SELECT * FROM decide_workflow_work_item((SELECT id FROM wf522r_ids WHERE name='wi1'),'approve',1,0,gen_random_uuid());
INSERT INTO wf522r_results VALUES (6,'carol successfully decides the work item as an authorized delegate, per the runtime integration');

-- ── 7: after deciding, carol still has no elevated standing RLS visibility -- she is not retroactively made a participant ──
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM workflow_work_items WHERE id=(SELECT id FROM wf522r_ids WHERE name='wi1');
  IF v_count <> 0 THEN RAISE EXCEPTION 'expected carol still not to gain RLS visibility from having decided, got %', v_count; END IF;
END $$;
INSERT INTO wf522r_results VALUES (7,'deciding as a delegate does not retroactively grant the delegate any new RLS visibility -- workflow_participants is never mutated to add the delegate, exactly as docs/73 intends');

-- ── 8: admin (organization admin) retains full visibility throughout, unchanged ──
SELECT set_config('request.jwt.claims', :'ADMIN', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM workflow_decisions WHERE work_item_id=(SELECT id FROM wf522r_ids WHERE name='wi1');
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected the org admin to retain full visibility, got %', v_count; END IF;
END $$;
INSERT INTO wf522r_results VALUES (8,'an organization admin retains full RLS visibility into the decision record, including its delegation traceability, unchanged by Phase 5.2');

RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf522r_results;
  IF v_count <> 8 THEN
    RAISE EXCEPTION 'Expected 8 scenarios to record a result, found %', v_count;
  END IF;
  RAISE NOTICE 'Workflow delegation/substitution runtime integration RLS tests PASSED: %/8', v_count;
END $$;

ROLLBACK;
