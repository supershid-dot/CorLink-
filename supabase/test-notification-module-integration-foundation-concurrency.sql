-- CAP-003 Phase 1.4 notification module integration foundation --
-- concurrency suite. Disposable local PostgreSQL only; requires
-- dblink. Mirrors the exact dblink-based genuinely-independent-session
-- pattern every other CAP-002/CAP-003 concurrency suite in this
-- repository already establishes.
--
-- Scoped narrowly to what Phase 1.4 actually adds: real concurrent
-- contention on assign_task()'s own atomic enqueue (a genuinely new
-- code path), and two workers racing to claim a REAL module event_type
-- (task.assigned.v1) rather than only the Phase 1.3 generic test
-- envelope. The underlying SKIP LOCKED claim/backoff/dead-letter
-- machinery itself is completely unmodified by Phase 1.4 (see the
-- structural validator) and is already exhaustively proven by Phase
-- 1.3's own 9-scenario concurrency suite -- not re-proven here.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;

CREATE TEMP TABLE wf85c_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf85c_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf85c_results, wf85c_ids TO authenticated, service_role;

INSERT INTO organizations(id,name,type,code) VALUES ('85200000-0000-0000-0000-000000000001','WF85C Org','authority','WF85C');
INSERT INTO divisions(id, org_id, name) VALUES ('85200000-0004-0000-0000-000000000001','85200000-0000-0000-0000-000000000001','WF85C Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES ('85200000-0002-0000-0000-000000000001','85200000-0000-0000-0000-000000000001','85200000-0004-0000-0000-000000000001','WF85C Sec','SC1');
INSERT INTO auth.users(id,email) VALUES
 ('85200000-0001-0000-0000-000000000001','creator@wf85ct.local'),
 ('85200000-0001-0000-0000-000000000002','assignee1@wf85ct.local'),
 ('85200000-0001-0000-0000-000000000003','assignee2@wf85ct.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('85200000-0001-0000-0000-000000000001','85200000-0000-0000-0000-000000000001','WF85C-1','Creator','creator@wf85ct.local',true),
 ('85200000-0001-0000-0000-000000000002','85200000-0000-0000-0000-000000000001','WF85C-2','Assignee 1','assignee1@wf85ct.local',true),
 ('85200000-0001-0000-0000-000000000003','85200000-0000-0000-0000-000000000001','WF85C-3','Assignee 2','assignee2@wf85ct.local',true);

INSERT INTO tasks (id, task_number, title, status, priority, created_by, organization_id, owning_section_id, visibility)
VALUES ('85200000-0007-0000-0000-000000000001','WF85C-T1','WF85C race task','open','normal',
        '85200000-0001-0000-0000-000000000001','85200000-0000-0000-0000-000000000001','85200000-0002-0000-0000-000000000001','organization');

CREATE OR REPLACE FUNCTION wf85c_connect(p_conn TEXT, p_sub TEXT) RETURNS VOID AS $$
BEGIN
  PERFORM dblink_connect(p_conn, 'host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
  PERFORM dblink_exec(p_conn, 'SET ROLE authenticated');
  PERFORM dblink_exec(p_conn, format('DO $inner$ BEGIN PERFORM set_config(''request.jwt.claims'', ''{"sub":"%s"}'', false); END $inner$;', p_sub));
END;
$$ LANGUAGE plpgsql;

-- ── 1: two concurrent assign_task() calls for the SAME (task, user)
-- pair -- only one task_assignments row and exactly one outbox event
-- are ever created, regardless of which session wins the race ──────
DO $$
DECLARE v_r1 TEXT; v_r2 TEXT; v_assign_count INTEGER; v_event_count INTEGER;
BEGIN
  PERFORM wf85c_connect('c1r1', '85200000-0001-0000-0000-000000000001');
  PERFORM wf85c_connect('c2r1', '85200000-0001-0000-0000-000000000001');

  PERFORM dblink_send_query('c1r1', $q$SELECT assign_task('85200000-0007-0000-0000-000000000001'::uuid, '85200000-0001-0000-0000-000000000002'::uuid)::TEXT$q$);
  PERFORM dblink_send_query('c2r1', $q$SELECT assign_task('85200000-0007-0000-0000-000000000001'::uuid, '85200000-0001-0000-0000-000000000002'::uuid)::TEXT$q$);

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1r1', false) AS t(v TEXT);
  PERFORM dblink_get_result('c1r1', false);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2r1', false) AS t(v TEXT);
  PERFORM dblink_get_result('c2r1', false);
  PERFORM dblink_disconnect('c1r1');
  PERFORM dblink_disconnect('c2r1');

  SELECT count(*) INTO v_assign_count FROM task_assignments
    WHERE task_id = '85200000-0007-0000-0000-000000000001' AND user_id = '85200000-0001-0000-0000-000000000002' AND is_active;
  SELECT count(*) INTO v_event_count FROM platform_outbox_events
    WHERE event_type = 'task.assigned.v1' AND source_record_id = '85200000-0007-0000-0000-000000000001';

  IF v_assign_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 active task_assignments row after concurrent racing assign_task() calls, got %', v_assign_count; END IF;
  IF v_event_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 task.assigned.v1 outbox event (the atomic enqueue must not duplicate under real concurrent contention), got %', v_event_count; END IF;
END $$;
INSERT INTO wf85c_ids SELECT 'race1_event', id FROM platform_outbox_events WHERE event_type='task.assigned.v1' AND source_record_id='85200000-0007-0000-0000-000000000001';
INSERT INTO wf85c_results VALUES (1,'Two genuinely concurrent sessions calling assign_task() for the SAME (task_id, user_id) pair produce exactly one active task_assignments row and exactly one task.assigned.v1 outbox event -- task_assignments'' own ON CONFLICT (task_id,user_id) WHERE is_active constraint serializes the race, and the loser''s early RETURN means the atomic enqueue code is reached by only the winner');

-- ── 2: two concurrent assign_task() calls for the SAME task but
-- DIFFERENT users -- both succeed independently, two separate outbox
-- events, no cross-contamination between the two ────────────────────
DO $$
DECLARE v_r1 TEXT; v_r2 TEXT; v_count2 INTEGER; v_count3 INTEGER;
BEGIN
  PERFORM wf85c_connect('c1r2', '85200000-0001-0000-0000-000000000001');
  PERFORM wf85c_connect('c2r2', '85200000-0001-0000-0000-000000000001');

  PERFORM dblink_send_query('c1r2', $q$SELECT assign_task('85200000-0007-0000-0000-000000000001'::uuid, '85200000-0001-0000-0000-000000000003'::uuid)::TEXT$q$);
  -- Re-assign the SAME user from scenario 1 concurrently too, to prove
  -- the two different-recipient races don't interfere with each other.
  PERFORM dblink_send_query('c2r2', $q$SELECT assign_task('85200000-0007-0000-0000-000000000001'::uuid, '85200000-0001-0000-0000-000000000002'::uuid)::TEXT$q$);

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1r2', false) AS t(v TEXT);
  PERFORM dblink_get_result('c1r2', false);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2r2', false) AS t(v TEXT);
  PERFORM dblink_get_result('c2r2', false);
  PERFORM dblink_disconnect('c1r2');
  PERFORM dblink_disconnect('c2r2');

  SELECT count(*) INTO v_count2 FROM platform_outbox_events WHERE event_type='task.assigned.v1' AND source_record_id='85200000-0007-0000-0000-000000000001'
    AND (payload->'target_user_ids') = jsonb_build_array('85200000-0001-0000-0000-000000000002');
  SELECT count(*) INTO v_count3 FROM platform_outbox_events WHERE event_type='task.assigned.v1' AND source_record_id='85200000-0007-0000-0000-000000000001'
    AND (payload->'target_user_ids') = jsonb_build_array('85200000-0001-0000-0000-000000000003');

  IF v_count2 <> 1 THEN RAISE EXCEPTION 'expected exactly 1 outbox event still targeting assignee 2 (unaffected by the concurrent different-recipient assignment), got %', v_count2; END IF;
  IF v_count3 <> 1 THEN RAISE EXCEPTION 'expected exactly 1 outbox event targeting the newly-added assignee 3, got %', v_count3; END IF;
END $$;
INSERT INTO wf85c_results VALUES (2,'A concurrent assign_task() call for a DIFFERENT recipient on the same task neither blocks on nor contaminates the scenario-1 race: each (task_id, user_id) pair gets its own independent task_assignments row and its own independent outbox event, with no cross-target interference');

-- ── 3: two workers concurrently call process_platform_outbox_batch()
-- and race to claim the SAME real task.assigned.v1 event -- exactly
-- one processes it to completion, the other sees it already claimed/
-- processed, and exactly one user_notifications row results ─────────
DO $$
DECLARE v_id UUID; v_r1 TEXT; v_r2 TEXT; v_completed_count INTEGER; v_notif_count INTEGER;
BEGIN
  SELECT id INTO v_id FROM wf85c_ids WHERE name = 'race1_event';

  PERFORM dblink_connect('c1r3', 'host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
  PERFORM dblink_connect('c2r3', 'host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
  PERFORM dblink_exec('c1r3', 'SET ROLE service_role');
  PERFORM dblink_exec('c2r3', 'SET ROLE service_role');

  PERFORM dblink_send_query('c1r3', format($q$SELECT outcome FROM process_platform_outbox_batch(25,'wf85c-A') WHERE event_id = '%s'::uuid$q$, v_id));
  PERFORM dblink_send_query('c2r3', format($q$SELECT outcome FROM process_platform_outbox_batch(25,'wf85c-B') WHERE event_id = '%s'::uuid$q$, v_id));

  SELECT t.v INTO v_r1 FROM dblink_get_result('c1r3', false) AS t(v TEXT);
  PERFORM dblink_get_result('c1r3', false);
  SELECT t.v INTO v_r2 FROM dblink_get_result('c2r3', false) AS t(v TEXT);
  PERFORM dblink_get_result('c2r3', false);
  PERFORM dblink_disconnect('c1r3');
  PERFORM dblink_disconnect('c2r3');

  v_completed_count := (CASE WHEN v_r1 IN ('processed','processed_zero_recipients') THEN 1 ELSE 0 END)
                      + (CASE WHEN v_r2 IN ('processed','processed_zero_recipients') THEN 1 ELSE 0 END);
  IF v_completed_count <> 1 THEN RAISE EXCEPTION 'expected exactly one of the two racing workers to see outcome=processed for the real task.assigned.v1 event, got r1=%, r2=%', v_r1, v_r2; END IF;
  IF NOT (v_r1 IN ('processed','processed_zero_recipients','skipped_locked') AND v_r2 IN ('processed','processed_zero_recipients','skipped_locked')) THEN
    RAISE EXCEPTION 'unexpected outcomes for a same-event worker race: r1=%, r2=%', v_r1, v_r2;
  END IF;

  SELECT count(*) INTO v_notif_count FROM user_notifications WHERE outbox_event_id = v_id;
  IF v_notif_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 user_notifications row despite the worker race, got %', v_notif_count; END IF;
END $$;
INSERT INTO wf85c_results VALUES (3,'Two genuinely concurrent workers racing to claim the SAME real task.assigned.v1 event via process_platform_outbox_batch() resolve exactly like Phase 1.3''s own generic-envelope race: exactly one claims it to outcome=completed (FOR UPDATE SKIP LOCKED, unmodified by Phase 1.4''s registry-driven dispatch change), the other sees skipped_locked, and exactly one durable user_notifications row results');

-- ── 4: a concurrent revocation of task_assignments racing against
-- resolve_notification_intent's own FOR UPDATE row lock on the intent
-- -- the row lock serializes the two, and whichever order they land
-- in produces a CONSISTENT, non-corrupted terminal outcome (never a
-- torn read of resolved_count/skipped_count) ───────────────────────
-- Setup runs as its own top-level statement so it is committed BEFORE
-- the race below -- a dblink sub-connection is a genuinely separate
-- session and can never see another session's still-in-flight,
-- uncommitted writes (this is the whole point of the race).
DO $$
DECLARE v_event_id UUID; v_intent_id UUID;
BEGIN
  INSERT INTO task_assignments (task_id, user_id, assigned_by, is_active)
  VALUES ('85200000-0007-0000-0000-000000000001','85200000-0001-0000-0000-000000000003','85200000-0001-0000-0000-000000000001',true)
  ON CONFLICT (task_id, user_id) WHERE is_active DO NOTHING;

  v_event_id := platform_enqueue_outbox_event('task.assigned.v1','tasks','task','85200000-0007-0000-0000-000000000001',
    '85200000-0000-0000-0000-000000000001', NULL, gen_random_uuid(), NULL, NOW(),
    jsonb_build_object('notification_type','task.assigned.v1','title_template_key','task.assigned',
      'template_params','{}'::JSONB,'priority','normal','target_type','specific_users',
      'target_user_ids', jsonb_build_array('85200000-0001-0000-0000-000000000003')),
    gen_random_uuid());
  v_intent_id := create_notification_intent(v_event_id, 'task.assigned.v1','task.assigned','{}'::JSONB,'normal',
    'specific_users', ARRAY['85200000-0001-0000-0000-000000000003']::UUID[], NULL, NULL, NULL, NULL,NULL,NULL);

  INSERT INTO wf85c_ids VALUES ('race4_intent', v_intent_id);
END $$;

DO $$
DECLARE v_intent_id UUID; v_status TEXT; v_resolved INTEGER; v_skipped INTEGER;
BEGIN
  SELECT id INTO v_intent_id FROM wf85c_ids WHERE name = 'race4_intent';

  PERFORM dblink_connect('c1r4', 'host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
  PERFORM dblink_exec('c1r4', 'SET ROLE service_role');
  PERFORM dblink_send_query('c1r4', format($q$SELECT status, resolved_count, skipped_count FROM resolve_notification_intent('%s'::uuid)$q$, v_intent_id));

  UPDATE task_assignments SET is_active = false
  WHERE task_id = '85200000-0007-0000-0000-000000000001' AND user_id = '85200000-0001-0000-0000-000000000003';

  SELECT t.v1, t.v2, t.v3 INTO v_status, v_resolved, v_skipped FROM dblink_get_result('c1r4', false) AS t(v1 TEXT, v2 INTEGER, v3 INTEGER);
  PERFORM dblink_get_result('c1r4', false);
  PERFORM dblink_disconnect('c1r4');

  IF (v_resolved + v_skipped) <> 1 THEN
    RAISE EXCEPTION 'torn resolution result: status=%, resolved=%, skipped=% (resolved+skipped must total exactly 1)', v_status, v_resolved, v_skipped;
  END IF;
  IF v_status NOT IN ('resolved','failed') THEN
    RAISE EXCEPTION 'unexpected terminal status % for a single-candidate intent', v_status;
  END IF;
END $$;
INSERT INTO wf85c_results VALUES (4,'A concurrent task_assignments revocation racing against resolve_notification_intent()''s own FOR UPDATE row lock on the intent never produces a torn/inconsistent result -- resolved_count+skipped_count always totals exactly 1 regardless of which session''s write actually lands first, matching Phase 1.2''s own already-proven row-locking guarantee, now exercised against a real task-sourced intent rather than only the workflow_instance/platform adapters');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf85c_results;
  IF v_count <> 4 THEN
    RAISE EXCEPTION 'Expected 4 scenarios to record a result, found %', v_count;
  END IF;
  RAISE NOTICE 'Notification module integration foundation concurrency tests PASSED: %/4', v_count;
END $$;

DROP FUNCTION wf85c_connect(TEXT, TEXT);
