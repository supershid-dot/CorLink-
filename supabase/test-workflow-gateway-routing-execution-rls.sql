-- CAP-002 Phase 4.2 gateway routing execution RLS suite (6 scenarios).
-- Runs in one transaction and leaves no fixtures.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wfger_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfger_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfger_results, wfger_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('64980000-0000-0000-0000-000000000001','WF Gateway Exec RLS A','authority','WFGER-A'),
 ('64980000-0000-0000-0000-000000000002','WF Gateway Exec RLS B','authority','WFGER-B');
INSERT INTO auth.users(id,email) VALUES
 ('64980000-0001-0000-0000-000000000001','admin@wfger.local'),
 ('64980000-0001-0000-0000-000000000002','outsider@wfger.local'),
 ('64980000-0001-0000-0000-000000000003','otherorg@wfger.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('64980000-0001-0000-0000-000000000001','64980000-0000-0000-0000-000000000001','WFGER-1','Admin','admin@wfger.local',true),
 ('64980000-0001-0000-0000-000000000002','64980000-0000-0000-0000-000000000001','WFGER-2','Outsider','outsider@wfger.local',true),
 ('64980000-0001-0000-0000-000000000003','64980000-0000-0000-0000-000000000002','WFGER-3','OtherOrg','otherorg@wfger.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('64980000-0001-0000-0000-000000000001','organization','64980000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('64980000-0001-0000-0000-000000000002','organization','64980000-0000-0000-0000-000000000001','staff',true,true),
 ('64980000-0001-0000-0000-000000000003','organization','64980000-0000-0000-0000-000000000002','authority_admin',true,true);

\set GW_PAYLOAD '\'{"schema_version":2,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"gw","type":"gateway_exclusive","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"b_end","type":"end","config":{"outcome_code":"b"}}],"edges":[{"source":"start","target":"gw","outcome":"started","priority":0,"default":false},{"source":"gw","target":"a_end","outcome":"routed","priority":0,"default":false,"condition":{"source":"instance_variable","variable_name":"x","operator":"is_null"}},{"source":"gw","target":"b_end","outcome":"routed","priority":1,"default":true}]}\''

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64980000-0001-0000-0000-000000000001"}',true);
WITH made AS (SELECT * FROM create_workflow_definition(
  '64980000-0000-0000-0000-000000000001','wfger_flow','WFGER Flow','opaque_case',
  :GW_PAYLOAD::jsonb, gen_random_uuid()))
INSERT INTO wfger_ids SELECT 'v', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfger_ids WHERE name='v'),0,gen_random_uuid());
INSERT INTO wfger_ids SELECT 'i', create_workflow_instance(
  (SELECT id FROM wfger_ids WHERE name='v'),'opaque_case',gen_random_uuid(),
  '64980000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfger_ids WHERE name='i'),0,gen_random_uuid());
RESET ROLE;

-- ── 1: the instance's own manager can see the route_selected event
--    produced by routing through the gateway, via the existing,
--    unmodified workflow_events_select policy. ─────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64980000-0001-0000-0000-000000000001"}',true);
DO $$
BEGIN
  IF (SELECT count(*) FROM workflow_events WHERE instance_id=(SELECT id FROM wfger_ids WHERE name='i') AND event_type='route_selected') <> 1
  THEN RAISE EXCEPTION 'expected the manager to see exactly one route_selected event'; END IF;
END $$;
INSERT INTO wfger_results VALUES (1,'the instance manager can see the route_selected event via the existing, unmodified workflow_events_select policy');
RESET ROLE;

-- ── 2: a same-organization non-manager outsider cannot see the
--    route_selected event (no new RLS relaxation for the new event
--    type). ──────────────────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64980000-0001-0000-0000-000000000002"}',true);
DO $$
BEGIN
  IF (SELECT count(*) FROM workflow_events WHERE instance_id=(SELECT id FROM wfger_ids WHERE name='i') AND event_type='route_selected') <> 0
  THEN RAISE EXCEPTION 'expected a same-org non-manager outsider to see zero route_selected events'; END IF;
END $$;
INSERT INTO wfger_results VALUES (2,'a same-organization non-manager outsider cannot see the route_selected event');
RESET ROLE;

-- ── 3: a cross-organization actor cannot see the route_selected
--    event either. ──────────────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64980000-0001-0000-0000-000000000003"}',true);
DO $$
BEGIN
  IF (SELECT count(*) FROM workflow_events WHERE instance_id=(SELECT id FROM wfger_ids WHERE name='i') AND event_type='route_selected') <> 0
  THEN RAISE EXCEPTION 'expected a cross-organization actor to see zero route_selected events'; END IF;
END $$;
INSERT INTO wfger_results VALUES (3,'a cross-organization actor cannot see the route_selected event');
RESET ROLE;

-- ── 4: an outsider cannot start/advance a gateway-containing
--    instance — reuses the exact existing can_manage_workflow_instance
--    boundary, no new permission model for gateway execution. ──────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64980000-0001-0000-0000-000000000001"}',true);
WITH made AS (SELECT * FROM create_workflow_definition(
  '64980000-0000-0000-0000-000000000001','wfger_flow2','WFGER Flow2','opaque_case',
  :GW_PAYLOAD::jsonb, gen_random_uuid()))
INSERT INTO wfger_ids SELECT 'v2', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfger_ids WHERE name='v2'),0,gen_random_uuid());
INSERT INTO wfger_ids SELECT 'i2', create_workflow_instance(
  (SELECT id FROM wfger_ids WHERE name='v2'),'opaque_case',gen_random_uuid(),
  '64980000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64980000-0001-0000-0000-000000000002"}',true);
