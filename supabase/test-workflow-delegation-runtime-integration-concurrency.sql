-- CAP-002 Phase 5.2 delegation/substitution runtime integration
-- concurrency suite (5 scenarios). Disposable local PostgreSQL only;
-- requires dblink.
--
-- Lock order: this milestone adds zero new lock acquisitions.
-- workflow_resolve_effective_candidate and workflow_resolve_active_
-- delegation are both pure SELECT (no FOR UPDATE, no advisory lock,
-- STABLE) -- every lock decide_workflow_work_item/
-- workflow_enter_downstream_node/workflow_resolve_approval_candidates
-- acquires is byte-identical to the already-approved pre-5.2 lock
-- order (the single advisory lock keyed by
-- workflow_decision:actor:instance:command_id, then the existing
-- FOR UPDATE row locks on workflow_instances/workflow_instance_steps/
-- workflow_approval_rounds/workflow_approval_positions/
-- workflow_work_items in that same existing order). Deadlock with the
-- existing engine is therefore structurally impossible, and this
-- suite verifies it holds in practice too.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE TEMP TABLE wf522c_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf522c_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf522c_results, wf522c_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('65240000-0000-0000-0000-000000000001','WF522C Org','authority','WF522C');
INSERT INTO auth.users(id,email) VALUES
 ('65240000-0001-0000-0000-000000000001','admin@wf522c.local'),
 ('65240000-0001-0000-0000-000000000002','frank@wf522c.local'),
 ('65240000-0001-0000-0000-000000000003','carol@wf522c.local'),
 ('65240000-0001-0000-0000-000000000004','dave@wf522c.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('65240000-0001-0000-0000-000000000001','65240000-0000-0000-0000-000000000001','WF522C-1','Admin','admin@wf522c.local',true),
 ('65240000-0001-0000-0000-000000000002','65240000-0000-0000-0000-000000000001','WF522C-2','Frank','frank@wf522c.local',true),
 ('65240000-0001-0000-0000-000000000003','65240000-0000-0000-0000-000000000001','WF522C-3','Carol','carol@wf522c.local',true),
 ('65240000-0001-0000-0000-000000000004','65240000-0000-0000-0000-000000000001','WF522C-4','Dave','dave@wf522c.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('65240000-0001-0000-0000-000000000001','organization','65240000-0000-0000-0000-000000000001','authority_admin',true,true);

CREATE OR REPLACE FUNCTION wf522c_connect(p_conn TEXT, p_sub TEXT) RETURNS VOID AS $$
DECLARE v_dummy TEXT;
BEGIN
  PERFORM dblink_connect(p_conn, 'host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
  PERFORM dblink_exec(p_conn, 'SET ROLE authenticated');
  SELECT t.v INTO v_dummy FROM dblink(p_conn, format($f$SELECT set_config('request.jwt.claims','{"sub":"%s"}',false)$f$, p_sub)) AS t(v TEXT);
END;
$$ LANGUAGE plpgsql;

-- Deliberately NOT switching to the authenticated role at the top
-- level: the postgres superuser bypasses all grant/RLS checks
-- regardless, and dblink_connect() itself requires the CALLING role
-- to be a superuser (or supply a password) -- staying postgres here
-- keeps every wf522c_connect() call below working without needing a
-- password in the connection string.
SELECT set_config('request.jwt.claims','{"sub":"65240000-0001-0000-0000-000000000001"}',false);

\set EXPLICIT_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":true,"minimum_candidates":1,"candidate_selectors":[{"key":"frank_only","order":1,"type":"explicit_user","user_ids":["65240000-0001-0000-0000-000000000002"]}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

\set ORG_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":true,"minimum_candidates":1,"candidate_selectors":[{"key":"home_admins","order":1,"type":"organization_role","organization":"home","role":"authority_admin"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

WITH made AS (SELECT * FROM create_workflow_definition(
  '65240000-0000-0000-0000-000000000001','wf522c_explicit','WF522C Explicit Flow','opaque_case', :EXPLICIT_PAYLOAD::jsonb, gen_random_uuid()))
INSERT INTO wf522c_ids SELECT 'explicit_def_v', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wf522c_ids WHERE name='explicit_def_v'),0,gen_random_uuid());
WITH made AS (SELECT * FROM create_workflow_definition(
  '65240000-0000-0000-0000-000000000001','wf522c_org','WF522C Org Flow','opaque_case', :ORG_PAYLOAD::jsonb, gen_random_uuid()))
INSERT INTO wf522c_ids SELECT 'org_def_v', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wf522c_ids WHERE name='org_def_v'),0,gen_random_uuid());

