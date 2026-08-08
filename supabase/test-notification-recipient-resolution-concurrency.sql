-- CAP-003 Phase 1.2 notification recipient resolution -- concurrency
-- suite (8 race scenarios). Disposable local PostgreSQL only;
-- requires dblink. Mirrors the exact dblink-based
-- genuinely-independent-session pattern every other CAP-002/CAP-003
-- concurrency suite in this repository already establishes.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;

CREATE TEMP TABLE wf82c_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf82c_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf82c_results, wf82c_ids TO authenticated, service_role;

INSERT INTO organizations(id,name,type,code) VALUES ('82200000-0000-0000-0000-000000000001','WF82C Org','authority','WF82C');
INSERT INTO divisions(id, org_id, name) VALUES ('82200000-0004-0000-0000-000000000001','82200000-0000-0000-0000-000000000001','WF82C Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES ('82200000-0002-0000-0000-000000000001','82200000-0000-0000-0000-000000000001','82200000-0004-0000-0000-000000000001','WF82C Sec','SC1');
INSERT INTO auth.users(id,email) VALUES
 ('82200000-0001-0000-0000-000000000001','admin@wf82ct.local'),
 ('82200000-0001-0000-0000-000000000002','candidate@wf82ct.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('82200000-0001-0000-0000-000000000001','82200000-0000-0000-0000-000000000001','WF82C-1','Admin','admin@wf82ct.local',true),
 ('82200000-0001-0000-0000-000000000002','82200000-0000-0000-0000-000000000001','WF82C-2','Candidate','candidate@wf82ct.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('82200000-0001-0000-0000-000000000001','organization','82200000-0000-0000-0000-000000000001','authority_admin',true,true);

CREATE OR REPLACE FUNCTION wf82c_connect_worker(p_conn TEXT) RETURNS VOID AS $$
BEGIN
  PERFORM dblink_connect(p_conn, 'host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
  PERFORM dblink_exec(p_conn, 'SET ROLE service_role');
END;
$$ LANGUAGE plpgsql;

-- Connects as authenticated, impersonating an admin -- needed for
-- scenario 4's users.is_active toggle, which trigger_protect_
-- privileged_user_columns() (rls.sql) gates on is_admin() (an
-- auth.uid()-bound check that service_role alone does not satisfy,
-- since that role sets no JWT claims of its own).
CREATE OR REPLACE FUNCTION wf82c_connect_authenticated(p_conn TEXT, p_sub TEXT) RETURNS VOID AS $$
DECLARE v_dummy TEXT;
BEGIN
  PERFORM dblink_connect(p_conn, 'host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
  PERFORM dblink_exec(p_conn, 'SET ROLE authenticated');
  SELECT t.v INTO v_dummy FROM dblink(p_conn, format($f$SELECT set_config('request.jwt.claims','{"sub":"%s"}',false)$f$, p_sub)) AS t(v TEXT);
END;
$$ LANGUAGE plpgsql;

-- Real workflow instance (create_workflow_instance auto-seeds a
-- workflow_participants row for the creator).
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"82200000-0001-0000-0000-000000000001"}',false);
\set ORG_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}}],"edges":[{"source":"start","target":"a_end","outcome":"started","priority":0,"default":false}]}\''
WITH made AS (SELECT * FROM create_workflow_definition(
  '82200000-0000-0000-0000-000000000001','wf82c_org','WF82C Flow','opaque_case', :ORG_PAYLOAD::jsonb, gen_random_uuid()))
SELECT version_id AS v INTO TEMP wf82c_def FROM made;
SELECT publish_workflow_definition_version((SELECT v FROM wf82c_def),0,gen_random_uuid());
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT v FROM wf82c_def),'opaque_case',gen_random_uuid(),
  '82200000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
SELECT create_workflow_instance AS id INTO TEMP wf82c_i1 FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf82c_i1),0,gen_random_uuid());
GRANT SELECT ON wf82c_i1 TO service_role, authenticated;
RESET ROLE;

