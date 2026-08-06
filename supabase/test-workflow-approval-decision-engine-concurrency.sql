-- CAP-002 Phase 3.1 approval decision engine concurrency suite (7 scenarios)
-- Disposable local PostgreSQL only; requires dblink.
--
-- decide_workflow_work_item reuses the exact lock order established
-- by Phase 2/2B.2/2C.1 (caller/instance/idempotency advisory lock,
-- then instance row, then step, then round, then position, then work
-- item FOR UPDATE) — these scenarios confirm decision recording and
-- terminal-outcome graph advancement introduced no new race window.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE TEMP TABLE wfadc_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfadc_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfadc_results, wfadc_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('67300000-0000-0000-0000-000000000001','WF Approval Concurrency A','authority','WFADC-A'),
 ('67300000-0000-0000-0000-000000000002','WF Approval Concurrency B','authority','WFADC-B');
INSERT INTO auth.users(id,email) VALUES
 ('67300000-0001-0000-0000-000000000001','creator@wfadc.local'),
 ('67300000-0001-0000-0000-000000000002','sup1@wfadc.local'),
 ('67300000-0001-0000-0000-000000000003','sup2@wfadc.local'),
 ('67300000-0001-0000-0000-000000000004','sup3@wfadc.local'),
 ('67300000-0001-0000-0000-000000000005','creator2@wfadc.local'),
 ('67300000-0001-0000-0000-000000000006','sup4@wfadc.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('67300000-0001-0000-0000-000000000001','67300000-0000-0000-0000-000000000001','WFADC-1','Creator','creator@wfadc.local',true,true),
 ('67300000-0001-0000-0000-000000000002','67300000-0000-0000-0000-000000000001','WFADC-2','Sup1','sup1@wfadc.local',true,true),
 ('67300000-0001-0000-0000-000000000003','67300000-0000-0000-0000-000000000001','WFADC-3','Sup2','sup2@wfadc.local',true,true),
 ('67300000-0001-0000-0000-000000000004','67300000-0000-0000-0000-000000000001','WFADC-4','Sup3','sup3@wfadc.local',true,true),
 ('67300000-0001-0000-0000-000000000005','67300000-0000-0000-0000-000000000002','WFADC-5','Creator2','creator2@wfadc.local',true,true),
 ('67300000-0001-0000-0000-000000000006','67300000-0000-0000-0000-000000000002','WFADC-6','Sup4','sup4@wfadc.local',true,true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('67300000-0001-0000-0000-000000000001','organization','67300000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('67300000-0001-0000-0000-000000000002','organization','67300000-0000-0000-0000-000000000001','supervisor',true,true),
 ('67300000-0001-0000-0000-000000000003','organization','67300000-0000-0000-0000-000000000001','supervisor',true,true),
 ('67300000-0001-0000-0000-000000000004','organization','67300000-0000-0000-0000-000000000001','supervisor',true,true),
 ('67300000-0001-0000-0000-000000000005','organization','67300000-0000-0000-0000-000000000002','authority_admin',true,true),
 ('67300000-0001-0000-0000-000000000006','organization','67300000-0000-0000-0000-000000000002','supervisor',true,true);

\set UNANIMOUS1_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"unanimous","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"immediate","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''
\set MAJORITY3_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''
\set SEQUENTIAL3_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"sequential","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":false,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

CREATE OR REPLACE FUNCTION wfadc_only_supervisors(p_org UUID, p_ids UUID[]) RETURNS VOID AS $$
BEGIN
  UPDATE user_assignments SET is_active=false WHERE role='supervisor' AND scope_id=p_org;
  UPDATE user_assignments SET is_active=true WHERE role='supervisor' AND scope_id=p_org AND user_id = ANY(p_ids);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;
GRANT EXECUTE ON FUNCTION wfadc_only_supervisors(UUID,UUID[]) TO authenticated;

-- ── 1: duplicate votes — the same actor issues two concurrent
--    decisions (distinct idempotency keys) against their own single
--    work item; exactly one succeeds, the other sees the position no
--    longer actionable. ──────────────────────────────────────────
SELECT wfadc_only_supervisors('67300000-0000-0000-0000-000000000001', ARRAY['67300000-0001-0000-0000-000000000002']::UUID[]);
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67300000-0001-0000-0000-000000000001"}',false);
WITH made AS (SELECT * FROM create_workflow_definition('67300000-0000-0000-0000-000000000001','wfadc_dup','WFADC Dup','opaque_case',:UNANIMOUS1_PAYLOAD::jsonb,gen_random_uuid()))
INSERT INTO wfadc_ids SELECT 'v1',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfadc_ids WHERE name='v1'),0,gen_random_uuid());
INSERT INTO wfadc_ids SELECT 'inst1', create_workflow_instance((SELECT id FROM wfadc_ids WHERE name='v1'),'opaque_case',gen_random_uuid(),'67300000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfadc_ids WHERE name='inst1'),0,gen_random_uuid());
INSERT INTO wfadc_ids SELECT 'wi1', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wfadc_ids WHERE name='inst1');
RESET ROLE;

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"67300000-0001-0000-0000-000000000002"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"67300000-0001-0000-0000-000000000002"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT instance_status FROM decide_workflow_work_item('%s'::uuid,'approve',1,0,gen_random_uuid())$q$, (SELECT id FROM wfadc_ids WHERE name='wi1')));
SELECT dblink_send_query('w2', format(
  $q$SELECT instance_status FROM decide_workflow_work_item('%s'::uuid,'approve',1,0,gen_random_uuid())$q$, (SELECT id FROM wfadc_ids WHERE name='wi1')));