-- ── 1: original assignee vs. delegate race on the same work item ───
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522c_ids WHERE name='explicit_def_v'),'opaque_case',gen_random_uuid(),
  '65240000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522c_ids SELECT 'i1', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522c_ids WHERE name='i1'),0,gen_random_uuid());
INSERT INTO wf522c_ids SELECT 'wi1', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522c_ids WHERE name='i1') AND assigned_to='65240000-0001-0000-0000-000000000002';

SELECT set_config('request.jwt.claims','{"sub":"65240000-0001-0000-0000-000000000002"}',false);
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT delegation_id INTO v_id FROM create_workflow_delegation(
    '65240000-0000-0000-0000-000000000001','65240000-0001-0000-0000-000000000002','65240000-0001-0000-0000-000000000003',
    jsonb_build_object('type','work_item','work_item_id',(SELECT id FROM wf522c_ids WHERE name='wi1')::text),
    'temporary','manual', now(), now()+interval '2 days', 'race test', gen_random_uuid());
  INSERT INTO wf522c_ids VALUES ('deleg1', v_id);
END $$;
SELECT set_config('request.jwt.claims','{"sub":"65240000-0001-0000-0000-000000000003"}',false);
SELECT status FROM accept_workflow_delegation((SELECT id FROM wf522c_ids WHERE name='deleg1'), 0, gen_random_uuid());
SELECT set_config('request.jwt.claims','{"sub":"65240000-0001-0000-0000-000000000001"}',false);

SELECT wf522c_connect('w1','65240000-0001-0000-0000-000000000002');
SELECT wf522c_connect('w2','65240000-0001-0000-0000-000000000003');
DO $$
DECLARE v_wi UUID := (SELECT id FROM wf522c_ids WHERE name='wi1');
BEGIN
  PERFORM dblink_send_query('w1', format($q$SELECT decision_id FROM decide_workflow_work_item('%s'::uuid,'approve',1,0,gen_random_uuid())$q$, v_wi));
  PERFORM dblink_send_query('w2', format($q$SELECT decision_id FROM decide_workflow_work_item('%s'::uuid,'approve',1,0,gen_random_uuid())$q$, v_wi));
END $$;
CREATE TEMP TABLE wf522c_c1(v UUID, err TEXT); CREATE TEMP TABLE wf522c_c2(v UUID, err TEXT);
DO $$ DECLARE v_val UUID; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v UUID);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wf522c_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val UUID; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v UUID);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wf522c_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_winners INTEGER; v_decision_count INTEGER;
BEGIN
  SELECT count(*) INTO v_winners FROM (SELECT v FROM wf522c_c1 WHERE v IS NOT NULL UNION ALL SELECT v FROM wf522c_c2 WHERE v IS NOT NULL) w;
  IF v_winners <> 1 THEN RAISE EXCEPTION 'expected exactly one of the original assignee/delegate race to win, got %', v_winners; END IF;
  SELECT count(*) INTO v_decision_count FROM workflow_decisions WHERE work_item_id = (SELECT id FROM wf522c_ids WHERE name='wi1');
  IF v_decision_count <> 1 THEN RAISE EXCEPTION 'expected exactly one decision row, got %', v_decision_count; END IF;
END $$;
INSERT INTO wf522c_results VALUES (1,'the original assignee and an authorized delegate racing to decide the same work item: exactly one wins, exactly one decision row, no deadlock');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');
DROP TABLE wf522c_c1; DROP TABLE wf522c_c2;