DO $$
BEGIN
  BEGIN
    PERFORM start_workflow_instance((SELECT id FROM wfger_ids WHERE name='i2'),0,gen_random_uuid());
    RAISE EXCEPTION 'a non-manager outsider was able to start a gateway-containing instance';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%not available for this action%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfger_results VALUES (4,'a same-organization non-manager outsider cannot activate a gateway-containing instance; reuses the existing can_manage_workflow_instance boundary');
RESET ROLE;

-- ── 5: workflow_variables visibility remains governed solely by the
--    existing Phase 1 SELECT-only policy — reading a variable inside
--    gateway condition evaluation happens server-side under SECURITY
--    DEFINER and does not expose it more broadly. ──────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64980000-0001-0000-0000-000000000001"}',true);
SELECT set_workflow_instance_variable((SELECT id FROM wfger_ids WHERE name='i2'),'x','boolean','true'::jsonb,'restricted',gen_random_uuid());
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64980000-0001-0000-0000-000000000002"}',true);
DO $$
BEGIN
  IF (SELECT count(*) FROM workflow_variables WHERE instance_id=(SELECT id FROM wfger_ids WHERE name='i2')) <> 0
  THEN RAISE EXCEPTION 'expected the outsider to see zero workflow_variables rows'; END IF;
END $$;
INSERT INTO wfger_results VALUES (5,'workflow_variables visibility remains governed solely by the existing Phase 1 SELECT-only policy, unaffected by gateway condition evaluation');
RESET ROLE;

-- ── 6: no new table or policy was added for gateway routing
--    execution — still exactly 12 workflow tables, and
--    workflow_events retains its single existing SELECT policy. ────
DO $$
BEGIN
  IF (SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 16 THEN -- CAP-002 Phase 5.1 legitimately added 4 tables
    RAISE EXCEPTION 'unexpected workflow table count';
  END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='workflow_events') <> 1 THEN
    RAISE EXCEPTION 'expected workflow_events to retain exactly one SELECT policy';
  END IF;
END $$;
INSERT INTO wfger_results VALUES (6,'no new table or policy was added for gateway routing execution; workflow_events retains its single existing SELECT policy');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfger_results;
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'Workflow gateway routing execution RLS tests FAILED: expected 6, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow gateway routing execution RLS tests PASSED: %/6', v_count;
END $$;

ROLLBACK;
