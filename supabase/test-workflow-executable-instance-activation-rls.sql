-- CAP-002 Phase 2B.2 RLS suite (6 scenarios)
-- Runs in one transaction and leaves no fixtures.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wfars_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfars_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfars_results, wfars_ids TO authenticated;
GRANT SELECT ON wfars_ids TO anon;

INSERT INTO organizations(id,name,type,code) VALUES
 ('65100000-0000-0000-0000-000000000001','WF Activation RLS A','authority','WFAR-A'),
 ('65100000-0000-0000-0000-000000000002','WF Activation RLS B','authority','WFAR-B');
INSERT INTO auth.users(id,email) VALUES
 ('65100000-0001-0000-0000-000000000001','owner@wfar.local'),
 ('65100000-0001-0000-0000-000000000002','cand@wfar.local'),
 ('65100000-0001-0000-0000-000000000003','outsider@wfar.local'),
 ('65100000-0001-0000-0000-000000000004','other@wfar.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('65100000-0001-0000-0000-000000000001','65100000-0000-0000-0000-000000000001','WFAR-1','Owner','owner@wfar.local',true),
 ('65100000-0001-0000-0000-000000000002','65100000-0000-0000-0000-000000000001','WFAR-2','Candidate','cand@wfar.local',true),
 ('65100000-0001-0000-0000-000000000003','65100000-0000-0000-0000-000000000001','WFAR-3','Outsider','outsider@wfar.local',true),
 ('65100000-0001-0000-0000-000000000004','65100000-0000-0000-0000-000000000002','WFAR-4','Other','other@wfar.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('65100000-0001-0000-0000-000000000001','organization','65100000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('65100000-0001-0000-0000-000000000002','organization','65100000-0000-0000-0000-000000000001','supervisor',true,true),
 ('65100000-0001-0000-0000-000000000003','organization','65100000-0000-0000-0000-000000000001','staff',true,true),
 ('65100000-0001-0000-0000-000000000004','organization','65100000-0000-0000-0000-000000000002','authority_admin',true,true);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65100000-0001-0000-0000-000000000001"}',true);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '65100000-0000-0000-0000-000000000001','wfar_flow','WFAR Flow','opaque_case',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}'::jsonb,
  '65100000-1000-0000-0000-000000000001'))
INSERT INTO wfars_ids SELECT 'version',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfars_ids WHERE name='version'),0,'65100000-1000-0000-0000-000000000002');
INSERT INTO wfars_ids SELECT 'instance', create_workflow_instance(
  (SELECT id FROM wfars_ids WHERE name='version'),'opaque_case','65100000-2000-0000-0000-000000000001',
  '65100000-0000-0000-0000-000000000001','65100000-1000-0000-0000-000000000003',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfars_ids WHERE name='instance'),0,'65100000-1000-0000-0000-000000000004');
RESET ROLE;

-- ── 1: the resolved candidate (assigned a work item) can see the
--    round and their own position via existing participant-scoped
--    RLS — no new visibility rule was needed. ─────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65100000-0001-0000-0000-000000000002"}',true);
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM workflow_approval_rounds WHERE instance_id = (SELECT id FROM wfars_ids WHERE name='instance')) THEN
    RAISE EXCEPTION 'candidate cannot see the round for an instance they are a participant of';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM workflow_approval_positions WHERE instance_id = (SELECT id FROM wfars_ids WHERE name='instance') AND user_id = '65100000-0001-0000-0000-000000000002') THEN
    RAISE EXCEPTION 'candidate cannot see their own position';
  END IF;
END $$;
INSERT INTO wfars_results VALUES (1,'a resolved candidate (workflow_participants row) can see the round and position via existing participant-scoped visibility');
RESET ROLE;

