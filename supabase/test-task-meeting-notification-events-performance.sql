-- CAP-003 Phase 1.4B notification event integration -- performance
-- suite. Disposable local PostgreSQL only. 20,000+ historical Tasks,
-- 10,000+ Meetings, 100,000+ background outbox rows.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES ('87300000-0000-0000-0000-000000000001','WF87P Org','authority','WF87P');
INSERT INTO divisions(id, org_id, name) VALUES ('87300000-0004-0000-0000-000000000001','87300000-0000-0000-0000-000000000001','WF87P Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES ('87300000-0002-0000-0000-000000000001','87300000-0000-0000-0000-000000000001','87300000-0004-0000-0000-000000000001','WF87P Sec','S8P1');
INSERT INTO organization_modules (organization_id, module_id, is_enabled)
  SELECT '87300000-0000-0000-0000-000000000001', pm.id, TRUE FROM platform_modules pm WHERE pm.module_key = 'meetings'
  ON CONFLICT (organization_id, module_id) DO UPDATE SET is_enabled = TRUE;

INSERT INTO auth.users(id,email)
  SELECT ('87300000-0001-0000-0000-' || lpad(i::text,12,'0'))::UUID, 'wf87p'||i||'@t.local'
  FROM generate_series(1,50) i;
INSERT INTO users(id,org_id,service_number,full_name,email,is_active)
  SELECT ('87300000-0001-0000-0000-' || lpad(i::text,12,'0'))::UUID, '87300000-0000-0000-0000-000000000001',
    'WF87P-'||i, 'User '||i, 'wf87p'||i||'@t.local', TRUE
  FROM generate_series(1,50) i;

SET ROLE service_role;

-- 20,000 historical, already-completed Tasks (background evidence,
-- never touched again) + 100 "live" tasks used for the actual timed
-- probes below, each with a small watcher set.
INSERT INTO tasks (id, task_number, title, status, priority, created_by, organization_id, owning_section_id, visibility, completed_at, completed_by)
  SELECT ('87300000-0007-0000-1000-' || lpad(i::text,12,'0'))::UUID, 'WF87P-BG-'||i, 'Background task '||i, 'completed', 'normal',
    ('87300000-0001-0000-0000-'||lpad(((i%50)+1)::text,12,'0'))::UUID, '87300000-0000-0000-0000-000000000001', '87300000-0002-0000-0000-000000000001', 'private',
    now() - (i || ' minutes')::interval, ('87300000-0001-0000-0000-'||lpad(((i%50)+1)::text,12,'0'))::UUID
  FROM generate_series(1,20000) i;

INSERT INTO tasks (id, task_number, title, status, priority, created_by, organization_id, owning_section_id, visibility)
  SELECT ('87300000-0007-0000-2000-' || lpad(i::text,12,'0'))::UUID, 'WF87P-LIVE-'||i, 'Live task '||i, 'in_progress', 'normal',
    '87300000-0001-0000-0000-000000000001', '87300000-0000-0000-0000-000000000001', '87300000-0002-0000-0000-000000000001', 'private'
  FROM generate_series(1,100) i;
-- Each live task gets 5 watchers, plus an assignee distinct from the
-- creator (user 2) -- the assignee, not the creator, completes each
-- live task below, so the specific_users(owner) event is NOT
-- self-excluded (creator <> actor) and both task.completed.v1 events
-- genuinely fire at scale, exactly as a real assignee-completes-their-
-- own-assigned-task flow would.
INSERT INTO task_watchers (task_id, user_id)
  SELECT ('87300000-0007-0000-2000-' || lpad(i::text,12,'0'))::UUID, ('87300000-0001-0000-0000-'||lpad(w::text,12,'0'))::UUID
  FROM generate_series(1,100) i, generate_series(1,5) w;
INSERT INTO task_assignments (task_id, user_id, assigned_by, assigned_at, is_active)
  SELECT ('87300000-0007-0000-2000-' || lpad(i::text,12,'0'))::UUID, '87300000-0001-0000-0000-000000000002', '87300000-0001-0000-0000-000000000001', NOW(), TRUE
  FROM generate_series(1,100) i;

-- 10,000 historical, already-cancelled Meetings (background evidence)
-- + 100 "live" meetings used for the actual timed probes, each with a
-- small participant set.
INSERT INTO meetings (id, organization_id, created_by, title, meeting_type, status, visibility, timezone, start_at, end_at, cancelled_by, cancelled_at)
  SELECT ('87300000-0008-0000-1000-' || lpad(i::text,12,'0'))::UUID, '87300000-0000-0000-0000-000000000001',
    ('87300000-0001-0000-0000-'||lpad(((i%50)+1)::text,12,'0'))::UUID, 'Background meeting '||i, 'general', 'cancelled', 'participants',
    'Indian/Maldives', now() - (i||' minutes')::interval, now() - (i||' minutes')::interval + interval '1 hour',
    ('87300000-0001-0000-0000-'||lpad(((i%50)+1)::text,12,'0'))::UUID, now() - (i||' minutes')::interval
  FROM generate_series(1,10000) i;

INSERT INTO meetings (id, organization_id, created_by, title, meeting_type, status, visibility, timezone, start_at, end_at)
  SELECT ('87300000-0008-0000-2000-' || lpad(i::text,12,'0'))::UUID, '87300000-0000-0000-0000-000000000001',
    '87300000-0001-0000-0000-000000000001', 'Live meeting '||i, 'general', 'scheduled', 'participants',
    'Indian/Maldives', now() + interval '1 day', now() + interval '1 day 1 hour'
  FROM generate_series(1,100) i;
INSERT INTO meeting_participants (meeting_id, user_id, participant_role, is_organizer, invited_by, invitation_status)
  SELECT ('87300000-0008-0000-2000-' || lpad(i::text,12,'0'))::UUID, '87300000-0001-0000-0000-000000000001', 'organizer', TRUE, '87300000-0001-0000-0000-000000000001', 'accepted'
  FROM generate_series(1,100) i;
INSERT INTO meeting_participants (meeting_id, user_id, participant_role, is_organizer, invited_by, invitation_status)
  SELECT ('87300000-0008-0000-2000-' || lpad(i::text,12,'0'))::UUID, ('87300000-0001-0000-0000-'||lpad(p::text,12,'0'))::UUID, 'attendee', FALSE, '87300000-0001-0000-0000-000000000001', 'accepted'
  FROM generate_series(1,100) i, generate_series(1,5) p
  WHERE p <> 1;

-- 100,000 background, already-completed outbox rows (unrelated
-- events, realistic table-scale pressure on the claim/dedup indexes).
INSERT INTO platform_outbox_events (event_type, source_module, source_record_type, source_record_id, organization_id, correlation_id, occurred_at, payload, idempotency_key, status, processed_at)
  SELECT 'platform.generic_notification_request.v1','platform','platform', gen_random_uuid(), '87300000-0000-0000-0000-000000000001',
    gen_random_uuid(), now() - (i||' seconds')::interval,
    jsonb_build_object('notification_type','wf87p.bg.v1','title_template_key','x','template_params','{}'::JSONB,'priority','normal','target_type','specific_users','target_user_ids', jsonb_build_array(('87300000-0001-0000-0000-'||lpad(((i%50)+1)::text,12,'0'))::UUID)),
    gen_random_uuid(), 'completed', now() - (i||' seconds')::interval
  FROM generate_series(1,100000) i;

RESET ROLE;

-- ── Dimension 1: complete_task() atomic-enqueue overhead at scale --
-- 100 real complete_task() calls (each producing 2 outbox events)
-- against a 100,000+-row outbox table. ─────────────────────────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; i INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87300000-0001-0000-0000-000000000002"}',true);
  v_start := clock_timestamp();
  FOR i IN 1..100 LOOP
    PERFORM complete_task(('87300000-0007-0000-2000-' || lpad(i::text,12,'0'))::UUID, NULL);
  END LOOP;
  RESET ROLE;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_ms > 10000 THEN RAISE EXCEPTION '100 complete_task() calls (each with its own atomic 2-event enqueue) took %ms, expected well under 10000ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 1: 100 complete_task() calls with atomic task.completed.v1 enqueue (against a 120,100+-row outbox table) took %ms', v_ms;
END $$;

-- ── Dimension 2: update_meeting() reschedule-enqueue overhead ──────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; i INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87300000-0001-0000-0000-000000000001"}',true);
  v_start := clock_timestamp();
  FOR i IN 1..100 LOOP
    PERFORM update_meeting(p_meeting_id := ('87300000-0008-0000-2000-' || lpad(i::text,12,'0'))::UUID, p_start_at := now()+interval '10 day', p_end_at := now()+interval '10 day 1 hour');
  END LOOP;
  RESET ROLE;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_ms > 10000 THEN RAISE EXCEPTION '100 update_meeting() reschedule calls took %ms, expected well under 10000ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 2: 100 update_meeting() reschedule calls with atomic meetings.rescheduled.v1 enqueue took %ms', v_ms;
END $$;

-- ── Dimension 3: cancel_meeting() enqueue overhead ──────────────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; i INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87300000-0001-0000-0000-000000000001"}',true);
  v_start := clock_timestamp();
  FOR i IN 1..100 LOOP
    PERFORM cancel_meeting(('87300000-0008-0000-2000-' || lpad(i::text,12,'0'))::UUID, 'perf test cancel');
  END LOOP;
  RESET ROLE;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_ms > 10000 THEN RAISE EXCEPTION '100 cancel_meeting() calls took %ms, expected well under 10000ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 3: 100 cancel_meeting() calls with atomic meetings.cancelled.v1 enqueue took %ms', v_ms;
END $$;

-- ── Dimension 4: idempotency-key uniqueness lookup uses its existing
-- index, not a sequential scan, against the 100,000+-row table. ────
DO $$
DECLARE v_row RECORD; v_plan TEXT := '';
BEGIN
  FOR v_row IN EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT 1 FROM platform_outbox_events
    WHERE source_module = 'tasks' AND source_record_type = 'task'
      AND source_record_id = '87300000-0007-0000-2000-000000000001'::UUID
      AND event_type = 'task.completed.v1'
      AND idempotency_key = gen_random_uuid()
  LOOP
    v_plan := v_plan || v_row."QUERY PLAN" || E'\n';
  END LOOP;
  RAISE NOTICE 'Dimension 4 EXPLAIN (idempotency-key uniqueness lookup): %', v_plan;
  IF v_plan ILIKE '%Seq Scan on platform_outbox_events%' THEN
    RAISE EXCEPTION 'idempotency-key lookup used a sequential scan against a 120,000+-row table instead of the existing unique index';
  END IF;
END $$;

-- ── Dimension 5: draining 200 real Phase 1.4B events (100
-- task.completed.v1-pair-halves already enqueued above, i.e. 200
-- events from dimension 1, plus 100 meetings.cancelled.v1 from
-- dimension 3) via the real, unmodified worker entry point. ────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_completed INTEGER := 0; v_batch RECORD; v_iteration INTEGER; v_rows_in_call INTEGER;
BEGIN
  v_start := clock_timestamp();
  FOR v_iteration IN 1..300 LOOP
    EXIT WHEN v_completed >= 300;
    v_rows_in_call := 0;
    FOR v_batch IN SELECT * FROM process_platform_outbox_batch(200, 'wf87p-worker') LOOP
      v_rows_in_call := v_rows_in_call + 1;
      IF v_batch.event_type IN ('task.completed.v1','meetings.cancelled.v1') THEN v_completed := v_completed + 1; END IF;
    END LOOP;
    EXIT WHEN v_rows_in_call = 0;
  END LOOP;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_completed < 250 THEN RAISE EXCEPTION 'expected at least 250 Phase 1.4B events drained (200 task.completed.v1 + 100 meetings.cancelled.v1), got %', v_completed; END IF;
  IF v_ms > 30000 THEN RAISE EXCEPTION 'draining % Phase 1.4B events took %ms, expected well under 30000ms', v_completed, v_ms; END IF;
  RAISE NOTICE 'Dimension 5: draining % real Phase 1.4B events via the unmodified process_platform_outbox_batch() worker entry point took %ms', v_completed, v_ms;
END $$;

-- ── Dimension 6: task_watchers/meeting_participants resolution for
-- the new event types remains index-backed at scale (reusing the
-- same access paths already measured in Phase 1.4A -- confirming no
-- regression from adding new event producers on top of them). ──────
DO $$
DECLARE v_row RECORD; v_plan TEXT := '';
BEGIN
  FOR v_row IN EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT tw.user_id FROM task_watchers tw WHERE tw.task_id = '87300000-0007-0000-2000-000000000001'::UUID
  LOOP
    v_plan := v_plan || v_row."QUERY PLAN" || E'\n';
  END LOOP;
  RAISE NOTICE 'Dimension 6 EXPLAIN (task_watchers lookup for a task.completed.v1-sourced resolution): %', v_plan;
  IF v_plan ILIKE '%Seq Scan on task_watchers%' THEN
    RAISE EXCEPTION 'task_watchers resolution used a sequential scan instead of its existing idx_task_watchers_task index';
  END IF;
END $$;

DO $$ BEGIN
  RAISE NOTICE 'Task/Meeting notification event integration performance probes PASSED (6/6 dimensions within bounds)';
END $$;

ROLLBACK;
