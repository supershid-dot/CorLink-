-- CAP-002 Phase 3.1 approval decision engine — behavioral suite
-- Runs in one transaction and leaves no fixtures.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wfad_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfad_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfad_results, wfad_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('67100000-0000-0000-0000-000000000001','WF Approval Decision A','authority','WFAD-A'),
 ('67100000-0000-0000-0000-000000000002','WF Approval Decision B','authority','WFAD-B');
INSERT INTO auth.users(id,email) VALUES
 ('67100000-0001-0000-0000-000000000001','creator@wfad.local'),
 ('67100000-0001-0000-0000-000000000002','sup1@wfad.local'),
 ('67100000-0001-0000-0000-000000000003','sup2@wfad.local'),
 ('67100000-0001-0000-0000-000000000004','sup3@wfad.local'),
 ('67100000-0001-0000-0000-000000000005','sup4@wfad.local'),
 ('67100000-0001-0000-0000-000000000006','rev1@wfad.local'),
 ('67100000-0001-0000-0000-000000000007','rev2@wfad.local'),
 ('67100000-0001-0000-0000-000000000008','intruder@wfad.local'),
 ('67100000-0001-0000-0000-000000000009','otherorg@wfad.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('67100000-0001-0000-0000-000000000001','67100000-0000-0000-0000-000000000001','WFAD-1','Creator','creator@wfad.local',true),
 ('67100000-0001-0000-0000-000000000002','67100000-0000-0000-0000-000000000001','WFAD-2','Sup1','sup1@wfad.local',true),
 ('67100000-0001-0000-0000-000000000003','67100000-0000-0000-0000-000000000001','WFAD-3','Sup2','sup2@wfad.local',true),
 ('67100000-0001-0000-0000-000000000004','67100000-0000-0000-0000-000000000001','WFAD-4','Sup3','sup3@wfad.local',true),
 ('67100000-0001-0000-0000-000000000005','67100000-0000-0000-0000-000000000001','WFAD-5','Sup4','sup4@wfad.local',true),
 ('67100000-0001-0000-0000-000000000006','67100000-0000-0000-0000-000000000001','WFAD-6','Rev1','rev1@wfad.local',true),
 ('67100000-0001-0000-0000-000000000007','67100000-0000-0000-0000-000000000001','WFAD-7','Rev2','rev2@wfad.local',true),
 ('67100000-0001-0000-0000-000000000008','67100000-0000-0000-0000-000000000001','WFAD-8','Intruder','intruder@wfad.local',true),
 ('67100000-0001-0000-0000-000000000009','67100000-0000-0000-0000-000000000002','WFAD-9','OtherOrg','otherorg@wfad.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('67100000-0001-0000-0000-000000000001','organization','67100000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('67100000-0001-0000-0000-000000000002','organization','67100000-0000-0000-0000-000000000001','supervisor',true,true),
 ('67100000-0001-0000-0000-000000000003','organization','67100000-0000-0000-0000-000000000001','supervisor',true,true),
 ('67100000-0001-0000-0000-000000000004','organization','67100000-0000-0000-0000-000000000001','supervisor',true,true),
 ('67100000-0001-0000-0000-000000000005','organization','67100000-0000-0000-0000-000000000001','supervisor',true,true),
 ('67100000-0001-0000-0000-000000000006','organization','67100000-0000-0000-0000-000000000001','assigned_receiver',true,true),
 ('67100000-0001-0000-0000-000000000007','organization','67100000-0000-0000-0000-000000000001','assigned_receiver',true,true),
 ('67100000-0001-0000-0000-000000000008','organization','67100000-0000-0000-0000-000000000001','staff',true,true),
 ('67100000-0001-0000-0000-000000000009','organization','67100000-0000-0000-0000-000000000002','authority_admin',true,true);

-- Single approval node, N supervisors, parallel delivery, unanimous
-- decision, reject_behavior=immediate.
\set UNANIMOUS_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"unanimous","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"immediate","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''
-- Single approval node, N supervisors, parallel delivery, majority
-- decision, reject_behavior=when_approval_impossible.
\set MAJORITY_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''
-- Same as MAJORITY_PAYLOAD but allow_abstain=false (comment_policy
-- for abstain must be 'forbidden' whenever allow_abstain is false,
-- per the Phase 2B.1 validator's approval_comment_policy_invalid rule).
\set MAJORITY_NOABSTAIN_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":false,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"forbidden"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''
-- Same electorate, sequential delivery, majority.
\set SEQUENTIAL_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"sequential","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''
-- Two-hop: review1 (supervisors, parallel/majority) -> review2
-- (assigned_receiver role, parallel/majority) -> ends. Disjoint role
-- selectors mean the creator never collides with either electorate.
\set TWO_HOP_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review1","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"review2","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_reviewers","order":1,"type":"organization_role","organization":"home","role":"assigned_receiver"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review1","outcome":"started","priority":0,"default":false},{"source":"review1","target":"review2","outcome":"approved","priority":0,"default":false},{"source":"review1","target":"r_end","outcome":"rejected","priority":0,"default":false},{"source":"review2","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review2","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

CREATE OR REPLACE FUNCTION wfad_assert_contiguous(p_instance_id UUID, p_label TEXT) RETURNS VOID AS $$
DECLARE v_max BIGINT; v_count BIGINT; v_next BIGINT;
BEGIN
  SELECT max(event_sequence), count(*) INTO v_max, v_count FROM workflow_events WHERE instance_id = p_instance_id;
  SELECT next_event_sequence INTO v_next FROM workflow_instances WHERE id = p_instance_id;
  IF v_max <> v_count THEN RAISE EXCEPTION '% : event sequence not contiguous (max=%, count=%)', p_label, v_max, v_count; END IF;
  IF v_next <> v_max + 1 THEN RAISE EXCEPTION '% : next_event_sequence (%) not exactly one past max (%)', p_label, v_next, v_max; END IF;
END;
$$ LANGUAGE plpgsql;

-- Restrict user_assignments to exactly the N lowest-UUID supervisors
-- among sup1..sup4, so electorate size is deterministic per scenario.
CREATE OR REPLACE FUNCTION wfad_set_supervisor_count(p_n INTEGER) RETURNS VOID AS $$
BEGIN
  UPDATE user_assignments SET is_active = false
    WHERE role = 'supervisor' AND scope_id = '67100000-0000-0000-0000-000000000001';
  UPDATE user_assignments SET is_active = true
    WHERE role = 'supervisor' AND scope_id = '67100000-0000-0000-0000-000000000001'
      AND user_id IN (SELECT unnest(ARRAY[
        '67100000-0001-0000-0000-000000000002','67100000-0001-0000-0000-000000000003',
        '67100000-0001-0000-0000-000000000004','67100000-0001-0000-0000-000000000005'
      ]::UUID[]) LIMIT p_n);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
GRANT EXECUTE ON FUNCTION wfad_set_supervisor_count(INTEGER) TO authenticated;

-- Helper: create+publish+start an instance for a given payload/name,
-- returning (instance_id) into wfad_ids under key p_name. Plain
-- (non-SECURITY DEFINER) function defined before the role switch
-- below, so it runs with the caller's own privileges at call time.
CREATE OR REPLACE FUNCTION wfad_start(p_name TEXT, p_payload JSONB, p_creator UUID) RETURNS UUID AS $$
DECLARE v_def_id UUID; v_ver_id UUID; v_inst_id UUID;
BEGIN
  SELECT definition_id, version_id INTO v_def_id, v_ver_id
  FROM create_workflow_definition('67100000-0000-0000-0000-000000000001', p_name, p_name, 'opaque_case', p_payload, gen_random_uuid());
  PERFORM publish_workflow_definition_version(v_ver_id, 0, gen_random_uuid());
  v_inst_id := create_workflow_instance(v_ver_id, 'opaque_case', gen_random_uuid(), '67100000-0000-0000-0000-000000000001', gen_random_uuid(), NULL);
  PERFORM start_workflow_instance(v_inst_id, 0, gen_random_uuid());
  INSERT INTO wfad_ids VALUES (p_name, v_inst_id);
  RETURN v_inst_id;
END;
$$ LANGUAGE plpgsql;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);

-- ── 1: unanimous approval — N=3 supervisors, all approve. ───────────
SELECT wfad_set_supervisor_count(3);
SELECT wfad_start('s1', :UNANIMOUS_PAYLOAD::jsonb, '67100000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfad_ids WHERE name='s1');
  v_wi UUID; v_lock BIGINT := 0; v_ilock BIGINT := 1; v_actor UUID;
BEGIN
  FOR v_actor IN SELECT user_id FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LOOP
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
    SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
    PERFORM decide_workflow_work_item(v_wi, 'approve', v_ilock, 0, gen_random_uuid());
    v_ilock := v_ilock + 1;
  END LOOP;
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed'
     OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 'a' THEN
    RAISE EXCEPTION 'expected unanimous approval to complete with outcome a';
  END IF;
END $$;
SELECT wfad_assert_contiguous((SELECT id FROM wfad_ids WHERE name='s1'), 'scenario 1');
INSERT INTO wfad_results VALUES (1,'unanimous decision rule: all N electors approving completes the round approved and advances to End');

-- ── 2: unanimous rejection — one reject fails immediately, other
--    electors'' work items are cancelled without ever deciding. ─────
SELECT wfad_set_supervisor_count(3);
SELECT wfad_start('s2', :UNANIMOUS_PAYLOAD::jsonb, '67100000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfad_ids WHERE name='s2'); v_wi UUID; v_actor UUID;
BEGIN
  SELECT user_id INTO v_actor FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LIMIT 1;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
  PERFORM decide_workflow_work_item(v_wi, 'reject', 1, 0, gen_random_uuid(), 'not compliant');
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed'
     OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 'r' THEN
    RAISE EXCEPTION 'expected unanimous rejection (immediate) to complete with outcome r';
  END IF;
  IF EXISTS (SELECT 1 FROM workflow_approval_positions WHERE instance_id=v_iid AND state NOT IN ('decided','cancelled')) THEN
    RAISE EXCEPTION 'expected all remaining positions cancelled';
  END IF;
END $$;
SELECT wfad_assert_contiguous((SELECT id FROM wfad_ids WHERE name='s2'), 'scenario 2');
INSERT INTO wfad_results VALUES (2,'unanimous decision rule with reject_behavior=immediate: a single rejection completes the round rejected without waiting on the remaining electors, cancelling their offered work items');

-- ── 3: majority approval — N=3, T=2, two approvals suffice. ─────────
SELECT wfad_set_supervisor_count(3);
SELECT wfad_start('s3', :MAJORITY_PAYLOAD::jsonb, '67100000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfad_ids WHERE name='s3'); v_wi UUID; v_actor UUID; v_n INTEGER := 0; v_ilock BIGINT := 1;
BEGIN
  FOR v_actor IN SELECT user_id FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LOOP
    EXIT WHEN v_n >= 2;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
    SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
    PERFORM decide_workflow_work_item(v_wi, 'approve', v_ilock, 0, gen_random_uuid());
    v_ilock := v_ilock + 1; v_n := v_n + 1;
  END LOOP;
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed'
     OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 'a' THEN
    RAISE EXCEPTION 'expected majority approval (2/3) to complete with outcome a';
  END IF;
  IF (SELECT count(*) FROM workflow_work_items WHERE instance_id=v_iid AND state='cancelled') <> 1 THEN
    RAISE EXCEPTION 'expected the 3rd elector''s still-offered work item to be cancelled once the round closed early';
  END IF;
END $$;
SELECT wfad_assert_contiguous((SELECT id FROM wfad_ids WHERE name='s3'), 'scenario 3');
INSERT INTO wfad_results VALUES (3,'majority decision rule: reaching the immutable approval_threshold (2 of 3) completes the round approved before the last elector decides, cancelling their still-offered work item');

-- ── 4: majority rejection via approval-impossible. ───────────────────
SELECT wfad_set_supervisor_count(3);
SELECT wfad_start('s4', :MAJORITY_PAYLOAD::jsonb, '67100000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfad_ids WHERE name='s4'); v_wi UUID; v_actor UUID; v_n INTEGER := 0; v_ilock BIGINT := 1;
BEGIN
  FOR v_actor IN SELECT user_id FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LOOP
    EXIT WHEN v_n >= 2;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
    SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
    PERFORM decide_workflow_work_item(v_wi, 'reject', v_ilock, 0, gen_random_uuid(), 'insufficient evidence');
    v_ilock := v_ilock + 1; v_n := v_n + 1;
  END LOOP;
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed'
     OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 'r' THEN
    RAISE EXCEPTION 'expected majority rejection (approval impossible after 2/3 reject) to complete with outcome r';
  END IF;
END $$;
SELECT wfad_assert_contiguous((SELECT id FROM wfad_ids WHERE name='s4'), 'scenario 4');
INSERT INTO wfad_results VALUES (4,'majority decision rule with reject_behavior=when_approval_impossible: enough rejections to make the threshold unreachable (A+U<T) completes the round rejected');

-- ── 5: abstention — docs/63''s own worked example (N=4,A=2,B=2,R=0
--    rejects because A+U<T even though zero explicit rejections). ───
SELECT wfad_set_supervisor_count(4);
SELECT wfad_start('s5', :MAJORITY_PAYLOAD::jsonb, '67100000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfad_ids WHERE name='s5'); v_wi UUID; v_actor UUID; v_n INTEGER := 0; v_ilock BIGINT := 1; v_code TEXT;
BEGIN
  IF (SELECT approval_threshold FROM workflow_approval_rounds WHERE instance_id=v_iid) <> 3 THEN
    RAISE EXCEPTION 'expected threshold 3 for N=4 majority';
  END IF;
  FOR v_actor IN SELECT user_id FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LOOP
    v_code := CASE WHEN v_n < 2 THEN 'approve' ELSE 'abstain' END;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
    SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
    PERFORM decide_workflow_work_item(v_wi, v_code, v_ilock, 0, gen_random_uuid());
    v_ilock := v_ilock + 1; v_n := v_n + 1;
  END LOOP;
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed'
     OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 'r' THEN
    RAISE EXCEPTION 'expected N=4,A=2,B=2 to reject per docs/63''s worked example, got status=%, outcome=%',
      (SELECT status FROM workflow_instances WHERE id=v_iid), (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid);
  END IF;
END $$;
SELECT wfad_assert_contiguous((SELECT id FROM wfad_ids WHERE name='s5'), 'scenario 5');
INSERT INTO wfad_results VALUES (5,'abstention never counts toward approval and never reduces the electorate denominator: two approvals and two abstentions out of four reject the round, matching docs/63''s worked example exactly');

-- ── 6: duplicate vote — a second decision against an already-decided
--    position''s work item is rejected without a second row. ────────
SELECT wfad_set_supervisor_count(3);
SELECT wfad_start('s6', :MAJORITY_PAYLOAD::jsonb, '67100000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfad_ids WHERE name='s6'); v_wi UUID; v_actor UUID; v_before INTEGER;
BEGIN
  SELECT user_id INTO v_actor FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LIMIT 1;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
  PERFORM decide_workflow_work_item(v_wi, 'approve', 1, 0, gen_random_uuid());
  SELECT count(*) INTO v_before FROM workflow_decisions WHERE instance_id=v_iid;
  BEGIN
    PERFORM decide_workflow_work_item(v_wi, 'approve', 2, 1, gen_random_uuid());
    RAISE EXCEPTION 'expected duplicate vote to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected duplicate vote to be rejected' THEN RAISE; END IF;
  END;
  IF (SELECT count(*) FROM workflow_decisions WHERE instance_id=v_iid) <> v_before THEN
    RAISE EXCEPTION 'duplicate vote attempt must not insert a second decision row';
  END IF;
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);
END $$;
SELECT wfad_assert_contiguous((SELECT id FROM wfad_ids WHERE name='s6'), 'scenario 6');
INSERT INTO wfad_results VALUES (6,'a second decision against a work item whose position is already decided is rejected without inserting a second row into the immutable decision ledger');

-- ── 7: unauthorized voting — a non-assigned actor cannot decide
--    someone else''s work item, even a manager/admin. ─────────────────
SELECT wfad_set_supervisor_count(3);
SELECT wfad_start('s7', :MAJORITY_PAYLOAD::jsonb, '67100000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfad_ids WHERE name='s7'); v_wi UUID; v_owner UUID;
BEGIN
  SELECT user_id INTO v_owner FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LIMIT 1;
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_owner;
  -- creator (an org admin) attempts to decide the supervisor's item.
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);
  BEGIN
    PERFORM decide_workflow_work_item(v_wi, 'approve', 1, 0, gen_random_uuid());
    RAISE EXCEPTION 'expected unauthorized decision by a non-owning admin to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected unauthorized decision by a non-owning admin to be rejected' THEN RAISE; END IF;
  END;
  IF EXISTS (SELECT 1 FROM workflow_decisions WHERE instance_id=v_iid) THEN
    RAISE EXCEPTION 'unauthorized attempt must not insert a decision row';
  END IF;
END $$;
SELECT wfad_assert_contiguous((SELECT id FROM wfad_ids WHERE name='s7'), 'scenario 7');
INSERT INTO wfad_results VALUES (7,'a caller who is not the exact assigned voter is rejected — managers and admins cannot cast another actor''s decision, even though they can manage the instance''s lifecycle');

-- ── 8: sequential approvals — only ordinal 1 is offered initially;
--    each nonterminal accepted decision offers exactly the next one. ─
SELECT wfad_set_supervisor_count(3);
SELECT wfad_start('s8', :SEQUENTIAL_PAYLOAD::jsonb, '67100000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfad_ids WHERE name='s8'); v_wi UUID; v_actor UUID; v_ord INTEGER;
BEGIN
  IF (SELECT count(*) FROM workflow_work_items WHERE instance_id=v_iid) <> 1 THEN
    RAISE EXCEPTION 'sequential delivery must offer exactly 1 work item at round-open';
  END IF;
  FOR v_ord IN 1..2 LOOP
    SELECT user_id INTO v_actor FROM workflow_approval_positions WHERE instance_id=v_iid AND ordinal=v_ord;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
    SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor AND state='offered';
    PERFORM decide_workflow_work_item(v_wi, 'approve', v_ord, 0, gen_random_uuid());
    IF v_ord < 2 AND (SELECT count(*) FROM workflow_work_items WHERE instance_id=v_iid AND state='offered') <> 1 THEN
      RAISE EXCEPTION 'expected exactly the next ordinal position to be offered after a nonterminal sequential decision';
    END IF;
  END LOOP;
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed'
     OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 'a' THEN
    RAISE EXCEPTION 'expected sequential majority (2/3) approval to complete with outcome a';
  END IF;
  IF EXISTS (SELECT 1 FROM workflow_approval_positions WHERE instance_id=v_iid AND ordinal=3 AND state <> 'cancelled') THEN
    RAISE EXCEPTION 'expected ordinal 3''s never-offered position to be cancelled, not left pending';
  END IF;
END $$;
SELECT wfad_assert_contiguous((SELECT id FROM wfad_ids WHERE name='s8'), 'scenario 8');
INSERT INTO wfad_results VALUES (8,'sequential delivery: only ordinal 1 is offered at round-open, each nonterminal accepted decision atomically offers the next pending position, and the terminal decision cancels any still-pending never-offered positions');

-- ── 9: parallel approvals — all positions offered at round-open, no
--    additional offers occur as decisions land. ─────────────────────
SELECT wfad_set_supervisor_count(3);
SELECT wfad_start('s9', :MAJORITY_PAYLOAD::jsonb, '67100000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfad_ids WHERE name='s9'); v_wi UUID; v_actor UUID;
BEGIN
  IF (SELECT count(*) FROM workflow_work_items WHERE instance_id=v_iid AND state='offered') <> 3 THEN
    RAISE EXCEPTION 'parallel delivery must offer all 3 work items at round-open';
  END IF;
  SELECT user_id INTO v_actor FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LIMIT 1;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
  PERFORM decide_workflow_work_item(v_wi, 'approve', 1, 0, gen_random_uuid());
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);
  IF (SELECT count(*) FROM workflow_work_items WHERE instance_id=v_iid) <> 3 THEN
    RAISE EXCEPTION 'a nonterminal parallel decision must not create any new work item';
  END IF;
END $$;
SELECT wfad_assert_contiguous((SELECT id FROM wfad_ids WHERE name='s9'), 'scenario 9');
INSERT INTO wfad_results VALUES (9,'parallel delivery: every position is already offered at round-open, and a nonterminal decision offers nothing further');

-- ── 10: idempotent replay — nonterminal and terminal decisions both
--     replay identically on an exact repeat of the same command. ────
SELECT wfad_set_supervisor_count(3);
SELECT wfad_start('s10', :MAJORITY_PAYLOAD::jsonb, '67100000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfad_ids WHERE name='s10'); v_wi UUID; v_actor UUID;
  v_cmd1 UUID := gen_random_uuid(); v_cmd2 UUID := gen_random_uuid();
  r1 RECORD; r2 RECORD;
BEGIN
  SELECT user_id INTO v_actor FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LIMIT 1;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
  SELECT * INTO r1 FROM decide_workflow_work_item(v_wi, 'approve', 1, 0, v_cmd1);
  SELECT * INTO r2 FROM decide_workflow_work_item(v_wi, 'approve', 1, 0, v_cmd1);
  IF r2.replayed IS NOT TRUE OR r1.event_id <> r2.event_id OR r1.event_sequence <> r2.event_sequence
     OR r1.decision_id <> r2.decision_id OR r1.round_state <> r2.round_state THEN
    RAISE EXCEPTION 'nonterminal replay must return an identical result';
  END IF;

  SELECT user_id INTO v_actor FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal OFFSET 1 LIMIT 1;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
  SELECT * INTO r1 FROM decide_workflow_work_item(v_wi, 'approve', 2, 0, v_cmd2);
  SELECT * INTO r2 FROM decide_workflow_work_item(v_wi, 'approve', 2, 0, v_cmd2);
  IF r2.replayed IS NOT TRUE OR r1.event_id <> r2.event_id OR r1.event_sequence <> r2.event_sequence
     OR r1.instance_status <> r2.instance_status OR r1.instance_status <> 'completed' THEN
    RAISE EXCEPTION 'terminal replay must return an identical result matching the original terminal outcome';
  END IF;
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);
END $$;
SELECT wfad_assert_contiguous((SELECT id FROM wfad_ids WHERE name='s10'), 'scenario 10');
INSERT INTO wfad_results VALUES (10,'exact replay with the same command id and identical input returns an identical result for both a nonterminal and a terminal decision, without inserting a second decision or event');

-- ── 11: graph advancement after completion — into a second approval
--     node, then from there into End; each closed round''s decisions
--     never re-open. ────────────────────────────────────────────────
SELECT wfad_set_supervisor_count(3);
SELECT wfad_start('s11', :TWO_HOP_PAYLOAD::jsonb, '67100000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfad_ids WHERE name='s11'); v_wi UUID; v_actor UUID; v_n INTEGER := 0; v_ilock BIGINT := 1;
BEGIN
  FOR v_actor IN SELECT user_id FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LOOP
    EXIT WHEN v_n >= 2;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
    SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
    PERFORM decide_workflow_work_item(v_wi, 'approve', v_ilock, 0, gen_random_uuid());
    v_ilock := v_ilock + 1; v_n := v_n + 1;
  END LOOP;
  IF (SELECT state FROM workflow_instance_steps WHERE instance_id=v_iid AND definition_node_key='review2') <> 'waiting' THEN
    RAISE EXCEPTION 'expected review2 to be entered (waiting) after review1 closes approved';
  END IF;
  IF (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id=v_iid) <> 2 THEN
    RAISE EXCEPTION 'expected a second round opened for review2';
  END IF;

  -- review2's electorate is 2 (rev1, rev2); majority threshold=2, so
  -- both must approve to close the round.
  v_n := 0;
  FOR v_actor IN SELECT user_id FROM workflow_approval_positions p JOIN workflow_instance_steps s ON s.id=p.step_id
                 WHERE p.instance_id=v_iid AND s.definition_node_key='review2' ORDER BY p.ordinal LOOP
    EXIT WHEN v_n >= 2;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
    SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
    PERFORM decide_workflow_work_item(v_wi, 'approve', v_ilock, 0, gen_random_uuid());
    v_ilock := v_ilock + 1; v_n := v_n + 1;
  END LOOP;
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);
  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed'
     OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 'a' THEN
    RAISE EXCEPTION 'expected the second round''s majority approval to complete the instance with outcome a';
  END IF;
  IF EXISTS (SELECT 1 FROM workflow_tokens WHERE instance_id=v_iid AND state <> 'consumed') THEN
    RAISE EXCEPTION 'expected the single token consumed at End';
  END IF;
END $$;
SELECT wfad_assert_contiguous((SELECT id FROM wfad_ids WHERE name='s11'), 'scenario 11');
INSERT INTO wfad_results VALUES (11,'a terminal approval decision invokes the shared graph-advancement helper: closing review1 approved enters review2 and opens its own independent round, and closing review2 approved completes the instance and consumes the token at End');

-- ── 12: comment policy — required (already exercised) and forbidden. ─
SELECT wfad_set_supervisor_count(3);
SELECT wfad_start('s12', :MAJORITY_PAYLOAD::jsonb, '67100000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfad_ids WHERE name='s12'); v_wi UUID; v_actor UUID;
BEGIN
  SELECT user_id INTO v_actor FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LIMIT 1;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
  -- approve is comment-optional; forbidden is not configured here, so
  -- exercise the required-comment path (reject) missing its comment.
  BEGIN
    PERFORM decide_workflow_work_item(v_wi, 'reject', 1, 0, gen_random_uuid(), NULL);
    RAISE EXCEPTION 'expected reject without a comment to fail (comment_policy.reject=required)';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected reject without a comment to fail (comment_policy.reject=required)' THEN RAISE; END IF;
  END;
  IF EXISTS (SELECT 1 FROM workflow_decisions WHERE instance_id=v_iid) THEN
    RAISE EXCEPTION 'a comment-policy failure must not insert a decision row';
  END IF;
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);
END $$;
SELECT wfad_assert_contiguous((SELECT id FROM wfad_ids WHERE name='s12'), 'scenario 12');
INSERT INTO wfad_results VALUES (12,'comment_policy=required is enforced: a reject decision without a comment is rejected before any row is written, atomically');

-- ── 13: abstention disallowed by round configuration. ────────────────
SELECT wfad_set_supervisor_count(3);
SELECT wfad_start('s13', :MAJORITY_NOABSTAIN_PAYLOAD::jsonb, '67100000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfad_ids WHERE name='s13'); v_wi UUID; v_actor UUID;
BEGIN
  SELECT user_id INTO v_actor FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LIMIT 1;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
  BEGIN
    PERFORM decide_workflow_work_item(v_wi, 'abstain', 1, 0, gen_random_uuid());
    RAISE EXCEPTION 'expected abstain to be rejected when allow_abstain=false';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected abstain to be rejected when allow_abstain=false' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);
END $$;
SELECT wfad_assert_contiguous((SELECT id FROM wfad_ids WHERE name='s13'), 'scenario 13');
INSERT INTO wfad_results VALUES (13,'a round configured with allow_abstain=false rejects an abstain decision');

-- ── 14: stale instance lock version rejected. ─────────────────────────
SELECT wfad_set_supervisor_count(3);
SELECT wfad_start('s14', :MAJORITY_PAYLOAD::jsonb, '67100000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfad_ids WHERE name='s14'); v_wi UUID; v_actor UUID;
BEGIN
  SELECT user_id INTO v_actor FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LIMIT 1;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
  BEGIN
    PERFORM decide_workflow_work_item(v_wi, 'approve', 99, 0, gen_random_uuid());
    RAISE EXCEPTION 'expected stale instance lock version to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected stale instance lock version to be rejected' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);
END $$;
SELECT wfad_assert_contiguous((SELECT id FROM wfad_ids WHERE name='s14'), 'scenario 14');
INSERT INTO wfad_results VALUES (14,'a stale expected instance lock version is rejected as a concurrent-change conflict');

-- ── 15: stale work item lock version rejected. ────────────────────────
SELECT wfad_set_supervisor_count(3);
SELECT wfad_start('s15', :MAJORITY_PAYLOAD::jsonb, '67100000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfad_ids WHERE name='s15'); v_wi UUID; v_actor UUID;
BEGIN
  SELECT user_id INTO v_actor FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LIMIT 1;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
  BEGIN
    PERFORM decide_workflow_work_item(v_wi, 'approve', 1, 99, gen_random_uuid());
    RAISE EXCEPTION 'expected stale work item lock version to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected stale work item lock version to be rejected' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);
END $$;
SELECT wfad_assert_contiguous((SELECT id FROM wfad_ids WHERE name='s15'), 'scenario 15');
INSERT INTO wfad_results VALUES (15,'a stale expected work item lock version is rejected as a concurrent-change conflict');

-- ── 16: idempotency key reused with different input is rejected. ─────
SELECT wfad_set_supervisor_count(3);
SELECT wfad_start('s16', :MAJORITY_PAYLOAD::jsonb, '67100000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfad_ids WHERE name='s16'); v_wi UUID; v_actor UUID; v_cmd UUID := gen_random_uuid();
BEGIN
  SELECT user_id INTO v_actor FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LIMIT 1;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
  PERFORM decide_workflow_work_item(v_wi, 'approve', 1, 0, v_cmd);
  BEGIN
    PERFORM decide_workflow_work_item(v_wi, 'reject', 1, 0, v_cmd, 'different input');
    RAISE EXCEPTION 'expected reused idempotency key with different input to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected reused idempotency key with different input to be rejected' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);
END $$;
SELECT wfad_assert_contiguous((SELECT id FROM wfad_ids WHERE name='s16'), 'scenario 16');
INSERT INTO wfad_results VALUES (16,'reusing a command id already recorded against a different decision code is rejected as an idempotency-key conflict, not silently replayed');

-- ── 17: a late decision after round closure fails without any write. ─
SELECT wfad_set_supervisor_count(3);
SELECT wfad_start('s17', :UNANIMOUS_PAYLOAD::jsonb, '67100000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfad_ids WHERE name='s17'); v_wi UUID; v_actor UUID; v_late_actor UUID; v_late_wi UUID; v_before INTEGER;
BEGIN
  SELECT user_id INTO v_actor FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LIMIT 1;
  SELECT user_id INTO v_late_actor FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal OFFSET 1 LIMIT 1;
  SELECT id INTO v_late_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_late_actor;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor)::text, true);
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
  PERFORM decide_workflow_work_item(v_wi, 'reject', 1, 0, gen_random_uuid(), 'closing the round');
  -- round is now completed (rejected, immediate); v_late_wi is cancelled.
  SELECT count(*) INTO v_before FROM workflow_decisions WHERE instance_id=v_iid;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_late_actor)::text, true);
  BEGIN
    PERFORM decide_workflow_work_item(v_late_wi, 'approve', 2, 0, gen_random_uuid());
    RAISE EXCEPTION 'expected a late decision after round closure to fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected a late decision after round closure to fail' THEN RAISE; END IF;
  END;
  IF (SELECT count(*) FROM workflow_decisions WHERE instance_id=v_iid) <> v_before THEN
    RAISE EXCEPTION 'a late decision after closure must not insert telemetry into the immutable decision ledger';
  END IF;
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);
END $$;
SELECT wfad_assert_contiguous((SELECT id FROM wfad_ids WHERE name='s17'), 'scenario 17');
INSERT INTO wfad_results VALUES (17,'a decision command against a work item whose round already closed fails without inserting a row into the immutable decision ledger');

-- ── 18: cross-org actor cannot decide (RLS-adjacent authorization
--     defense-in-depth at the command layer, not only via row grants). ─
SELECT wfad_set_supervisor_count(3);
SELECT wfad_start('s18', :MAJORITY_PAYLOAD::jsonb, '67100000-0001-0000-0000-000000000001');
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfad_ids WHERE name='s18'); v_wi UUID; v_actor UUID;
BEGIN
  SELECT user_id INTO v_actor FROM workflow_approval_positions WHERE instance_id=v_iid ORDER BY ordinal LIMIT 1;
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=v_iid AND assigned_to=v_actor;
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000009"}',true);
  BEGIN
    PERFORM decide_workflow_work_item(v_wi, 'approve', 1, 0, gen_random_uuid());
    RAISE EXCEPTION 'expected a cross-org actor to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected a cross-org actor to be rejected' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claims','{"sub":"67100000-0001-0000-0000-000000000001"}',true);
END $$;
SELECT wfad_assert_contiguous((SELECT id FROM wfad_ids WHERE name='s18'), 'scenario 18');
INSERT INTO wfad_results VALUES (18,'an actor from a different organization who was never offered the work item is rejected');

RESET ROLE;

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfad_results;
  IF v_count <> 18 THEN
    RAISE EXCEPTION 'Workflow approval decision engine behavioral tests FAILED: expected 18, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow approval decision engine behavioral tests PASSED: %/18', v_count;
END $$;

ROLLBACK;