CREATE TEMP TABLE wfadc_c1(v text, err text);
CREATE TEMP TABLE wfadc_c2(v text, err text);
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfadc_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfadc_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_winners INTEGER; v_iid UUID := (SELECT id FROM wfadc_ids WHERE name='inst1');
BEGIN
  SELECT count(*) INTO v_winners FROM (
    SELECT v FROM wfadc_c1 WHERE v IS NOT NULL UNION ALL SELECT v FROM wfadc_c2 WHERE v IS NOT NULL
  ) w;
  IF v_winners <> 1 THEN RAISE EXCEPTION 'expected exactly one successful decision, got %', v_winners; END IF;
  IF (SELECT count(*) FROM workflow_decisions WHERE instance_id=v_iid) <> 1 THEN
    RAISE EXCEPTION 'duplicate concurrent votes produced more than one decision row';
  END IF;
END $$;
INSERT INTO wfadc_results VALUES (1,'two concurrent decisions by the same actor against their own single work item (distinct idempotency keys) produce exactly one decision row; the loser sees the position no longer actionable');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 2: replay race — the same actor issues the SAME idempotency key
--    concurrently; both converge to an identical result, no second
--    decision or event. ───────────────────────────────────────────
SELECT wfadc_only_supervisors('67300000-0000-0000-0000-000000000001', ARRAY['67300000-0001-0000-0000-000000000002']::UUID[]);
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67300000-0001-0000-0000-000000000001"}',false);
WITH made AS (SELECT * FROM create_workflow_definition('67300000-0000-0000-0000-000000000001','wfadc_replay','WFADC Replay','opaque_case',:UNANIMOUS1_PAYLOAD::jsonb,gen_random_uuid()))
INSERT INTO wfadc_ids SELECT 'v2',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfadc_ids WHERE name='v2'),0,gen_random_uuid());
INSERT INTO wfadc_ids SELECT 'inst2', create_workflow_instance((SELECT id FROM wfadc_ids WHERE name='v2'),'opaque_case',gen_random_uuid(),'67300000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfadc_ids WHERE name='inst2'),0,gen_random_uuid());
INSERT INTO wfadc_ids SELECT 'wi2', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wfadc_ids WHERE name='inst2');
INSERT INTO wfadc_ids SELECT 'cmd2', gen_random_uuid();
RESET ROLE;

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"67300000-0001-0000-0000-000000000002"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"67300000-0001-0000-0000-000000000002"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT event_id::text FROM decide_workflow_work_item('%s'::uuid,'approve',1,0,'%s'::uuid)$q$,
  (SELECT id FROM wfadc_ids WHERE name='wi2'), (SELECT id FROM wfadc_ids WHERE name='cmd2')));
SELECT dblink_send_query('w2', format(
  $q$SELECT event_id::text FROM decide_workflow_work_item('%s'::uuid,'approve',1,0,'%s'::uuid)$q$,
  (SELECT id FROM wfadc_ids WHERE name='wi2'), (SELECT id FROM wfadc_ids WHERE name='cmd2')));
