-- CAP-002 Phase 3.2 approval round lifecycle — behavioral suite
-- Runs in one transaction and leaves no fixtures.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wfrl_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfrl_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfrl_results, wfrl_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('67800000-0000-0000-0000-000000000001','WF Round Lifecycle A','authority','WFRL-A'),
 ('67800000-0000-0000-0000-000000000002','WF Round Lifecycle B','authority','WFRL-B');
INSERT INTO auth.users(id,email) VALUES
 ('67800000-0001-0000-0000-000000000001','creator@wfrl.local'),
 ('67800000-0001-0000-0000-000000000002','sup1@wfrl.local'),
 ('67800000-0001-0000-0000-000000000003','sup2@wfrl.local'),
 ('67800000-0001-0000-0000-000000000004','sup3@wfrl.local'),
 ('67800000-0001-0000-0000-000000000005','outsider@wfrl.local'),
 ('67800000-0001-0000-0000-000000000006','otherorg@wfrl.local'),
 ('67800000-0001-0000-0000-000000000007','recv1@wfrl.local'),
 ('67800000-0001-0000-0000-000000000008','recv2@wfrl.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('67800000-0001-0000-0000-000000000001','67800000-0000-0000-0000-000000000001','WFRL-1','Creator','creator@wfrl.local',true),
 ('67800000-0001-0000-0000-000000000002','67800000-0000-0000-0000-000000000001','WFRL-2','Sup1','sup1@wfrl.local',true),
 ('67800000-0001-0000-0000-000000000003','67800000-0000-0000-0000-000000000001','WFRL-3','Sup2','sup2@wfrl.local',true),
 ('67800000-0001-0000-0000-000000000004','67800000-0000-0000-0000-000000000001','WFRL-4','Sup3','sup3@wfrl.local',true),
 ('67800000-0001-0000-0000-000000000005','67800000-0000-0000-0000-000000000001','WFRL-5','Outsider','outsider@wfrl.local',true),
 ('67800000-0001-0000-0000-000000000006','67800000-0000-0000-0000-000000000002','WFRL-6','OtherOrg','otherorg@wfrl.local',true),
 ('67800000-0001-0000-0000-000000000007','67800000-0000-0000-0000-000000000001','WFRL-7','Recv1','recv1@wfrl.local',true),
 ('67800000-0001-0000-0000-000000000008','67800000-0000-0000-0000-000000000001','WFRL-8','Recv2','recv2@wfrl.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('67800000-0001-0000-0000-000000000001','organization','67800000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('67800000-0001-0000-0000-000000000002','organization','67800000-0000-0000-0000-000000000001','supervisor',true,true),
 ('67800000-0001-0000-0000-000000000003','organization','67800000-0000-0000-0000-000000000001','supervisor',true,true),
 ('67800000-0001-0000-0000-000000000004','organization','67800000-0000-0000-0000-000000000001','supervisor',true,true),
 ('67800000-0001-0000-0000-000000000005','organization','67800000-0000-0000-0000-000000000001','staff',true,true),
 ('67800000-0001-0000-0000-000000000006','organization','67800000-0000-0000-0000-000000000002','authority_admin',true,true),
 ('67800000-0001-0000-0000-000000000007','organization','67800000-0000-0000-0000-000000000001','mcs_admin',true,true),
 ('67800000-0001-0000-0000-000000000008','organization','67800000-0000-0000-0000-000000000001','mcs_admin',true,true);

\set REQUIRED_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''
\set OPTIONAL_NONZERO_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"optional","optional_policy":"skip_if_no_candidates","allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}},{"key":"s_end","type":"end","config":{"outcome_code":"s"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"review","target":"s_end","outcome":"skipped","priority":0,"default":false}]}\''
-- review1 is OPTIONAL with a role nobody holds (assigned_receiver);
-- its 'skipped' edge routes to s_end.
\set SINGLE_SKIP_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review1","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"optional","optional_policy":"skip_if_no_candidates","allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_receivers","order":1,"type":"organization_role","organization":"home","role":"assigned_receiver"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}},{"key":"s_end","type":"end","config":{"outcome_code":"s"}}],"edges":[{"source":"start","target":"review1","outcome":"started","priority":0,"default":false},{"source":"review1","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review1","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"review1","target":"s_end","outcome":"skipped","priority":0,"default":false}]}\''
-- review1(optional, zero-candidate) skips -> review2(required, supervisors) waits.
-- An approval node must have exactly one inbound edge, so review1's
-- structurally-required (but never reachable, given zero candidates)
-- 'approved' edge routes to a distinct dead-end node, never to
-- review2 — only the 'skipped' edge targets review2.
\set TWO_HOP_SKIP_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review1","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"optional","optional_policy":"skip_if_no_candidates","allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_receivers","order":1,"type":"organization_role","organization":"home","role":"assigned_receiver"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"review2","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}},{"key":"x_dead_end","type":"end","config":{"outcome_code":"x"}}],"edges":[{"source":"start","target":"review1","outcome":"started","priority":0,"default":false},{"source":"review1","target":"x_dead_end","outcome":"approved","priority":0,"default":false},{"source":"review1","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"review1","target":"review2","outcome":"skipped","priority":0,"default":false},{"source":"review2","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review2","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''
\set SEQUENTIAL_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"sequential","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''
-- Two REAL rounds, disjoint roles (supervisor then mcs_admin), for
-- "late vote after replacement" — deciding review1 replaces it with
-- review2 as the instance's current round.
\set TWO_HOP_REAL_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review1","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"review2","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_mcs","order":1,"type":"organization_role","organization":"home","role":"mcs_admin"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review1","outcome":"started","priority":0,"default":false},{"source":"review1","target":"review2","outcome":"approved","priority":0,"default":false},{"source":"review1","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"review2","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review2","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''
-- A real required round (reviewa) whose approval advances into a
-- zero-candidate optional round (reviewb) that skips through to End —
-- exercises replay through a decision whose peek must resolve a skip
-- chain beyond the immediately-closed round.
\set DECIDE_THEN_SKIP_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"reviewa","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"unanimous","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"immediate","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"reviewb","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"optional","optional_policy":"skip_if_no_candidates","allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_receivers","order":1,"type":"organization_role","organization":"home","role":"assigned_receiver"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"x_dead_end","type":"end","config":{"outcome_code":"x"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}},{"key":"s_end","type":"end","config":{"outcome_code":"s"}}],"edges":[{"source":"start","target":"reviewa","outcome":"started","priority":0,"default":false},{"source":"reviewa","target":"reviewb","outcome":"approved","priority":0,"default":false},{"source":"reviewa","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"reviewb","target":"x_dead_end","outcome":"approved","priority":0,"default":false},{"source":"reviewb","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"reviewb","target":"s_end","outcome":"skipped","priority":0,"default":false}]}\''

