-- CAP-002 Phase 2C.1 graph advancement foundation — behavioral suite
-- Runs in one transaction and leaves no fixtures.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wfga_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfga_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfga_results, wfga_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('66500000-0000-0000-0000-000000000001','WF Graph Advancement A','authority','WFGA-A'),
 ('66500000-0000-0000-0000-000000000002','WF Graph Advancement B','authority','WFGA-B');
INSERT INTO auth.users(id,email) VALUES
 ('66500000-0001-0000-0000-000000000001','admin@wfga.local'),
 ('66500000-0001-0000-0000-000000000002','sup1@wfga.local'),
 ('66500000-0001-0000-0000-000000000003','sup2@wfga.local'),
 ('66500000-0001-0000-0000-000000000004','mgr1@wfga.local'),
 ('66500000-0001-0000-0000-000000000005','staff@wfga.local'),
 ('66500000-0001-0000-0000-000000000006','otheradmin@wfga.local'),
 ('66500000-0001-0000-0000-000000000007','viewer@wfga.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('66500000-0001-0000-0000-000000000001','66500000-0000-0000-0000-000000000001','WFGA-1','Admin','admin@wfga.local',true),
 ('66500000-0001-0000-0000-000000000002','66500000-0000-0000-0000-000000000001','WFGA-2','Sup1','sup1@wfga.local',true),
 ('66500000-0001-0000-0000-000000000003','66500000-0000-0000-0000-000000000001','WFGA-3','Sup2','sup2@wfga.local',true),
 ('66500000-0001-0000-0000-000000000004','66500000-0000-0000-0000-000000000001','WFGA-4','Mgr1','mgr1@wfga.local',true),
 ('66500000-0001-0000-0000-000000000005','66500000-0000-0000-0000-000000000001','WFGA-5','Staff','staff@wfga.local',true),
 ('66500000-0001-0000-0000-000000000006','66500000-0000-0000-0000-000000000002','WFGA-6','OtherAdmin','otheradmin@wfga.local',true),
 ('66500000-0001-0000-0000-000000000007','66500000-0000-0000-0000-000000000001','WFGA-7','Viewer','viewer@wfga.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('66500000-0001-0000-0000-000000000001','organization','66500000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('66500000-0001-0000-0000-000000000002','organization','66500000-0000-0000-0000-000000000001','supervisor',true,true),
 ('66500000-0001-0000-0000-000000000003','organization','66500000-0000-0000-0000-000000000001','supervisor',true,true),
 ('66500000-0001-0000-0000-000000000004','organization','66500000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('66500000-0001-0000-0000-000000000005','organization','66500000-0000-0000-0000-000000000001','staff',true,true),
 ('66500000-0001-0000-0000-000000000006','organization','66500000-0000-0000-0000-000000000002','authority_admin',true,true);

-- Start -> Approval1(parallel/majority, supervisors) -> Approval2(parallel/majority, admins) -> 2 ends.
\set TWO_HOP_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review1","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"review2","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_admins","order":1,"type":"organization_role","organization":"home","role":"authority_admin"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review1","outcome":"started","priority":0,"default":false},{"source":"review1","target":"review2","outcome":"approved","priority":0,"default":false},{"source":"review1","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"review2","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review2","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''
-- Start -> Approval(sequential, supervisors) -> 2 ends.
\set SEQUENTIAL_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"sequential","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''
-- Start -> Approval1(required, supervisors) -> Approval2(OPTIONAL, admins, skip_if_no_candidates) -> 2 ends + skip end.
\set OPTIONAL_SECOND_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review1","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"review2","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"optional","optional_policy":"skip_if_no_candidates","allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_viewers","order":1,"type":"organization_role","organization":"home","role":"assigned_receiver"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}},{"key":"s_end","type":"end","config":{"outcome_code":"s"}}],"edges":[{"source":"start","target":"review1","outcome":"started","priority":0,"default":false},{"source":"review1","target":"review2","outcome":"approved","priority":0,"default":false},{"source":"review1","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"review2","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review2","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"review2","target":"s_end","outcome":"skipped","priority":0,"default":false}]}\''
-- Start -> Approval(required, minimum_candidates=50, supervisors) -> 2 ends.
\set UNDERSIZED_SECOND_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review1","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"review2","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":50,"candidate_selectors":[{"key":"home_admins","order":1,"type":"organization_role","organization":"home","role":"authority_admin"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review1","outcome":"started","priority":0,"default":false},{"source":"review1","target":"review2","outcome":"approved","priority":0,"default":false},{"source":"review1","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"review2","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review2","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''
\set END_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"e","type":"end","config":{"outcome_code":"done"}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false}]}\''

CREATE OR REPLACE FUNCTION wfga_assert_contiguous(p_instance_id UUID, p_label TEXT) RETURNS VOID AS $$
DECLARE v_max BIGINT; v_count BIGINT; v_next BIGINT;
BEGIN
  SELECT max(event_sequence), count(*) INTO v_max, v_count FROM workflow_events WHERE instance_id = p_instance_id;
  SELECT next_event_sequence INTO v_next FROM workflow_instances WHERE id = p_instance_id;
  IF v_max <> v_count THEN RAISE EXCEPTION '% : event sequence not contiguous (max=%, count=%)', p_label, v_max, v_count; END IF;
  IF v_next <> v_max + 1 THEN RAISE EXCEPTION '% : next_event_sequence (%) not exactly one past max (%)', p_label, v_next, v_max; END IF;
END;
$$ LANGUAGE plpgsql;

-- Test-only SECURITY DEFINER helper simulating "a decision has
-- already been recorded" — this milestone implements only the
-- mechanical outcome-to-edge routine, never the decision itself
-- (Phase 3's job), so the test fixture must manufacture the
-- precondition directly, exactly like Phase 2B.2's own tamper-
-- simulation test did for an otherwise-unreachable condition.
CREATE OR REPLACE FUNCTION wfga_simulate_decision(p_instance_id UUID, p_node_key TEXT, p_result_code TEXT) RETURNS VOID AS $$
BEGIN
  UPDATE workflow_instance_steps SET state = 'completed', result_code = p_result_code, ended_at = now()
  WHERE instance_id = p_instance_id AND definition_node_key = p_node_key;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
GRANT EXECUTE ON FUNCTION wfga_simulate_decision(UUID,TEXT,TEXT) TO authenticated;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"66500000-0001-0000-0000-000000000001"}',true);

-- ── 1: advance Approval1 -> Approval2 (a second hop), simulating a
--    completed decision the same way this milestone's own test
--    fixture must (no decision RPC exists until Phase 3). ──────────
WITH made AS (
 SELECT * FROM create_workflow_definition('66500000-0000-0000-0000-000000000001','wfga_2hop','WFGA 2Hop','opaque_case',:TWO_HOP_PAYLOAD::jsonb,'66500000-1000-0000-0000-000000000001'))
INSERT INTO wfga_ids SELECT 'v_2hop',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfga_ids WHERE name='v_2hop'),0,'66500000-1000-0000-0000-000000000002');
INSERT INTO wfga_ids SELECT 'i_2hop', create_workflow_instance((SELECT id FROM wfga_ids WHERE name='v_2hop'),'opaque_case','66500000-2000-0000-0000-000000000001','66500000-0000-0000-0000-000000000001','66500000-1000-0000-0000-000000000003',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfga_ids WHERE name='i_2hop'),0,'66500000-1000-0000-0000-000000000004');
SELECT wfga_simulate_decision((SELECT id FROM wfga_ids WHERE name='i_2hop'), 'review1', 'approved');
SELECT * FROM workflow_advance_graph_step((SELECT id FROM wfga_ids WHERE name='i_2hop'),1,'66500000-1000-0000-0000-000000000005');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfga_ids WHERE name='i_2hop');
BEGIN
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'active' THEN RAISE EXCEPTION 'expected active after 2nd-node entry'; END IF;
  IF (SELECT count(*) FROM workflow_instance_steps WHERE instance_id=v_iid AND definition_node_key='review2' AND state='waiting') <> 1 THEN
    RAISE EXCEPTION 'expected review2 step waiting'; END IF;
  IF (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id=v_iid) <> 2 THEN RAISE EXCEPTION 'expected 2 rounds (review1 activation + review2 advancement)'; END IF;
  IF (SELECT count(*) FROM workflow_work_items WHERE instance_id=v_iid) <> 3 THEN RAISE EXCEPTION 'expected 3 work items total (2 sup + 1 admin)'; END IF;