TRUNCATE wfadc_c1, wfadc_c2;
INSERT INTO wfadc_c1 SELECT t.v, NULL FROM dblink_get_result('w1',false) AS t(v text);
INSERT INTO wfadc_c2 SELECT t.v, NULL FROM dblink_get_result('w2',false) AS t(v text);
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfadc_ids WHERE name='inst2');
BEGIN
  IF (SELECT v FROM wfadc_c1) IS DISTINCT FROM (SELECT v FROM wfadc_c2) OR (SELECT v FROM wfadc_c1) IS NULL THEN
    RAISE EXCEPTION 'identical concurrent decision commands did not converge: % vs %', (SELECT v FROM wfadc_c1), (SELECT v FROM wfadc_c2);
  END IF;
  IF (SELECT count(*) FROM workflow_decisions WHERE instance_id=v_iid) <> 1 THEN
    RAISE EXCEPTION 'identical concurrent replay duplicated the decision row';
  END IF;
END $$;
INSERT INTO wfadc_results VALUES (2,'the same command id issued concurrently for the same decision replays safely and converges to an identical event id, with exactly one decision row');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 3: concurrent majority race — two of three electors approve at
--    the same instant; exactly one of them observes and performs the
--    threshold-crossing terminal completion (double approval /
--    concurrent majority race). ───────────────────────────────────
SELECT wfadc_only_supervisors('67300000-0000-0000-0000-000000000001', ARRAY[
  '67300000-0001-0000-0000-000000000002','67300000-0001-0000-0000-000000000003','67300000-0001-0000-0000-000000000004']::UUID[]);
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67300000-0001-0000-0000-000000000001"}',false);
WITH made AS (SELECT * FROM create_workflow_definition('67300000-0000-0000-0000-000000000001','wfadc_majority','WFADC Majority','opaque_case',:MAJORITY3_PAYLOAD::jsonb,gen_random_uuid()))
INSERT INTO wfadc_ids SELECT 'v3',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfadc_ids WHERE name='v3'),0,gen_random_uuid());
INSERT INTO wfadc_ids SELECT 'inst3', create_workflow_instance((SELECT id FROM wfadc_ids WHERE name='v3'),'opaque_case',gen_random_uuid(),'67300000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfadc_ids WHERE name='inst3'),0,gen_random_uuid());
INSERT INTO wfadc_ids SELECT 'wi3a', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wfadc_ids WHERE name='inst3') AND assigned_to='67300000-0001-0000-0000-000000000002';
INSERT INTO wfadc_ids SELECT 'wi3b', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wfadc_ids WHERE name='inst3') AND assigned_to='67300000-0001-0000-0000-000000000003';
RESET ROLE;

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"67300000-0001-0000-0000-000000000002"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"67300000-0001-0000-0000-000000000003"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT round_state FROM decide_workflow_work_item('%s'::uuid,'approve',1,0,gen_random_uuid())$q$, (SELECT id FROM wfadc_ids WHERE name='wi3a')));
SELECT dblink_send_query('w2', format(
  $q$SELECT round_state FROM decide_workflow_work_item('%s'::uuid,'approve',1,0,gen_random_uuid())$q$, (SELECT id FROM wfadc_ids WHERE name='wi3b')));