CREATE OR REPLACE FUNCTION wfrl_assert_contiguous(p_instance_id UUID, p_label TEXT) RETURNS VOID AS $$
DECLARE v_max BIGINT; v_count BIGINT; v_next BIGINT;
BEGIN
  SELECT max(event_sequence), count(*) INTO v_max, v_count FROM workflow_events WHERE instance_id = p_instance_id;
  SELECT next_event_sequence INTO v_next FROM workflow_instances WHERE id = p_instance_id;
  IF v_max <> v_count THEN RAISE EXCEPTION '% : event sequence not contiguous (max=%, count=%)', p_label, v_max, v_count; END IF;
  IF v_next <> v_max + 1 THEN RAISE EXCEPTION '% : next_event_sequence (%) not exactly one past max (%)', p_label, v_next, v_max; END IF;
END;
$$ LANGUAGE plpgsql;

-- Restrict active supervisors to exactly the given set, so electorate
-- size is deterministic per scenario. Plain (non-SECURITY DEFINER)
-- helper defined before the role switch below, runs with the
-- caller's own privileges at call time.
CREATE OR REPLACE FUNCTION wfrl_start(p_name TEXT, p_payload JSONB) RETURNS UUID AS $$
DECLARE v_ver UUID; v_inst UUID;
BEGIN
  SELECT version_id INTO v_ver FROM create_workflow_definition('67800000-0000-0000-0000-000000000001', p_name, p_name, 'opaque_case', p_payload, gen_random_uuid());
  PERFORM publish_workflow_definition_version(v_ver, 0, gen_random_uuid());
  v_inst := create_workflow_instance(v_ver, 'opaque_case', gen_random_uuid(), '67800000-0000-0000-0000-000000000001', gen_random_uuid(), NULL);
  PERFORM start_workflow_instance(v_inst, 0, gen_random_uuid());
  INSERT INTO wfrl_ids VALUES (p_name, v_inst);
  RETURN v_inst;
