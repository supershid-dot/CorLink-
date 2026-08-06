-- CAP-002 Phase 2B.2A — activation event-sequence correction suite
-- Verifies next_event_sequence is exactly correct (contiguous, no
-- duplicates, no gaps) for every electorate size, that replay remains
-- identical, and that later lifecycle commands succeed afterward.
-- Runs in one transaction and leaves no fixtures.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wfsc_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfsc_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfsc_results, wfsc_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('66300000-0000-0000-0000-000000000001','WF Sequence Correction','authority','WFSC');
INSERT INTO auth.users(id,email) VALUES
 ('66300000-0001-0000-0000-000000000001','admin@wfsc.local'),
 ('66300000-0001-0000-0000-000000000002','sup1@wfsc.local'),
 ('66300000-0001-0000-0000-000000000003','sup2@wfsc.local'),
 ('66300000-0001-0000-0000-000000000004','sup3@wfsc.local'),
 ('66300000-0001-0000-0000-000000000005','sup4@wfsc.local'),
 ('66300000-0001-0000-0000-000000000006','sup5@wfsc.local'),
 ('66300000-0001-0000-0000-000000000007','staff1@wfsc.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('66300000-0001-0000-0000-000000000001','66300000-0000-0000-0000-000000000001','WFSC-1','Admin','admin@wfsc.local',true),
 ('66300000-0001-0000-0000-000000000002','66300000-0000-0000-0000-000000000001','WFSC-2','Sup1','sup1@wfsc.local',true),
 ('66300000-0001-0000-0000-000000000003','66300000-0000-0000-0000-000000000001','WFSC-3','Sup2','sup2@wfsc.local',true),
 ('66300000-0001-0000-0000-000000000004','66300000-0000-0000-0000-000000000001','WFSC-4','Sup3','sup3@wfsc.local',true),
 ('66300000-0001-0000-0000-000000000005','66300000-0000-0000-0000-000000000001','WFSC-5','Sup4','sup4@wfsc.local',true),
 ('66300000-0001-0000-0000-000000000006','66300000-0000-0000-0000-000000000001','WFSC-6','Sup5','sup5@wfsc.local',true),
 ('66300000-0001-0000-0000-000000000007','66300000-0000-0000-0000-000000000001','WFSC-7','Staff1','staff1@wfsc.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('66300000-0001-0000-0000-000000000001','organization','66300000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('66300000-0001-0000-0000-000000000002','organization','66300000-0000-0000-0000-000000000001','supervisor',true,true),
 ('66300000-0001-0000-0000-000000000003','organization','66300000-0000-0000-0000-000000000001','supervisor',true,true),
 ('66300000-0001-0000-0000-000000000004','organization','66300000-0000-0000-0000-000000000001','supervisor',true,true),
 ('66300000-0001-0000-0000-000000000005','organization','66300000-0000-0000-0000-000000000001','supervisor',true,true),
 ('66300000-0001-0000-0000-000000000006','organization','66300000-0000-0000-0000-000000000001','supervisor',true,true),
 ('66300000-0001-0000-0000-000000000007','organization','66300000-0000-0000-0000-000000000001','staff',true,true);

-- Builds a Start->Approval[parallel or sequential]->2 ends payload
-- whose sole candidate_selector is organization_role:supervisor, so
-- the resolved electorate size is controlled purely by how many of
-- the 5 seeded supervisors are still active (deactivated by each
-- scenario as needed to hit the target size).
\set PARALLEL_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''
\set SEQUENTIAL_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"sequential","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''
\set OPTIONAL_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"optional","optional_policy":"skip_if_no_candidates","allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}},{"key":"s_end","type":"end","config":{"outcome_code":"s"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"review","target":"s_end","outcome":"skipped","priority":0,"default":false}]}\''

-- Helper assertion, invoked after each activation: event sequence is
-- perfectly contiguous from 1 (no duplicates, no gaps), and
-- next_event_sequence is exactly one past the highest used sequence.
CREATE OR REPLACE FUNCTION wfsc_assert_contiguous(p_instance_id UUID, p_scenario INT, p_label TEXT) RETURNS VOID AS $$
DECLARE
  v_max BIGINT; v_count BIGINT; v_next BIGINT;
BEGIN
  SELECT max(event_sequence), count(*) INTO v_max, v_count FROM workflow_events WHERE instance_id = p_instance_id;
  SELECT next_event_sequence INTO v_next FROM workflow_instances WHERE id = p_instance_id;
  IF v_max <> v_count THEN
    RAISE EXCEPTION '% : event sequence is not contiguous (max=%, count=%)', p_label, v_max, v_count;
  END IF;
  IF v_next <> v_max + 1 THEN
    RAISE EXCEPTION '% : next_event_sequence (%) is not exactly one past the highest used sequence (%)', p_label, v_next, v_max;
  END IF;
  IF (SELECT count(DISTINCT event_sequence) FROM workflow_events WHERE instance_id = p_instance_id) <> v_count THEN
    RAISE EXCEPTION '% : duplicate event_sequence values found', p_label;
  END IF;
END;
$$ LANGUAGE plpgsql;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"66300000-0001-0000-0000-000000000001"}',true);

-- ── 1: electorate = 1, parallel ────────────────────────────────────
UPDATE user_assignments SET is_active = false WHERE user_id IN (
 '66300000-0001-0000-0000-000000000003','66300000-0001-0000-0000-000000000004',
 '66300000-0001-0000-0000-000000000005','66300000-0001-0000-0000-000000000006') AND role='supervisor';
WITH made AS (
 SELECT * FROM create_workflow_definition('66300000-0000-0000-0000-000000000001','wfsc_e1','WFSC E1','opaque_case',:PARALLEL_PAYLOAD::jsonb,'66300000-1000-0000-0000-000000000001'))
INSERT INTO wfsc_ids SELECT 'v_e1',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfsc_ids WHERE name='v_e1'),0,'66300000-1000-0000-0000-000000000002');
INSERT INTO wfsc_ids SELECT 'i_e1', create_workflow_instance((SELECT id FROM wfsc_ids WHERE name='v_e1'),'opaque_case','66300000-2000-0000-0000-000000000001','66300000-0000-0000-0000-000000000001','66300000-1000-0000-0000-000000000003',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfsc_ids WHERE name='i_e1'),0,'66300000-1000-0000-0000-000000000004');
DO $$ BEGIN
  IF (SELECT count(*) FROM workflow_approval_positions WHERE instance_id = (SELECT id FROM wfsc_ids WHERE name='i_e1')) <> 1 THEN
    RAISE EXCEPTION 'expected electorate 1'; END IF;
