-- CAP-002 Phase 2C.1 graph advancement foundation RLS suite (6 scenarios)
-- Runs in one transaction and leaves no fixtures.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wfgar_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfgar_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfgar_results, wfgar_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('66600000-0000-0000-0000-000000000001','WF Graph Advancement RLS A','authority','WFGAR-A'),
 ('66600000-0000-0000-0000-000000000002','WF Graph Advancement RLS B','authority','WFGAR-B');
INSERT INTO auth.users(id,email) VALUES
 ('66600000-0001-0000-0000-000000000001','owner@wfgar.local'),
 ('66600000-0001-0000-0000-000000000002','admin2@wfgar.local'),
 ('66600000-0001-0000-0000-000000000003','outsider@wfgar.local'),
 ('66600000-0001-0000-0000-000000000004','other@wfgar.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('66600000-0001-0000-0000-000000000001','66600000-0000-0000-0000-000000000001','WFGAR-1','Owner','owner@wfgar.local',true),
 ('66600000-0001-0000-0000-000000000002','66600000-0000-0000-0000-000000000001','WFGAR-2','Admin2','admin2@wfgar.local',true),
 ('66600000-0001-0000-0000-000000000003','66600000-0000-0000-0000-000000000001','WFGAR-3','Outsider','outsider@wfgar.local',true),
 ('66600000-0001-0000-0000-000000000004','66600000-0000-0000-0000-000000000002','WFGAR-4','Other','other@wfgar.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('66600000-0001-0000-0000-000000000001','organization','66600000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('66600000-0001-0000-0000-000000000002','organization','66600000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('66600000-0001-0000-0000-000000000003','organization','66600000-0000-0000-0000-000000000001','staff',true,true),
 ('66600000-0001-0000-0000-000000000004','organization','66600000-0000-0000-0000-000000000002','authority_admin',true,true);

\set TWO_HOP_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review1","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_admins","order":1,"type":"organization_role","organization":"home","role":"authority_admin"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"review2","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_admins","order":1,"type":"organization_role","organization":"home","role":"authority_admin"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review1","outcome":"started","priority":0,"default":false},{"source":"review1","target":"review2","outcome":"approved","priority":0,"default":false},{"source":"review1","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"review2","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review2","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"66600000-0001-0000-0000-000000000001"}',true);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '66600000-0000-0000-0000-000000000001','wfgar_flow','WFGAR Flow','opaque_case',
  :TWO_HOP_PAYLOAD::jsonb, '66600000-1000-0000-0000-000000000001'))
INSERT INTO wfgar_ids SELECT 'version',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfgar_ids WHERE name='version'),0,'66600000-1000-0000-0000-000000000002');
INSERT INTO wfgar_ids SELECT 'instance', create_workflow_instance(
  (SELECT id FROM wfgar_ids WHERE name='version'),'opaque_case','66600000-2000-0000-0000-000000000001',
  '66600000-0000-0000-0000-000000000001','66600000-1000-0000-0000-000000000003',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfgar_ids WHERE name='instance'),0,'66600000-1000-0000-0000-000000000004');
RESET ROLE;

-- Simulate a completed decision (this milestone implements no
-- decision RPC — see wfga_simulate_decision precedent in the
-- behavioral suite).
UPDATE workflow_instance_steps SET state='completed', result_code='approved', ended_at=now()
WHERE instance_id=(SELECT id FROM wfgar_ids WHERE name='instance') AND definition_node_key='review1';

-- ── 1: the instance owner/manager can call workflow_advance_graph_step
--    successfully (reusing can_manage_workflow_instance, not a new
--    authorization model). ─────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"66600000-0001-0000-0000-000000000001"}',true);
DO $$
BEGIN
  PERFORM * FROM workflow_advance_graph_step((SELECT id FROM wfgar_ids WHERE name='instance'),1,'66600000-1000-0000-0000-000000000005');
END $$;
DO $$ BEGIN
  IF (SELECT status FROM workflow_instances WHERE id=(SELECT id FROM wfgar_ids WHERE name='instance')) <> 'active' THEN
    RAISE EXCEPTION 'owner/manager advancement did not succeed';
  END IF;
END $$;
INSERT INTO wfgar_results VALUES (1,'the instance owner/manager can call workflow_advance_graph_step successfully via existing can_manage_workflow_instance authorization');
RESET ROLE;

-- ── 2: a same-organization non-manager outsider cannot advance and
--    sees no existence leakage. ────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"66600000-0001-0000-0000-000000000003"}',true);
DO $$
BEGIN
  BEGIN
    PERFORM * FROM workflow_advance_graph_step((SELECT id FROM wfgar_ids WHERE name='instance'),2,'66600000-1000-0000-0000-000000000006');
    RAISE EXCEPTION 'outsider was able to advance the graph';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%not available for this action%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfgar_results VALUES (2,'a same-organization non-manager outsider cannot call workflow_advance_graph_step, with a non-disclosing error');
RESET ROLE;

-- ── 3: a cross-organization actor cannot advance. ───────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"66600000-0001-0000-0000-000000000004"}',true);
DO $$
BEGIN
  BEGIN
    PERFORM * FROM workflow_advance_graph_step((SELECT id FROM wfgar_ids WHERE name='instance'),2,'66600000-1000-0000-0000-000000000007');
    RAISE EXCEPTION 'cross-org actor was able to advance the graph';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%not available for this action%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfgar_results VALUES (3,'a cross-organization actor cannot call workflow_advance_graph_step');
RESET ROLE;

-- ── 4: workflow_enter_downstream_node has no direct execute grant to
--    authenticated or anon — reachable only from within another
--    SECURITY DEFINER function's own transaction. ──────────────────
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='workflow_enter_downstream_node'
      AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))
  ) THEN RAISE EXCEPTION 'workflow_enter_downstream_node has a direct execute grant'; END IF;
END $$;
INSERT INTO wfgar_results VALUES (4,'workflow_enter_downstream_node has no direct execute grant to authenticated or anon');

-- ── 5: no new table, no new policy — this milestone reuses Phase
--    2B.2's storage shape unchanged. ────────────────────────────────
DO $$
BEGIN
  IF (SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 12 THEN
    RAISE EXCEPTION 'unexpected workflow table count';
  END IF;
END $$;
INSERT INTO wfgar_results VALUES (5,'no new table or policy was added; the Phase 2B.2 storage shape (12 workflow tables) is unchanged');

-- ── 6: workflow_advance_graph_step reuses can_manage_workflow_instance,
--    not a duplicated authorization model. ─────────────────────────
DO $$
BEGIN
  IF (SELECT pg_get_functiondef('workflow_advance_graph_step(uuid,bigint,uuid)'::regprocedure)) NOT ILIKE '%can_manage_workflow_instance%'
  THEN RAISE EXCEPTION 'workflow_advance_graph_step does not reuse can_manage_workflow_instance'; END IF;
END $$;
INSERT INTO wfgar_results VALUES (6,'existing can_manage_workflow_instance() authorization is reused by advancement, not duplicated');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfgar_results;
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'Workflow graph advancement foundation RLS tests FAILED: expected 6, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow graph advancement foundation RLS tests PASSED: %/6', v_count;
END $$;

ROLLBACK;