DO $$
DECLARE v_instance_id UUID;
BEGIN
  SELECT id INTO v_instance_id FROM wf82c_i1;
  INSERT INTO wf82c_ids VALUES ('instance', v_instance_id);
  -- Candidate: a genuine, active participant -- the recipient every
  -- race below targets.
  INSERT INTO workflow_participants (instance_id, user_id, participant_role, authority_source, created_by)
  VALUES (v_instance_id, '82200000-0001-0000-0000-000000000002', 'viewer', 'wf82c-test-fixture', '82200000-0001-0000-0000-000000000001');
END $$;

-- ── 1: two resolvers resolving same intent ──
SET ROLE service_role;
DO $$
DECLARE v_outbox_id UUID; v_intent_id UUID;
BEGIN
  v_outbox_id := platform_enqueue_outbox_event(
    'workflow.wf82c_race1.v1','workflow','workflow_instance',(SELECT id FROM wf82c_ids WHERE name='instance'),
    '82200000-0000-0000-0000-000000000001'::UUID,NULL,gen_random_uuid(),NULL,now(),'{}'::JSONB,gen_random_uuid());
  v_intent_id := create_notification_intent(
    v_outbox_id,'workflow.wf82c_race1.v1','x.title','{}'::JSONB,'normal',
    'workflow_participants',NULL,NULL,NULL,(SELECT id FROM wf82c_ids WHERE name='instance'),NULL);
  INSERT INTO wf82c_ids VALUES ('race1_intent', v_intent_id);
  INSERT INTO wf82c_ids VALUES ('race1_outbox', v_outbox_id);
END $$;
RESET ROLE;
DO $$
DECLARE v_intent_id UUID; v_r1 TEXT; v_r2 TEXT; v_count INTEGER;
BEGIN
  SELECT id INTO v_intent_id FROM wf82c_ids WHERE name = 'race1_intent';
  PERFORM wf82c_connect_worker('c1race1');
  PERFORM wf82c_connect_worker('c2race1');

  PERFORM dblink_send_query('c1race1', format($q$SELECT status FROM resolve_notification_intent('%s'::uuid)$q$, v_intent_id));
  PERFORM dblink_send_query('c2race1', format($q$SELECT status FROM resolve_notification_intent('%s'::uuid)$q$, v_intent_id));

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1race1', false) AS t(v TEXT);
  PERFORM dblink_get_result('c1race1', false);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2race1', false) AS t(v TEXT);
  PERFORM dblink_get_result('c2race1', false);
  PERFORM dblink_disconnect('c1race1');
  PERFORM dblink_disconnect('c2race1');

  IF v_r1 IS NULL OR v_r2 IS NULL THEN RAISE EXCEPTION 'both racing resolve calls must succeed, got r1=%, r2=%', v_r1, v_r2; END IF;
  IF v_r1 <> v_r2 THEN RAISE EXCEPTION 'both racing resolve calls must report the same final status, got % and %', v_r1, v_r2; END IF;

  SELECT count(*) INTO v_count FROM user_notifications
    WHERE outbox_event_id = (SELECT id FROM wf82c_ids WHERE name='race1_outbox') AND recipient_user_id = '82200000-0001-0000-0000-000000000001';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 notification after two concurrent resolvers raced the same intent, got %', v_count; END IF;
END $$;
INSERT INTO wf82c_results VALUES (1,'Two concurrent sessions racing to resolve the SAME intent both succeed, report the same final status, and produce exactly one durable notification per participant -- the intent row''s own FOR UPDATE lock serializes the race safely');

-- ── 2: duplicate intent creation race ──
SET ROLE service_role;
DO $$
DECLARE v_outbox_id UUID;
BEGIN
  v_outbox_id := platform_enqueue_outbox_event(
    'workflow.wf82c_race2.v1','workflow','workflow_instance',(SELECT id FROM wf82c_ids WHERE name='instance'),
    '82200000-0000-0000-0000-000000000001'::UUID,NULL,gen_random_uuid(),NULL,now(),'{}'::JSONB,gen_random_uuid());
  INSERT INTO wf82c_ids VALUES ('race2_outbox', v_outbox_id);
