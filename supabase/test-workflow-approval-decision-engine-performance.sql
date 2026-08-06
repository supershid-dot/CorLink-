-- CAP-002 Phase 3.1 disposable performance probe
-- Disposable local PostgreSQL only. Measures decide_workflow_work_item
-- across three dimensions: a minimal single-elector terminal decision
-- (decide + close round + complete step + graph-advance to End), a
-- maximal 100-candidate round's final closing decision (measures the
-- A/R/B/U aggregate recount over 100 positions plus the O(offered)
-- work-item/position cancellation loop), and a decision against an
-- instance whose event table already has 100,000 rows.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES ('67400000-0000-0000-0000-000000000001','WF Approval Performance','authority','WFADP');
INSERT INTO auth.users(id,email) VALUES ('67400000-0001-0000-0000-000000000001','perf@wfadp.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('67400000-0001-0000-0000-000000000001','67400000-0000-0000-0000-000000000001','WFADP-1','Performance Admin','perf@wfadp.local',true,true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('67400000-0001-0000-0000-000000000001','organization','67400000-0000-0000-0000-000000000001','authority_admin',true,true);

\set SINGLE_PAYLOAD '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"unanimous","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"immediate","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"s1","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}'

-- psql :VAR substitution does not work inside DO $$ ... $$ blocks —
-- stage the payload in a temp table instead, referenced from within
-- each DO block below (the same established workaround Phase 2C.1's
-- own performance probe and behavioral suite used).
CREATE TEMP TABLE wfadp_payloads (name TEXT PRIMARY KEY, payload JSONB);
INSERT INTO wfadp_payloads VALUES ('single', :'SINGLE_PAYLOAD'::jsonb);
GRANT SELECT ON wfadp_payloads TO authenticated;

-- ── Dimension 1: minimal single-elector terminal decision
--    (decide -> close round -> complete step -> graph-advance to End) ─
INSERT INTO auth.users(id,email) VALUES ('67400000-0001-0000-0000-000000000002','sup1@wfadp.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('67400000-0001-0000-0000-000000000002','67400000-0000-0000-0000-000000000001','WFADP-2','Sup1','sup1@wfadp.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('67400000-0001-0000-0000-000000000002','organization','67400000-0000-0000-0000-000000000001','supervisor',true,true);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67400000-0001-0000-0000-000000000001"}',true);
DO $$
DECLARE
  v_def UUID; v_ver UUID; v_inst UUID; v_wi UUID; v_t0 TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  SELECT definition_id, version_id INTO v_def, v_ver FROM create_workflow_definition(
    '67400000-0000-0000-0000-000000000001','wfadp_minimal','WFADP Minimal','opaque_case',
    (SELECT payload FROM wfadp_payloads WHERE name='single'), '67400000-1000-0000-0000-000000000001'
  );
  PERFORM publish_workflow_definition_version(v_ver, 0, '67400000-1000-0000-0000-000000000002');
  v_inst := create_workflow_instance(v_ver,'opaque_case','67400000-2000-0000-0000-000000000001','67400000-0000-0000-0000-000000000001','67400000-1000-0000-0000-000000000003',NULL);
  PERFORM start_workflow_instance(v_inst, 0, '67400000-1000-0000-0000-000000000004');
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id = v_inst;

  PERFORM set_config('request.jwt.claims','{"sub":"67400000-0001-0000-0000-000000000002"}',true);
  v_t0 := clock_timestamp();
  PERFORM decide_workflow_work_item(v_wi, 'approve', 1, 0, '67400000-1000-0000-0000-000000000005');
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  PERFORM set_config('request.jwt.claims','{"sub":"67400000-0001-0000-0000-000000000001"}',true);
  RAISE NOTICE 'Dimension 1 (minimal single-elector terminal decision, decide->close round->complete step->End): % ms', round(v_ms,2);
  IF (SELECT status FROM workflow_instances WHERE id=v_inst) <> 'completed' THEN
    RAISE EXCEPTION 'dimension 1 fixture did not complete as expected';
  END IF;
  IF v_ms > 2000 THEN RAISE EXCEPTION 'minimal-decision performance regression: % ms', v_ms; END IF;
END $$;

-- ── Dimension 2: maximal 100-candidate round's final closing
--    decision (majority threshold=51; the 51st approval must recount
--    A/R/B/U across 100 positions and cancel up to 49 still-offered
--    work items/positions atomically). ──────────────────────────────
RESET ROLE;
INSERT INTO auth.users(id,email)
SELECT ('67400000-0001-0000-0001-'||lpad(to_hex(g),12,'0'))::uuid,'perf-cand-'||g||'@wfadp.local' FROM generate_series(1,100) g;
INSERT INTO users(id,org_id,service_number,full_name,email,is_active)
SELECT ('67400000-0001-0000-0001-'||lpad(to_hex(g),12,'0'))::uuid,'67400000-0000-0000-0000-000000000001',
 'WFADP-C-'||g,'Perf Candidate '||g,'perf-cand-'||g||'@wfadp.local',true FROM generate_series(1,100) g;
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active)
SELECT ('67400000-0001-0000-0001-'||lpad(to_hex(g),12,'0'))::uuid,'organization','67400000-0000-0000-0000-000000000001','assigned_receiver',false,true
FROM generate_series(1,100) g;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67400000-0001-0000-0000-000000000001"}',true);
DO $$
DECLARE
  v_def UUID; v_ver UUID; v_inst UUID; v_wi UUID; v_actor UUID; v_lock BIGINT := 1;
  v_t0 TIMESTAMPTZ; v_ms NUMERIC; v_n INTEGER := 0; v_cancelled INTEGER;
BEGIN
  SELECT definition_id, version_id INTO v_def, v_ver FROM create_workflow_definition(
    '67400000-0000-0000-0000-000000000001','wfadp_max_electorate','WFADP Max Electorate','opaque_case',
    jsonb_set(jsonb_set((SELECT payload FROM wfadp_payloads WHERE name='single'), '{nodes,1,config,candidate_selectors,0,role}', '"assigned_receiver"'),
      '{nodes,1,config,decision_rule}', '"majority"'),
    '67400000-1000-0000-0000-000000000006'
  );
  PERFORM publish_workflow_definition_version(v_ver, 0, '67400000-1000-0000-0000-000000000007');
  v_inst := create_workflow_instance(v_ver,'opaque_case','67400000-2000-0000-0000-000000000002','67400000-0000-0000-0000-000000000001','67400000-1000-0000-0000-000000000008',NULL);
  PERFORM start_workflow_instance(v_inst, 0, '67400000-1000-0000-0000-000000000009');

  IF (SELECT approval_threshold FROM workflow_approval_rounds WHERE instance_id=v_inst) <> 51 THEN
    RAISE EXCEPTION 'expected threshold 51 for N=100 majority, got %', (SELECT approval_threshold FROM workflow_approval_rounds WHERE instance_id=v_inst);
  END IF;

  FOR v_actor IN
    SELECT user_id FROM workflow_approval_positions WHERE instance_id=v_inst ORDER BY ordinal LIMIT 51
  LOOP
    v_n := v_n + 1;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
    SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_inst AND assigned_to=v_actor;
    IF v_n < 51 THEN
      PERFORM decide_workflow_work_item(v_wi, 'approve', v_lock, 0, gen_random_uuid());
      v_lock := v_lock + 1;
    ELSE
      v_t0 := clock_timestamp();
      PERFORM decide_workflow_work_item(v_wi, 'approve', v_lock, 0, gen_random_uuid());
      v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
    END IF;
  END LOOP;
  PERFORM set_config('request.jwt.claims','{"sub":"67400000-0001-0000-0000-000000000001"}',true);

  SELECT count(*) INTO v_cancelled FROM workflow_work_items WHERE instance_id=v_inst AND state='cancelled';
  RAISE NOTICE 'Dimension 2 (100-position round, 51st/threshold-crossing decision, % still-offered items cancelled): % ms', v_cancelled, round(v_ms,2);
  IF (SELECT status FROM workflow_instances WHERE id=v_inst) <> 'completed' THEN
    RAISE EXCEPTION 'dimension 2 fixture did not complete as expected';
  END IF;
  IF v_cancelled <> 49 THEN RAISE EXCEPTION 'expected exactly 49 cancelled still-offered work items, got %', v_cancelled; END IF;
  IF v_ms > 3000 THEN RAISE EXCEPTION 'maximal-electorate closing-decision performance regression: % ms', v_ms; END IF;
END $$;

RESET ROLE;
CREATE TEMP TABLE wfadp_bulk_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfadp_bulk_ids TO authenticated;

-- ── Dimension 3: decision against an instance whose event table
--    already has 100,000 rows. The definition/version, instance,
--    round, position, and work item are created through the real
--    RPCs (as authenticated) so publication integrity and every
--    composite (id, instance_id) foreign key this milestone added
--    are exactly what production code would produce — only the bulk
--    event history is hand-inserted. ────────────────────────────────
INSERT INTO auth.users(id,email) VALUES ('67400000-0001-0000-0000-000000000003','sup2@wfadp.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('67400000-0001-0000-0000-000000000003','67400000-0000-0000-0000-000000000001','WFADP-3','Sup2','sup2@wfadp.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('67400000-0001-0000-0000-000000000003','organization','67400000-0000-0000-0000-000000000001','supervisor',true,true);
-- Dimension 1's sup1 is also a 'supervisor' in this org; deactivate
-- that assignment so this dimension's round resolves a single-elector
-- electorate (sup2 only), matching its intended fixture shape.
UPDATE user_assignments SET is_active=false
  WHERE user_id='67400000-0001-0000-0000-000000000002' AND role='supervisor';

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67400000-0001-0000-0000-000000000001"}',true);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '67400000-0000-0000-0000-000000000001','wfadp_bulk_flow','WFADP Bulk Flow','opaque_case',
  :'SINGLE_PAYLOAD'::jsonb, '67400000-1000-0000-0000-000000009000'))