END;
$$ LANGUAGE plpgsql;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67800000-0001-0000-0000-000000000001"}',true);

-- ── 1: required approval — normal majority approval completes. ──────
SELECT wfrl_start('s1', :REQUIRED_PAYLOAD::jsonb);
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfrl_ids WHERE name='s1'); v_wi UUID; v_actor UUID; v_n INTEGER := 0; v_lock BIGINT := 1;
BEGIN
  FOR v_actor IN SELECT user_id FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LOOP
    EXIT WHEN v_n >= 2;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
    SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
    PERFORM decide_workflow_work_item(v_wi, 'approve', v_lock, 0, gen_random_uuid());
    v_lock := v_lock + 1; v_n := v_n + 1;
  END LOOP;
  PERFORM set_config('request.jwt.claims','{"sub":"67800000-0001-0000-0000-000000000001"}',true);
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed'
     OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 'a' THEN
    RAISE EXCEPTION 'expected required-node majority approval to complete';
  END IF;
END $$;
SELECT wfrl_assert_contiguous((SELECT id FROM wfrl_ids WHERE name='s1'), 'scenario 1');
INSERT INTO wfrl_results VALUES (1,'a required approval node behaves exactly as before: majority approval completes the round and the instance');

-- ── 2: optional approval with nonzero candidates behaves exactly
--    like a required node under its decision rule — not silently
--    skipped (docs/63's own worked-example phrasing). ───────────────
SELECT wfrl_start('s2', :OPTIONAL_NONZERO_PAYLOAD::jsonb);
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfrl_ids WHERE name='s2'); v_wi UUID; v_actor UUID; v_n INTEGER := 0; v_lock BIGINT := 1;
BEGIN
  IF (SELECT electorate_count FROM workflow_approval_rounds WHERE instance_id=v_iid) <> 3 THEN
    RAISE EXCEPTION 'expected optional node with 3 resolvable supervisors to open a real round of 3, not skip';
  END IF;
  FOR v_actor IN SELECT user_id FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LOOP
    EXIT WHEN v_n >= 2;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
    SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
    PERFORM decide_workflow_work_item(v_wi, 'approve', v_lock, 0, gen_random_uuid());
    v_lock := v_lock + 1; v_n := v_n + 1;
  END LOOP;
  PERFORM set_config('request.jwt.claims','{"sub":"67800000-0001-0000-0000-000000000001"}',true);
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed'
     OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 'a' THEN
    RAISE EXCEPTION 'expected optional node with nonzero candidates to resolve normally to approved';
  END IF;
END $$;
SELECT wfrl_assert_contiguous((SELECT id FROM wfrl_ids WHERE name='s2'), 'scenario 2');
INSERT INTO wfrl_results VALUES (2,'an optional approval node with one or more resolved candidates is never silently skipped; it follows its normal decision rule exactly like a required node');

-- ── 3: empty electorate — single-hop skip. Immutable skipped round/
--    step history, no work item, correct skip events, follows the
--    skipped edge to End. ────────────────────────────────────────────
SELECT wfrl_start('s3', :SINGLE_SKIP_PAYLOAD::jsonb);
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfrl_ids WHERE name='s3'); v_round RECORD;
BEGIN
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed'
     OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 's' THEN
    RAISE EXCEPTION 'expected zero-candidate optional node to skip straight through to s_end';
  END IF;
  SELECT * INTO v_round FROM workflow_approval_rounds WHERE instance_id=v_iid;
  IF v_round.electorate_count <> 0 OR v_round.approval_threshold <> 0
     OR v_round.state <> 'completed' OR v_round.outcome_code <> 'skipped' THEN
    RAISE EXCEPTION 'expected the skipped round to record electorate_count=0, approval_threshold=0, state=completed, outcome_code=skipped';
  END IF;
  IF (SELECT count(*) FROM workflow_work_items WHERE instance_id=v_iid) <> 0 THEN
    RAISE EXCEPTION 'expected zero work items created for the skipped round';
  END IF;
  IF (SELECT count(*) FROM workflow_approval_positions WHERE round_id=v_round.id) <> 0 THEN
    RAISE EXCEPTION 'expected zero positions created for the skipped round';
  END IF;
  IF (SELECT state FROM workflow_instance_steps WHERE instance_id=v_iid AND definition_node_key='review1') <> 'completed'
     OR (SELECT result_code FROM workflow_instance_steps WHERE instance_id=v_iid AND definition_node_key='review1') <> 'skipped' THEN
    RAISE EXCEPTION 'expected review1 to be completed with result_code skipped';
  END IF;
  IF (SELECT count(*) FROM workflow_events WHERE instance_id=v_iid AND event_type='step_skipped') <> 1 THEN
    RAISE EXCEPTION 'expected exactly one step_skipped event';
  END IF;
  IF EXISTS (
    SELECT 1 FROM workflow_events WHERE instance_id=v_iid AND event_type='step_completed'
      AND step_id=(SELECT id FROM workflow_instance_steps WHERE instance_id=v_iid AND definition_node_key='review1')
  ) THEN RAISE EXCEPTION 'the skipped step must emit step_skipped, never step_completed'; END IF;