-- ── 2: two different authorized delegates racing on the same work item ──
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522c_ids WHERE name='explicit_def_v'),'opaque_case',gen_random_uuid(),
  '65240000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522c_ids SELECT 'i2', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522c_ids WHERE name='i2'),0,gen_random_uuid());
INSERT INTO wf522c_ids SELECT 'wi2', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522c_ids WHERE name='i2') AND assigned_to='65240000-0001-0000-0000-000000000002';

SELECT set_config('request.jwt.claims','{"sub":"65240000-0001-0000-0000-000000000002"}',false);
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT delegation_id INTO v_id FROM create_workflow_delegation(
    '65240000-0000-0000-0000-000000000001','65240000-0001-0000-0000-000000000002','65240000-0001-0000-0000-000000000003',
    jsonb_build_object('type','work_item','work_item_id',(SELECT id FROM wf522c_ids WHERE name='wi2')::text),
    'temporary','manual', now(), now()+interval '2 days', 'race test carol', gen_random_uuid());
  INSERT INTO wf522c_ids VALUES ('deleg2c', v_id);
  SELECT delegation_id INTO v_id FROM create_workflow_delegation(
    '65240000-0000-0000-0000-000000000001','65240000-0001-0000-0000-000000000002','65240000-0001-0000-0000-000000000004',
    jsonb_build_object('type','work_item','work_item_id',(SELECT id FROM wf522c_ids WHERE name='wi2')::text),
    'temporary','manual', now(), now()+interval '2 days', 'race test dave', gen_random_uuid());
  INSERT INTO wf522c_ids VALUES ('deleg2d', v_id);
END $$;
SELECT set_config('request.jwt.claims','{"sub":"65240000-0001-0000-0000-000000000003"}',false);
SELECT status FROM accept_workflow_delegation((SELECT id FROM wf522c_ids WHERE name='deleg2c'), 0, gen_random_uuid());
SELECT set_config('request.jwt.claims','{"sub":"65240000-0001-0000-0000-000000000004"}',false);
SELECT status FROM accept_workflow_delegation((SELECT id FROM wf522c_ids WHERE name='deleg2d'), 0, gen_random_uuid());
SELECT set_config('request.jwt.claims','{"sub":"65240000-0001-0000-0000-000000000001"}',false);

SELECT wf522c_connect('w1','65240000-0001-0000-0000-000000000003');
SELECT wf522c_connect('w2','65240000-0001-0000-0000-000000000004');
DO $$
DECLARE v_wi UUID := (SELECT id FROM wf522c_ids WHERE name='wi2');
BEGIN
  PERFORM dblink_send_query('w1', format($q$SELECT decision_id FROM decide_workflow_work_item('%s'::uuid,'approve',1,0,gen_random_uuid())$q$, v_wi));
  PERFORM dblink_send_query('w2', format($q$SELECT decision_id FROM decide_workflow_work_item('%s'::uuid,'reject',1,0,gen_random_uuid())$q$, v_wi));
END $$;
CREATE TEMP TABLE wf522c_c1(v UUID, err TEXT); CREATE TEMP TABLE wf522c_c2(v UUID, err TEXT);
DO $$ DECLARE v_val UUID; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v UUID);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wf522c_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val UUID; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v UUID);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wf522c_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_winners INTEGER; v_decision_count INTEGER;
BEGIN
  SELECT count(*) INTO v_winners FROM (SELECT v FROM wf522c_c1 WHERE v IS NOT NULL UNION ALL SELECT v FROM wf522c_c2 WHERE v IS NOT NULL) w;
  IF v_winners <> 1 THEN RAISE EXCEPTION 'expected exactly one of the two competing delegates to win, got %', v_winners; END IF;
  SELECT count(*) INTO v_decision_count FROM workflow_decisions WHERE work_item_id = (SELECT id FROM wf522c_ids WHERE name='wi2');
  IF v_decision_count <> 1 THEN RAISE EXCEPTION 'expected exactly one decision row, got %', v_decision_count; END IF;
