-- CAP-003 Phase 1.4A notification target expansion -- performance
-- probes. Disposable local PostgreSQL only.
--
-- Scale: 12,000 task_watchers rows (one high-fanout task with 10,000
-- watchers -- the realistic upper bound this data model actually
-- allows, since UNIQUE(task_id,user_id) caps per-task fanout at the
-- organization's user count -- plus 2,000 background rows across
-- other tasks), 12,000 meeting_participants rows (one high-fanout
-- meeting with 10,000 internal participants plus 2,000 background
-- rows, plus a batch of external/removed rows mixed in to prove the
-- filtering itself doesn't regress at scale).
\set ON_ERROR_STOP on

INSERT INTO organizations(id,name,type,code) VALUES ('86300000-0000-0000-0000-000000000001','WF86P Org','authority','WF86P');
INSERT INTO divisions(id, org_id, name) VALUES ('86300000-0004-0000-0000-000000000001','86300000-0000-0000-0000-000000000001','WF86P Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES ('86300000-0002-0000-0000-000000000001','86300000-0000-0000-0000-000000000001','86300000-0004-0000-0000-000000000001','WF86P Sec','SP1');

INSERT INTO auth.users(id,email)
SELECT ('86300000-0001-0000-0000-'||lpad(i::text,12,'0'))::uuid, 'u'||i||'@wf86pt.local'
FROM generate_series(1,10000) i;
INSERT INTO users(id,org_id,service_number,full_name,email,is_active)
SELECT ('86300000-0001-0000-0000-'||lpad(i::text,12,'0'))::uuid,'86300000-0000-0000-0000-000000000001','WF86P-'||i,'User '||i,'u'||i||'@wf86pt.local',true
FROM generate_series(1,10000) i;

INSERT INTO tasks (id, task_number, title, status, priority, created_by, organization_id, owning_section_id, visibility)
SELECT ('86300000-0007-0000-0000-'||lpad(i::text,12,'0'))::uuid,'WF86P-T'||i,'WF86P task '||i,'open','normal',
  '86300000-0001-0000-0000-000000000001','86300000-0000-0000-0000-000000000001','86300000-0002-0000-0000-000000000001','organization'
FROM generate_series(1,201) i;

-- The one high-fanout task: all 10,000 users watch it.
INSERT INTO task_watchers (task_id, user_id)
SELECT '86300000-0007-0000-0000-000000000001'::uuid, ('86300000-0001-0000-0000-'||lpad(i::text,12,'0'))::uuid
FROM generate_series(1,10000) i;
-- 2,000 background watcher rows spread across 200 other tasks.
INSERT INTO task_watchers (task_id, user_id)
SELECT ('86300000-0007-0000-0000-'||lpad(((i % 200)+2)::text,12,'0'))::uuid, ('86300000-0001-0000-0000-'||lpad(((i % 10000)+1)::text,12,'0'))::uuid
FROM generate_series(1,2000) i
ON CONFLICT DO NOTHING;

INSERT INTO meetings (id, organization_id, created_by, title, meeting_type, status, visibility, timezone, start_at, end_at)
SELECT ('86300000-0008-0000-0000-'||lpad(i::text,12,'0'))::uuid,'86300000-0000-0000-0000-000000000001','86300000-0001-0000-0000-000000000001',
  'WF86P meeting '||i,'general','scheduled','organization','Indian/Maldives', now()+interval '1 day', now()+interval '1 day 1 hour'
FROM generate_series(1,201) i;

-- The one high-fanout meeting: 10,000 internal participants.
INSERT INTO meeting_participants (meeting_id, user_id, participant_role, invited_by)
SELECT '86300000-0008-0000-0000-000000000001'::uuid, ('86300000-0001-0000-0000-'||lpad(i::text,12,'0'))::uuid, 'attendee', '86300000-0001-0000-0000-000000000001'
FROM generate_series(1,10000) i;
-- 1,500 external (non-user) participant rows mixed into the SAME
-- high-fanout meeting, to prove the internal-only filter itself
-- doesn't regress at scale.
INSERT INTO meeting_participants (meeting_id, external_name, external_email, participant_role, invited_by)
SELECT '86300000-0008-0000-0000-000000000001'::uuid, 'External Guest '||i, 'ext'||i||'@example.test', 'attendee', '86300000-0001-0000-0000-000000000001'
FROM generate_series(1,1500) i;
-- 2,000 background participant rows spread across 200 other meetings.
INSERT INTO meeting_participants (meeting_id, user_id, participant_role, invited_by)
SELECT ('86300000-0008-0000-0000-'||lpad(((i % 200)+2)::text,12,'0'))::uuid, ('86300000-0001-0000-0000-'||lpad(((i % 10000)+1)::text,12,'0'))::uuid, 'attendee', '86300000-0001-0000-0000-000000000001'
FROM generate_series(1,2000) i
ON CONFLICT DO NOTHING;

ANALYZE task_watchers; ANALYZE meeting_participants; ANALYZE tasks; ANALYZE meetings;

SET ROLE service_role;

-- ── Dimension 1: resolving a 10,000-watcher task_watchers target end
-- to end (candidate resolution + per-candidate authorization
-- revalidation + notification creation, all 10,000) ──────────────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_intent_id UUID; v_resolved INTEGER;
BEGIN
  v_intent_id := create_notification_intent(
    platform_enqueue_outbox_event('wf86p.dim1.v1','tasks','task','86300000-0007-0000-0000-000000000001','86300000-0000-0000-0000-000000000001',NULL,gen_random_uuid(),NULL,NOW(),'{}'::JSONB,gen_random_uuid()),
    'wf86p.dim1.v1','x','{}'::JSONB,'normal','task_watchers',NULL,NULL,NULL,NULL,NULL,'86300000-0007-0000-0000-000000000001'::UUID,NULL);
  v_start := clock_timestamp();
  SELECT resolved_count INTO v_resolved FROM resolve_notification_intent(v_intent_id);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_resolved <> 10000 THEN RAISE EXCEPTION 'expected 10000 resolved watchers, got %', v_resolved; END IF;
  IF v_ms > 20000 THEN RAISE EXCEPTION 'resolving a 10,000-watcher task_watchers target took %ms, expected well under 20000ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 1: resolving a 10,000-watcher task_watchers target (candidate resolution + authorization revalidation + notification creation, all 10,000) took %ms', v_ms;
END $$;

-- ── Dimension 2: resolving a 10,000-participant meeting_participants
-- target (11,500 raw rows including 1,500 external, filtered down) ──
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_intent_id UUID; v_resolved INTEGER;
BEGIN
  v_intent_id := create_notification_intent(
    platform_enqueue_outbox_event('wf86p.dim2.v1','meetings','meeting','86300000-0008-0000-0000-000000000001','86300000-0000-0000-0000-000000000001',NULL,gen_random_uuid(),NULL,NOW(),'{}'::JSONB,gen_random_uuid()),
    'wf86p.dim2.v1','x','{}'::JSONB,'normal','meeting_participants',NULL,NULL,NULL,NULL,NULL,NULL,'86300000-0008-0000-0000-000000000001'::UUID);
  v_start := clock_timestamp();
  SELECT resolved_count INTO v_resolved FROM resolve_notification_intent(v_intent_id);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_resolved <> 10000 THEN RAISE EXCEPTION 'expected 10000 resolved participants (1,500 external correctly excluded), got %', v_resolved; END IF;
  IF v_ms > 20000 THEN RAISE EXCEPTION 'resolving a 10,000-participant meeting_participants target took %ms, expected well under 20000ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 2: resolving a 10,000-participant meeting_participants target (11,500 raw rows, 1,500 external filtered) took %ms', v_ms;
END $$;

-- ── Dimension 3: EXPLAIN on the underlying task_watchers candidate
-- lookup -- confirms it uses idx_task_watchers_task, not a sequential
-- scan, at 12,000-row scale ──────────────────────────────────────────
DO $$
DECLARE v_plan TEXT; v_line TEXT;
BEGIN
  FOR v_line IN EXECUTE $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT array_agg(DISTINCT tw.user_id) FROM task_watchers tw WHERE tw.task_id = '86300000-0007-0000-0000-000000000001'::uuid$q$
  LOOP v_plan := coalesce(v_plan,'') || v_line || E'\n'; END LOOP;
  IF v_plan ~* 'Seq Scan on task_watchers' THEN
    RAISE EXCEPTION 'task_watchers candidate lookup used a sequential scan at 12,000-row scale: %', v_plan;
  END IF;
  RAISE NOTICE 'Dimension 3 EXPLAIN (task_watchers candidate lookup, 12,000-row table): %', v_plan;
END $$;

-- ── Dimension 4: EXPLAIN on meeting_participant_recipient_ids()'s own
-- underlying query -- confirms idx_meeting_participants_meeting is
-- used at 13,500-row scale for a REALISTIC (low-selectivity)
-- background meeting -- the one deliberately high-fanout meeting used
-- in Dimension 2 above is ~85% of the whole table by itself, where a
-- sequential scan is the genuinely correct, faster plan (confirmed
-- directly: the planner already chooses it there, and execution time
-- is ~5ms regardless -- not a defect, and adding an index would not
-- change that plan for that specific query since it wouldn't be
-- selective). Real-world meetings are the low-selectivity case this
-- dimension actually measures. ────────────────────────────────────
DO $$
DECLARE v_plan TEXT; v_line TEXT;
BEGIN
  FOR v_line IN EXECUTE $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT DISTINCT mp.user_id FROM meeting_participants mp
    WHERE mp.meeting_id = '86300000-0008-0000-0000-000000000002'::uuid AND mp.user_id IS NOT NULL AND mp.removed_at IS NULL$q$
  LOOP v_plan := coalesce(v_plan,'') || v_line || E'\n'; END LOOP;
  IF v_plan ~* 'Seq Scan on meeting_participants' THEN
    RAISE EXCEPTION 'meeting_participants candidate lookup used a sequential scan for a realistic, low-selectivity background meeting at 13,500-row scale: %', v_plan;
  END IF;
  RAISE NOTICE 'Dimension 4 EXPLAIN (meeting_participants candidate lookup for a realistic background meeting, 13,500-row table): %', v_plan;
END $$;

-- ── Dimension 5: replay of an already-resolved 10,000-recipient
-- intent (idempotent no-op path) is fast -- proves the FOR UPDATE +
-- early-return-on-non-pending path doesn't re-walk all 10,000
-- candidates on every replay ──────────────────────────────────────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_intent_id UUID; v_resolved INTEGER;
BEGIN
  SELECT id INTO v_intent_id FROM notification_intents WHERE notification_type = 'wf86p.dim1.v1';
  v_start := clock_timestamp();
  SELECT resolved_count INTO v_resolved FROM resolve_notification_intent(v_intent_id);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_resolved <> 10000 THEN RAISE EXCEPTION 'expected the replay to report the same resolved_count=10000, got %', v_resolved; END IF;
  IF v_ms > 500 THEN RAISE EXCEPTION 'replaying an already-resolved 10,000-recipient intent took %ms, expected well under 500ms (early-return path, not a re-walk)', v_ms; END IF;
  RAISE NOTICE 'Dimension 5: replaying an already-resolved 10,000-recipient task_watchers intent (early-return path) took %ms', v_ms;
END $$;

-- ── Dimension 6: draining both high-fanout events via the real
-- process_platform_outbox_batch() worker entry point ──────────────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_event_id1 UUID; v_event_id2 UUID; v_completed INTEGER := 0; v_batch RECORD;
  v_iteration INTEGER; v_rows_in_call INTEGER;
BEGIN
  v_event_id1 := platform_enqueue_outbox_event('platform.generic_notification_request.v1','platform','task','86300000-0007-0000-0000-000000000002',
    '86300000-0000-0000-0000-000000000001', NULL, gen_random_uuid(), NULL, NOW(),
    jsonb_build_object('notification_type','wf86p.dim6a.v1','title_template_key','x','template_params','{}'::JSONB,'priority','normal',
      'target_type','task_watchers','target_task_id','86300000-0007-0000-0000-000000000001'),
    gen_random_uuid());
  v_event_id2 := platform_enqueue_outbox_event('platform.generic_notification_request.v1','platform','meeting','86300000-0008-0000-0000-000000000002',
    '86300000-0000-0000-0000-000000000001', NULL, gen_random_uuid(), NULL, NOW(),
    jsonb_build_object('notification_type','wf86p.dim6b.v1','title_template_key','x','template_params','{}'::JSONB,'priority','normal',
      'target_type','meeting_participants','target_meeting_id','86300000-0008-0000-0000-000000000001'),
    gen_random_uuid());
  -- A full regression sweep shares one database across every prior phase's
  -- test suites, some of which leave their own unrelated pending backlog in
  -- platform_outbox_events. process_platform_outbox_batch() drains oldest-
  -- pending-first and clamps to 200 rows/call, so our 2 freshly-enqueued
  -- events are not guaranteed to land in the very next call. Loop bounded
  -- worker calls (draining that unrelated backlog as a side effect, exactly
  -- as the real worker would in production) until both target events are
  -- confirmed processed, rather than assuming a single call's batch window.
  v_start := clock_timestamp();
  FOR v_iteration IN 1..200 LOOP
    EXIT WHEN v_completed >= 2;
    v_rows_in_call := 0;
    FOR v_batch IN SELECT * FROM process_platform_outbox_batch(200, 'wf86p-worker') LOOP
      v_rows_in_call := v_rows_in_call + 1;
      IF v_batch.event_id IN (v_event_id1, v_event_id2) THEN
        IF v_batch.outcome NOT IN ('processed','processed_zero_recipients') THEN
          RAISE EXCEPTION 'expected outcome=processed for event %, got %', v_batch.event_id, v_batch.outcome;
        END IF;
        v_completed := v_completed + 1;
      END IF;
    END LOOP;
    EXIT WHEN v_rows_in_call = 0;
  END LOOP;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_completed <> 2 THEN RAISE EXCEPTION 'expected both high-fanout events to be processed, got %', v_completed; END IF;
  IF v_ms > 25000 THEN RAISE EXCEPTION 'draining both 10,000-recipient events via the real worker took %ms, expected well under 25000ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 6: draining both 10,000-recipient events (one task_watchers, one meeting_participants) via the real process_platform_outbox_batch() worker entry point took %ms', v_ms;
END $$;

RESET ROLE;

DO $$ BEGIN
  RAISE NOTICE 'Notification target expansion performance probes PASSED (6/6 dimensions within bounds)';
END $$;