INSERT INTO wfadp_bulk_ids SELECT 'def',definition_id FROM made UNION ALL SELECT 'ver',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfadp_bulk_ids WHERE name='ver'),0,'67400000-1000-0000-0000-000000009001');
INSERT INTO wfadp_bulk_ids SELECT 'inst', create_workflow_instance(
  (SELECT id FROM wfadp_bulk_ids WHERE name='ver'),'opaque_case','67400000-2000-0000-0000-000000000003',
  '67400000-0000-0000-0000-000000000001','67400000-1000-0000-0000-000000009002',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfadp_bulk_ids WHERE name='inst'),0,'67400000-1000-0000-0000-000000009003');
INSERT INTO wfadp_bulk_ids SELECT 'wi', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wfadp_bulk_ids WHERE name='inst');
RESET ROLE;

-- Bulk-insert 100,000 filler events (append-only, distinct sequence
-- range above the handful the real setup above already produced),
-- then repoint the instance's next_event_sequence past them, exactly
-- mirroring Phase 2C.1's own Dimension 3 methodology.
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfadp_bulk_ids WHERE name='inst'); v_start BIGINT;
BEGIN
  SELECT next_event_sequence INTO v_start FROM workflow_instances WHERE id=v_iid;
  INSERT INTO workflow_events(instance_id,event_sequence,event_type,actor_id,correlation_id,idempotency_key,metadata,created_at)
  SELECT v_iid, v_start - 1 + g, 'instance_created', '67400000-0001-0000-0000-000000000001',
    (SELECT correlation_id FROM workflow_instances WHERE id=v_iid), gen_random_uuid(), '{}'::jsonb,
    now() - ((100000-g)||' seconds')::interval
  FROM generate_series(1,100000) g;
  UPDATE workflow_instances SET next_event_sequence = v_start - 1 + 100001 WHERE id=v_iid;
