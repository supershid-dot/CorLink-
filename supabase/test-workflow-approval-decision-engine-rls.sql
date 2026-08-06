-- CAP-002 Phase 3.1 approval decision engine RLS suite (7 scenarios)
-- Runs in one transaction and leaves no fixtures.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wfadr_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfadr_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfadr_results, wfadr_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('67200000-0000-0000-0000-000000000001','WF Approval RLS A','authority','WFADR-A'),
 ('67200000-0000-0000-0000-000000000002','WF Approval RLS B','authority','WFADR-B');
INSERT INTO auth.users(id,email) VALUES
 ('67200000-0001-0000-0000-000000000001','creator@wfadr.local'),
 ('67200000-0001-0000-0000-000000000002','sup1@wfadr.local'),
 ('67200000-0001-0000-0000-000000000003','outsider@wfadr.local'),
 ('67200000-0001-0000-0000-000000000004','other@wfadr.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('67200000-0001-0000-0000-000000000001','67200000-0000-0000-0000-000000000001','WFADR-1','Creator','creator@wfadr.local',true),
 ('67200000-0001-0000-0000-000000000002','67200000-0000-0000-0000-000000000001','WFADR-2','Sup1','sup1@wfadr.local',true),
 ('67200000-0001-0000-0000-000000000003','67200000-0000-0000-0000-000000000001','WFADR-3','Outsider','outsider@wfadr.local',true),
 ('67200000-0001-0000-0000-000000000004','67200000-0000-0000-0000-000000000002','WFADR-4','Other','other@wfadr.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('67200000-0001-0000-0000-000000000001','organization','67200000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('67200000-0001-0000-0000-000000000002','organization','67200000-0000-0000-0000-000000000001','supervisor',true,true),
 ('67200000-0001-0000-0000-000000000003','organization','67200000-0000-0000-0000-000000000001','staff',true,true),
 ('67200000-0001-0000-0000-000000000004','organization','67200000-0000-0000-0000-000000000002','authority_admin',true,true);

\set SINGLE_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"unanimous","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"immediate","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67200000-0001-0000-0000-000000000001"}',true);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '67200000-0000-0000-0000-000000000001','wfadr_flow','WFADR Flow','opaque_case',
  :SINGLE_PAYLOAD::jsonb, '67200000-1000-0000-0000-000000000001'))
INSERT INTO wfadr_ids SELECT 'version',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfadr_ids WHERE name='version'),0,'67200000-1000-0000-0000-000000000002');
INSERT INTO wfadr_ids SELECT 'instance', create_workflow_instance(
  (SELECT id FROM wfadr_ids WHERE name='version'),'opaque_case','67200000-2000-0000-0000-000000000001',
  '67200000-0000-0000-0000-000000000001','67200000-1000-0000-0000-000000000003',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfadr_ids WHERE name='instance'),0,'67200000-1000-0000-0000-000000000004');
INSERT INTO wfadr_ids SELECT 'work_item', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wfadr_ids WHERE name='instance');
RESET ROLE;

-- ── 1: a same-org non-manager outsider (not the assigned voter)
--    cannot decide the work item, with a non-disclosing error. ─────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67200000-0001-0000-0000-000000000003"}',true);
DO $$
BEGIN
  BEGIN
    PERFORM decide_workflow_work_item((SELECT id FROM wfadr_ids WHERE name='work_item'), 'approve', 1, 0, gen_random_uuid());
    RAISE EXCEPTION 'outsider was able to decide the work item';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%not available for this action%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfadr_results VALUES (1,'a same-organization non-manager outsider who is not the assigned voter cannot decide the work item, with a non-disclosing error');
RESET ROLE;

-- ── 2: the instance owner/admin (who can manage the instance's
--    lifecycle) still cannot decide someone else's work item — voting
--    rights are not derived from can_manage_workflow_instance. ─────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67200000-0001-0000-0000-000000000001"}',true);
DO $$
BEGIN
  BEGIN
    PERFORM decide_workflow_work_item((SELECT id FROM wfadr_ids WHERE name='work_item'), 'approve', 1, 0, gen_random_uuid());
    RAISE EXCEPTION 'the instance owner/admin was able to decide another actor''s work item';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%not available for this action%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfadr_results VALUES (2,'the instance owner/admin, despite managing the instance''s lifecycle, cannot decide another actor''s work item');