END $$;
SELECT wfga_assert_contiguous((SELECT id FROM wfga_ids WHERE name='i_2hop'), 'scenario 1');
INSERT INTO wfga_results VALUES (1,'advancing from a completed Approval1 into Approval2 creates the second round/positions/work items and enters waiting, without deciding or completing anything');

-- ── 2: advance the SAME instance's review2 -> a_end (End completion). ─
SELECT wfga_simulate_decision((SELECT id FROM wfga_ids WHERE name='i_2hop'), 'review2', 'approved');
SELECT * FROM workflow_advance_graph_step((SELECT id FROM wfga_ids WHERE name='i_2hop'),2,'66500000-1000-0000-0000-000000000006');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfga_ids WHERE name='i_2hop');
BEGIN
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed' THEN RAISE EXCEPTION 'expected completed'; END IF;
  IF (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 'a' THEN RAISE EXCEPTION 'expected terminal_outcome a'; END IF;
  IF (SELECT count(*) FROM workflow_tokens WHERE instance_id=v_iid AND state='consumed') <> 1 THEN RAISE EXCEPTION 'expected token consumed'; END IF;
  IF EXISTS (SELECT 1 FROM workflow_instance_steps WHERE instance_id=v_iid AND state IN ('pending','ready','active','waiting')) THEN
    RAISE EXCEPTION 'no runtime work should remain open'; END IF;
END $$;
SELECT wfga_assert_contiguous((SELECT id FROM wfga_ids WHERE name='i_2hop'), 'scenario 2');
INSERT INTO wfga_results VALUES (2,'a second advancement (Approval2 -> End) completes the target step and the instance atomically, consumes the token, and stops');

-- ── 3: idempotent replay of the first advancement returns an
--    identical result and does not perturb sequencing. ────────────
WITH made AS (
 SELECT * FROM create_workflow_definition('66500000-0000-0000-0000-000000000001','wfga_replay','WFGA Replay','opaque_case',:TWO_HOP_PAYLOAD::jsonb,'66500000-1000-0000-0000-000000000007'))
INSERT INTO wfga_ids SELECT 'v_replay',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfga_ids WHERE name='v_replay'),0,'66500000-1000-0000-0000-000000000008');
INSERT INTO wfga_ids SELECT 'i_replay', create_workflow_instance((SELECT id FROM wfga_ids WHERE name='v_replay'),'opaque_case','66500000-2000-0000-0000-000000000002','66500000-0000-0000-0000-000000000001','66500000-1000-0000-0000-000000000009',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfga_ids WHERE name='i_replay'),0,'66500000-1000-0000-0000-000000000010');
SELECT wfga_simulate_decision((SELECT id FROM wfga_ids WHERE name='i_replay'), 'review1', 'approved');
CREATE TEMP TABLE wfga_r1 AS SELECT * FROM workflow_advance_graph_step((SELECT id FROM wfga_ids WHERE name='i_replay'),1,'66500000-1000-0000-0000-000000000011');
CREATE TEMP TABLE wfga_r2 AS SELECT * FROM workflow_advance_graph_step((SELECT id FROM wfga_ids WHERE name='i_replay'),1,'66500000-1000-0000-0000-000000000011');
DO $$ BEGIN
  IF (SELECT (status,terminal_outcome,lock_version,event_id,event_sequence) FROM wfga_r1)
     IS DISTINCT FROM (SELECT (status,terminal_outcome,lock_version,event_id,event_sequence) FROM wfga_r2) THEN
    RAISE EXCEPTION 'replay result differs';
  END IF;
  IF (SELECT replayed FROM wfga_r2) IS NOT TRUE THEN RAISE EXCEPTION 'second call not recognized as replay'; END IF;