END $$;
SELECT wfsc_assert_contiguous((SELECT id FROM wfsc_ids WHERE name='i_e1'), 1, 'scenario 1 (electorate=1, parallel)');
INSERT INTO wfsc_results VALUES (1,'electorate=1 parallel activation leaves contiguous, gap-free, duplicate-free event sequencing');

-- ── 2: a later lifecycle command succeeds without collision ───────
SELECT * FROM cancel_workflow_instance((SELECT id FROM wfsc_ids WHERE name='i_e1'),1,'66300000-1000-0000-0000-000000000005','sequence_check');
SELECT wfsc_assert_contiguous((SELECT id FROM wfsc_ids WHERE name='i_e1'), 2, 'scenario 2 (post-activation cancel)');
INSERT INTO wfsc_results VALUES (2,'a later lifecycle command (cancel) after an electorate=1 activation succeeds with no sequence collision');

-- ── 3: replay with the same idempotency key is identical ──────────
UPDATE user_assignments SET is_active = false WHERE user_id IN (
 '66300000-0001-0000-0000-000000000003','66300000-0001-0000-0000-000000000004',
 '66300000-0001-0000-0000-000000000005','66300000-0001-0000-0000-000000000006') AND role='supervisor';
WITH made AS (
 SELECT * FROM create_workflow_definition('66300000-0000-0000-0000-000000000001','wfsc_e1r','WFSC E1 Replay','opaque_case',:PARALLEL_PAYLOAD::jsonb,'66300000-1000-0000-0000-000000000006'))
INSERT INTO wfsc_ids SELECT 'v_e1r',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfsc_ids WHERE name='v_e1r'),0,'66300000-1000-0000-0000-000000000007');
INSERT INTO wfsc_ids SELECT 'i_e1r', create_workflow_instance((SELECT id FROM wfsc_ids WHERE name='v_e1r'),'opaque_case','66300000-2000-0000-0000-000000000002','66300000-0000-0000-0000-000000000001','66300000-1000-0000-0000-000000000008',NULL);
CREATE TEMP TABLE wfsc_replay1 AS SELECT * FROM start_workflow_instance((SELECT id FROM wfsc_ids WHERE name='i_e1r'),0,'66300000-1000-0000-0000-000000000009');
CREATE TEMP TABLE wfsc_replay2 AS SELECT * FROM start_workflow_instance((SELECT id FROM wfsc_ids WHERE name='i_e1r'),0,'66300000-1000-0000-0000-000000000009');
DO $$
DECLARE v_events_before INTEGER; v_events_after INTEGER;
BEGIN
  IF (SELECT (status,terminal_outcome,lock_version,event_id,event_sequence) FROM wfsc_replay1)
     IS DISTINCT FROM (SELECT (status,terminal_outcome,lock_version,event_id,event_sequence) FROM wfsc_replay2) THEN
    RAISE EXCEPTION 'replay result differs from the original';
  END IF;
  IF (SELECT replayed FROM wfsc_replay2) IS NOT TRUE THEN
    RAISE EXCEPTION 'second identical call was not recognized as a replay';
  END IF;