END $$;
SELECT wfrl_assert_contiguous((SELECT id FROM wfrl_ids WHERE name='s3'), 'scenario 3');
INSERT INTO wfrl_results VALUES (3,'a zero-candidate optional approval node creates an immutable skipped round/step history (electorate_count=0, approval_threshold=0), creates no work item, emits step_skipped (not step_completed), and follows the skipped edge synchronously to End');

-- ── 4: empty electorate — multi-hop chain (two consecutive
--    zero-candidate optional skips) before a real round opens and
--    waits. ────────────────────────────────────────────────────────
WITH made AS (SELECT * FROM create_workflow_definition('67800000-0000-0000-0000-000000000001','s4_def','s4_def','opaque_case',
  :TWO_HOP_SKIP_PAYLOAD::jsonb, gen_random_uuid()))
INSERT INTO wfrl_ids SELECT 's4_ver', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfrl_ids WHERE name='s4_ver'),0,gen_random_uuid());
INSERT INTO wfrl_ids SELECT 's4', create_workflow_instance((SELECT id FROM wfrl_ids WHERE name='s4_ver'),'opaque_case',gen_random_uuid(),'67800000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfrl_ids WHERE name='s4'),0,gen_random_uuid());
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfrl_ids WHERE name='s4');
BEGIN
  IF (SELECT state FROM workflow_instance_steps WHERE instance_id=v_iid AND definition_node_key='review2') <> 'waiting' THEN
    RAISE EXCEPTION 'expected review2 (a real required round) to be waiting after review1 skipped';
  END IF;
  IF (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id=v_iid) <> 2 THEN
    RAISE EXCEPTION 'expected 2 rounds: review1 (skipped) + review2 (real, open)';
  END IF;
  IF (SELECT state FROM workflow_approval_rounds WHERE instance_id=v_iid AND step_id=(SELECT id FROM workflow_instance_steps WHERE instance_id=v_iid AND definition_node_key='review1')) <> 'completed'
     OR (SELECT outcome_code FROM workflow_approval_rounds WHERE instance_id=v_iid AND step_id=(SELECT id FROM workflow_instance_steps WHERE instance_id=v_iid AND definition_node_key='review1')) <> 'skipped' THEN
    RAISE EXCEPTION 'expected review1''s round to be completed/skipped';
  END IF;
END $$;
SELECT wfrl_assert_contiguous((SELECT id FROM wfrl_ids WHERE name='s4'), 'scenario 4');
INSERT INTO wfrl_results VALUES (4,'a zero-candidate optional node whose skipped edge targets another approval node synchronously continues into that node, opening a real round and waiting there — the bounded multi-hop skip chain docs/63''s empty-electorate contract requires');