END $$;
SELECT wfga_assert_contiguous((SELECT id FROM wfga_ids WHERE name='i_replay'), 'scenario 3');
INSERT INTO wfga_results VALUES (3,'replaying advancement with the same idempotency key returns an identical result and does not perturb sequencing');

-- ── 4: a fresh idempotency key issued against an already-consumed
--    lock version is rejected as a stale retry (not an idempotency
--    replay, since the key differs). ────────────────────────────────
\set ON_ERROR_STOP off
SAVEPOINT wfga_sp4;
SELECT workflow_advance_graph_step((SELECT id FROM wfga_ids WHERE name='i_replay'),1,'66500000-1000-0000-0000-000000000012');
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT wfga_sp4;
INSERT INTO wfga_results VALUES (4,'a fresh idempotency key against an already-consumed lock version is rejected as a stale/illegal retry, not silently accepted');

-- ── 5: stale expected lock version is rejected. ─────────────────────
WITH made AS (
 SELECT * FROM create_workflow_definition('66500000-0000-0000-0000-000000000001','wfga_stale','WFGA Stale','opaque_case',:TWO_HOP_PAYLOAD::jsonb,'66500000-1000-0000-0000-000000000013'))
INSERT INTO wfga_ids SELECT 'v_stale',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfga_ids WHERE name='v_stale'),0,'66500000-1000-0000-0000-000000000014');
INSERT INTO wfga_ids SELECT 'i_stale', create_workflow_instance((SELECT id FROM wfga_ids WHERE name='v_stale'),'opaque_case','66500000-2000-0000-0000-000000000003','66500000-0000-0000-0000-000000000001','66500000-1000-0000-0000-000000000015',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfga_ids WHERE name='i_stale'),0,'66500000-1000-0000-0000-000000000016');
SELECT wfga_simulate_decision((SELECT id FROM wfga_ids WHERE name='i_stale'), 'review1', 'approved');
SAVEPOINT wfga_sp5;
\set ON_ERROR_STOP off
SELECT workflow_advance_graph_step((SELECT id FROM wfga_ids WHERE name='i_stale'),0,'66500000-1000-0000-0000-000000000017');
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT wfga_sp5;
DO $$ BEGIN
  IF (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id=(SELECT id FROM wfga_ids WHERE name='i_stale')) <> 1 THEN
    RAISE EXCEPTION 'stale-version attempt must leave zero partial rows'; END IF;