END $$;
SELECT wfsc_assert_contiguous((SELECT id FROM wfsc_ids WHERE name='i_e1r'), 3, 'scenario 3 (replay)');
INSERT INTO wfsc_results VALUES (3,'replaying activation with the same idempotency key returns an identical result and does not perturb event sequencing');

-- ── 4: electorate = 2 (the pre-correction coincidentally-passing case) ─
UPDATE user_assignments SET is_active = true WHERE user_id = '66300000-0001-0000-0000-000000000003' AND role='supervisor';
WITH made AS (
 SELECT * FROM create_workflow_definition('66300000-0000-0000-0000-000000000001','wfsc_e2','WFSC E2','opaque_case',:PARALLEL_PAYLOAD::jsonb,'66300000-1000-0000-0000-000000000010'))
INSERT INTO wfsc_ids SELECT 'v_e2',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfsc_ids WHERE name='v_e2'),0,'66300000-1000-0000-0000-000000000011');
INSERT INTO wfsc_ids SELECT 'i_e2', create_workflow_instance((SELECT id FROM wfsc_ids WHERE name='v_e2'),'opaque_case','66300000-2000-0000-0000-000000000003','66300000-0000-0000-0000-000000000001','66300000-1000-0000-0000-000000000012',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfsc_ids WHERE name='i_e2'),0,'66300000-1000-0000-0000-000000000013');
DO $$ BEGIN
  IF (SELECT count(*) FROM workflow_approval_positions WHERE instance_id = (SELECT id FROM wfsc_ids WHERE name='i_e2')) <> 2 THEN
    RAISE EXCEPTION 'expected electorate 2'; END IF;
END $$;
SELECT wfsc_assert_contiguous((SELECT id FROM wfsc_ids WHERE name='i_e2'), 4, 'scenario 4 (electorate=2, parallel)');
INSERT INTO wfsc_results VALUES (4,'electorate=2 parallel activation (the previously-masking case) remains correct after the fix');

-- ── 5: electorate = 3, parallel ────────────────────────────────────
UPDATE user_assignments SET is_active = true WHERE user_id = '66300000-0001-0000-0000-000000000004' AND role='supervisor';
WITH made AS (
 SELECT * FROM create_workflow_definition('66300000-0000-0000-0000-000000000001','wfsc_e3','WFSC E3','opaque_case',:PARALLEL_PAYLOAD::jsonb,'66300000-1000-0000-0000-000000000014'))
INSERT INTO wfsc_ids SELECT 'v_e3',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfsc_ids WHERE name='v_e3'),0,'66300000-1000-0000-0000-000000000015');
INSERT INTO wfsc_ids SELECT 'i_e3', create_workflow_instance((SELECT id FROM wfsc_ids WHERE name='v_e3'),'opaque_case','66300000-2000-0000-0000-000000000004','66300000-0000-0000-0000-000000000001','66300000-1000-0000-0000-000000000016',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfsc_ids WHERE name='i_e3'),0,'66300000-1000-0000-0000-000000000017');
DO $$ BEGIN
  IF (SELECT count(*) FROM workflow_approval_positions WHERE instance_id = (SELECT id FROM wfsc_ids WHERE name='i_e3')) <> 3 THEN
    RAISE EXCEPTION 'expected electorate 3'; END IF;
END $$;
SELECT wfsc_assert_contiguous((SELECT id FROM wfsc_ids WHERE name='i_e3'), 5, 'scenario 5 (electorate=3, parallel)');
SELECT * FROM suspend_workflow_instance((SELECT id FROM wfsc_ids WHERE name='i_e3'),1,'66300000-1000-0000-0000-000000000018','sequence_check');
SELECT * FROM resume_workflow_instance((SELECT id FROM wfsc_ids WHERE name='i_e3'),2,'66300000-1000-0000-0000-000000000019','sequence_check');
SELECT wfsc_assert_contiguous((SELECT id FROM wfsc_ids WHERE name='i_e3'), 6, 'scenario 6 (post electorate=3, suspend+resume)');
INSERT INTO wfsc_results VALUES (5,'electorate=3 parallel activation leaves correct sequencing');
INSERT INTO wfsc_results VALUES (6,'two further lifecycle commands (suspend, resume) after an electorate=3 activation both succeed with no collision');