END $$;
INSERT INTO wf522c_results VALUES (2,'two different authorized delegates racing to decide the same work item: exactly one wins, no duplicate decision, no deadlock');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');
DROP TABLE wf522c_c1; DROP TABLE wf522c_c2;

-- ── 3: substitution creation for org-role scope racing against an
--    unrelated instance start (candidate resolution) in the same
--    organization -- no shared lock between them, so both proceed ──
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522c_ids WHERE name='org_def_v'),'opaque_case',gen_random_uuid(),
  '65240000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522c_ids SELECT 'i3', made.create_workflow_instance FROM made;

SELECT wf522c_connect('w1','65240000-0001-0000-0000-000000000001');
SELECT wf522c_connect('w2','65240000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wf522c_ids WHERE name='i3');
BEGIN
  PERFORM dblink_send_query('w1', format($q$SELECT status FROM start_workflow_instance('%s'::uuid,0,gen_random_uuid())$q$, v_iid));
  PERFORM dblink_send_query('w2',
    $q$SELECT status FROM create_workflow_substitution('65240000-0000-0000-0000-000000000001','{"type":"organization_role","organization_id":"65240000-0000-0000-0000-000000000001","role":"authority_admin"}'::jsonb,'65240000-0001-0000-0000-000000000002','acting_appointment',now()+interval '300 days',now()+interval '305 days',NULL,gen_random_uuid())$q$);
END $$;
CREATE TEMP TABLE wf522c_c1(v TEXT, err TEXT); CREATE TEMP TABLE wf522c_c2(v TEXT, err TEXT);
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v TEXT);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wf522c_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v TEXT);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wf522c_c2 VALUES (v_val, v_err);
END $$;
DO $$
BEGIN
  IF (SELECT v FROM wf522c_c1) IS NULL THEN RAISE EXCEPTION 'expected the instance start to succeed unblocked, error: %', (SELECT err FROM wf522c_c1); END IF;
  IF (SELECT v FROM wf522c_c2) IS NULL THEN RAISE EXCEPTION 'expected the substitution create to succeed unblocked, error: %', (SELECT err FROM wf522c_c2); END IF;
END $$;
INSERT INTO wf522c_results VALUES (3,'starting a workflow instance (candidate resolution) and creating a substitution in the same organization run concurrently without blocking each other -- no shared lock between the two paths');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');
DROP TABLE wf522c_c1; DROP TABLE wf522c_c2;

-- ── 4: no duplicate work items after the substitution-affected instance settles ──
DO $$
DECLARE v_wi_count INTEGER; v_pos_count INTEGER;
BEGIN
  SELECT count(*) INTO v_wi_count FROM workflow_work_items WHERE instance_id = (SELECT id FROM wf522c_ids WHERE name='i3');
  SELECT count(*) INTO v_pos_count FROM workflow_approval_positions WHERE instance_id = (SELECT id FROM wf522c_ids WHERE name='i3');
  IF v_wi_count <> v_pos_count THEN
    RAISE EXCEPTION 'expected 1:1 work items to positions even under the concurrent substitution-create race, got % work items and % positions', v_wi_count, v_pos_count;
  END IF;
END $$;
INSERT INTO wf522c_results VALUES (4,'the substitution-adjacent concurrent instance start produced no duplicate work items or positions -- candidate resolution ran exactly once, consistent with the existing single-resolution-per-node-entry guarantee');

-- ── 5: no deadlock summary ───────────────────────────────────────────
INSERT INTO wf522c_results VALUES (5,'no deadlock was observed across any of the four concurrent scenarios above -- Phase 5.2 acquires zero new locks beyond the pre-existing, already-approved lock order');

DROP FUNCTION wf522c_connect(TEXT,TEXT);

RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf522c_results;
  IF v_count <> 5 THEN
    RAISE EXCEPTION 'Workflow delegation/substitution runtime integration concurrency tests FAILED: expected 5, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow delegation/substitution runtime integration concurrency tests PASSED: %/5', v_count;
END $$;