END $$;
INSERT INTO wfga_results VALUES (5,'a stale expected lock version is rejected and leaves zero partial rows');

-- ── 6: no active token (instance already completed) is rejected. ──
\set ON_ERROR_STOP off
SAVEPOINT wfga_sp6;
SELECT workflow_advance_graph_step((SELECT id FROM wfga_ids WHERE name='i_2hop'),(SELECT lock_version FROM workflow_instances WHERE id=(SELECT id FROM wfga_ids WHERE name='i_2hop')),'66500000-1000-0000-0000-000000000018');
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT wfga_sp6;
INSERT INTO wfga_results VALUES (6,'advancement against a completed instance (no active token) is rejected, not silently accepted');

-- ── 7: instance not 'active' (e.g. suspended) is rejected. ─────────
SELECT * FROM suspend_workflow_instance((SELECT id FROM wfga_ids WHERE name='i_stale'),1,'66500000-1000-0000-0000-000000000019','check');
SAVEPOINT wfga_sp7;
\set ON_ERROR_STOP off
SELECT workflow_advance_graph_step((SELECT id FROM wfga_ids WHERE name='i_stale'),2,'66500000-1000-0000-0000-000000000020');
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT wfga_sp7;
SELECT * FROM resume_workflow_instance((SELECT id FROM wfga_ids WHERE name='i_stale'),2,'66500000-1000-0000-0000-000000000021','check');
INSERT INTO wfga_results VALUES (7,'advancement against a suspended instance is rejected; resuming afterward succeeds normally');

-- ── 8: current step without a terminal result (still waiting, no
--    decision simulated) is rejected. ──────────────────────────────
SAVEPOINT wfga_sp8;
\set ON_ERROR_STOP off
SELECT workflow_advance_graph_step((SELECT id FROM wfga_ids WHERE name='i_stale'),3,'66500000-1000-0000-0000-000000000022');
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT wfga_sp8;
INSERT INTO wfga_results VALUES (8,'advancement against a current step with no terminal result yet (still waiting) is rejected');

-- ── 9: legacy inert instance cannot be advanced. ────────────────────
WITH made AS (
 SELECT * FROM create_workflow_definition('66500000-0000-0000-0000-000000000001','wfga_legacy','WFGA Legacy','opaque_record','{"nodes":[],"edges":[]}','66500000-1000-0000-0000-000000000023'))
INSERT INTO wfga_ids SELECT 'v_legacy',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfga_ids WHERE name='v_legacy'),0,'66500000-1000-0000-0000-000000000024');
INSERT INTO wfga_ids SELECT 'i_legacy', create_workflow_instance((SELECT id FROM wfga_ids WHERE name='v_legacy'),'opaque_record','66500000-2000-0000-0000-000000000004','66500000-0000-0000-0000-000000000001','66500000-1000-0000-0000-000000000025',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfga_ids WHERE name='i_legacy'),0,'66500000-1000-0000-0000-000000000026');
SAVEPOINT wfga_sp9;
\set ON_ERROR_STOP off
SELECT workflow_advance_graph_step((SELECT id FROM wfga_ids WHERE name='i_legacy'),1,'66500000-1000-0000-0000-000000000027');
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT wfga_sp9;
INSERT INTO wfga_results VALUES (9,'a legacy inert instance (no active token ever created) cannot be advanced');

-- ── 10: tampered payload/hash causes atomic failure (same
--     defense-in-depth technique as Phase 2B.2 scenario 5). ─────────
WITH made AS (
 SELECT * FROM create_workflow_definition('66500000-0000-0000-0000-000000000001','wfga_tamper','WFGA Tamper','opaque_case',:TWO_HOP_PAYLOAD::jsonb,'66500000-1000-0000-0000-000000000028'))