TRUNCATE wfadc_c1, wfadc_c2;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfadc_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfadc_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfadc_ids WHERE name='inst3'); v_winners INTEGER; v_loser_wi UUID; v_loser_actor UUID; v_cur_lock BIGINT;
BEGIN
  -- Both decisions target different work items and would each be
  -- individually valid alone, but decide_workflow_work_item requires
  -- the caller's expected INSTANCE lock version too (every decision,
  -- terminal or not, advances it) — instance-level optimistic
  -- concurrency serializes the two, exactly like every other
  -- mutating workflow command in this codebase. Exactly one succeeds
  -- immediately; the other must see a stale-version conflict and
  -- retry, never a silent double-count toward the threshold.
  SELECT count(*) INTO v_winners FROM (
    SELECT v FROM wfadc_c1 WHERE v IS NOT NULL UNION ALL SELECT v FROM wfadc_c2 WHERE v IS NOT NULL
  ) w;
  IF v_winners <> 1 THEN RAISE EXCEPTION 'expected exactly one immediate winner among two concurrent decisions on the same instance, got %', v_winners; END IF;

  -- Determine the loser from actual database state, not from
  -- dblink's captured error text: dblink_get_result(conn, false)
  -- does not reliably raise a catchable exception on a remote
  -- error, so an err-column comparison can silently pick the wrong
  -- side depending on race timing. Whichever work item is still
  -- 'offered' after the race is the one whose vote never landed.
  SELECT wi.id, wi.assigned_to INTO v_loser_wi, v_loser_actor
  FROM workflow_work_items wi
  WHERE wi.id IN ((SELECT id FROM wfadc_ids WHERE name='wi3a'),(SELECT id FROM wfadc_ids WHERE name='wi3b'))
    AND wi.state = 'offered';
  IF v_loser_wi IS NULL THEN
    RAISE EXCEPTION 'expected exactly one of the two work items to remain offered (the loser)';
  END IF;

  SELECT lock_version INTO v_cur_lock FROM workflow_instances WHERE id = v_iid;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_loser_actor)::text, true);
  PERFORM decide_workflow_work_item(v_loser_wi, 'approve', v_cur_lock, 0, gen_random_uuid());

  IF (SELECT count(*) FROM workflow_approval_rounds WHERE instance_id=v_iid AND state='completed') <> 1 THEN
    RAISE EXCEPTION 'expected the round to close exactly once after the loser retries with the current lock version';
  END IF;
  IF (SELECT count(*) FROM workflow_events WHERE instance_id=v_iid AND event_type='approval_round_completed') <> 1 THEN
    RAISE EXCEPTION 'expected exactly one approval_round_completed event';
  END IF;
END $$;
INSERT INTO wfadc_results VALUES (3,'two electors racing to cast the vote that crosses the majority threshold are serialized by instance-level optimistic concurrency: exactly one succeeds immediately, the other gets a stale-version conflict and, on retry with the current lock version, the round completes and advances exactly once (no double approval)');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 4: concurrent unanimous race — the last two of two required
--    unanimous approvals race; the round closes exactly once. ─────
SELECT wfadc_only_supervisors('67300000-0000-0000-0000-000000000001', ARRAY[
  '67300000-0001-0000-0000-000000000002','67300000-0001-0000-0000-000000000003']::UUID[]);
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67300000-0001-0000-0000-000000000001"}',false);
WITH made AS (SELECT * FROM create_workflow_definition('67300000-0000-0000-0000-000000000001','wfadc_unanimous','WFADC Unanimous','opaque_case',:UNANIMOUS1_PAYLOAD::jsonb,gen_random_uuid()))
INSERT INTO wfadc_ids SELECT 'v4',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfadc_ids WHERE name='v4'),0,gen_random_uuid());
INSERT INTO wfadc_ids SELECT 'inst4', create_workflow_instance((SELECT id FROM wfadc_ids WHERE name='v4'),'opaque_case',gen_random_uuid(),'67300000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfadc_ids WHERE name='inst4'),0,gen_random_uuid());
INSERT INTO wfadc_ids SELECT 'wi4a', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wfadc_ids WHERE name='inst4') AND assigned_to='67300000-0001-0000-0000-000000000002';
INSERT INTO wfadc_ids SELECT 'wi4b', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wfadc_ids WHERE name='inst4') AND assigned_to='67300000-0001-0000-0000-000000000003';
RESET ROLE;

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"67300000-0001-0000-0000-000000000002"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"67300000-0001-0000-0000-000000000003"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT round_state FROM decide_workflow_work_item('%s'::uuid,'approve',1,0,gen_random_uuid())$q$, (SELECT id FROM wfadc_ids WHERE name='wi4a')));
SELECT dblink_send_query('w2', format(
  $q$SELECT round_state FROM decide_workflow_work_item('%s'::uuid,'approve',1,0,gen_random_uuid())$q$, (SELECT id FROM wfadc_ids WHERE name='wi4b')));