END $$;
RESET ROLE;
DO $$
DECLARE v_outbox_id UUID; v_r1 TEXT; v_r2 TEXT; v_count INTEGER;
BEGIN
  SELECT id INTO v_outbox_id FROM wf82c_ids WHERE name = 'race2_outbox';
  PERFORM wf82c_connect_worker('c1race2');
  PERFORM wf82c_connect_worker('c2race2');

  PERFORM dblink_send_query('c1race2', format(
    $q$SELECT create_notification_intent('%s'::uuid,'workflow.wf82c_race2.v1','x.title','{}'::jsonb,'normal','workflow_participants',NULL,NULL,NULL,'%s'::uuid,NULL)$q$,
    v_outbox_id, (SELECT id FROM wf82c_ids WHERE name='instance')));
  PERFORM dblink_send_query('c2race2', format(
    $q$SELECT create_notification_intent('%s'::uuid,'workflow.wf82c_race2.v1','x.title','{}'::jsonb,'normal','workflow_participants',NULL,NULL,NULL,'%s'::uuid,NULL)$q$,
    v_outbox_id, (SELECT id FROM wf82c_ids WHERE name='instance')));

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1race2', false) AS t(v TEXT);
  PERFORM dblink_get_result('c1race2', false);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2race2', false) AS t(v TEXT);
  PERFORM dblink_get_result('c2race2', false);
  PERFORM dblink_disconnect('c1race2');
  PERFORM dblink_disconnect('c2race2');

  IF v_r1 IS NULL OR v_r2 IS NULL THEN RAISE EXCEPTION 'both racing intent-creation calls must succeed, got r1=%, r2=%', v_r1, v_r2; END IF;
  IF v_r1 <> v_r2 THEN RAISE EXCEPTION 'both racing calls must return the same intent id, got % and %', v_r1, v_r2; END IF;

  SELECT count(*) INTO v_count FROM notification_intents WHERE outbox_event_id = v_outbox_id;
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 intent row after the race, got %', v_count; END IF;
END $$;
INSERT INTO wf82c_results VALUES (2,'Two concurrent sessions racing to create the same logical intent (same outbox event + target descriptor) never produce a duplicate row -- exactly 1 intent exists, both callers return the same intent id');

-- ── 3: recipient loses authorization during resolution ──
SET ROLE service_role;
DO $$
DECLARE v_outbox_id UUID; v_intent_id UUID;
BEGIN
  v_outbox_id := platform_enqueue_outbox_event(
    'workflow.wf82c_race3.v1','workflow','workflow_instance',(SELECT id FROM wf82c_ids WHERE name='instance'),
    '82200000-0000-0000-0000-000000000001'::UUID,NULL,gen_random_uuid(),NULL,now(),'{}'::JSONB,gen_random_uuid());
  v_intent_id := create_notification_intent(
    v_outbox_id,'workflow.wf82c_race3.v1','x.title','{}'::JSONB,'normal',
    'specific_users', ARRAY['82200000-0001-0000-0000-000000000002']::UUID[], NULL, NULL, NULL, NULL);
  INSERT INTO wf82c_ids VALUES ('race3_intent', v_intent_id);
  INSERT INTO wf82c_ids VALUES ('race3_outbox', v_outbox_id);
END $$;
RESET ROLE;
DO $$
DECLARE v_intent_id UUID; v_status TEXT; v_count INTEGER;
BEGIN
  SELECT id INTO v_intent_id FROM wf82c_ids WHERE name = 'race3_intent';
  PERFORM wf82c_connect_worker('c1race3');
  -- Session B revokes Candidate's authorization (ends their
  -- participant row) via an independent session BEFORE resolution --
  -- proving revalidation reads the CURRENT state, not a cached
  -- enqueue-time fact.
  PERFORM dblink_exec('c1race3', format(
    $q$UPDATE workflow_participants SET ended_at = now() WHERE instance_id = '%s'::uuid AND user_id = '82200000-0001-0000-0000-000000000002'::uuid$q$,
    (SELECT id FROM wf82c_ids WHERE name='instance')));
  PERFORM dblink_disconnect('c1race3');

  SELECT status INTO v_status FROM resolve_notification_intent(v_intent_id);
  IF v_status <> 'failed' THEN RAISE EXCEPTION 'expected the intent to fail (its sole candidate lost authorization), got status=%', v_status; END IF;

  SELECT count(*) INTO v_count FROM user_notifications
    WHERE outbox_event_id = (SELECT id FROM wf82c_ids WHERE name='race3_outbox') AND recipient_user_id = '82200000-0001-0000-0000-000000000002';
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: Candidate received a notification after losing authorization before resolution ran, count=%', v_count; END IF;
END $$;
INSERT INTO wf82c_results VALUES (3,'A recipient whose authorization is revoked (their workflow_participants row ended) by an independent session between intent creation and resolution is skipped -- resolution reads live state, never a stale enqueue-time snapshot');