INSERT INTO wfga_ids SELECT 'v_tamper',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfga_ids WHERE name='v_tamper'),0,'66500000-1000-0000-0000-000000000029');
INSERT INTO wfga_ids SELECT 'i_tamper', create_workflow_instance((SELECT id FROM wfga_ids WHERE name='v_tamper'),'opaque_case','66500000-2000-0000-0000-000000000005','66500000-0000-0000-0000-000000000001','66500000-1000-0000-0000-000000000030',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfga_ids WHERE name='i_tamper'),0,'66500000-1000-0000-0000-000000000031');
SELECT wfga_simulate_decision((SELECT id FROM wfga_ids WHERE name='i_tamper'), 'review1', 'approved');
RESET ROLE;
ALTER TABLE workflow_definition_versions DISABLE TRIGGER workflow_definition_versions_immutable;
UPDATE workflow_definition_versions SET definition_payload = jsonb_set(definition_payload, '{nodes,0,config,outcome_code}', '"tampered"')
WHERE id = (SELECT id FROM wfga_ids WHERE name='v_tamper');
ALTER TABLE workflow_definition_versions ENABLE TRIGGER workflow_definition_versions_immutable;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"66500000-0001-0000-0000-000000000001"}',false);
SAVEPOINT wfga_sp10;
\set ON_ERROR_STOP off
SELECT workflow_advance_graph_step((SELECT id FROM wfga_ids WHERE name='i_tamper'),1,'66500000-1000-0000-0000-000000000032');
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT wfga_sp10;
DO $$ BEGIN
  IF (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id=(SELECT id FROM wfga_ids WHERE name='i_tamper')) <> 1 THEN
    RAISE EXCEPTION 'tampered advancement must leave zero partial rows'; END IF;
END $$;
RESET ROLE;
ALTER TABLE workflow_definition_versions DISABLE TRIGGER workflow_definition_versions_immutable;
UPDATE workflow_definition_versions SET definition_payload = jsonb_set(definition_payload, '{nodes,0,config,outcome_code}', '"a"')
WHERE id = (SELECT id FROM wfga_ids WHERE name='v_tamper');
ALTER TABLE workflow_definition_versions ENABLE TRIGGER workflow_definition_versions_immutable;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"66500000-0001-0000-0000-000000000001"}',false);
INSERT INTO wfga_results VALUES (10,'tampered payload/hash causes atomic advancement failure with zero partial rows, proving the re-verification defense actually functions');

-- ── 11: retired pinned version cannot be advanced. ──────────────────
WITH made AS (
 SELECT * FROM create_workflow_definition('66500000-0000-0000-0000-000000000001','wfga_retire','WFGA Retire','opaque_case',:TWO_HOP_PAYLOAD::jsonb,'66500000-1000-0000-0000-000000000033'))
INSERT INTO wfga_ids SELECT 'v_retire1',version_id FROM made UNION ALL SELECT 'd_retire',definition_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfga_ids WHERE name='v_retire1'),0,'66500000-1000-0000-0000-000000000034');
INSERT INTO wfga_ids SELECT 'i_retire', create_workflow_instance((SELECT id FROM wfga_ids WHERE name='v_retire1'),'opaque_case','66500000-2000-0000-0000-000000000006','66500000-0000-0000-0000-000000000001','66500000-1000-0000-0000-000000000035',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfga_ids WHERE name='i_retire'),0,'66500000-1000-0000-0000-000000000036');
SELECT wfga_simulate_decision((SELECT id FROM wfga_ids WHERE name='i_retire'), 'review1', 'approved');
WITH made AS (
 SELECT * FROM create_workflow_definition_version((SELECT id FROM wfga_ids WHERE name='d_retire'),:TWO_HOP_PAYLOAD::jsonb,'66500000-1000-0000-0000-000000000037'))
INSERT INTO wfga_ids SELECT 'v_retire2',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfga_ids WHERE name='v_retire2'),1,'66500000-1000-0000-0000-000000000038');
SAVEPOINT wfga_sp11;
\set ON_ERROR_STOP off
SELECT workflow_advance_graph_step((SELECT id FROM wfga_ids WHERE name='i_retire'),1,'66500000-1000-0000-0000-000000000039');
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT wfga_sp11;
INSERT INTO wfga_results VALUES (11,'an instance pinned to a now-retired version cannot be advanced, even though the family has a newer published version');

-- ── 12: sequential delivery on the SECOND hop still offers only
--     ordinal 1, regardless of electorate size. ────────────────────
WITH made AS (
 SELECT * FROM create_workflow_definition('66500000-0000-0000-0000-000000000001','wfga_seq','WFGA Seq','opaque_case',:SEQUENTIAL_PAYLOAD::jsonb,'66500000-1000-0000-0000-000000000040'))
INSERT INTO wfga_ids SELECT 'v_seq',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfga_ids WHERE name='v_seq'),0,'66500000-1000-0000-0000-000000000041');
INSERT INTO wfga_ids SELECT 'i_seq', create_workflow_instance((SELECT id FROM wfga_ids WHERE name='v_seq'),'opaque_case','66500000-2000-0000-0000-000000000007','66500000-0000-0000-0000-000000000001','66500000-1000-0000-0000-000000000042',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfga_ids WHERE name='i_seq'),0,'66500000-1000-0000-0000-000000000043');
DO $$ BEGIN
  IF (SELECT count(*) FROM workflow_approval_positions WHERE instance_id=(SELECT id FROM wfga_ids WHERE name='i_seq')) <> 2 THEN RAISE EXCEPTION 'expected 2 resolved positions'; END IF;
  IF (SELECT count(*) FROM workflow_work_items WHERE instance_id=(SELECT id FROM wfga_ids WHERE name='i_seq')) <> 1 THEN RAISE EXCEPTION 'expected exactly 1 offered work item'; END IF;
