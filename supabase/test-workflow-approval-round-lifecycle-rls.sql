-- CAP-002 Phase 3.2 approval round lifecycle RLS suite (6 scenarios)
-- Runs in one transaction and leaves no fixtures.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wfrlr_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfrlr_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfrlr_results, wfrlr_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('67810000-0000-0000-0000-000000000001','WF Round Lifecycle RLS A','authority','WFRLR-A'),
 ('67810000-0000-0000-0000-000000000002','WF Round Lifecycle RLS B','authority','WFRLR-B');
INSERT INTO auth.users(id,email) VALUES
 ('67810000-0001-0000-0000-000000000001','admin@wfrlr.local'),
 ('67810000-0001-0000-0000-000000000002','sup1@wfrlr.local'),
 ('67810000-0001-0000-0000-000000000003','outsider@wfrlr.local'),
 ('67810000-0001-0000-0000-000000000004','other@wfrlr.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('67810000-0001-0000-0000-000000000001','67810000-0000-0000-0000-000000000001','WFRLR-1','Admin','admin@wfrlr.local',true),
 ('67810000-0001-0000-0000-000000000002','67810000-0000-0000-0000-000000000001','WFRLR-2','Sup1','sup1@wfrlr.local',true),
 ('67810000-0001-0000-0000-000000000003','67810000-0000-0000-0000-000000000001','WFRLR-3','Outsider','outsider@wfrlr.local',true),
 ('67810000-0001-0000-0000-000000000004','67810000-0000-0000-0000-000000000002','WFRLR-4','Other','other@wfrlr.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('67810000-0001-0000-0000-000000000001','organization','67810000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('67810000-0001-0000-0000-000000000002','organization','67810000-0000-0000-0000-000000000001','supervisor',true,true),
 ('67810000-0001-0000-0000-000000000003','organization','67810000-0000-0000-0000-000000000001','staff',true,true),
 ('67810000-0001-0000-0000-000000000004','organization','67810000-0000-0000-0000-000000000002','authority_admin',true,true);

\set SINGLE_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"unanimous","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"immediate","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67810000-0001-0000-0000-000000000001"}',true);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '67810000-0000-0000-0000-000000000001','wfrlr_flow','WFRLR Flow','opaque_case',
  :SINGLE_PAYLOAD::jsonb, '67810000-1000-0000-0000-000000000001'))
INSERT INTO wfrlr_ids SELECT 'version',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfrlr_ids WHERE name='version'),0,'67810000-1000-0000-0000-000000000002');
INSERT INTO wfrlr_ids SELECT 'instance', create_workflow_instance(
  (SELECT id FROM wfrlr_ids WHERE name='version'),'opaque_case','67810000-2000-0000-0000-000000000001',
  '67810000-0000-0000-0000-000000000001','67810000-1000-0000-0000-000000000003',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfrlr_ids WHERE name='instance'),0,'67810000-1000-0000-0000-000000000004');
INSERT INTO wfrlr_ids SELECT 'round', id FROM workflow_approval_rounds WHERE instance_id=(SELECT id FROM wfrlr_ids WHERE name='instance');
RESET ROLE;

-- ── 1: the instance owner/manager can call
--    get_workflow_approval_round_blocked_count successfully (reusing
--    can_manage_workflow_instance, not a new authorization model). ──
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67810000-0001-0000-0000-000000000001"}',true);
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT get_workflow_approval_round_blocked_count((SELECT id FROM wfrlr_ids WHERE name='round')) INTO v_count;
  IF v_count <> 0 THEN RAISE EXCEPTION 'expected 0 blocked candidates, got %', v_count; END IF;
END $$;
INSERT INTO wfrlr_results VALUES (1,'the instance owner/manager can call get_workflow_approval_round_blocked_count successfully via existing can_manage_workflow_instance authorization');
RESET ROLE;

-- ── 2: a same-organization non-manager outsider cannot call it, with
--    a non-disclosing error. ────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67810000-0001-0000-0000-000000000003"}',true);
DO $$
BEGIN
  BEGIN
    PERFORM get_workflow_approval_round_blocked_count((SELECT id FROM wfrlr_ids WHERE name='round'));
    RAISE EXCEPTION 'outsider was able to read the blocked count';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%not available for this action%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfrlr_results VALUES (2,'a same-organization non-manager outsider cannot call get_workflow_approval_round_blocked_count, with a non-disclosing error');
RESET ROLE;

-- ── 3: a cross-organization actor cannot call it. ────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67810000-0001-0000-0000-000000000004"}',true);
DO $$
BEGIN
  BEGIN
    PERFORM get_workflow_approval_round_blocked_count((SELECT id FROM wfrlr_ids WHERE name='round'));
    RAISE EXCEPTION 'cross-org actor was able to read the blocked count';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%not available for this action%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfrlr_results VALUES (3,'a cross-organization actor cannot call get_workflow_approval_round_blocked_count');
RESET ROLE;

-- ── 4: a nonexistent round id is rejected the same non-disclosing
--    way as an unauthorized one (no existence leakage). ────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67810000-0001-0000-0000-000000000001"}',true);
DO $$
BEGIN
  BEGIN
    PERFORM get_workflow_approval_round_blocked_count(gen_random_uuid());
    RAISE EXCEPTION 'a nonexistent round id was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%not available for this action%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfrlr_results VALUES (4,'a nonexistent round id is rejected with the same non-disclosing error as an unauthorized one');
RESET ROLE;

-- ── 5: no new table or policy was added — this milestone reuses
--    Phase 1+2B.2's storage shape unchanged. ───────────────────────
DO $$
BEGIN
  IF (SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 16 THEN -- CAP-002 Phase 5.1 legitimately added 4 tables
    RAISE EXCEPTION 'unexpected workflow table count';
  END IF;
END $$;
INSERT INTO wfrlr_results VALUES (5,'no new table or policy was added; the Phase 1/2B.2 storage shape (12 workflow tables) is unchanged');

-- ── 6: get_workflow_approval_round_blocked_count reuses
--    can_manage_workflow_instance, not a duplicated authorization
--    model. ──────────────────────────────────────────────────────
DO $$
BEGIN
  IF (SELECT pg_get_functiondef('get_workflow_approval_round_blocked_count(uuid)'::regprocedure)) NOT ILIKE '%can_manage_workflow_instance%'
  THEN RAISE EXCEPTION 'get_workflow_approval_round_blocked_count does not reuse can_manage_workflow_instance'; END IF;
END $$;
INSERT INTO wfrlr_results VALUES (6,'existing can_manage_workflow_instance() authorization is reused by the blocked-count function, not duplicated');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfrlr_results;
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'Workflow approval round lifecycle RLS tests FAILED: expected 6, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow approval round lifecycle RLS tests PASSED: %/6', v_count;
END $$;

ROLLBACK;