-- ── 7: larger electorate (5), parallel ─────────────────────────────
UPDATE user_assignments SET is_active = true WHERE user_id IN (
 '66300000-0001-0000-0000-000000000005','66300000-0001-0000-0000-000000000006') AND role='supervisor';
WITH made AS (
 SELECT * FROM create_workflow_definition('66300000-0000-0000-0000-000000000001','wfsc_e5','WFSC E5','opaque_case',:PARALLEL_PAYLOAD::jsonb,'66300000-1000-0000-0000-000000000020'))
INSERT INTO wfsc_ids SELECT 'v_e5',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfsc_ids WHERE name='v_e5'),0,'66300000-1000-0000-0000-000000000021');
INSERT INTO wfsc_ids SELECT 'i_e5', create_workflow_instance((SELECT id FROM wfsc_ids WHERE name='v_e5'),'opaque_case','66300000-2000-0000-0000-000000000005','66300000-0000-0000-0000-000000000001','66300000-1000-0000-0000-000000000022',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfsc_ids WHERE name='i_e5'),0,'66300000-1000-0000-0000-000000000023');
DO $$ BEGIN
  IF (SELECT count(*) FROM workflow_approval_positions WHERE instance_id = (SELECT id FROM wfsc_ids WHERE name='i_e5')) <> 5 THEN
    RAISE EXCEPTION 'expected electorate 5'; END IF;
END $$;
SELECT wfsc_assert_contiguous((SELECT id FROM wfsc_ids WHERE name='i_e5'), 7, 'scenario 7 (electorate=5, parallel)');
INSERT INTO wfsc_results VALUES (7,'larger electorate (5) parallel activation leaves correct sequencing');

-- ── 8: electorate = 3, sequential (only ordinal 1 offered) ─────────
WITH made AS (
 SELECT * FROM create_workflow_definition('66300000-0000-0000-0000-000000000001','wfsc_seq3','WFSC Seq3','opaque_case',:SEQUENTIAL_PAYLOAD::jsonb,'66300000-1000-0000-0000-000000000024'))
INSERT INTO wfsc_ids SELECT 'v_seq3',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfsc_ids WHERE name='v_seq3'),0,'66300000-1000-0000-0000-000000000025');
INSERT INTO wfsc_ids SELECT 'i_seq3', create_workflow_instance((SELECT id FROM wfsc_ids WHERE name='v_seq3'),'opaque_case','66300000-2000-0000-0000-000000000006','66300000-0000-0000-0000-000000000001','66300000-1000-0000-0000-000000000026',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfsc_ids WHERE name='i_seq3'),0,'66300000-1000-0000-0000-000000000027');
DO $$ BEGIN
  IF (SELECT count(*) FROM workflow_approval_positions WHERE instance_id = (SELECT id FROM wfsc_ids WHERE name='i_seq3')) <> 5 THEN
    RAISE EXCEPTION 'expected electorate 5 (all resolved positions), only 1 offered'; END IF;
  IF (SELECT count(*) FROM workflow_work_items WHERE instance_id = (SELECT id FROM wfsc_ids WHERE name='i_seq3')) <> 1 THEN
    RAISE EXCEPTION 'sequential delivery must offer exactly 1 work item regardless of electorate size'; END IF;
END $$;
SELECT wfsc_assert_contiguous((SELECT id FROM wfsc_ids WHERE name='i_seq3'), 8, 'scenario 8 (electorate=5, sequential, offered=1)');
INSERT INTO wfsc_results VALUES (8,'sequential delivery with a larger electorate (5, only 1 offered) leaves correct sequencing driven by offered count, not electorate size');

-- ── 9: electorate = 1, sequential ──────────────────────────────────
UPDATE user_assignments SET is_active = false WHERE user_id IN (
 '66300000-0001-0000-0000-000000000003','66300000-0001-0000-0000-000000000004',
 '66300000-0001-0000-0000-000000000005','66300000-0001-0000-0000-000000000006') AND role='supervisor';
WITH made AS (
 SELECT * FROM create_workflow_definition('66300000-0000-0000-0000-000000000001','wfsc_seq1','WFSC Seq1','opaque_case',:SEQUENTIAL_PAYLOAD::jsonb,'66300000-1000-0000-0000-000000000028'))