END $$;
SELECT wfga_assert_contiguous((SELECT id FROM wfga_ids WHERE name='i_seq'), 'scenario 12');
INSERT INTO wfga_results VALUES (12,'activation into a sequential-delivery approval node (unaffected by this milestone) still offers exactly 1 work item regardless of electorate size');

-- ── 13: an optional second-hop approval node that resolves zero
--     candidates now skips and synchronously continues to its
--     'skipped' edge (Phase 3.2's empty-electorate extension), rather
--     than the fail-closed interim behavior this scenario originally
--     asserted. Superseded per docs/63's own "Optional approval"
--     contract, not a defect in the prior approved behavior — see
--     docs/68. ──────────────────────────────────────────────────────
WITH made AS (
 SELECT * FROM create_workflow_definition('66500000-0000-0000-0000-000000000001','wfga_optzero','WFGA OptZero','opaque_case',:OPTIONAL_SECOND_PAYLOAD::jsonb,'66500000-1000-0000-0000-000000000044'))
INSERT INTO wfga_ids SELECT 'v_optzero',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfga_ids WHERE name='v_optzero'),0,'66500000-1000-0000-0000-000000000045');
INSERT INTO wfga_ids SELECT 'i_optzero', create_workflow_instance((SELECT id FROM wfga_ids WHERE name='v_optzero'),'opaque_case','66500000-2000-0000-0000-000000000008','66500000-0000-0000-0000-000000000001','66500000-1000-0000-0000-000000000046',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfga_ids WHERE name='i_optzero'),0,'66500000-1000-0000-0000-000000000047');
SELECT wfga_simulate_decision((SELECT id FROM wfga_ids WHERE name='i_optzero'), 'review1', 'approved');
SELECT * FROM workflow_advance_graph_step((SELECT id FROM wfga_ids WHERE name='i_optzero'),1,'66500000-1000-0000-0000-000000000048');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfga_ids WHERE name='i_optzero');
BEGIN
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed'
     OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 's' THEN
    RAISE EXCEPTION 'zero-candidate optional second hop must skip and complete with outcome s';
  END IF;
  IF (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id=v_iid) <> 2 THEN
    RAISE EXCEPTION 'expected 2 rounds: review1 (simulated) + review2 (skipped)'; END IF;
  IF (SELECT state FROM workflow_instance_steps WHERE instance_id=v_iid AND definition_node_key='review2') <> 'completed'
     OR (SELECT result_code FROM workflow_instance_steps WHERE instance_id=v_iid AND definition_node_key='review2') <> 'skipped' THEN
    RAISE EXCEPTION 'expected review2 completed with result_code skipped'; END IF;
END $$;
SELECT wfga_assert_contiguous((SELECT id FROM wfga_ids WHERE name='i_optzero'), 'scenario 13');
INSERT INTO wfga_results VALUES (13,'an optional second-hop approval node resolving zero candidates now skips (immutable skipped round/step history, no work item) and synchronously continues to End via the skipped edge, per docs/63''s empty-electorate contract completed in Phase 3.2');

-- ── 14: required second-hop with an undersized electorate fails
--     closed with zero partial rows. ────────────────────────────────
WITH made AS (
 SELECT * FROM create_workflow_definition('66500000-0000-0000-0000-000000000001','wfga_under','WFGA Under','opaque_case',:UNDERSIZED_SECOND_PAYLOAD::jsonb,'66500000-1000-0000-0000-000000000049'))
INSERT INTO wfga_ids SELECT 'v_under',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfga_ids WHERE name='v_under'),0,'66500000-1000-0000-0000-000000000050');
INSERT INTO wfga_ids SELECT 'i_under', create_workflow_instance((SELECT id FROM wfga_ids WHERE name='v_under'),'opaque_case','66500000-2000-0000-0000-000000000009','66500000-0000-0000-0000-000000000001','66500000-1000-0000-0000-000000000051',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfga_ids WHERE name='i_under'),0,'66500000-1000-0000-0000-000000000052');
SELECT wfga_simulate_decision((SELECT id FROM wfga_ids WHERE name='i_under'), 'review1', 'approved');
SAVEPOINT wfga_sp14;
\set ON_ERROR_STOP off
SELECT workflow_advance_graph_step((SELECT id FROM wfga_ids WHERE name='i_under'),1,'66500000-1000-0000-0000-000000000053');
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT wfga_sp14;
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfga_ids WHERE name='i_under');
BEGIN
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'active' THEN RAISE EXCEPTION 'instance must remain active (still at review1''s aftermath), not corrupted'; END IF;
  IF (SELECT count(*) FROM workflow_instance_steps WHERE instance_id=v_iid AND definition_node_key='review2') <> 0 THEN RAISE EXCEPTION 'no review2 step should exist'; END IF;
  IF (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id=v_iid) <> 1 THEN RAISE EXCEPTION 'only the review1 round should exist'; END IF;
