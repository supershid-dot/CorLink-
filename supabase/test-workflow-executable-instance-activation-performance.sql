-- CAP-002 Phase 2B.2 disposable performance probe
-- Disposable local PostgreSQL only. Measures activation across the
-- dimensions the milestone specifies: a minimal Start->Approval->End
-- graph, a maximum-sized candidate snapshot, many published versions
-- in one family, many definitions in one organization, and a
-- pre-existing 100,000-row event table.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES ('65300000-0000-0000-0000-000000000001','WF Activation Performance','authority','WFAP');
INSERT INTO auth.users(id,email) VALUES ('65300000-0001-0000-0000-000000000001','perf@wfap.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('65300000-0001-0000-0000-000000000001','65300000-0000-0000-0000-000000000001','WFAP-1','Performance Admin','perf@wfap.local',true,true);

-- 100 candidate users for the maximal-electorate scenario, plus 100
-- for the many-definitions-in-one-org scenario baseline.
INSERT INTO auth.users(id,email)
SELECT ('65300000-0001-0000-0001-'||lpad(to_hex(g),12,'0'))::uuid,'perf-cand-'||g||'@wfap.local' FROM generate_series(1,100) g;
INSERT INTO users(id,org_id,service_number,full_name,email,is_active)
SELECT ('65300000-0001-0000-0001-'||lpad(to_hex(g),12,'0'))::uuid,'65300000-0000-0000-0000-000000000001',
 'WFAP-C-'||g,'Perf Candidate '||g,'perf-cand-'||g||'@wfap.local',true FROM generate_series(1,100) g;
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active)
SELECT ('65300000-0001-0000-0001-'||lpad(to_hex(g),12,'0'))::uuid,'organization','65300000-0000-0000-0000-000000000001','supervisor',false,true
FROM generate_series(1,100) g;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65300000-0001-0000-0000-000000000001"}',true);

-- ── Dimension 1: minimal Start -> Approval -> End graph ────────────
DO $$
DECLARE
  v_def UUID; v_ver UUID; v_inst UUID; v_t0 TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  SELECT definition_id, version_id INTO v_def, v_ver FROM create_workflow_definition(
    '65300000-0000-0000-0000-000000000001','wfap_minimal','WFAP Minimal','opaque_case',
    '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}'::jsonb,
    '65300000-1000-0000-0000-000000000001'
  );
  PERFORM publish_workflow_definition_version(v_ver, 0, '65300000-1000-0000-0000-000000000002');
  v_inst := create_workflow_instance(v_ver,'opaque_case','65300000-2000-0000-0000-000000000001','65300000-0000-0000-0000-000000000001','65300000-1000-0000-0000-000000000003',NULL);
  v_t0 := clock_timestamp();
  PERFORM start_workflow_instance(v_inst, 0, '65300000-1000-0000-0000-000000000004');
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  RAISE NOTICE 'Dimension 1 (minimal Start->Approval->End, 100 supervisors resolvable): % ms', round(v_ms,2);
  IF v_ms > 2000 THEN RAISE EXCEPTION 'minimal-graph activation performance regression: % ms', v_ms; END IF;
END $$;

-- ── Dimension 2: maximum allowed candidate snapshot (100 positions,
--    the documented version-1 cap) ─────────────────────────────────
DO $$
DECLARE
  v_def UUID; v_ver UUID; v_inst UUID; v_t0 TIMESTAMPTZ; v_ms NUMERIC; v_count INTEGER;
BEGIN
  SELECT definition_id, version_id INTO v_def, v_ver FROM create_workflow_definition(
    '65300000-0000-0000-0000-000000000001','wfap_max_electorate','WFAP Max Electorate','opaque_case',
    '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}'::jsonb,
    '65300000-1000-0000-0000-000000000005'
  );
  PERFORM publish_workflow_definition_version(v_ver, 0, '65300000-1000-0000-0000-000000000006');
  v_inst := create_workflow_instance(v_ver,'opaque_case','65300000-2000-0000-0000-000000000002','65300000-0000-0000-0000-000000000001','65300000-1000-0000-0000-000000000007',NULL);
  v_t0 := clock_timestamp();
  PERFORM start_workflow_instance(v_inst, 0, '65300000-1000-0000-0000-000000000008');
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  SELECT count(*) INTO v_count FROM workflow_approval_positions WHERE instance_id = v_inst;
  RAISE NOTICE 'Dimension 2 (maximum 100-position candidate snapshot, % positions, % work items): % ms',
    v_count, (SELECT count(*) FROM workflow_work_items WHERE instance_id = v_inst), round(v_ms,2);
  IF v_count <> 100 THEN RAISE EXCEPTION 'expected exactly 100 resolved positions, got %', v_count; END IF;
  IF v_ms > 3000 THEN RAISE EXCEPTION 'maximal-electorate activation performance regression: % ms', v_ms; END IF;