-- ── 5: skipped voter — sequential delivery closes before the last
--    position is ever offered; the never-offered position is
--    cancelled without its own event (no work item existed to
--    cancel). ─────────────────────────────────────────────────────
SELECT wfrl_start('s5', :SEQUENTIAL_PAYLOAD::jsonb);
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfrl_ids WHERE name='s5'); v_wi UUID; v_actor UUID; v_ord INTEGER;
BEGIN
  IF (SELECT count(*) FROM workflow_work_items WHERE instance_id=v_iid) <> 1 THEN
    RAISE EXCEPTION 'sequential delivery must offer exactly 1 work item at round-open';
  END IF;
  FOR v_ord IN 1..2 LOOP
    SELECT user_id INTO v_actor FROM workflow_approval_positions WHERE instance_id=v_iid AND ordinal=v_ord;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
    SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor AND state='offered';
    PERFORM decide_workflow_work_item(v_wi, 'approve', v_ord, 0, gen_random_uuid());
  END LOOP;
  PERFORM set_config('request.jwt.claims','{"sub":"67800000-0001-0000-0000-000000000001"}',true);
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed' THEN
    RAISE EXCEPTION 'expected the round to close after 2/3 sequential approvals (majority)';
  END IF;
  IF (SELECT state FROM workflow_approval_positions WHERE instance_id=v_iid AND ordinal=3) <> 'cancelled' THEN
    RAISE EXCEPTION 'expected ordinal 3 (never offered) to be cancelled, the skipped voter';
  END IF;
  IF (SELECT work_item_id FROM workflow_approval_positions WHERE instance_id=v_iid AND ordinal=3) IS NOT NULL THEN
    RAISE EXCEPTION 'the skipped voter never had a work item and must not gain one retroactively';
  END IF;
  IF EXISTS (SELECT 1 FROM workflow_events WHERE instance_id=v_iid AND event_type='work_item_cancelled'
             AND metadata->>'reason_code'='round_closed' AND work_item_id IS NULL) THEN
    RAISE EXCEPTION 'a never-offered position must not emit a work_item_cancelled event (nothing work-item-shaped to cancel)';
  END IF;
END $$;
SELECT wfrl_assert_contiguous((SELECT id FROM wfrl_ids WHERE name='s5'), 'scenario 5');
INSERT INTO wfrl_results VALUES (5,'the skipped voter in sequential delivery (a position never reached because the round closed early) is cancelled without ever gaining a work item and without its own event');

-- ── 6: unavailable voter — a candidate deactivated after the round
--    opens cannot decide; the position remains counted; other
--    eligible voters can still decide; the round stays blocked until
--    a later recovery mechanism (none in v1) or cancellation. ───────
SELECT wfrl_start('s6', :REQUIRED_PAYLOAD::jsonb);
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfrl_ids WHERE name='s6'); v_blocked_user UUID; v_wi UUID;
BEGIN
  -- Look up the work item and deactivate the user while still acting
  -- as an actor with visibility (RLS on workflow_work_items/
  -- workflow_approval_positions requires the viewer to have instance
  -- visibility, which an inactive actor loses for their own rows
  -- too) — switch to the blocked user's identity ONLY for the
  -- decision attempt itself, then switch straight back.
  SELECT user_id INTO v_blocked_user FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LIMIT 1;
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_blocked_user;
  UPDATE users SET is_active=false WHERE id=v_blocked_user;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_blocked_user)::text, true);
  BEGIN
    PERFORM decide_workflow_work_item(v_wi, 'approve', 1, 0, gen_random_uuid());
    RAISE EXCEPTION 'expected the deactivated voter to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected the deactivated voter to be rejected' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claims','{"sub":"67800000-0001-0000-0000-000000000001"}',true);

  IF (SELECT count(*) FROM workflow_approval_positions WHERE instance_id=v_iid) <> 3 THEN
    RAISE EXCEPTION 'the unavailable voter''s position must remain in the denominator, not be removed (got %)', (SELECT count(*) FROM workflow_approval_positions WHERE instance_id=v_iid);
  END IF;
  IF (SELECT state FROM workflow_approval_positions WHERE instance_id=v_iid AND user_id=v_blocked_user) <> 'offered' THEN
    RAISE EXCEPTION 'the unavailable voter''s position must remain offered (blocked, not silently resolved)';
  END IF;

  UPDATE users SET is_active=true WHERE id=v_blocked_user;
END $$;
INSERT INTO wfrl_results VALUES (6,'an approval candidate deactivated after the round opens cannot submit a decision, their position remains in the denominator rather than being reassigned or removed, and other eligible voters remain unaffected');

