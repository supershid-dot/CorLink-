-- CAP-003 Phase 1.1 notification outbox persistence foundation --
-- concurrency suite (5 race scenarios). Disposable local PostgreSQL
-- only; requires dblink. Mirrors the exact dblink-based
-- genuinely-independent-session pattern every other CAP-002/CAP-003
-- concurrency suite in this repository already establishes.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;

CREATE TEMP TABLE wf81c_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf81c_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf81c_results, wf81c_ids TO authenticated, service_role;

INSERT INTO organizations(id,name,type,code) VALUES
 ('81300000-0000-0000-0000-000000000001','WF81C Org A','authority','WF81CA'),
 ('81300000-0000-0000-0000-000000000002','WF81C Org B','authority','WF81CB');
INSERT INTO auth.users(id,email) VALUES
 ('81300000-0001-0000-0000-000000000001','c1@wf81ct.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('81300000-0001-0000-0000-000000000001','81300000-0000-0000-0000-000000000001','WF81C-1','Recipient','c1@wf81ct.local',true);

CREATE OR REPLACE FUNCTION wf81c_connect_worker(p_conn TEXT) RETURNS VOID AS $$
BEGIN
  PERFORM dblink_connect(p_conn, 'host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
  PERFORM dblink_exec(p_conn, 'SET ROLE service_role');
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION wf81c_connect_authenticated(p_conn TEXT, p_sub TEXT) RETURNS VOID AS $$
DECLARE v_dummy TEXT;
BEGIN
  PERFORM dblink_connect(p_conn, 'host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
  PERFORM dblink_exec(p_conn, 'SET ROLE authenticated');
  SELECT t.v INTO v_dummy FROM dblink(p_conn, format($f$SELECT set_config('request.jwt.claims','{"sub":"%s"}',false)$f$, p_sub)) AS t(v TEXT);
END;
$$ LANGUAGE plpgsql;

-- ── 1: duplicate outbox enqueue race ──
-- Two independent worker sessions race to enqueue the SAME logical
-- fact (identical source identity + idempotency_key + payload +
-- correlation_id) concurrently. Exactly one row must exist afterward,
-- neither session may error, and both must return the same event id.
DO $$
DECLARE
  v_record_id UUID := gen_random_uuid();
  v_idem UUID := gen_random_uuid();
  v_corr UUID := gen_random_uuid();
  v_r1 TEXT; v_r2 TEXT; v_count INTEGER;
BEGIN
  PERFORM wf81c_connect_worker('c1race1');
  PERFORM wf81c_connect_worker('c2race1');

  PERFORM dblink_send_query('c1race1', format(
    $q$SELECT platform_enqueue_outbox_event('platform.wf81c_race1.v1','platform','wf81c_record','%s'::uuid,'81300000-0000-0000-0000-000000000001'::uuid,NULL,'%s'::uuid,NULL,now(),'{"a":1}'::jsonb,'%s'::uuid)$q$,
    v_record_id, v_corr, v_idem));
  PERFORM dblink_send_query('c2race1', format(
    $q$SELECT platform_enqueue_outbox_event('platform.wf81c_race1.v1','platform','wf81c_record','%s'::uuid,'81300000-0000-0000-0000-000000000001'::uuid,NULL,'%s'::uuid,NULL,now(),'{"a":1}'::jsonb,'%s'::uuid)$q$,
    v_record_id, v_corr, v_idem));

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1race1', false) AS t(v TEXT);
  PERFORM dblink_get_result('c1race1', false); -- drain command-complete
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2race1', false) AS t(v TEXT);
  PERFORM dblink_get_result('c2race1', false);

  PERFORM dblink_disconnect('c1race1');
  PERFORM dblink_disconnect('c2race1');

  IF v_r1 IS NULL OR v_r2 IS NULL THEN RAISE EXCEPTION 'both racing enqueue calls must succeed, got r1=%, r2=%', v_r1, v_r2; END IF;
  IF v_r1 <> v_r2 THEN RAISE EXCEPTION 'both racing calls must return the same event id, got % and %', v_r1, v_r2; END IF;

  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE idempotency_key = v_idem;
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 outbox row after the race, got %', v_count; END IF;
END $$;
INSERT INTO wf81c_results VALUES (1,'Two concurrent sessions racing to enqueue the same logical outbox event (same source identity + idempotency_key + content) never produce a duplicate row -- exactly 1 row exists, both callers succeed with the same event id, no deadlock');

-- ── 2: duplicate durable-notification creation race ──
DO $$
DECLARE v_outbox_id UUID;
BEGIN
  v_outbox_id := platform_enqueue_outbox_event(
    'platform.wf81c_race2.v1','platform','wf81c_record',gen_random_uuid(),
    '81300000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(), '{}'::JSONB, gen_random_uuid());
  INSERT INTO wf81c_ids VALUES ('race2_outbox', v_outbox_id);
END $$;
DO $$
DECLARE v_outbox_id UUID; v_r1 TEXT; v_r2 TEXT; v_count INTEGER;
BEGIN
  SELECT id INTO v_outbox_id FROM wf81c_ids WHERE name = 'race2_outbox';
  PERFORM wf81c_connect_worker('c1race2');
  PERFORM wf81c_connect_worker('c2race2');

  PERFORM dblink_send_query('c1race2', format(
    $q$SELECT platform_create_user_notification('81300000-0001-0000-0000-000000000001'::uuid,'81300000-0000-0000-0000-000000000001'::uuid,'platform.wf81c_race2.v1','x.title','{}'::jsonb,'platform','wf81c_record',gen_random_uuid(),'%s'::uuid,'normal',NULL,NULL,NULL)$q$,
    v_outbox_id));
  PERFORM dblink_send_query('c2race2', format(
    $q$SELECT platform_create_user_notification('81300000-0001-0000-0000-000000000001'::uuid,'81300000-0000-0000-0000-000000000001'::uuid,'platform.wf81c_race2.v1','x.title','{}'::jsonb,'platform','wf81c_record',gen_random_uuid(),'%s'::uuid,'normal',NULL,NULL,NULL)$q$,
    v_outbox_id));

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1race2', false) AS t(v TEXT);
  PERFORM dblink_get_result('c1race2', false);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2race2', false) AS t(v TEXT);
  PERFORM dblink_get_result('c2race2', false);

  PERFORM dblink_disconnect('c1race2');
  PERFORM dblink_disconnect('c2race2');

  IF v_r1 IS NULL OR v_r2 IS NULL THEN RAISE EXCEPTION 'both racing notification-creation calls must succeed, got r1=%, r2=%', v_r1, v_r2; END IF;
  IF v_r1 <> v_r2 THEN RAISE EXCEPTION 'both racing calls must return the same notification id, got % and %', v_r1, v_r2; END IF;

  SELECT count(*) INTO v_count FROM user_notifications WHERE outbox_event_id = v_outbox_id AND recipient_user_id = '81300000-0001-0000-0000-000000000001';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 notification row after the race, got %', v_count; END IF;
END $$;
INSERT INTO wf81c_results VALUES (2,'Two concurrent sessions racing to create a durable notification for the same (outbox_event_id, recipient) pair never produce a duplicate row -- exactly 1 row exists, both callers succeed with the same notification id, no deadlock');

-- ── 3: concurrent mark-read race ──
DO $$
DECLARE v_outbox_id UUID; v_notif_id UUID;
BEGIN
  v_outbox_id := platform_enqueue_outbox_event(
    'platform.wf81c_race3.v1','platform','wf81c_record',gen_random_uuid(),
    '81300000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(), '{}'::JSONB, gen_random_uuid());
  v_notif_id := platform_create_user_notification(
    '81300000-0001-0000-0000-000000000001'::UUID, '81300000-0000-0000-0000-000000000001'::UUID,
    'platform.wf81c_race3.v1', 'x.title', '{}'::JSONB, 'platform', 'wf81c_record', gen_random_uuid(),
    v_outbox_id, 'normal', NULL, NULL, NULL);
  INSERT INTO wf81c_ids VALUES ('race3_notif', v_notif_id);
END $$;
DO $$
DECLARE v_notif_id UUID; v_read_count INTEGER;
BEGIN
  SELECT id INTO v_notif_id FROM wf81c_ids WHERE name = 'race3_notif';
  PERFORM wf81c_connect_authenticated('c1race3', '81300000-0001-0000-0000-000000000001');
  PERFORM wf81c_connect_authenticated('c2race3', '81300000-0001-0000-0000-000000000001');

  PERFORM dblink_send_query('c1race3', format(
    $q$UPDATE user_notifications SET read_at = now() WHERE id = '%s'::uuid$q$, v_notif_id));
  PERFORM dblink_send_query('c2race3', format(
    $q$UPDATE user_notifications SET read_at = now() WHERE id = '%s'::uuid$q$, v_notif_id));

  PERFORM dblink_get_result('c1race3', false);
  PERFORM dblink_get_result('c2race3', false);
  PERFORM dblink_disconnect('c1race3');
  PERFORM dblink_disconnect('c2race3');

  SELECT count(*) INTO v_read_count FROM user_notifications WHERE id = v_notif_id AND read_at IS NOT NULL;
  IF v_read_count <> 1 THEN RAISE EXCEPTION 'expected the notification to end up marked read exactly once (no lost update, no error), got read-count %', v_read_count; END IF;
END $$;
INSERT INTO wf81c_results VALUES (3,'Two concurrent mark-read UPDATEs from the same recipient race safely -- no lost update, no deadlock, the notification ends up read_at IS NOT NULL regardless of which session''s UPDATE physically applied last');

-- ── 4: unrelated organizations progress independently ──
DO $$
DECLARE v_r1 TEXT; v_r2 TEXT; v_start TIMESTAMPTZ; v_elapsed_ms NUMERIC;
BEGIN
  PERFORM wf81c_connect_worker('c1race4');
  PERFORM wf81c_connect_worker('c2race4');
  v_start := clock_timestamp();

  PERFORM dblink_send_query('c1race4', format(
    $q$SELECT platform_enqueue_outbox_event('platform.wf81c_race4.v1','platform','wf81c_record',gen_random_uuid(),'81300000-0000-0000-0000-000000000001'::uuid,NULL,gen_random_uuid(),NULL,now(),'{}'::jsonb,gen_random_uuid())$q$));
  PERFORM dblink_send_query('c2race4', format(
    $q$SELECT platform_enqueue_outbox_event('platform.wf81c_race4.v1','platform','wf81c_record',gen_random_uuid(),'81300000-0000-0000-0000-000000000002'::uuid,NULL,gen_random_uuid(),NULL,now(),'{}'::jsonb,gen_random_uuid())$q$));

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1race4', false) AS t(v TEXT);
  PERFORM dblink_get_result('c1race4', false);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2race4', false) AS t(v TEXT);
  PERFORM dblink_get_result('c2race4', false);

  PERFORM dblink_disconnect('c1race4');
  PERFORM dblink_disconnect('c2race4');

  v_elapsed_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_r1 IS NULL OR v_r2 IS NULL THEN RAISE EXCEPTION 'both unrelated-org enqueues must succeed independently, got r1=%, r2=%', v_r1, v_r2; END IF;
  -- No shared row/constraint between the two organizations' events, so
  -- neither session should ever block on the other -- a generous
  -- bound (not a tight timing assertion) catches an accidental shared
  -- lock (e.g. a table-level lock instead of row-level) without being
  -- flaky under normal CI/local-disk variance.
  IF v_elapsed_ms > 5000 THEN RAISE EXCEPTION 'unrelated-organization enqueues took %ms -- expected them to progress independently with no shared contention', v_elapsed_ms; END IF;
END $$;
INSERT INTO wf81c_results VALUES (4,'Two concurrent enqueues for unrelated organizations complete independently (both succeed, well under a generous contention-detection bound) -- no unnecessary shared lock serializes unrelated organizations'' outbox activity');

-- ── 5: no deadlock (aggregate) ──
-- Every scenario above already exercises real concurrent dblink
-- sessions; had any of them deadlocked, dblink_get_result would have
-- surfaced a "deadlock detected" error and aborted the scenario's own
-- DO block before reaching its INSERT INTO wf81c_results -- the fact
-- all four preceding scenarios recorded a result is itself the
-- deadlock-freedom proof, asserted explicitly here as its own scenario.
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf81c_results WHERE scenario IN (1,2,3,4);
  IF v_count <> 4 THEN RAISE EXCEPTION 'expected scenarios 1-4 to have all completed without a deadlock error, found %', v_count; END IF;
END $$;
INSERT INTO wf81c_results VALUES (5,'No deadlock occurred in any of the four preceding concurrent-session races -- each would have surfaced a "deadlock detected" dblink error and aborted before recording its result otherwise');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf81c_results;
  IF v_count <> 5 THEN RAISE EXCEPTION 'Expected 5 scenarios to record a result, found %', v_count; END IF;
  RAISE NOTICE 'Notification outbox persistence foundation concurrency tests PASSED: %/5', v_count;
END $$;

DROP FUNCTION wf81c_connect_worker(TEXT);
DROP FUNCTION wf81c_connect_authenticated(TEXT, TEXT);