END $$;

-- ── Dimension 3: many published versions in one definition family ─
DO $$
DECLARE
  v_def UUID; v_ver UUID; v_inst UUID; v_t0 TIMESTAMPTZ; v_ms NUMERIC; v_i INTEGER;
  v_payload JSONB := '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"e","type":"end","config":{"outcome_code":"done"}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false}]}'::jsonb;
BEGIN
  SELECT definition_id, version_id INTO v_def, v_ver FROM create_workflow_definition(
    '65300000-0000-0000-0000-000000000001','wfap_many_versions','WFAP Many Versions','opaque_case',
    v_payload, '65300000-1000-0000-0000-000000000009'
  );
  PERFORM publish_workflow_definition_version(v_ver, 0, '65300000-1000-0000-0000-000000000010');
  FOR v_i IN 1..49 LOOP
    SELECT version_id INTO v_ver FROM create_workflow_definition_version(
      v_def,
      jsonb_set(v_payload, '{nodes,1,config,outcome_code}', to_jsonb('done_'||v_i)),
      ('65300000-1000-0000-0000-000001'||lpad(v_i::text,6,'0'))::uuid
    );
    PERFORM publish_workflow_definition_version(v_ver, v_i, ('65300000-1000-0000-0000-000002'||lpad(v_i::text,6,'0'))::uuid);
  END LOOP;
  IF (SELECT count(*) FROM workflow_definition_versions WHERE definition_id = v_def) <> 50 THEN
    RAISE EXCEPTION 'expected 50 versions under one family';
  END IF;
  v_inst := create_workflow_instance(v_ver,'opaque_case','65300000-2000-0000-0000-000000000003','65300000-0000-0000-0000-000000000001','65300000-1000-0000-0000-000000000011',NULL);
  v_t0 := clock_timestamp();
  PERFORM start_workflow_instance(v_inst, 0, '65300000-1000-0000-0000-000000000012');
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  RAISE NOTICE 'Dimension 3 (activation against the 50th published version of one family): % ms', round(v_ms,2);
  IF v_ms > 2000 THEN RAISE EXCEPTION 'many-versions activation performance regression: % ms', v_ms; END IF;
END $$;

-- ── Dimension 4: many workflow definitions in one organization ────
DO $$
DECLARE
  v_def UUID; v_ver UUID; v_inst UUID; v_t0 TIMESTAMPTZ; v_ms NUMERIC; v_i INTEGER;
BEGIN
  FOR v_i IN 1..99 LOOP
    SELECT version_id INTO v_ver FROM create_workflow_definition(
      '65300000-0000-0000-0000-000000000001','wfap_org_flow_'||v_i,'WFAP Org Flow '||v_i,'opaque_case',
      '{"nodes":[],"edges":[]}'::jsonb,
      ('65300000-1000-0000-0000-000000002'||lpad(v_i::text,3,'0'))::uuid
    );
  END LOOP;
  SELECT definition_id, version_id INTO v_def, v_ver FROM create_workflow_definition(
    '65300000-0000-0000-0000-000000000001','wfap_org_flow_100','WFAP Org Flow 100','opaque_case',
    '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"e","type":"end","config":{"outcome_code":"done"}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false}]}'::jsonb,
    '65300000-1000-0000-0000-000000003100'
  );
  PERFORM publish_workflow_definition_version(v_ver, 0, '65300000-1000-0000-0000-000000003101');
  IF (SELECT count(*) FROM workflow_definitions WHERE organization_id = '65300000-0000-0000-0000-000000000001') < 100 THEN
    RAISE EXCEPTION 'expected at least 100 definitions in the organization';
  END IF;
  v_inst := create_workflow_instance(v_ver,'opaque_case','65300000-2000-0000-0000-000000000004','65300000-0000-0000-0000-000000000001','65300000-1000-0000-0000-000000003102',NULL);
  v_t0 := clock_timestamp();
  PERFORM start_workflow_instance(v_inst, 0, '65300000-1000-0000-0000-000000003103');
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  RAISE NOTICE 'Dimension 4 (100+ definitions in one organization, activate the 100th): % ms', round(v_ms,2);
  IF v_ms > 2000 THEN RAISE EXCEPTION 'many-definitions activation performance regression: % ms', v_ms; END IF;