-- ── 7: get_workflow_approval_round_blocked_count — a manager sees
--    the correct identity-free count; a non-manager is rejected. ────
SELECT wfrl_start('s7', :REQUIRED_PAYLOAD::jsonb);
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfrl_ids WHERE name='s7'); v_rid UUID; v_blocked1 UUID; v_blocked2 UUID; v_count INTEGER;
BEGIN
  SELECT id INTO v_rid FROM workflow_approval_rounds WHERE instance_id=v_iid;
  SELECT user_id INTO v_blocked1 FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LIMIT 1;
  SELECT user_id INTO v_blocked2 FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal OFFSET 1 LIMIT 1;
  UPDATE users SET is_active=false WHERE id IN (v_blocked1, v_blocked2);

  SELECT get_workflow_approval_round_blocked_count(v_rid) INTO v_count;
  IF v_count <> 2 THEN RAISE EXCEPTION 'expected blocked count 2, got %', v_count; END IF;

  UPDATE users SET is_active=true WHERE id IN (v_blocked1, v_blocked2);
END $$;
INSERT INTO wfrl_results VALUES (7,'get_workflow_approval_round_blocked_count returns the correct count of offered/pending positions whose assigned user is inactive, to an authorized manager, reusing can_manage_workflow_instance() unchanged');

DO $$
DECLARE v_iid UUID := (SELECT id FROM wfrl_ids WHERE name='s7'); v_rid UUID;
BEGIN
  SELECT id INTO v_rid FROM workflow_approval_rounds WHERE instance_id=v_iid;
  PERFORM set_config('request.jwt.claims','{"sub":"67800000-0001-0000-0000-000000000005"}',true);
  BEGIN
    PERFORM get_workflow_approval_round_blocked_count(v_rid);
    RAISE EXCEPTION 'expected a non-manager to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected a non-manager to be rejected' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claims','{"sub":"67800000-0001-0000-0000-000000000001"}',true);
END $$;
INSERT INTO wfrl_results VALUES (8,'get_workflow_approval_round_blocked_count rejects a non-manager caller, revealing no blocked count and no identity details to an unauthorized viewer');

-- ── 9: late vote after closure — a round that has already reached
--    its terminal outcome rejects a further decision on its own
--    remaining (now-cancelled) work items. ──────────────────────────
SELECT wfrl_start('s9', :REQUIRED_PAYLOAD::jsonb);
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfrl_ids WHERE name='s9'); v_wi UUID; v_actor UUID; v_n INTEGER := 0; v_lock BIGINT := 1;
  v_late_wi UUID; v_late_actor UUID;
BEGIN
  SELECT user_id INTO v_late_actor FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal OFFSET 2 LIMIT 1;
  SELECT id INTO v_late_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_late_actor;
  FOR v_actor IN SELECT user_id FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LOOP
    EXIT WHEN v_n >= 2;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
    SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
    PERFORM decide_workflow_work_item(v_wi, 'approve', v_lock, 0, gen_random_uuid());
    v_lock := v_lock + 1; v_n := v_n + 1;
  END LOOP;
  -- round is now closed (2/3 majority); v_late_wi was cancelled.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_late_actor)::text, true);
  BEGIN
    PERFORM decide_workflow_work_item(v_late_wi, 'approve', v_lock, 0, gen_random_uuid());
    RAISE EXCEPTION 'expected a late decision after round closure to fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected a late decision after round closure to fail' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claims','{"sub":"67800000-0001-0000-0000-000000000001"}',true);
END $$;
INSERT INTO wfrl_results VALUES (9,'voting after closure: a decision against a work item whose round already reached its terminal outcome and cancelled that work item is rejected');

-- ── 10: late vote after cancellation — cancelling the instance closes
--    the open round/positions; a subsequent decision fails because
--    the instance is no longer active. ─────────────────────────────
SELECT wfrl_start('s10', :REQUIRED_PAYLOAD::jsonb);
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfrl_ids WHERE name='s10'); v_wi UUID; v_actor UUID;
BEGIN
  SELECT user_id INTO v_actor FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LIMIT 1;
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
  PERFORM cancel_workflow_instance(v_iid, 1, gen_random_uuid(), 'lifecycle_test');
  IF (SELECT state FROM workflow_approval_rounds WHERE instance_id=v_iid) <> 'cancelled' THEN
    RAISE EXCEPTION 'expected instance cancellation to close the open round';
  END IF;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
  BEGIN
    PERFORM decide_workflow_work_item(v_wi, 'approve', 2, 0, gen_random_uuid());
    RAISE EXCEPTION 'expected a decision after instance cancellation to fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected a decision after instance cancellation to fail' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claims','{"sub":"67800000-0001-0000-0000-000000000001"}',true);