END $$;

DO $$
DECLARE v_t0 TIMESTAMPTZ; v_ms NUMERIC; v_iid UUID := (SELECT id FROM wfadp_bulk_ids WHERE name='inst'); v_wi UUID := (SELECT id FROM wfadp_bulk_ids WHERE name='wi');
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"67400000-0001-0000-0000-000000000003"}',true);
  v_t0 := clock_timestamp();
  PERFORM decide_workflow_work_item(v_wi, 'approve', 1, 0, gen_random_uuid());
  v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
  RAISE NOTICE 'Dimension 3 (decision against an instance whose event table already has 100,000 rows): % ms', round(v_ms,2);
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed' THEN
    RAISE EXCEPTION 'dimension 3 fixture did not complete as expected';
  END IF;
  IF v_ms > 2000 THEN RAISE EXCEPTION 'large-event-table decision performance regression: % ms', v_ms; END IF;
END $$;

-- Statistics on the just-bulk-inserted rows are stale within this
-- single transaction (autovacuum has not run); ANALYZE so the
-- diagnostic EXPLAIN below reflects steady-state planning, not a
-- transient cold-statistics artifact.
RESET ROLE;
ANALYZE workflow_events;

EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM workflow_events WHERE instance_id = (SELECT id FROM wfadp_bulk_ids WHERE name='inst') ORDER BY event_sequence DESC LIMIT 100;

ROLLBACK;

DO $$ BEGIN RAISE NOTICE 'Workflow approval decision engine performance probe PASSED'; END $$;