END $$;

RESET ROLE;

-- ── Dimension 5: pre-existing 100,000-row event table ──────────────
INSERT INTO workflow_definitions(id,organization_id,definition_key,name,subject_type,status,created_by,updated_by,create_idempotency_key)
 VALUES ('65300000-9000-0000-0000-000000000001','65300000-0000-0000-0000-000000000001','wfap_bulk_flow','WFAP Bulk Flow','opaque_case','draft','65300000-0001-0000-0000-000000000001','65300000-0001-0000-0000-000000000001','65300000-1000-0000-0000-000000009001');
INSERT INTO workflow_definition_versions(id,definition_id,version_number,status,definition_payload,content_hash,created_by,create_idempotency_key,published_by,published_at,publish_idempotency_key)
 VALUES ('65300000-9000-0000-0000-000000000002','65300000-9000-0000-0000-000000000001',1,'published','{"nodes":[],"edges":[]}',encode(digest(convert_to('{"edges": [], "nodes": []}'::jsonb::text,'UTF8'),'sha256'),'hex'),'65300000-0001-0000-0000-000000000001','65300000-1000-0000-0000-000000009002','65300000-0001-0000-0000-000000000001',now(),'65300000-1000-0000-0000-000000009003');
UPDATE workflow_definitions SET status='active',active_version_id='65300000-9000-0000-0000-000000000002' WHERE id='65300000-9000-0000-0000-000000000001';

INSERT INTO workflow_instances(id,definition_id,definition_version_id,subject_type,subject_id,home_organization_id,participant_organization_ids,status,correlation_id,created_by,create_idempotency_key,next_event_sequence)
 VALUES ('65300000-9000-0000-0000-000000000003','65300000-9000-0000-0000-000000000001','65300000-9000-0000-0000-000000000002','opaque_case','65300000-9000-0000-0000-000000000004','65300000-0000-0000-0000-000000000001',ARRAY['65300000-0000-0000-0000-000000000001'::uuid],'pending','65300000-9000-0000-0000-000000000005','65300000-0001-0000-0000-000000000001','65300000-1000-0000-0000-000000009004',100001);

INSERT INTO workflow_events(instance_id,event_sequence,event_type,actor_id,correlation_id,idempotency_key,metadata,created_at)
SELECT '65300000-9000-0000-0000-000000000003',g,'instance_created','65300000-0001-0000-0000-000000000001',
  '65300000-9000-0000-0000-000000000005',('65300000-9000-0000-0001-'||lpad(to_hex(g),12,'0'))::uuid,'{}'::jsonb,now()-((100000-g)||' seconds')::interval
FROM generate_series(1,100000) g;

DO $$
DECLARE v_t0 TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"65300000-0001-0000-0000-000000000001"}',true);
  v_t0 := clock_timestamp();
  PERFORM start_workflow_instance('65300000-9000-0000-0000-000000000003', 0, '65300000-1000-0000-0000-000000009005');
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  RAISE NOTICE 'Dimension 5 (activation against an instance whose event table already has 100,000 rows): % ms', round(v_ms,2);
  IF v_ms > 2000 THEN RAISE EXCEPTION 'large-event-table activation performance regression: % ms', v_ms; END IF;
END $$;

EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM workflow_events WHERE instance_id = '65300000-9000-0000-0000-000000000003' ORDER BY event_sequence DESC LIMIT 100;

ROLLBACK;

DO $$ BEGIN RAISE NOTICE 'Workflow executable instance activation performance probe PASSED'; END $$;