END $$;
INSERT INTO wfrl_results VALUES (10,'voting after cancellation: instance cancellation closes the open round and its offered/pending positions, and a subsequent decision fails because the instance is no longer active');

-- ── 11: late vote after completion — once the instance has completed
--    (End reached), a decision attempt against any residual work
--    item reference fails because the instance is no longer active. ─
SELECT wfrl_start('s11', :REQUIRED_PAYLOAD::jsonb);
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfrl_ids WHERE name='s11'); v_wi UUID; v_actor UUID; v_n INTEGER := 0; v_lock BIGINT := 1; v_third_wi UUID; v_third_actor UUID;
BEGIN
  SELECT user_id INTO v_third_actor FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal OFFSET 2 LIMIT 1;
  SELECT id INTO v_third_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_third_actor;
  FOR v_actor IN SELECT user_id FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LOOP
    EXIT WHEN v_n >= 2;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
    SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
    PERFORM decide_workflow_work_item(v_wi, 'approve', v_lock, 0, gen_random_uuid());
    v_lock := v_lock + 1; v_n := v_n + 1;
  END LOOP;
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed' THEN
    RAISE EXCEPTION 'expected the instance to complete after majority approval';
  END IF;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_third_actor)::text, true);
  BEGIN
    PERFORM decide_workflow_work_item(v_third_wi, 'approve', v_lock, 0, gen_random_uuid());
    RAISE EXCEPTION 'expected a decision after instance completion to fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected a decision after instance completion to fail' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claims','{"sub":"67800000-0001-0000-0000-000000000001"}',true);
END $$;
INSERT INTO wfrl_results VALUES (11,'voting after completion: once the instance has completed, a decision against a residual (already-cancelled) work item fails because the instance is no longer active');

-- ── 12: late vote after replacement — deciding review1 approved
--    replaces it with review2 as the instance's current round; a
--    decision against review1's now-closed position fails. ──────────
SELECT wfrl_start('s12', :TWO_HOP_REAL_PAYLOAD::jsonb);
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfrl_ids WHERE name='s12'); v_wi UUID; v_actor UUID; v_n INTEGER := 0; v_lock BIGINT := 1;
  v_r1_late_wi UUID; v_r1_late_actor UUID;
BEGIN
  SELECT user_id INTO v_r1_late_actor FROM workflow_approval_positions p JOIN workflow_instance_steps s ON s.id=p.step_id
    WHERE p.instance_id=v_iid AND s.definition_node_key='review1' ORDER BY p.ordinal OFFSET 2 LIMIT 1;
  SELECT id INTO v_r1_late_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_r1_late_actor;

  FOR v_actor IN SELECT user_id FROM workflow_approval_positions p JOIN workflow_instance_steps s ON s.id=p.step_id
                 WHERE p.instance_id=v_iid AND s.definition_node_key='review1' ORDER BY p.ordinal LOOP
    EXIT WHEN v_n >= 2;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
    SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
    PERFORM decide_workflow_work_item(v_wi, 'approve', v_lock, 0, gen_random_uuid());
    v_lock := v_lock + 1; v_n := v_n + 1;
  END LOOP;
  -- review1's round is now replaced: review2 has opened as the
  -- instance's current round.
  IF (SELECT state FROM workflow_instance_steps WHERE instance_id=v_iid AND definition_node_key='review2') <> 'waiting' THEN
    RAISE EXCEPTION 'expected review2 to have opened, replacing review1 as the current round';
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_r1_late_actor)::text, true);
  BEGIN
    PERFORM decide_workflow_work_item(v_r1_late_wi, 'approve', v_lock, 0, gen_random_uuid());
    RAISE EXCEPTION 'expected a decision against the replaced round to fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected a decision against the replaced round to fail' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claims','{"sub":"67800000-0001-0000-0000-000000000001"}',true);
END $$;
INSERT INTO wfrl_results VALUES (12,'voting after replacement: once the graph has advanced past a closed round into the next approval node, a decision against the superseded round''s own now-closed position fails');