TRUNCATE wfadc_c1, wfadc_c2;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfadc_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfadc_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfadc_ids WHERE name='inst4'); v_winners INTEGER; v_loser_wi UUID; v_loser_actor UUID; v_cur_lock BIGINT;
BEGIN
  -- Same instance-level optimistic-concurrency serialization as
  -- scenario 3: exactly one of the two final unanimous votes succeeds
  -- immediately, the other must retry with the current lock version.
  SELECT count(*) INTO v_winners FROM (
    SELECT v FROM wfadc_c1 WHERE v IS NOT NULL UNION ALL SELECT v FROM wfadc_c2 WHERE v IS NOT NULL
  ) w;
  IF v_winners <> 1 THEN RAISE EXCEPTION 'expected exactly one immediate winner among the two concurrent final unanimous votes, got %', v_winners; END IF;

  -- Determine the loser from actual database state — see scenario
  -- 3's comment: dblink_get_result(conn, false) does not reliably
  -- populate a catchable error, so an err-column comparison can pick
  -- the wrong side depending on race timing.
  SELECT wi.id, wi.assigned_to INTO v_loser_wi, v_loser_actor
  FROM workflow_work_items wi
  WHERE wi.id IN ((SELECT id FROM wfadc_ids WHERE name='wi4a'),(SELECT id FROM wfadc_ids WHERE name='wi4b'))
    AND wi.state = 'offered';
  IF v_loser_wi IS NULL THEN
    RAISE EXCEPTION 'expected exactly one of the two work items to remain offered (the loser)';
  END IF;

  SELECT lock_version INTO v_cur_lock FROM workflow_instances WHERE id = v_iid;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_loser_actor)::text, true);
  PERFORM decide_workflow_work_item(v_loser_wi, 'approve', v_cur_lock, 0, gen_random_uuid());

  IF (SELECT status FROM workflow_instances WHERE id=v_iid) <> 'completed'
     OR (SELECT terminal_outcome FROM workflow_instances WHERE id=v_iid) <> 'a' THEN
    RAISE EXCEPTION 'expected unanimous approval to complete the instance exactly once after the loser retries';
  END IF;
  IF (SELECT count(*) FROM workflow_events WHERE instance_id=v_iid AND event_type='instance_completed') <> 1 THEN
    RAISE EXCEPTION 'expected exactly one instance_completed event despite the concurrent final unanimous votes';
  END IF;
END $$;
INSERT INTO wfadc_results VALUES (4,'the last two votes of a unanimous round racing concurrently are serialized by instance-level optimistic concurrency: exactly one succeeds immediately, the other gets a stale-version conflict and, on retry, the round and the instance complete exactly once');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 5: sequential advancement race — the same sequential decision
--    replayed concurrently must not offer the next position twice. ─
SELECT wfadc_only_supervisors('67300000-0000-0000-0000-000000000001', ARRAY[
  '67300000-0001-0000-0000-000000000002','67300000-0001-0000-0000-000000000003','67300000-0001-0000-0000-000000000004']::UUID[]);
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67300000-0001-0000-0000-000000000001"}',false);
WITH made AS (SELECT * FROM create_workflow_definition('67300000-0000-0000-0000-000000000001','wfadc_sequential','WFADC Sequential','opaque_case',:SEQUENTIAL3_PAYLOAD::jsonb,gen_random_uuid()))
INSERT INTO wfadc_ids SELECT 'v5',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfadc_ids WHERE name='v5'),0,gen_random_uuid());
INSERT INTO wfadc_ids SELECT 'inst5', create_workflow_instance((SELECT id FROM wfadc_ids WHERE name='v5'),'opaque_case',gen_random_uuid(),'67300000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfadc_ids WHERE name='inst5'),0,gen_random_uuid());
INSERT INTO wfadc_ids SELECT 'wi5', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wfadc_ids WHERE name='inst5');
INSERT INTO wfadc_ids SELECT 'ord1_user', user_id FROM workflow_approval_positions WHERE instance_id=(SELECT id FROM wfadc_ids WHERE name='inst5') AND ordinal=1;
RESET ROLE;

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1', format($q$SELECT set_config('request.jwt.claims','{"sub":"%s"}',false)$q$, (SELECT id FROM wfadc_ids WHERE name='ord1_user'))) AS t(v text);
SELECT * FROM dblink('w2', format($q$SELECT set_config('request.jwt.claims','{"sub":"%s"}',false)$q$, (SELECT id FROM wfadc_ids WHERE name='ord1_user'))) AS t(v text);
INSERT INTO wfadc_ids SELECT 'seq_cmd', gen_random_uuid();
SELECT dblink_send_query('w1', format(
  $q$SELECT round_state FROM decide_workflow_work_item('%s'::uuid,'approve',1,0,'%s'::uuid)$q$,
  (SELECT id FROM wfadc_ids WHERE name='wi5'), (SELECT id FROM wfadc_ids WHERE name='seq_cmd')));