-- ── 4: user disabled during resolution ──
SET ROLE service_role;
DO $$
DECLARE v_outbox_id UUID; v_intent_id UUID;
BEGIN
  -- Re-activate Candidate's participation for this scenario (scenario
  -- 3 ended it) so this scenario tests active-status specifically,
  -- not participation.
  UPDATE workflow_participants SET ended_at = NULL WHERE instance_id = (SELECT id FROM wf82c_ids WHERE name='instance') AND user_id = '82200000-0001-0000-0000-000000000002';
  v_outbox_id := platform_enqueue_outbox_event(
    'workflow.wf82c_race4.v1','workflow','workflow_instance',(SELECT id FROM wf82c_ids WHERE name='instance'),
    '82200000-0000-0000-0000-000000000001'::UUID,NULL,gen_random_uuid(),NULL,now(),'{}'::JSONB,gen_random_uuid());
  v_intent_id := create_notification_intent(
    v_outbox_id,'workflow.wf82c_race4.v1','x.title','{}'::JSONB,'normal',
    'specific_users', ARRAY['82200000-0001-0000-0000-000000000002']::UUID[], NULL, NULL, NULL, NULL);
  INSERT INTO wf82c_ids VALUES ('race4_intent', v_intent_id);
  INSERT INTO wf82c_ids VALUES ('race4_outbox', v_outbox_id);
END $$;
RESET ROLE;
DO $$
DECLARE v_intent_id UUID; v_status TEXT; v_count INTEGER;
BEGIN
  SELECT id INTO v_intent_id FROM wf82c_ids WHERE name = 'race4_intent';
  -- Session B disables Candidate's account via an independent session
  -- before resolution -- impersonating Admin (authority_admin),
  -- satisfying trigger_protect_privileged_user_columns()'s is_admin()
  -- gate on the users.is_active column.
  PERFORM wf82c_connect_authenticated('c1race4', '82200000-0001-0000-0000-000000000001');
  PERFORM dblink_exec('c1race4', $q$UPDATE users SET is_active = FALSE WHERE id = '82200000-0001-0000-0000-000000000002'::uuid$q$);
  PERFORM dblink_disconnect('c1race4');

  SELECT status INTO v_status FROM resolve_notification_intent(v_intent_id);
  IF v_status <> 'failed' THEN RAISE EXCEPTION 'expected the intent to fail (its sole candidate was disabled), got status=%', v_status; END IF;

  SELECT count(*) INTO v_count FROM user_notifications
    WHERE outbox_event_id = (SELECT id FROM wf82c_ids WHERE name='race4_outbox') AND recipient_user_id = '82200000-0001-0000-0000-000000000002';
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: a disabled user received a notification, count=%', v_count; END IF;

  PERFORM wf82c_connect_authenticated('c2race4', '82200000-0001-0000-0000-000000000001');
  PERFORM dblink_exec('c2race4', $q$UPDATE users SET is_active = TRUE WHERE id = '82200000-0001-0000-0000-000000000002'::uuid$q$);
  PERFORM dblink_disconnect('c2race4');
END $$;
INSERT INTO wf82c_results VALUES (4,'A user disabled (users.is_active = FALSE) by an independent session between intent creation and resolution is skipped -- the active-status check reads live state at resolution time');