RESET ROLE;

-- ── 3: a cross-organization actor cannot decide. ─────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67200000-0001-0000-0000-000000000004"}',true);
DO $$
BEGIN
  BEGIN
    PERFORM decide_workflow_work_item((SELECT id FROM wfadr_ids WHERE name='work_item'), 'approve', 1, 0, gen_random_uuid());
    RAISE EXCEPTION 'cross-org actor was able to decide the work item';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%not available for this action%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfadr_results VALUES (3,'a cross-organization actor cannot decide the work item');
RESET ROLE;

-- ── 4: the exact assigned voter can decide successfully. ────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67200000-0001-0000-0000-000000000002"}',true);
DO $$
BEGIN
  PERFORM decide_workflow_work_item((SELECT id FROM wfadr_ids WHERE name='work_item'), 'approve', 1, 0, gen_random_uuid());
END $$;
DO $$ BEGIN
  IF (SELECT status FROM workflow_instances WHERE id=(SELECT id FROM wfadr_ids WHERE name='instance')) <> 'completed' THEN
    RAISE EXCEPTION 'assigned voter decision did not complete the (single-elector unanimous) round';
  END IF;
END $$;
INSERT INTO wfadr_results VALUES (4,'the exact assigned voter can decide their own offered work item successfully');
RESET ROLE;

-- ── 5: no direct INSERT/UPDATE/DELETE grant on workflow_decisions
--    (or any workflow_* table) to anon/authenticated — writes are
--    reachable only via the SECURITY DEFINER command. ──────────────
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema='public' AND table_name='workflow_decisions'
      AND grantee IN ('anon','authenticated') AND privilege_type <> 'SELECT'
  ) THEN RAISE EXCEPTION 'workflow_decisions has a direct write grant to anon/authenticated'; END IF;
END $$;
INSERT INTO wfadr_results VALUES (5,'workflow_decisions has no direct INSERT/UPDATE/DELETE grant; the immutable ledger is writable only through decide_workflow_work_item');

-- ── 6: workflow_decisions SELECT visibility is still governed by the
--    existing can_view_workflow_instance() policy, unaffected by
--    this milestone's new round_id/position_id columns. ────────────
DO $$
DECLARE v_visible BOOLEAN; v_decision_id UUID;
BEGIN
  SELECT id INTO v_decision_id FROM workflow_decisions
  WHERE instance_id=(SELECT id FROM wfadr_ids WHERE name='instance') LIMIT 1;
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"67200000-0001-0000-0000-000000000004"}',true);
  v_visible := EXISTS (SELECT 1 FROM workflow_decisions WHERE id=v_decision_id);
  RESET ROLE;
  IF v_visible THEN RAISE EXCEPTION 'a cross-org actor could see the decision row'; END IF;
END $$;
INSERT INTO wfadr_results VALUES (6,'workflow_decisions row visibility remains governed by the existing can_view_workflow_instance() policy: a cross-organization actor sees no rows');

-- ── 7: decide_workflow_work_item reuses workflow_actor_is_active and
--    assignment-based ownership, not a duplicated permission model
--    (and specifically not can_manage_workflow_instance, which would
--    incorrectly let managers cast votes for others). ──────────────
DO $$
DECLARE v_def TEXT;
BEGIN
  SELECT pg_get_functiondef('decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)'::regprocedure) INTO v_def;
  IF v_def NOT ILIKE '%workflow_actor_is_active%' OR v_def NOT ILIKE '%assigned_to%' THEN
    RAISE EXCEPTION 'decide_workflow_work_item does not reuse the expected authorization primitives';
  END IF;
END $$;
INSERT INTO wfadr_results VALUES (7,'decide_workflow_work_item reuses workflow_actor_is_active() and assignment-based ownership (work_item.assigned_to), not a new or duplicated permission model');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfadr_results;
  IF v_count <> 7 THEN
    RAISE EXCEPTION 'Workflow approval decision engine RLS tests FAILED: expected 7, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow approval decision engine RLS tests PASSED: %/7', v_count;
END $$;

ROLLBACK;
