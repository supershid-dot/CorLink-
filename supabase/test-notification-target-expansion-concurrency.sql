-- CAP-003 Phase 1.4A notification target expansion -- concurrency
-- suite (8 scenarios). Disposable local PostgreSQL only; requires
-- dblink. Mirrors the exact dblink-based genuinely-independent-session
-- pattern every other CAP-002/CAP-003 concurrency suite already
-- establishes.
--
-- For membership-change races (scenarios 2, 3, 5, 6), resolve_
-- notification_intent() takes no lock on task_watchers/
-- meeting_participants themselves (only on the intent row) -- a
-- concurrent membership change can legitimately land before or after
-- the resolver's own SELECT, and BOTH orderings are correct outcomes
-- (the row either existed at the resolver's read or it didn't). These
-- scenarios therefore assert the two allowed serial outcomes and a
-- non-negotiable invariant (no torn/inconsistent count, no duplicate
-- notification, no crash) rather than one single deterministic result.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;

CREATE TEMP TABLE wf86c_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf86c_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf86c_results, wf86c_ids TO authenticated, service_role;

INSERT INTO organizations(id,name,type,code) VALUES ('86200000-0000-0000-0000-000000000001','WF86C Org','authority','WF86C');
INSERT INTO divisions(id, org_id, name) VALUES ('86200000-0004-0000-0000-000000000001','86200000-0000-0000-0000-000000000001','WF86C Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES ('86200000-0002-0000-0000-000000000001','86200000-0000-0000-0000-000000000001','86200000-0004-0000-0000-000000000001','WF86C Sec','SC1');
INSERT INTO auth.users(id,email) VALUES
 ('86200000-0001-0000-0000-000000000001','creator@wf86ct.local'),
 ('86200000-0001-0000-0000-000000000002','watcher1@wf86ct.local'),
 ('86200000-0001-0000-0000-000000000003','watcher2@wf86ct.local'),
 ('86200000-0001-0000-0000-000000000004','participant1@wf86ct.local'),
 ('86200000-0001-0000-0000-000000000005','participant2@wf86ct.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('86200000-0001-0000-0000-000000000001','86200000-0000-0000-0000-000000000001','WF86C-1','Creator','creator@wf86ct.local',true),
 ('86200000-0001-0000-0000-000000000002','86200000-0000-0000-0000-000000000001','WF86C-2','Watcher 1','watcher1@wf86ct.local',true),
 ('86200000-0001-0000-0000-000000000003','86200000-0000-0000-0000-000000000001','WF86C-3','Watcher 2','watcher2@wf86ct.local',true),
 ('86200000-0001-0000-0000-000000000004','86200000-0000-0000-0000-000000000001','WF86C-4','Participant 1','participant1@wf86ct.local',true),
 ('86200000-0001-0000-0000-000000000005','86200000-0000-0000-0000-000000000001','WF86C-5','Participant 2','participant2@wf86ct.local',true);

INSERT INTO tasks (id, task_number, title, status, priority, created_by, organization_id, owning_section_id, visibility)
VALUES
 ('86200000-0007-0000-0000-000000000001','WF86C-T1','WF86C task 1','open','normal','86200000-0001-0000-0000-000000000001','86200000-0000-0000-0000-000000000001','86200000-0002-0000-0000-000000000001','organization'),
 ('86200000-0007-0000-0000-000000000002','WF86C-T2','WF86C task 2','open','normal','86200000-0001-0000-0000-000000000001','86200000-0000-0000-0000-000000000001','86200000-0002-0000-0000-000000000001','organization');
INSERT INTO task_watchers (task_id, user_id) VALUES ('86200000-0007-0000-0000-000000000001','86200000-0001-0000-0000-000000000002');

INSERT INTO meetings (id, organization_id, created_by, title, meeting_type, status, visibility, timezone, start_at, end_at)
VALUES
 ('86200000-0008-0000-0000-000000000001','86200000-0000-0000-0000-000000000001','86200000-0001-0000-0000-000000000001','WF86C Meeting 1','general','scheduled','organization','Indian/Maldives', now()+interval '1 day', now()+interval '1 day 1 hour'),
 ('86200000-0008-0000-0000-000000000002','86200000-0000-0000-0000-000000000001','86200000-0001-0000-0000-000000000001','WF86C Meeting 2','general','scheduled','organization','Indian/Maldives', now()+interval '2 day', now()+interval '2 day 1 hour');
INSERT INTO meeting_participants (meeting_id, user_id, participant_role, invited_by)
VALUES ('86200000-0008-0000-0000-000000000001','86200000-0001-0000-0000-000000000004','attendee','86200000-0001-0000-0000-000000000001');

CREATE OR REPLACE FUNCTION wf86c_connect(p_conn TEXT) RETURNS VOID AS $$
BEGIN
  PERFORM dblink_connect(p_conn, 'host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
  PERFORM dblink_exec(p_conn, 'SET ROLE service_role');
END;
$$ LANGUAGE plpgsql;

-- ── 1: two concurrent resolutions of ONE task_watchers intent --
-- exactly one durable notification per watcher, no torn/duplicate
-- state regardless of which session's resolve call actually does the
-- work (both observe the same intent row lock) ──
DO $$ DECLARE v_id UUID; BEGIN
  v_id := create_notification_intent(
    platform_enqueue_outbox_event('wf86c.r1.v1','tasks','task','86200000-0007-0000-0000-000000000001','86200000-0000-0000-0000-000000000001',NULL,gen_random_uuid(),NULL,NOW(),'{}'::JSONB,gen_random_uuid()),
    'wf86c.r1.v1','x','{}'::JSONB,'normal','task_watchers',NULL,NULL,NULL,NULL,NULL,'86200000-0007-0000-0000-000000000001'::UUID,NULL);
  INSERT INTO wf86c_ids VALUES ('intent1', v_id);
END $$;

DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_notif_count INTEGER;
BEGIN
  SELECT id INTO v_id FROM wf86c_ids WHERE name='intent1';
  PERFORM wf86c_connect('c1r1');
  PERFORM wf86c_connect('c2r1');
  PERFORM dblink_send_query('c1r1', format($q$SELECT status FROM resolve_notification_intent('%s'::uuid)$q$, v_id));
  PERFORM dblink_send_query('c2r1', format($q$SELECT status FROM resolve_notification_intent('%s'::uuid)$q$, v_id));
  SELECT t.v INTO v_r1 FROM dblink_get_result('c1r1', false) AS t(v TEXT);
  PERFORM dblink_get_result('c1r1', false);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2r1', false) AS t(v TEXT);
  PERFORM dblink_get_result('c2r1', false);
  PERFORM dblink_disconnect('c1r1');
  PERFORM dblink_disconnect('c2r1');
  IF v_r1 <> v_r2 THEN RAISE EXCEPTION 'expected identical status from both racing resolutions (row lock serializes them), got %/%', v_r1, v_r2; END IF;
  SELECT count(*) INTO v_notif_count FROM user_notifications WHERE outbox_event_id = (SELECT outbox_event_id FROM notification_intents WHERE id = v_id);
  IF v_notif_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 durable notification, got %', v_notif_count; END IF;
END $$;
INSERT INTO wf86c_results VALUES (1,'Two genuinely concurrent sessions calling resolve_notification_intent() on the SAME task_watchers intent produce identical status and exactly 1 durable notification -- the intent row''s own FOR UPDATE lock (Phase 1.2) serializes the race exactly as it already does for every other target kind');

-- ── 2: watcher removal racing with resolution -- both allowed serial
-- outcomes (resolved before or after the removal lands) are correct;
-- the non-negotiable invariant is NO torn/duplicate/crashed state ──
DO $$ DECLARE v_event_id UUID; v_intent_id UUID; BEGIN
  INSERT INTO task_watchers (task_id, user_id) VALUES ('86200000-0007-0000-0000-000000000001','86200000-0001-0000-0000-000000000003');
  v_event_id := platform_enqueue_outbox_event('wf86c.r2.v1','tasks','task','86200000-0007-0000-0000-000000000001','86200000-0000-0000-0000-000000000001',NULL,gen_random_uuid(),NULL,NOW(),'{}'::JSONB,gen_random_uuid());
  v_intent_id := create_notification_intent(v_event_id,'wf86c.r2.v1','x','{}'::JSONB,'normal','task_watchers',NULL,NULL,NULL,NULL,NULL,'86200000-0007-0000-0000-000000000001'::UUID,NULL);
  INSERT INTO wf86c_ids VALUES ('intent2', v_intent_id);
  INSERT INTO wf86c_ids VALUES ('event2', v_event_id);
END $$;

DO $$
DECLARE v_intent_id UUID; v_event_id UUID; v_resolved INTEGER; v_notif_count INTEGER;
BEGIN
  SELECT id INTO v_intent_id FROM wf86c_ids WHERE name='intent2';
  SELECT id INTO v_event_id FROM wf86c_ids WHERE name='event2';
  PERFORM wf86c_connect('c1r2');
  PERFORM dblink_send_query('c1r2', format($q$SELECT resolved_count FROM resolve_notification_intent('%s'::uuid)$q$, v_intent_id));
  DELETE FROM task_watchers WHERE task_id='86200000-0007-0000-0000-000000000001' AND user_id='86200000-0001-0000-0000-000000000003';
  SELECT t.v INTO v_resolved FROM dblink_get_result('c1r2', false) AS t(v INTEGER);
  PERFORM dblink_get_result('c1r2', false);
  PERFORM dblink_disconnect('c1r2');
  IF v_resolved NOT IN (1, 2) THEN RAISE EXCEPTION 'unexpected resolved_count for a removal-race: % (both 1 and 2 are legitimate depending on ordering)', v_resolved; END IF;
  SELECT count(*) INTO v_notif_count FROM user_notifications WHERE outbox_event_id = v_event_id;
  IF v_notif_count <> v_resolved THEN RAISE EXCEPTION 'torn state: resolved_count=% but % durable notification rows', v_resolved, v_notif_count; END IF;
END $$;
INSERT INTO wf86c_results VALUES (2,'A watcher removal racing with resolve_notification_intent() produces one of the two legitimate outcomes (the removed watcher was or was not included, depending on true statement ordering -- resolve_notification_intent() takes no lock on task_watchers itself) with zero torn state: resolved_count always exactly matches the durable notification row count');

-- ── 3: watcher addition racing with resolution ──
DO $$ DECLARE v_event_id UUID; v_intent_id UUID; BEGIN
  v_event_id := platform_enqueue_outbox_event('wf86c.r3.v1','tasks','task','86200000-0007-0000-0000-000000000002','86200000-0000-0000-0000-000000000001',NULL,gen_random_uuid(),NULL,NOW(),'{}'::JSONB,gen_random_uuid());
  v_intent_id := create_notification_intent(v_event_id,'wf86c.r3.v1','x','{}'::JSONB,'normal','task_watchers',NULL,NULL,NULL,NULL,NULL,'86200000-0007-0000-0000-000000000002'::UUID,NULL);
  INSERT INTO wf86c_ids VALUES ('intent3', v_intent_id);
  INSERT INTO wf86c_ids VALUES ('event3', v_event_id);
END $$;

DO $$
DECLARE v_intent_id UUID; v_event_id UUID; v_resolved INTEGER; v_notif_count INTEGER;
BEGIN
  SELECT id INTO v_intent_id FROM wf86c_ids WHERE name='intent3';
  SELECT id INTO v_event_id FROM wf86c_ids WHERE name='event3';
  PERFORM wf86c_connect('c1r3');
  PERFORM dblink_send_query('c1r3', format($q$SELECT resolved_count FROM resolve_notification_intent('%s'::uuid)$q$, v_intent_id));
  INSERT INTO task_watchers (task_id, user_id) VALUES ('86200000-0007-0000-0000-000000000002','86200000-0001-0000-0000-000000000002');
  SELECT t.v INTO v_resolved FROM dblink_get_result('c1r3', false) AS t(v INTEGER);
  PERFORM dblink_get_result('c1r3', false);
  PERFORM dblink_disconnect('c1r3');
  IF v_resolved NOT IN (0, 1) THEN RAISE EXCEPTION 'unexpected resolved_count for an addition-race: % (both 0 and 1 are legitimate)', v_resolved; END IF;
  SELECT count(*) INTO v_notif_count FROM user_notifications WHERE outbox_event_id = v_event_id;
  IF v_notif_count <> v_resolved THEN RAISE EXCEPTION 'torn state: resolved_count=% but % durable notification rows', v_resolved, v_notif_count; END IF;
END $$;
INSERT INTO wf86c_results VALUES (3,'A watcher addition racing with resolve_notification_intent() likewise produces one of two legitimate outcomes (the newly-added watcher was or was not included) with zero torn state');

-- ── 4: two concurrent resolutions of ONE meeting_participants intent ──
DO $$ DECLARE v_id UUID; BEGIN
  v_id := create_notification_intent(
    platform_enqueue_outbox_event('wf86c.r4.v1','meetings','meeting','86200000-0008-0000-0000-000000000001','86200000-0000-0000-0000-000000000001',NULL,gen_random_uuid(),NULL,NOW(),'{}'::JSONB,gen_random_uuid()),
    'wf86c.r4.v1','x','{}'::JSONB,'normal','meeting_participants',NULL,NULL,NULL,NULL,NULL,NULL,'86200000-0008-0000-0000-000000000001'::UUID);
  INSERT INTO wf86c_ids VALUES ('intent4', v_id);
END $$;

DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_notif_count INTEGER;
BEGIN
  SELECT id INTO v_id FROM wf86c_ids WHERE name='intent4';
  PERFORM wf86c_connect('c1r4');
  PERFORM wf86c_connect('c2r4');
  PERFORM dblink_send_query('c1r4', format($q$SELECT status FROM resolve_notification_intent('%s'::uuid)$q$, v_id));
  PERFORM dblink_send_query('c2r4', format($q$SELECT status FROM resolve_notification_intent('%s'::uuid)$q$, v_id));
  SELECT t.v INTO v_r1 FROM dblink_get_result('c1r4', false) AS t(v TEXT);
  PERFORM dblink_get_result('c1r4', false);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2r4', false) AS t(v TEXT);
  PERFORM dblink_get_result('c2r4', false);
  PERFORM dblink_disconnect('c1r4');
  PERFORM dblink_disconnect('c2r4');
  IF v_r1 <> v_r2 THEN RAISE EXCEPTION 'expected identical status from both racing resolutions, got %/%', v_r1, v_r2; END IF;
  SELECT count(*) INTO v_notif_count FROM user_notifications WHERE outbox_event_id = (SELECT outbox_event_id FROM notification_intents WHERE id = v_id);
  IF v_notif_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 durable notification, got %', v_notif_count; END IF;
END $$;
INSERT INTO wf86c_results VALUES (4,'Two genuinely concurrent sessions calling resolve_notification_intent() on the SAME meeting_participants intent produce identical status and exactly 1 durable notification');

-- ── 5: participant removal racing with resolution ──
DO $$ DECLARE v_event_id UUID; v_intent_id UUID; BEGIN
  INSERT INTO meeting_participants (meeting_id, user_id, participant_role, invited_by)
    VALUES ('86200000-0008-0000-0000-000000000001','86200000-0001-0000-0000-000000000005','attendee','86200000-0001-0000-0000-000000000001');
  v_event_id := platform_enqueue_outbox_event('wf86c.r5.v1','meetings','meeting','86200000-0008-0000-0000-000000000001','86200000-0000-0000-0000-000000000001',NULL,gen_random_uuid(),NULL,NOW(),'{}'::JSONB,gen_random_uuid());
  v_intent_id := create_notification_intent(v_event_id,'wf86c.r5.v1','x','{}'::JSONB,'normal','meeting_participants',NULL,NULL,NULL,NULL,NULL,NULL,'86200000-0008-0000-0000-000000000001'::UUID);
  INSERT INTO wf86c_ids VALUES ('intent5', v_intent_id);
  INSERT INTO wf86c_ids VALUES ('event5', v_event_id);
END $$;

DO $$
DECLARE v_intent_id UUID; v_event_id UUID; v_resolved INTEGER; v_notif_count INTEGER;
BEGIN
  SELECT id INTO v_intent_id FROM wf86c_ids WHERE name='intent5';
  SELECT id INTO v_event_id FROM wf86c_ids WHERE name='event5';
  PERFORM wf86c_connect('c1r5');
  PERFORM dblink_send_query('c1r5', format($q$SELECT resolved_count FROM resolve_notification_intent('%s'::uuid)$q$, v_intent_id));
  UPDATE meeting_participants SET removed_at = now(), removed_by='86200000-0001-0000-0000-000000000001'
    WHERE meeting_id='86200000-0008-0000-0000-000000000001' AND user_id='86200000-0001-0000-0000-000000000005';
  SELECT t.v INTO v_resolved FROM dblink_get_result('c1r5', false) AS t(v INTEGER);
  PERFORM dblink_get_result('c1r5', false);
  PERFORM dblink_disconnect('c1r5');
  IF v_resolved NOT IN (1, 2) THEN RAISE EXCEPTION 'unexpected resolved_count for a participant removal-race: % (both 1 and 2 are legitimate)', v_resolved; END IF;
  SELECT count(*) INTO v_notif_count FROM user_notifications WHERE outbox_event_id = v_event_id;
  IF v_notif_count <> v_resolved THEN RAISE EXCEPTION 'torn state: resolved_count=% but % durable notification rows', v_resolved, v_notif_count; END IF;
END $$;
INSERT INTO wf86c_results VALUES (5,'A participant removal racing with resolve_notification_intent() produces one of two legitimate outcomes with zero torn state, identical guarantee to task_watchers'' own removal race');

-- ── 6: participant addition racing with resolution ──
DO $$ DECLARE v_event_id UUID; v_intent_id UUID; BEGIN
  v_event_id := platform_enqueue_outbox_event('wf86c.r6.v1','meetings','meeting','86200000-0008-0000-0000-000000000002','86200000-0000-0000-0000-000000000001',NULL,gen_random_uuid(),NULL,NOW(),'{}'::JSONB,gen_random_uuid());
  v_intent_id := create_notification_intent(v_event_id,'wf86c.r6.v1','x','{}'::JSONB,'normal','meeting_participants',NULL,NULL,NULL,NULL,NULL,NULL,'86200000-0008-0000-0000-000000000002'::UUID);
  INSERT INTO wf86c_ids VALUES ('intent6', v_intent_id);
  INSERT INTO wf86c_ids VALUES ('event6', v_event_id);
END $$;

DO $$
DECLARE v_intent_id UUID; v_event_id UUID; v_resolved INTEGER; v_notif_count INTEGER;
BEGIN
  SELECT id INTO v_intent_id FROM wf86c_ids WHERE name='intent6';
  SELECT id INTO v_event_id FROM wf86c_ids WHERE name='event6';
  PERFORM wf86c_connect('c1r6');
  PERFORM dblink_send_query('c1r6', format($q$SELECT resolved_count FROM resolve_notification_intent('%s'::uuid)$q$, v_intent_id));
  INSERT INTO meeting_participants (meeting_id, user_id, participant_role, invited_by)
    VALUES ('86200000-0008-0000-0000-000000000002','86200000-0001-0000-0000-000000000004','attendee','86200000-0001-0000-0000-000000000001');
  SELECT t.v INTO v_resolved FROM dblink_get_result('c1r6', false) AS t(v INTEGER);
  PERFORM dblink_get_result('c1r6', false);
  PERFORM dblink_disconnect('c1r6');
  IF v_resolved NOT IN (0, 1) THEN RAISE EXCEPTION 'unexpected resolved_count for a participant addition-race: % (both 0 and 1 are legitimate)', v_resolved; END IF;
  SELECT count(*) INTO v_notif_count FROM user_notifications WHERE outbox_event_id = v_event_id;
  IF v_notif_count <> v_resolved THEN RAISE EXCEPTION 'torn state: resolved_count=% but % durable notification rows', v_resolved, v_notif_count; END IF;
END $$;
INSERT INTO wf86c_results VALUES (6,'A participant addition racing with resolve_notification_intent() produces one of two legitimate outcomes with zero torn state');

-- ── 7: unrelated Task and Meeting resolutions progress independently
-- and concurrently (no shared/global lock across the two target kinds) ──
DO $$ DECLARE v_task_intent UUID; v_meeting_intent UUID; BEGIN
  v_task_intent := create_notification_intent(
    platform_enqueue_outbox_event('wf86c.r7a.v1','tasks','task','86200000-0007-0000-0000-000000000001','86200000-0000-0000-0000-000000000001',NULL,gen_random_uuid(),NULL,NOW(),'{}'::JSONB,gen_random_uuid()),
    'wf86c.r7a.v1','x','{}'::JSONB,'normal','task_watchers',NULL,NULL,NULL,NULL,NULL,'86200000-0007-0000-0000-000000000001'::UUID,NULL);
  v_meeting_intent := create_notification_intent(
    platform_enqueue_outbox_event('wf86c.r7b.v1','meetings','meeting','86200000-0008-0000-0000-000000000001','86200000-0000-0000-0000-000000000001',NULL,gen_random_uuid(),NULL,NOW(),'{}'::JSONB,gen_random_uuid()),
    'wf86c.r7b.v1','x','{}'::JSONB,'normal','meeting_participants',NULL,NULL,NULL,NULL,NULL,NULL,'86200000-0008-0000-0000-000000000001'::UUID);
  INSERT INTO wf86c_ids VALUES ('intent7task', v_task_intent);
  INSERT INTO wf86c_ids VALUES ('intent7meeting', v_meeting_intent);
END $$;

DO $$
DECLARE v_task_id UUID; v_meeting_id UUID; v_r1 TEXT; v_r2 TEXT; v_start TIMESTAMPTZ; v_elapsed_ms NUMERIC;
BEGIN
  SELECT id INTO v_task_id FROM wf86c_ids WHERE name='intent7task';
  SELECT id INTO v_meeting_id FROM wf86c_ids WHERE name='intent7meeting';
  PERFORM wf86c_connect('c1r7');
  PERFORM wf86c_connect('c2r7');
  v_start := clock_timestamp();
  PERFORM dblink_send_query('c1r7', format($q$SELECT status FROM resolve_notification_intent('%s'::uuid)$q$, v_task_id));
  PERFORM dblink_send_query('c2r7', format($q$SELECT status FROM resolve_notification_intent('%s'::uuid)$q$, v_meeting_id));
  SELECT t.v INTO v_r1 FROM dblink_get_result('c1r7', false) AS t(v TEXT);
  PERFORM dblink_get_result('c1r7', false);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2r7', false) AS t(v TEXT);
  PERFORM dblink_get_result('c2r7', false);
  v_elapsed_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  PERFORM dblink_disconnect('c1r7');
  PERFORM dblink_disconnect('c2r7');
  IF v_r1 NOT IN ('resolved','failed') OR v_r2 NOT IN ('resolved','failed') THEN
    RAISE EXCEPTION 'unexpected terminal status for the unrelated concurrent resolutions: %/%', v_r1, v_r2;
  END IF;
  IF v_elapsed_ms > 5000 THEN RAISE EXCEPTION 'unrelated Task/Meeting concurrent resolution took %ms -- expected independent progress with no shared contention', v_elapsed_ms; END IF;
END $$;
INSERT INTO wf86c_results VALUES (7,'An unrelated task_watchers resolution and meeting_participants resolution, run concurrently, complete independently well under a generous contention-detection bound -- no global/cross-target-kind lock exists');

-- ── 8: no deadlocks (aggregate) ──
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf86c_results WHERE scenario IN (1,2,3,4,5,6,7);
  IF v_count <> 7 THEN RAISE EXCEPTION 'expected scenarios 1-7 to have all completed without a deadlock error, found %', v_count; END IF;
END $$;
INSERT INTO wf86c_results VALUES (8,'No deadlock occurred in any of the preceding concurrent-session races -- each would have surfaced a "deadlock detected" dblink error and aborted before recording its result otherwise');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf86c_results;
  IF v_count <> 8 THEN RAISE EXCEPTION 'Expected 8 scenarios to record a result, found %', v_count; END IF;
  RAISE NOTICE 'Notification target expansion concurrency tests PASSED: %/8', v_count;
END $$;

DROP FUNCTION wf86c_connect(TEXT);