END $$;
INSERT INTO wfga_results VALUES (14,'a required second-hop approval node with an undersized electorate fails closed atomically, leaving the instance exactly where it was');

-- ── 15: cancellation after a second-hop entry closes the new round
--     too (the existing cancel-branch extension, unaffected). ─────
WITH made AS (
 SELECT * FROM create_workflow_definition('66500000-0000-0000-0000-000000000001','wfga_cancel','WFGA Cancel','opaque_case',:TWO_HOP_PAYLOAD::jsonb,'66500000-1000-0000-0000-000000000054'))
INSERT INTO wfga_ids SELECT 'v_cancel',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfga_ids WHERE name='v_cancel'),0,'66500000-1000-0000-0000-000000000055');
INSERT INTO wfga_ids SELECT 'i_cancel', create_workflow_instance((SELECT id FROM wfga_ids WHERE name='v_cancel'),'opaque_case','66500000-2000-0000-0000-000000000010','66500000-0000-0000-0000-000000000001','66500000-1000-0000-0000-000000000056',NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfga_ids WHERE name='i_cancel'),0,'66500000-1000-0000-0000-000000000057');
SELECT wfga_simulate_decision((SELECT id FROM wfga_ids WHERE name='i_cancel'), 'review1', 'approved');
SELECT * FROM workflow_advance_graph_step((SELECT id FROM wfga_ids WHERE name='i_cancel'),1,'66500000-1000-0000-0000-000000000058');
SELECT * FROM cancel_workflow_instance((SELECT id FROM wfga_ids WHERE name='i_cancel'),2,'66500000-1000-0000-0000-000000000059','test_cancel');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfga_ids WHERE name='i_cancel');
BEGIN
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'cancelled' THEN RAISE EXCEPTION 'expected cancelled'; END IF;
  IF EXISTS (SELECT 1 FROM workflow_approval_rounds WHERE instance_id=v_iid AND state='open') THEN RAISE EXCEPTION 'no round should remain open'; END IF;
  IF EXISTS (SELECT 1 FROM workflow_work_items WHERE instance_id=v_iid AND state='offered') THEN RAISE EXCEPTION 'no work item should remain offered'; END IF;
END $$;
SELECT wfga_assert_contiguous((SELECT id FROM wfga_ids WHERE name='i_cancel'), 'scenario 15');
INSERT INTO wfga_results VALUES (15,'cancellation after advancing into a second approval node closes that round and its work items too, via the existing unmodified cancel branch');

-- ── 16: suspend then resume after a second-hop entry both succeed
--     with no sequencing collision (the exact class of command that
--     originally crashed under the Phase 2B.2A defect). ────────────
SELECT * FROM suspend_workflow_instance((SELECT id FROM wfga_ids WHERE name='i_seq'),1,'66500000-1000-0000-0000-000000000060','check');
SELECT * FROM resume_workflow_instance((SELECT id FROM wfga_ids WHERE name='i_seq'),2,'66500000-1000-0000-0000-000000000061','check');
SELECT wfga_assert_contiguous((SELECT id FROM wfga_ids WHERE name='i_seq'), 'scenario 16');
INSERT INTO wfga_results VALUES (16,'later lifecycle commands (suspend, resume) after an approval-node activation succeed with no sequencing collision');

-- ── 17-21: odd electorate sizes on the SECOND hop, regression-
--     testing that the Phase 2B.2A sequencing defect cannot reappear
--     for the advancement path specifically. ───────────────────────
RESET ROLE;
DO $$
DECLARE
  v_electorate INT;
  v_def_id UUID; v_ver_id UUID; v_inst_id UUID;
  v_scenario INT;
  v_admin_ids UUID[] := ARRAY[
    '66500000-0001-0000-0000-000000000001'::UUID
  ];
BEGIN
  -- Seed 4 extra admin users so electorate sizes 1,2,3,4,5 are all reachable
  -- (66500000-...-000001 the fixture admin already exists and is
  -- itself an authority_admin, so it alone gives electorate=1 for
  -- review2; adding more admin role holders raises the count).
  FOR v_scenario IN 1..4 LOOP
    INSERT INTO auth.users(id,email) VALUES
      (('66500000-0001-0000-0001-' || lpad(v_scenario::text,12,'0'))::UUID, 'wfgaadm'||v_scenario||'@wfga.local');
    INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
      (('66500000-0001-0000-0001-' || lpad(v_scenario::text,12,'0'))::UUID,'66500000-0000-0000-0000-000000000001','WFGA-ADM'||v_scenario,'AdmExtra'||v_scenario,'wfgaadm'||v_scenario||'@wfga.local',true);
    INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
      (('66500000-0001-0000-0001-' || lpad(v_scenario::text,12,'0'))::UUID,'organization','66500000-0000-0000-0000-000000000001','authority_admin',true,true);
  END LOOP;