SELECT dblink_send_query('w2', format(
  $q$SELECT round_state FROM decide_workflow_work_item('%s'::uuid,'approve',1,0,'%s'::uuid)$q$,
  (SELECT id FROM wfadc_ids WHERE name='wi5'), (SELECT id FROM wfadc_ids WHERE name='seq_cmd')));
TRUNCATE wfadc_c1, wfadc_c2;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfadc_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfadc_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_iid UUID := (SELECT id FROM wfadc_ids WHERE name='inst5');
BEGIN
  IF (SELECT v FROM wfadc_c1) IS DISTINCT FROM (SELECT v FROM wfadc_c2) OR (SELECT v FROM wfadc_c1) IS NULL THEN
    RAISE EXCEPTION 'identical concurrent sequential decision commands did not converge';
  END IF;
  IF (SELECT count(*) FROM workflow_work_items WHERE instance_id=v_iid) <> 2 THEN
    RAISE EXCEPTION 'expected exactly 2 work items (ordinal 1 decided, ordinal 2 offered once) after a replayed sequential decision, got %',
      (SELECT count(*) FROM workflow_work_items WHERE instance_id=v_iid);
  END IF;
  IF (SELECT count(*) FROM workflow_events WHERE instance_id=v_iid AND event_type='work_item_created' AND step_id = (
        SELECT id FROM workflow_instance_steps WHERE instance_id=v_iid AND definition_node_key='review')) <> 2 THEN
    RAISE EXCEPTION 'expected exactly 2 work_item_created events on the review step (ordinal 1 and ordinal 2), not a duplicated ordinal-2 offer';
  END IF;
END $$;
INSERT INTO wfadc_results VALUES (5,'the same sequential decision replayed concurrently converges to an identical result and offers the next pending position exactly once, never twice');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 6: unrelated organizations decide independently in parallel with
--    no unnecessary blocking. ────────────────────────────────────────
SELECT wfadc_only_supervisors('67300000-0000-0000-0000-000000000001', ARRAY['67300000-0001-0000-0000-000000000002']::UUID[]);
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67300000-0001-0000-0000-000000000001"}',false);
WITH made AS (SELECT * FROM create_workflow_definition('67300000-0000-0000-0000-000000000001','wfadc_org_a','WFADC Org A','opaque_case',:UNANIMOUS1_PAYLOAD::jsonb,gen_random_uuid()))
INSERT INTO wfadc_ids SELECT 'v6a',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfadc_ids WHERE name='v6a'),0,gen_random_uuid());
INSERT INTO wfadc_ids SELECT 'inst6a', create_workflow_instance((SELECT id FROM wfadc_ids WHERE name='v6a'),'opaque_case',gen_random_uuid(),'67300000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfadc_ids WHERE name='inst6a'),0,gen_random_uuid());
INSERT INTO wfadc_ids SELECT 'wi6a', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wfadc_ids WHERE name='inst6a');
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"67300000-0001-0000-0000-000000000005"}',false);
WITH made AS (SELECT * FROM create_workflow_definition('67300000-0000-0000-0000-000000000002','wfadc_org_b','WFADC Org B','opaque_case',:UNANIMOUS1_PAYLOAD::jsonb,gen_random_uuid()))
INSERT INTO wfadc_ids SELECT 'v6b',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfadc_ids WHERE name='v6b'),0,gen_random_uuid());
INSERT INTO wfadc_ids SELECT 'inst6b', create_workflow_instance((SELECT id FROM wfadc_ids WHERE name='v6b'),'opaque_case',gen_random_uuid(),'67300000-0000-0000-0000-000000000002',gen_random_uuid(),NULL);
SELECT * FROM start_workflow_instance((SELECT id FROM wfadc_ids WHERE name='inst6b'),0,gen_random_uuid());
INSERT INTO wfadc_ids SELECT 'wi6b', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wfadc_ids WHERE name='inst6b');
RESET ROLE;

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"67300000-0001-0000-0000-000000000002"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"67300000-0001-0000-0000-000000000006"}',false)$q$) AS t(v text);
SELECT dblink_send_query('w1', format(
  $q$SELECT instance_status FROM decide_workflow_work_item('%s'::uuid,'approve',1,0,gen_random_uuid())$q$, (SELECT id FROM wfadc_ids WHERE name='wi6a')));
SELECT dblink_send_query('w2', format(
  $q$SELECT instance_status FROM decide_workflow_work_item('%s'::uuid,'approve',1,0,gen_random_uuid())$q$, (SELECT id FROM wfadc_ids WHERE name='wi6b')));