INSERT INTO wfsc_ids SELECT 'v_seq1',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfsc_ids WHERE name='v_seq1'),0,'66300000-1000-0000-0000-000000000029');
INSERT INTO wfsc_ids SELECT 'i_seq1', create_workflow_instance((SELECT id FROM wfsc_ids WHERE name='v_seq1'),'opaque_case','66300000-2000-0000-0000-000000000007','66300000-0000-0000-0000-000000000001','66300000-1000-0000-0000-000000000030',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfsc_ids WHERE name='i_seq1'),0,'66300000-1000-0000-0000-000000000031');
SELECT wfsc_assert_contiguous((SELECT id FROM wfsc_ids WHERE name='i_seq1'), 9, 'scenario 9 (electorate=1, sequential)');
INSERT INTO wfsc_results VALUES (9,'electorate=1 sequential activation leaves correct sequencing');

-- ── 10 & 11: electorate = 0 remains correctly rejected, unaffected
--    by the fix (required-undersized and optional-zero-candidate). ──
WITH made AS (
 SELECT * FROM create_workflow_definition('66300000-0000-0000-0000-000000000001','wfsc_e0req','WFSC E0 Required','opaque_case',:PARALLEL_PAYLOAD::jsonb,'66300000-1000-0000-0000-000000000032'))
INSERT INTO wfsc_ids SELECT 'v_e0req',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfsc_ids WHERE name='v_e0req'),0,'66300000-1000-0000-0000-000000000033');
INSERT INTO wfsc_ids SELECT 'i_e0req', create_workflow_instance((SELECT id FROM wfsc_ids WHERE name='v_e0req'),'opaque_case','66300000-2000-0000-0000-000000000008','66300000-0000-0000-0000-000000000001','66300000-1000-0000-0000-000000000034',NULL);
UPDATE user_assignments SET is_active = false WHERE user_id IN (
 '66300000-0001-0000-0000-000000000002','66300000-0001-0000-0000-000000000003','66300000-0001-0000-0000-000000000004',
 '66300000-0001-0000-0000-000000000005','66300000-0001-0000-0000-000000000006') AND role='supervisor';
\set ON_ERROR_STOP off
SAVEPOINT wfsc_sp_req;
SELECT start_workflow_instance((SELECT id FROM wfsc_ids WHERE name='i_e0req'),0,'66300000-1000-0000-0000-000000000035');
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT wfsc_sp_req;
DO $$ BEGIN
  IF (SELECT status FROM workflow_instances WHERE id = (SELECT id FROM wfsc_ids WHERE name='i_e0req')) <> 'pending' THEN
    RAISE EXCEPTION 'electorate=0 required activation did not fail closed';
  END IF;
END $$;
INSERT INTO wfsc_results VALUES (10,'electorate=0 with requirement=required is still correctly rejected (unaffected by the sequencing fix)');

WITH made AS (
 SELECT * FROM create_workflow_definition('66300000-0000-0000-0000-000000000001','wfsc_e0opt','WFSC E0 Optional','opaque_case',:OPTIONAL_PAYLOAD::jsonb,'66300000-1000-0000-0000-000000000036'))
INSERT INTO wfsc_ids SELECT 'v_e0opt',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfsc_ids WHERE name='v_e0opt'),0,'66300000-1000-0000-0000-000000000037');
INSERT INTO wfsc_ids SELECT 'i_e0opt', create_workflow_instance((SELECT id FROM wfsc_ids WHERE name='v_e0opt'),'opaque_case','66300000-2000-0000-0000-000000000009','66300000-0000-0000-0000-000000000001','66300000-1000-0000-0000-000000000038',NULL);
SAVEPOINT wfsc_sp_opt;
\set ON_ERROR_STOP off
SELECT start_workflow_instance((SELECT id FROM wfsc_ids WHERE name='i_e0opt'),0,'66300000-1000-0000-0000-000000000039');
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT wfsc_sp_opt;
DO $$ BEGIN
  IF (SELECT status FROM workflow_instances WHERE id = (SELECT id FROM wfsc_ids WHERE name='i_e0opt')) <> 'pending' THEN
    RAISE EXCEPTION 'electorate=0 optional activation did not fail closed';
  END IF;
END $$;
INSERT INTO wfsc_results VALUES (11,'electorate=0 with requirement=optional is still correctly rejected fail-closed (unaffected by the sequencing fix)');

RESET ROLE;

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfsc_results;
  IF v_count <> 11 THEN
    RAISE EXCEPTION 'Workflow activation event sequence correction tests FAILED: expected 11, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow activation event sequence correction tests PASSED: %/11', v_count;
END $$;

ROLLBACK;