-- ── 5: overlapping targets resolving same user ──
SET ROLE service_role;
DO $$
DECLARE v_outbox_id UUID; v_intent1 UUID; v_intent2 UUID;
BEGIN
  v_outbox_id := platform_enqueue_outbox_event(
    'workflow.wf82c_race5.v1','workflow','workflow_instance',(SELECT id FROM wf82c_ids WHERE name='instance'),
    '82200000-0000-0000-0000-000000000001'::UUID,NULL,gen_random_uuid(),NULL,now(),'{}'::JSONB,gen_random_uuid());
  v_intent1 := create_notification_intent(
    v_outbox_id,'workflow.wf82c_race5.v1','x.title','{}'::JSONB,'normal',
    'specific_users', ARRAY['82200000-0001-0000-0000-000000000002']::UUID[], NULL, NULL, NULL, NULL);
  v_intent2 := create_notification_intent(
    v_outbox_id,'workflow.wf82c_race5.v1','x.title','{}'::JSONB,'normal',
    'workflow_participants', NULL, NULL, NULL, (SELECT id FROM wf82c_ids WHERE name='instance'), NULL);
  INSERT INTO wf82c_ids VALUES ('race5_intent1', v_intent1);
  INSERT INTO wf82c_ids VALUES ('race5_intent2', v_intent2);
  INSERT INTO wf82c_ids VALUES ('race5_outbox', v_outbox_id);
END $$;
RESET ROLE;
DO $$
DECLARE v_i1 UUID; v_i2 UUID; v_r1 TEXT; v_r2 TEXT; v_count INTEGER;
BEGIN
  SELECT id INTO v_i1 FROM wf82c_ids WHERE name = 'race5_intent1';
  SELECT id INTO v_i2 FROM wf82c_ids WHERE name = 'race5_intent2';
  PERFORM wf82c_connect_worker('c1race5');
  PERFORM wf82c_connect_worker('c2race5');

  -- Two DIFFERENT intents, both including Candidate as a candidate,
  -- resolved concurrently -- must still land on exactly one durable
  -- notification for Candidate under real concurrency, not merely
  -- when resolved sequentially (behavioral suite scenario 6).
  PERFORM dblink_send_query('c1race5', format($q$SELECT status FROM resolve_notification_intent('%s'::uuid)$q$, v_i1));
  PERFORM dblink_send_query('c2race5', format($q$SELECT status FROM resolve_notification_intent('%s'::uuid)$q$, v_i2));

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1race5', false) AS t(v TEXT);
  PERFORM dblink_get_result('c1race5', false);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2race5', false) AS t(v TEXT);
  PERFORM dblink_get_result('c2race5', false);
  PERFORM dblink_disconnect('c1race5');
  PERFORM dblink_disconnect('c2race5');

  IF v_r1 IS NULL OR v_r2 IS NULL THEN RAISE EXCEPTION 'both overlapping-target resolutions must succeed, got r1=%, r2=%', v_r1, v_r2; END IF;

  SELECT count(*) INTO v_count FROM user_notifications
    WHERE outbox_event_id = (SELECT id FROM wf82c_ids WHERE name='race5_outbox') AND recipient_user_id = '82200000-0001-0000-0000-000000000002';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 notification for a user resolved by two overlapping targets concurrently, got %', v_count; END IF;
END $$;
INSERT INTO wf82c_results VALUES (5,'Two different intents on the same outbox event, both naming the same candidate (specific_users and workflow_participants overlapping on Candidate), resolved by two concurrent sessions, still produce exactly one durable notification for that user');

-- ── 6: unrelated intents resolve independently ──
SET ROLE service_role;
DO $$
DECLARE v_outbox_id1 UUID; v_outbox_id2 UUID; v_intent1 UUID; v_intent2 UUID;
BEGIN
  v_outbox_id1 := platform_enqueue_outbox_event(
    'platform.wf82c_race6a.v1','platform','platform',gen_random_uuid(),
    '82200000-0000-0000-0000-000000000001'::UUID,NULL,gen_random_uuid(),NULL,now(),'{}'::JSONB,gen_random_uuid());
  v_outbox_id2 := platform_enqueue_outbox_event(
    'platform.wf82c_race6b.v1','platform','platform',gen_random_uuid(),
    '82200000-0000-0000-0000-000000000001'::UUID,NULL,gen_random_uuid(),NULL,now(),'{}'::JSONB,gen_random_uuid());
  v_intent1 := create_notification_intent(
    v_outbox_id1,'platform.wf82c_race6a.v1','x.title','{}'::JSONB,'normal',
    'specific_users', ARRAY['82200000-0001-0000-0000-000000000001']::UUID[], NULL, NULL, NULL, NULL);
  v_intent2 := create_notification_intent(
    v_outbox_id2,'platform.wf82c_race6b.v1','x.title','{}'::JSONB,'normal',
    'specific_users', ARRAY['82200000-0001-0000-0000-000000000002']::UUID[], NULL, NULL, NULL, NULL);
  INSERT INTO wf82c_ids VALUES ('race6_intent1', v_intent1);
  INSERT INTO wf82c_ids VALUES ('race6_intent2', v_intent2);