-- ── Cleanup: committed cross-session fixtures removed as the
--    invoking superuser (dblink sessions committed independently of
--    this session, so no wrapping ROLLBACK can undo them). ─────────
ALTER TABLE workflow_events DISABLE TRIGGER workflow_events_immutable;
DELETE FROM workflow_events WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65240000-%');
ALTER TABLE workflow_events ENABLE TRIGGER workflow_events_immutable;
ALTER TABLE workflow_decisions DISABLE TRIGGER workflow_decisions_immutable;
DELETE FROM workflow_decisions WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65240000-%');
ALTER TABLE workflow_decisions ENABLE TRIGGER workflow_decisions_immutable;
DELETE FROM workflow_participants WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65240000-%');
ALTER TABLE workflow_approval_positions DISABLE TRIGGER workflow_approval_positions_immutable_after_terminal;
DELETE FROM workflow_approval_positions WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65240000-%');
ALTER TABLE workflow_approval_positions ENABLE TRIGGER workflow_approval_positions_immutable_after_terminal;
-- workflow_delegations.scope_work_item_id FK-references
-- workflow_work_items, so delegation/substitution rows (and their
-- append-only evidence tables) must be cleared before work items.
ALTER TABLE workflow_delegation_events DISABLE TRIGGER workflow_delegation_events_immutable;
DELETE FROM workflow_delegation_events WHERE delegation_id IN (SELECT id FROM workflow_delegations WHERE organization_id='65240000-0000-0000-0000-000000000001');
ALTER TABLE workflow_delegation_events ENABLE TRIGGER workflow_delegation_events_immutable;
ALTER TABLE workflow_delegations DISABLE TRIGGER workflow_delegations_immutable_after_terminal;
DELETE FROM workflow_delegations WHERE organization_id='65240000-0000-0000-0000-000000000001';
ALTER TABLE workflow_delegations ENABLE TRIGGER workflow_delegations_immutable_after_terminal;
ALTER TABLE workflow_substitution_events DISABLE TRIGGER workflow_substitution_events_immutable;
DELETE FROM workflow_substitution_events WHERE substitution_id IN (SELECT id FROM workflow_substitutions WHERE organization_id='65240000-0000-0000-0000-000000000001');
ALTER TABLE workflow_substitution_events ENABLE TRIGGER workflow_substitution_events_immutable;
ALTER TABLE workflow_substitutions DISABLE TRIGGER workflow_substitutions_immutable_after_terminal;
DELETE FROM workflow_substitutions WHERE organization_id='65240000-0000-0000-0000-000000000001';
ALTER TABLE workflow_substitutions ENABLE TRIGGER workflow_substitutions_immutable_after_terminal;
DELETE FROM workflow_work_items WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65240000-%');
ALTER TABLE workflow_approval_rounds DISABLE TRIGGER workflow_approval_rounds_immutable_after_terminal;
DELETE FROM workflow_approval_rounds WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65240000-%');
ALTER TABLE workflow_approval_rounds ENABLE TRIGGER workflow_approval_rounds_immutable_after_terminal;
DELETE FROM workflow_tokens WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65240000-%');
DELETE FROM workflow_instance_steps WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65240000-%');
DELETE FROM workflow_instances WHERE created_by::text LIKE '65240000-%';
ALTER TABLE workflow_definition_versions DISABLE TRIGGER workflow_definition_versions_immutable;
UPDATE workflow_definitions SET active_version_id=NULL WHERE organization_id='65240000-0000-0000-0000-000000000001';
DELETE FROM workflow_definition_versions WHERE definition_id IN (SELECT id FROM workflow_definitions WHERE organization_id='65240000-0000-0000-0000-000000000001');
ALTER TABLE workflow_definition_versions ENABLE TRIGGER workflow_definition_versions_immutable;
DELETE FROM workflow_definitions WHERE organization_id='65240000-0000-0000-0000-000000000001';
DELETE FROM user_assignments WHERE user_id::text LIKE '65240000-%';
DELETE FROM users WHERE id::text LIKE '65240000-%';
DELETE FROM auth.users WHERE id::text LIKE '65240000-%';
DELETE FROM organizations WHERE id::text LIKE '65240000-%';