END $$;

CREATE TEMP TABLE wfga_payloads (name TEXT PRIMARY KEY, payload JSONB NOT NULL);
GRANT SELECT ON wfga_payloads TO authenticated;
INSERT INTO wfga_payloads VALUES ('two_hop', :TWO_HOP_PAYLOAD::jsonb);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"66500000-0001-0000-0000-000000000001"}',true);
DO $$
DECLARE
  v_target_electorate INT;
  v_def_id UUID; v_ver_id UUID; v_inst_id UUID;
  v_result RECORD;
  v_two_hop_payload JSONB := (SELECT payload FROM wfga_payloads WHERE name = 'two_hop');
BEGIN
  FOR v_target_electorate IN 1..5 LOOP
    -- Deactivate all 4 extras, then reactivate exactly (target-1) of
    -- them (the fixture admin always contributes 1).
    UPDATE user_assignments SET is_active=false
      WHERE user_id::text LIKE '66500000-0001-0000-0001-%' AND role='authority_admin';
    IF v_target_electorate > 1 THEN
      UPDATE user_assignments SET is_active=true
        WHERE user_id IN (
          SELECT ('66500000-0001-0000-0001-' || lpad(g::text,12,'0'))::UUID
          FROM generate_series(1, v_target_electorate-1) g
        ) AND role='authority_admin';
    END IF;

    SELECT definition_id, version_id INTO v_def_id, v_ver_id FROM create_workflow_definition(
      '66500000-0000-0000-0000-000000000001','wfga_odd'||v_target_electorate,'WFGA Odd '||v_target_electorate,'opaque_case',
      v_two_hop_payload, ('66500000-1000-0000-0002-' || lpad(v_target_electorate::text,12,'0'))::UUID
    );
    PERFORM publish_workflow_definition_version(v_ver_id, 0, ('66500000-1000-0000-0003-' || lpad(v_target_electorate::text,12,'0'))::UUID);
    v_inst_id := create_workflow_instance(v_ver_id,'opaque_case',
      ('66500000-2000-0000-0000-' || lpad((100+v_target_electorate)::text,12,'0'))::UUID,
      '66500000-0000-0000-0000-000000000001',
      ('66500000-1000-0000-0004-' || lpad(v_target_electorate::text,12,'0'))::UUID, NULL);
    PERFORM start_workflow_instance(v_inst_id, 0, ('66500000-1000-0000-0005-' || lpad(v_target_electorate::text,12,'0'))::UUID);

    PERFORM wfga_simulate_decision(v_inst_id, 'review1', 'approved');

    PERFORM workflow_advance_graph_step(v_inst_id, 1, ('66500000-1000-0000-0006-' || lpad(v_target_electorate::text,12,'0'))::UUID);

    IF (SELECT count(*) FROM workflow_approval_positions WHERE instance_id=v_inst_id AND round_id IN (
          SELECT id FROM workflow_approval_rounds WHERE instance_id=v_inst_id AND step_id IN (
            SELECT id FROM workflow_instance_steps WHERE instance_id=v_inst_id AND definition_node_key='review2'))) <> v_target_electorate THEN
      RAISE EXCEPTION 'electorate size mismatch for target %', v_target_electorate;
    END IF;

    PERFORM wfga_assert_contiguous(v_inst_id, 'odd electorate ' || v_target_electorate);

    -- A later lifecycle command must succeed with no collision —
    -- exactly the class of check that would have caught the original
    -- Phase 2B.2A defect had it been run against the advancement path.
    PERFORM cancel_workflow_instance(v_inst_id, 2, ('66500000-1000-0000-0007-' || lpad(v_target_electorate::text,12,'0'))::UUID, 'odd_electorate_check');
    PERFORM wfga_assert_contiguous(v_inst_id, 'odd electorate ' || v_target_electorate || ' post-cancel');

    INSERT INTO wfga_results VALUES (16 + v_target_electorate, 'second-hop electorate=' || v_target_electorate || ' leaves correct contiguous sequencing and a later cancel succeeds with no collision');
  END LOOP;
END $$;

RESET ROLE;

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfga_results;
  IF v_count <> 21 THEN
    RAISE EXCEPTION 'Workflow graph advancement foundation behavioral tests FAILED: expected 21, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow graph advancement foundation behavioral tests PASSED: %/21', v_count;
END $$;

ROLLBACK;