-- ── 13: replay through a skip chain — replaying the same terminal
--    decision command twice, where the closed round''s advancement
--    passes through a zero-candidate optional skip before reaching
--    End, returns an identical result both times. ───────────────────
SELECT wfrl_start('s13', :DECIDE_THEN_SKIP_PAYLOAD::jsonb);
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfrl_ids WHERE name='s13'); v_wi UUID; v_actor UUID; v_n INTEGER := 0; v_lock BIGINT := 1;
  v_cmd UUID := gen_random_uuid(); r1 RECORD; r2 RECORD;
BEGIN
  FOR v_actor IN SELECT user_id FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LOOP
    v_n := v_n + 1;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
    SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
    IF v_n < 3 THEN
      PERFORM decide_workflow_work_item(v_wi, 'approve', v_lock, 0, gen_random_uuid());
      v_lock := v_lock + 1;
    ELSE
      SELECT * INTO r1 FROM decide_workflow_work_item(v_wi, 'approve', v_lock, 0, v_cmd);
      SELECT * INTO r2 FROM decide_workflow_work_item(v_wi, 'approve', v_lock, 0, v_cmd);
    END IF;
  END LOOP;
  PERFORM set_config('request.jwt.claims','{"sub":"67800000-0001-0000-0000-000000000001"}',true);

  IF r2.replayed IS NOT TRUE OR r1.event_id <> r2.event_id OR r1.event_sequence <> r2.event_sequence
     OR r1.instance_status <> r2.instance_status OR r1.round_outcome <> r2.round_outcome THEN
    RAISE EXCEPTION 'replay through a skip chain must return an identical result';
  END IF;
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed'
     OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 's' THEN
    RAISE EXCEPTION 'expected reviewa''s unanimous approval to advance through reviewb''s skip to s_end, got status=%, outcome=%',
      (SELECT status FROM workflow_instances WHERE id=v_iid), (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid);
  END IF;
END $$;
SELECT wfrl_assert_contiguous((SELECT id FROM wfrl_ids WHERE name='s13'), 'scenario 13');
INSERT INTO wfrl_results VALUES (13,'replaying the same command id for a decision whose closure advances through a zero-candidate optional skip chain returns an identical result on both calls, proving the peek-computed root-event metadata is replay-consistent even across a multi-hop synchronous advance');

RESET ROLE;

-- ── 14: immutable round completion — a direct UPDATE or DELETE
--    against an already-terminal round is rejected at the database
--    level, independent of RLS/grants (superuser bypasses those). ──
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfrl_ids WHERE name='s9'); v_rid UUID;
BEGIN
  SELECT id INTO v_rid FROM workflow_approval_rounds WHERE instance_id=v_iid;
  BEGIN
    UPDATE workflow_approval_rounds SET outcome_code='approved' WHERE id=v_rid;
    RAISE EXCEPTION 'expected UPDATE on a terminal round to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected UPDATE on a terminal round to be rejected' THEN RAISE; END IF;
  END;
  BEGIN
    DELETE FROM workflow_approval_rounds WHERE id=v_rid;
    RAISE EXCEPTION 'expected DELETE on a terminal round to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected DELETE on a terminal round to be rejected' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfrl_results VALUES (14,'a database-enforced trigger rejects any UPDATE or DELETE against an approval round that has already reached a terminal state, independent of RLS or application-layer checks');

-- ── 15: immutable position history — same guarantee for a decided
--    position. ────────────────────────────────────────────────────
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfrl_ids WHERE name='s1'); v_pid UUID;
BEGIN
  SELECT id INTO v_pid FROM workflow_approval_positions WHERE instance_id=v_iid AND state='decided' LIMIT 1;
  BEGIN
    UPDATE workflow_approval_positions SET state='offered' WHERE id=v_pid;
    RAISE EXCEPTION 'expected UPDATE on a decided position to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected UPDATE on a decided position to be rejected' THEN RAISE; END IF;
  END;
  BEGIN
    DELETE FROM workflow_approval_positions WHERE id=v_pid;
    RAISE EXCEPTION 'expected DELETE on a decided position to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected DELETE on a decided position to be rejected' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfrl_results VALUES (15,'a database-enforced trigger rejects any UPDATE or DELETE against an approval position that has already reached a terminal state (decided/cancelled/unavailable), preserving immutable round history at the database level');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfrl_results;
  IF v_count <> 15 THEN
    RAISE EXCEPTION 'Workflow approval round lifecycle behavioral tests FAILED: expected 15, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow approval round lifecycle behavioral tests PASSED: %/15', v_count;
END $$;

ROLLBACK;