END $$;
RESET ROLE;
DO $$
DECLARE v_i1 UUID; v_i2 UUID; v_r1 TEXT; v_r2 TEXT; v_start TIMESTAMPTZ; v_elapsed_ms NUMERIC;
BEGIN
  SELECT id INTO v_i1 FROM wf82c_ids WHERE name = 'race6_intent1';
  SELECT id INTO v_i2 FROM wf82c_ids WHERE name = 'race6_intent2';
  PERFORM wf82c_connect_worker('c1race6');
  PERFORM wf82c_connect_worker('c2race6');
  v_start := clock_timestamp();

  PERFORM dblink_send_query('c1race6', format($q$SELECT status FROM resolve_notification_intent('%s'::uuid)$q$, v_i1));
  PERFORM dblink_send_query('c2race6', format($q$SELECT status FROM resolve_notification_intent('%s'::uuid)$q$, v_i2));

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1race6', false) AS t(v TEXT);
  PERFORM dblink_get_result('c1race6', false);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2race6', false) AS t(v TEXT);
  PERFORM dblink_get_result('c2race6', false);
  PERFORM dblink_disconnect('c1race6');
  PERFORM dblink_disconnect('c2race6');

  v_elapsed_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_r1 IS NULL OR v_r2 IS NULL THEN RAISE EXCEPTION 'both unrelated-intent resolutions must succeed independently, got r1=%, r2=%', v_r1, v_r2; END IF;
  IF v_elapsed_ms > 5000 THEN RAISE EXCEPTION 'unrelated-intent resolution took %ms -- expected independent progress with no shared contention', v_elapsed_ms; END IF;
END $$;
INSERT INTO wf82c_results VALUES (6,'Two unrelated intents (different outbox events, disjoint targets) resolved by two concurrent sessions complete independently, well under a generous contention-detection bound -- no unnecessary shared lock serializes unrelated intent resolution');

-- ── 7: no duplicate durable notification (aggregate) ──
DO $$
DECLARE v_dupes INTEGER;
BEGIN
  SELECT count(*) INTO v_dupes FROM (
    SELECT outbox_event_id, recipient_user_id, count(*) c FROM user_notifications
    GROUP BY outbox_event_id, recipient_user_id HAVING count(*) > 1
  ) x;
  IF v_dupes <> 0 THEN RAISE EXCEPTION 'expected zero duplicate (outbox_event_id, recipient_user_id) pairs across every race above, found %', v_dupes; END IF;
END $$;
INSERT INTO wf82c_results VALUES (7,'Across every concurrent race scenario above, zero duplicate (outbox_event_id, recipient_user_id) pairs exist in user_notifications -- the uniqueness constraint held under real concurrent load throughout');

-- ── 8: no deadlocks (aggregate) ──
-- Every scenario above already exercises real concurrent dblink
-- sessions; had any of them deadlocked, dblink_get_result would have
-- surfaced a "deadlock detected" error and aborted that scenario's
-- own block before reaching its INSERT INTO wf82c_results -- the fact
-- all six preceding scenarios recorded a result is itself the
-- deadlock-freedom proof, asserted explicitly here as its own scenario.
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf82c_results WHERE scenario IN (1,2,3,4,5,6);
  IF v_count <> 6 THEN RAISE EXCEPTION 'expected scenarios 1-6 to have all completed without a deadlock error, found %', v_count; END IF;
END $$;
INSERT INTO wf82c_results VALUES (8,'No deadlock occurred in any of the six preceding concurrent-session races -- each would have surfaced a "deadlock detected" dblink error and aborted before recording its result otherwise');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf82c_results;
  IF v_count <> 8 THEN RAISE EXCEPTION 'Expected 8 scenarios to record a result, found %', v_count; END IF;
  RAISE NOTICE 'Notification recipient resolution concurrency tests PASSED: %/8', v_count;
END $$;

DROP FUNCTION wf82c_connect_worker(TEXT);
DROP FUNCTION wf82c_connect_authenticated(TEXT, TEXT);