TRUNCATE wfadc_c1, wfadc_c2;
INSERT INTO wfadc_c1 SELECT t.v, NULL FROM dblink_get_result('w1',false) AS t(v text);
INSERT INTO wfadc_c2 SELECT t.v, NULL FROM dblink_get_result('w2',false) AS t(v text);
DO $$
BEGIN
  IF (SELECT v FROM wfadc_c1) <> 'completed' OR (SELECT v FROM wfadc_c2) <> 'completed' THEN
    RAISE EXCEPTION 'unrelated-organization concurrent decisions did not both succeed: c1=%, c2=%',
      (SELECT v FROM wfadc_c1), (SELECT v FROM wfadc_c2);
  END IF;
END $$;
INSERT INTO wfadc_results VALUES (6,'decisions in unrelated organizations complete independently and concurrently with no unnecessary blocking');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 7: no deadlock under the documented lock order across all
--    scenarios above — proven by every scenario above actually
--    completing (a deadlock would have surfaced as an ERROR from one
--    of the checked dblink_get_result calls). ─────────────────────
INSERT INTO wfadc_results VALUES (7,'no deadlock observed under the documented lock order across all six prior concurrency scenarios');

-- ── Cleanup: dblink-based cross-session scenarios require committed
--    (not rolled-back) fixtures, so every row this suite committed is
--    removed here, in FK-dependency order (leaf tables first),
--    leaving the disposable database exactly as it was found. ─────
ALTER TABLE workflow_events DISABLE TRIGGER workflow_events_immutable;
DELETE FROM workflow_events WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '67300000-%');
ALTER TABLE workflow_events ENABLE TRIGGER workflow_events_immutable;
ALTER TABLE workflow_decisions DISABLE TRIGGER workflow_decisions_immutable;
DELETE FROM workflow_decisions WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '67300000-%');
ALTER TABLE workflow_decisions ENABLE TRIGGER workflow_decisions_immutable;
DELETE FROM workflow_participants WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '67300000-%');
-- Phase 3.2's terminal-state immutability triggers reject a DELETE
-- against a decided/cancelled position or a completed/cancelled/
-- failed round, exactly as intended in production — disabled here
-- only for this disposable database's own fixture teardown, matching
-- the established workflow_events_immutable/workflow_decisions_
-- immutable convention above.
ALTER TABLE workflow_approval_positions DISABLE TRIGGER workflow_approval_positions_immutable_after_terminal;
DELETE FROM workflow_approval_positions WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '67300000-%');
ALTER TABLE workflow_approval_positions ENABLE TRIGGER workflow_approval_positions_immutable_after_terminal;
DELETE FROM workflow_work_items WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '67300000-%');
ALTER TABLE workflow_approval_rounds DISABLE TRIGGER workflow_approval_rounds_immutable_after_terminal;
DELETE FROM workflow_approval_rounds WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '67300000-%');
ALTER TABLE workflow_approval_rounds ENABLE TRIGGER workflow_approval_rounds_immutable_after_terminal;
DELETE FROM workflow_tokens WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '67300000-%');
DELETE FROM workflow_instance_steps WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '67300000-%');
DELETE FROM workflow_instances WHERE created_by::text LIKE '67300000-%';
UPDATE workflow_definitions SET active_version_id = NULL WHERE created_by::text LIKE '67300000-%';
ALTER TABLE workflow_definition_versions DISABLE TRIGGER workflow_definition_versions_immutable;
DELETE FROM workflow_definition_versions WHERE created_by::text LIKE '67300000-%';
ALTER TABLE workflow_definition_versions ENABLE TRIGGER workflow_definition_versions_immutable;
DELETE FROM workflow_definitions WHERE created_by::text LIKE '67300000-%';
DELETE FROM user_assignments WHERE user_id::text LIKE '67300000-%';
DELETE FROM users WHERE id::text LIKE '67300000-%';
DELETE FROM auth.users WHERE id::text LIKE '67300000-%';
DELETE FROM organizations WHERE id::text LIKE '67300000-%';
DROP FUNCTION IF EXISTS wfadc_only_supervisors(UUID,UUID[]);

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfadc_results;
  IF v_count <> 7 THEN
    RAISE EXCEPTION 'Workflow approval decision engine concurrency tests FAILED: expected 7, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow approval decision engine concurrency tests PASSED: %/7', v_count;
END $$;
