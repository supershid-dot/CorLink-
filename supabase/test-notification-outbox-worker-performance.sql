-- CAP-003 Phase 1.3 notification outbox worker -- performance probes.
-- Disposable local PostgreSQL only. Scale: 100,900 platform_outbox_events
-- (100,000 completed -- large processed history/historical tail;
-- 500 pending, due now -- small pending subset actually drained via
-- real process_platform_outbox_batch calls; 200 pending with a future
-- next_attempt_at -- retryable subset; 200 dead_letter -- dead-letter
-- subset), 100,000 already-resolved notification_intents (historical
-- volume, on top of Phase 1.2's own already-measured 100,000-row
-- scale), 100,000 user_notifications alongside (background volume --
-- Phase 1.1's own performance suite already measures the 1M-row scale
-- for user_notifications' own access paths independently; Phase 1.3
-- introduces no new user_notifications-specific query, so re-proving
-- that scale here would add cost without new signal).
\set ON_ERROR_STOP on

INSERT INTO organizations(id,name,type,code) VALUES
 ('83300000-0000-0000-0000-000000000001','WF83P Org','authority','WF83P');
INSERT INTO auth.users(id,email) VALUES ('83300000-0001-0000-0000-000000000001','admin@wf83pt.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('83300000-0001-0000-0000-000000000001','83300000-0000-0000-0000-000000000001','WF83P-1','Admin','admin@wf83pt.local',true);

-- ── Bulk fixture 1: 100,000 completed outbox events + 100,000
--    already-resolved notification_intents (historical volume/scale). ──
INSERT INTO platform_outbox_events (
  id, event_type, source_module, source_record_type, source_record_id, organization_id,
  correlation_id, occurred_at, created_at, payload, status, processed_at, idempotency_key
)
SELECT
  ('83300000-0005-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'platform.wf83p_bulk.v1','platform','platform', gen_random_uuid(),
  '83300000-0000-0000-0000-000000000001',
  gen_random_uuid(), now() - (i || ' seconds')::interval, now() - (i || ' seconds')::interval,
  '{}'::JSONB, 'completed', now() - (i || ' seconds')::interval, gen_random_uuid()
FROM generate_series(1, 100000) i;

INSERT INTO notification_intents (
  id, outbox_event_id, organization_id, notification_type, title_template_key, template_params,
  source_module, source_record_type, source_record_id, priority,
  target_type, target_user_ids, target_key, status, resolved_at, resolved_count, skipped_count, created_at
)
SELECT
  ('83300000-0006-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  ('83300000-0005-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  '83300000-0000-0000-0000-000000000001',
  'platform.wf83p_bulk.v1','x.title','{}'::JSONB,
  'platform','platform', gen_random_uuid(), 'normal',
  'specific_users', ARRAY['83300000-0001-0000-0000-000000000001']::UUID[],
  '83300000-0001-0000-0000-000000000001',
  'resolved', now() - (i || ' seconds')::interval, 1, 0, now() - (i || ' seconds')::interval
FROM generate_series(1, 100000) i;

INSERT INTO user_notifications (
  recipient_user_id, organization_id, notification_type, title_template_key, template_params,
  source_module, source_record_type, source_record_id, outbox_event_id, priority, created_at, read_at
)
SELECT
  '83300000-0001-0000-0000-000000000001',
  '83300000-0000-0000-0000-000000000001',
  'platform.wf83p_bulk.v1','x.title','{}'::JSONB,
  'platform','platform', gen_random_uuid(),
  ('83300000-0005-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'normal', now() - (i || ' seconds')::interval, now() - (i || ' seconds')::interval
FROM generate_series(1, 100000) i;

-- ── Bulk fixture 2: 500 pending events, due now (small pending
--    subset -- the ones actually drained by real worker calls below). ──
INSERT INTO platform_outbox_events (
  id, event_type, source_module, source_record_type, source_record_id, organization_id,
  correlation_id, occurred_at, created_at, payload, status, idempotency_key
)
SELECT
  ('83300000-0007-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'platform.generic_notification_request.v1','platform','platform', gen_random_uuid(),
  '83300000-0000-0000-0000-000000000001',
  gen_random_uuid(), now(), now(),
  jsonb_build_object('notification_type','platform.wf83p_pending.v1','title_template_key','x.title',
    'target_type','specific_users','target_user_ids', jsonb_build_array('83300000-0001-0000-0000-000000000001')),
  'pending', gen_random_uuid()
FROM generate_series(1, 500) i;

-- ── Bulk fixture 3: 200 pending events with a future next_attempt_at
--    (retryable subset -- not yet due, already failed at least once). ──
INSERT INTO platform_outbox_events (
  id, event_type, source_module, source_record_type, source_record_id, organization_id,
  correlation_id, occurred_at, created_at, payload, status, attempt_count, next_attempt_at, last_error, idempotency_key
)
SELECT
  ('83300000-0008-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'platform.wf83p_unsupported.v1','platform','platform', gen_random_uuid(),
  '83300000-0000-0000-0000-000000000001',
  gen_random_uuid(), now() - (i||' minutes')::interval, now() - (i||' minutes')::interval,
  '{}'::JSONB, 'pending', 2, now() + ((i % 30) + 30 || ' minutes')::interval,
  'unsupported_event_type: platform.wf83p_unsupported.v1', gen_random_uuid()
FROM generate_series(1, 200) i;

-- ── Bulk fixture 4: 200 dead_letter events (dead-letter subset). ──
INSERT INTO platform_outbox_events (
  id, event_type, source_module, source_record_type, source_record_id, organization_id,
  correlation_id, occurred_at, created_at, payload, status, attempt_count, last_error, idempotency_key
)
SELECT
  ('83300000-0009-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'platform.wf83p_poison.v1','platform','platform', gen_random_uuid(),
  '83300000-0000-0000-0000-000000000001',
  gen_random_uuid(), now() - (i||' hours')::interval, now() - (i||' hours')::interval,
  '{}'::JSONB, 'dead_letter', 5, 'unsupported_event_type: platform.wf83p_poison.v1', gen_random_uuid()
FROM generate_series(1, 200) i;

ANALYZE platform_outbox_events;
ANALYZE notification_intents;
ANALYZE user_notifications;

DO $$ DECLARE v_count BIGINT; BEGIN
  SELECT count(*) INTO v_count FROM platform_outbox_events; RAISE NOTICE 'platform_outbox_events rows: %', v_count;
  SELECT count(*) FILTER (WHERE status='pending' AND next_attempt_at IS NULL) INTO v_count FROM platform_outbox_events; RAISE NOTICE '  pending, due now: %', v_count;
  SELECT count(*) FILTER (WHERE status='pending' AND next_attempt_at IS NOT NULL) INTO v_count FROM platform_outbox_events; RAISE NOTICE '  pending, retryable (future next_attempt_at): %', v_count;
  SELECT count(*) FILTER (WHERE status='dead_letter') INTO v_count FROM platform_outbox_events; RAISE NOTICE '  dead_letter: %', v_count;
  SELECT count(*) FILTER (WHERE status='completed') INTO v_count FROM platform_outbox_events; RAISE NOTICE '  completed (historical tail): %', v_count;
  SELECT count(*) INTO v_count FROM notification_intents; RAISE NOTICE 'notification_intents rows: %', v_count;
  SELECT count(*) INTO v_count FROM user_notifications; RAISE NOTICE 'user_notifications rows: %', v_count;
END $$;

-- ── Dimension 1: pending-work discovery ──────────────────────────────
DO $$
DECLARE v_line TEXT; v_plan TEXT := '';
BEGIN
  FOR v_line IN EXECUTE $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT id FROM platform_outbox_events_due_for_processing(25)$q$
  LOOP
    v_plan := v_plan || v_line || E'\n';
  END LOOP;
  IF v_plan ILIKE '%Seq Scan on platform_outbox_events%' THEN
    RAISE EXCEPTION 'expected pending-work discovery to use the partial pending index, got a sequential scan across 100,900 rows. Plan: %', v_plan;
  END IF;
  RAISE NOTICE 'Dimension 1 EXPLAIN (pending-work discovery, 100,900-row table, 500 due-now candidates): %', v_plan;
END $$;

-- ── Dimension 2: SKIP LOCKED claim + successful single-event
--    processing (full pipeline: claim, create_notification_intent,
--    resolve_notification_intent, materialize, mark completed). ──────
SET ROLE service_role;
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_row RECORD;
BEGIN
  SELECT * INTO v_row FROM process_platform_outbox_batch(1, 'perf-worker');
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 2 (SKIP LOCKED claim + full single-event pipeline, amid 100,900-row table): % ms, outcome=%', round(v_ms,2), v_row.outcome;
  IF v_row.outcome <> 'processed' THEN RAISE EXCEPTION 'expected the single claimed event to process successfully, got %', v_row.outcome; END IF;
  IF v_ms > 1000 THEN RAISE EXCEPTION 'single-event claim+process took %ms, expected well under 1000ms', v_ms; END IF;
END $$;
RESET ROLE;

-- ── Dimension 3: batch processing (full pipeline, 25 events at once). ──
SET ROLE service_role;
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM process_platform_outbox_batch(25, 'perf-worker');
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 3 (full pipeline, 25-event batch, amid 100,900-row table): % ms total, % ms/event, % events', round(v_ms,2), round(v_ms/GREATEST(v_count,1),3), v_count;
  IF v_count <> 25 THEN RAISE EXCEPTION 'expected exactly 25 events claimed in this batch, got %', v_count; END IF;
  IF v_ms > 5000 THEN RAISE EXCEPTION '25-event batch took %ms, expected well under 5000ms', v_ms; END IF;
END $$;
RESET ROLE;

-- ── Dimension 4: retry lookup (retryable subset -- pending with a
--    future next_attempt_at, amid the full table). ──────────────────
DO $$
DECLARE v_line TEXT; v_plan TEXT := '';
BEGIN
  FOR v_line IN EXECUTE $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT id, attempt_count, next_attempt_at, last_error FROM platform_outbox_events
    WHERE status = 'pending' AND next_attempt_at > now()
    ORDER BY next_attempt_at LIMIT 50$q$
  LOOP
    v_plan := v_plan || v_line || E'\n';
  END LOOP;
  RAISE NOTICE 'Dimension 4 EXPLAIN (retry/retryable-subset lookup, 200 of 100,900 rows): %', v_plan;
END $$;

-- ── Dimension 5: dead-letter lookup (dead_letter subset, amid the
--    full table). No dedicated status-only index exists (Phase 1.1
--    never added one, and dead_letter rows are expected to remain a
--    small, self-limiting, operator-visible subset -- per the
--    governing instruction, "add indexes only if measurements
--    demonstrate need"). This dimension measures whether that
--    assumption holds at 100,900-row scale rather than asserting it
--    a priori. ─────────────────────────────────────────────────────
-- The global dead_letter count is not asserted exactly: when this
-- suite runs as part of a larger cumulative regression sweep, other
-- suites (e.g. this milestone's own concurrency suite, scenario 5)
-- may legitimately dead-letter a handful of their own fixture rows
-- too. What is asserted precisely is that this suite's own 200
-- dead_letter fixture rows are present and counted correctly.
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_count INTEGER; v_own_count INTEGER; v_line TEXT; v_plan TEXT := '';
BEGIN
  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE status = 'dead_letter';
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  SELECT count(*) INTO v_own_count FROM platform_outbox_events
    WHERE status = 'dead_letter' AND id::text LIKE '83300000-0009-%';
  IF v_own_count <> 200 THEN RAISE EXCEPTION 'expected 200 of this suite''s own dead_letter fixture rows, got %', v_own_count; END IF;

  FOR v_line IN EXECUTE $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT id, attempt_count, last_error FROM platform_outbox_events
    WHERE status = 'dead_letter' ORDER BY created_at DESC LIMIT 50$q$
  LOOP
    v_plan := v_plan || v_line || E'\n';
  END LOOP;
  RAISE NOTICE 'Dimension 5 (dead-letter subset lookup, 200 of 100,900 rows): % ms (count), plan: %', round(v_ms,2), v_plan;
  IF v_ms > 200 THEN
    RAISE EXCEPTION 'dead-letter subset count took %ms at 100,900-row scale -- measurements now demonstrate a dedicated status index would be warranted, revisit before shipping', v_ms;
  END IF;
END $$;

-- ── Dimension 6: processing against the large historical tail --
--    drain the remaining ~474 due-now pending events (500 minus the
--    1 + 25 already claimed in Dimensions 2-3) via successive real
--    batch calls, confirming the 100,000-row completed backlog never
--    degrades discovery or claiming. ─────────────────────────────────
-- The global drain count is not asserted exactly: when this suite
-- runs as part of a larger cumulative regression sweep, other phases'
-- own disposable performance-fixture rows may still be sitting in the
-- shared pending queue (harmless to also drain here) and would
-- inflate the raw total beyond this suite's own 474 remaining
-- fixture rows. What is asserted precisely is that every one of THIS
-- suite's own fixture rows (the 83300000-0007-... id range) reaches
-- completed.
SET ROLE service_role;
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_total INTEGER := 0; v_count INTEGER; v_own_remaining INTEGER; v_i INTEGER := 0;
BEGIN
  LOOP
    SELECT count(*) INTO v_count FROM process_platform_outbox_batch(200, 'perf-worker');
    v_total := v_total + v_count;
    v_i := v_i + 1;
    SELECT count(*) INTO v_own_remaining FROM platform_outbox_events
      WHERE id::text LIKE '83300000-0007-%' AND status <> 'completed';
    EXIT WHEN v_own_remaining = 0 OR v_i > 200;
  END LOOP;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 6 (drain remaining due-now pending subset amid 100,900+-row table): % ms total, % events drained overall (%s own fixture rows all completed)', round(v_ms,2), v_total, CASE WHEN v_own_remaining = 0 THEN '474' ELSE v_own_remaining::text || ' NOT' END;
  IF v_own_remaining <> 0 THEN RAISE EXCEPTION 'expected all 474 of this suite''s own remaining due-now fixture rows to reach completed, % still do not', v_own_remaining; END IF;
  IF v_ms > 15000 THEN RAISE EXCEPTION 'draining the remaining pending subset took %ms amid the large historical tail, expected well under 15000ms', v_ms; END IF;
END $$;
RESET ROLE;

DO $$ BEGIN RAISE NOTICE 'Notification outbox worker performance probe PASSED'; END $$;