-- ── 2: an outsider (same org, no participant row) cannot see the
--    round/position/token/step/instance at all. ────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65100000-0001-0000-0000-000000000003"}',true);
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM workflow_instances WHERE id = (SELECT id FROM wfars_ids WHERE name='instance')) THEN
    RAISE EXCEPTION 'outsider can see the instance';
  END IF;
  IF EXISTS (SELECT 1 FROM workflow_approval_rounds WHERE instance_id = (SELECT id FROM wfars_ids WHERE name='instance')) THEN
    RAISE EXCEPTION 'outsider can see the round';
  END IF;
  IF EXISTS (SELECT 1 FROM workflow_approval_positions WHERE instance_id = (SELECT id FROM wfars_ids WHERE name='instance')) THEN
    RAISE EXCEPTION 'outsider can see positions';
  END IF;
  IF EXISTS (SELECT 1 FROM workflow_tokens WHERE instance_id = (SELECT id FROM wfars_ids WHERE name='instance')) THEN
    RAISE EXCEPTION 'outsider can see tokens';
  END IF;
  IF EXISTS (SELECT 1 FROM workflow_instance_steps WHERE instance_id = (SELECT id FROM wfars_ids WHERE name='instance')) THEN
    RAISE EXCEPTION 'outsider can see steps';
  END IF;
END $$;
INSERT INTO wfars_results VALUES (2,'a same-organization outsider with no participant row sees no instance/round/position/token/step data (no existence leakage)');
RESET ROLE;

-- ── 3: a cross-organization actor cannot see anything either. ─────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65100000-0001-0000-0000-000000000004"}',true);
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM workflow_approval_rounds WHERE instance_id = (SELECT id FROM wfars_ids WHERE name='instance')) THEN
    RAISE EXCEPTION 'cross-org actor can see the round';
  END IF;
END $$;
INSERT INTO wfars_results VALUES (3,'a cross-organization actor sees nothing');
RESET ROLE;

-- ── 4: the new tables have no direct write grant to authenticated
--    or anon (mutation is RPC-only). ───────────────────────────────
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema='public' AND table_name IN ('workflow_approval_rounds','workflow_approval_positions')
      AND grantee IN ('anon','authenticated') AND privilege_type <> 'SELECT'
  ) THEN RAISE EXCEPTION 'direct write grant exists on a new table'; END IF;
END $$;
INSERT INTO wfars_results VALUES (4,'new tables have no direct write grant');

-- ── 5: exactly one SELECT policy per new table, no others. ────────
DO $$
BEGIN
  IF (SELECT count(*) FROM pg_policy WHERE polrelid='workflow_approval_rounds'::regclass AND polcmd='r') <> 1
     OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid='workflow_approval_rounds'::regclass AND polcmd<>'r')
     OR (SELECT count(*) FROM pg_policy WHERE polrelid='workflow_approval_positions'::regclass AND polcmd='r') <> 1
     OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid='workflow_approval_positions'::regclass AND polcmd<>'r')
  THEN RAISE EXCEPTION 'unexpected policy shape on new tables'; END IF;
END $$;
INSERT INTO wfars_results VALUES (5,'exactly one SELECT-only policy exists per new table');

-- ── 6: owner/manager (can_manage_workflow_instance) can activate;
--    reused unchanged, not duplicated. ──────────────────────────────
DO $$
BEGIN
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'can_manage_workflow_instance(uuid)'::regprocedure) THEN
    RAISE EXCEPTION 'can_manage_workflow_instance is not SECURITY DEFINER';
  END IF;
  IF (SELECT pg_get_functiondef('workflow_transition_instance(uuid,text,bigint,uuid,text,text)'::regprocedure))
     NOT ILIKE '%can_manage_workflow_instance%'
  THEN RAISE EXCEPTION 'activation does not reuse can_manage_workflow_instance'; END IF;
END $$;
INSERT INTO wfars_results VALUES (6,'existing can_manage_workflow_instance() authorization is reused, not duplicated');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfars_results;
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'Workflow executable instance activation RLS tests FAILED: expected 6, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow executable instance activation RLS tests PASSED: %/6', v_count;
END $$;

ROLLBACK;
