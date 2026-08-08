-- CAP-003 Phase 1.1 notification outbox persistence foundation --
-- performance probes. Disposable local PostgreSQL only. Scale:
-- 105,000 platform_outbox_events rows (2,000 genuinely pending,
-- the rest completed -- a realistic small live queue against a large
-- historical tail), 1,000,000 user_notifications rows spread across
-- 500 recipients (the general-volume access path), plus 5,000
-- dedicated notifications for ONE single heavy user (~4,900 read,
-- ~100 unread -- "large read history with small unread subset",
-- failure scenario 14 of docs/78 §22, exercised directly).
\set ON_ERROR_STOP on

INSERT INTO organizations(id,name,type,code) VALUES
 ('81400000-0000-0000-0000-000000000001','WF81P Org','authority','WF81P');
INSERT INTO auth.users(id,email)
  SELECT ('81400000-0001-'||lpad(i::text,4,'0')||'-0000-000000000001')::uuid, 'u'||i||'@wf81pt.local'
  FROM generate_series(1,500) i;
INSERT INTO users(id,org_id,service_number,full_name,email,is_active)
  SELECT ('81400000-0001-'||lpad(i::text,4,'0')||'-0000-000000000001')::uuid,
         '81400000-0000-0000-0000-000000000001','WF81P-'||i,'Bulk User '||i,'u'||i||'@wf81pt.local',true
  FROM generate_series(1,500) i;

-- The single heavy user for the "thousands of notifications, mostly
-- read, small unread subset" access path.
INSERT INTO auth.users(id,email) VALUES ('81400000-0002-0000-0000-000000000001','heavy@wf81pt.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active)
VALUES ('81400000-0002-0000-0000-000000000001','81400000-0000-0000-0000-000000000001','WF81P-HEAVY','Heavy User','heavy@wf81pt.local',true);

-- ── Bulk fixture: 100,000 outbox events for the general-volume
--    notification fan-out, 98,000 already 'completed', 2,000 still
--    genuinely 'pending' with next_attempt_at in the past (the live
--    queue the claim query must find quickly regardless of the
--    98,000-row completed tail sitting alongside it). ────────────────
INSERT INTO platform_outbox_events (
  id, event_type, source_module, source_record_type, source_record_id, organization_id,
  correlation_id, occurred_at, created_at, payload, status, next_attempt_at, processed_at, idempotency_key
)
SELECT
  ('81400000-0003-'||lpad((i/100000)::text,4,'0')||'-0000-'||lpad(i::text,12,'0'))::uuid,
  'platform.wf81p_bulk.v1','platform','wf81p_record', gen_random_uuid(),
  '81400000-0000-0000-0000-000000000001',
  gen_random_uuid(), now() - (i || ' seconds')::interval, now() - (i || ' seconds')::interval,
  '{}'::JSONB,
  CASE WHEN i <= 2000 THEN 'pending' ELSE 'completed' END,
  CASE WHEN i <= 2000 THEN now() - interval '5 minutes' ELSE NULL END,
  CASE WHEN i <= 2000 THEN NULL ELSE now() - (i || ' seconds')::interval END,
  gen_random_uuid()
FROM generate_series(1, 100000) i;

-- ── Bulk fixture: 1,000,000 user_notifications, 10 per outbox event
--    across 10 DISTINCT recipients (rotating offset into the 500-user
--    pool) -- satisfies the (outbox_event_id, recipient_user_id)
--    uniqueness constraint by construction (10 < 500, so the 10
--    rotating offsets per event never collide with each other). ─────
INSERT INTO user_notifications (
  recipient_user_id, organization_id, notification_type, title_template_key, template_params,
  source_module, source_record_type, source_record_id, outbox_event_id, priority, created_at, read_at
)
SELECT
  ('81400000-0001-'||lpad((1 + ((e + k) % 500))::text,4,'0')||'-0000-000000000001')::uuid,
  '81400000-0000-0000-0000-000000000001',
  'platform.wf81p_bulk.v1','x.title','{}'::JSONB,
  'platform','wf81p_record', gen_random_uuid(),
  ('81400000-0003-'||lpad((e/100000)::text,4,'0')||'-0000-'||lpad(e::text,12,'0'))::uuid,
  'normal', now() - (e || ' seconds')::interval,
  CASE WHEN k < 8 THEN now() - (e || ' seconds')::interval ELSE NULL END
FROM generate_series(1, 100000) e, generate_series(0, 9) k;

-- ── Dedicated heavy-user fixture: 5,000 notifications, ~4,900 read,
--    ~100 unread (the newest 100 stay unread -- the realistic shape
--    of "caught up on everything except what just arrived"). ────────
INSERT INTO platform_outbox_events (
  id, event_type, source_module, source_record_type, source_record_id, organization_id,
  correlation_id, occurred_at, created_at, payload, status, processed_at, idempotency_key
)
SELECT
  ('81400000-0004-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'platform.wf81p_heavy.v1','platform','wf81p_record', gen_random_uuid(),
  '81400000-0000-0000-0000-000000000001',
  gen_random_uuid(), now() - (i || ' minutes')::interval, now() - (i || ' minutes')::interval,
  '{}'::JSONB, 'completed', now() - (i || ' minutes')::interval, gen_random_uuid()
FROM generate_series(1, 5000) i;

INSERT INTO user_notifications (
  recipient_user_id, organization_id, notification_type, title_template_key, template_params,
  source_module, source_record_type, source_record_id, outbox_event_id, priority, created_at, read_at
)
SELECT
  '81400000-0002-0000-0000-000000000001', '81400000-0000-0000-0000-000000000001',
  'platform.wf81p_heavy.v1','x.title','{}'::JSONB,
  'platform','wf81p_record', gen_random_uuid(),
  ('81400000-0004-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'normal', now() - (i || ' minutes')::interval,
  CASE WHEN i > 100 THEN now() - (i || ' minutes')::interval ELSE NULL END
FROM generate_series(1, 5000) i;

ANALYZE platform_outbox_events;
ANALYZE user_notifications;

DO $$ DECLARE v_count BIGINT; BEGIN
  SELECT count(*) INTO v_count FROM platform_outbox_events; RAISE NOTICE 'platform_outbox_events rows: %', v_count;
  SELECT count(*) INTO v_count FROM user_notifications; RAISE NOTICE 'user_notifications rows: %', v_count;
END $$;

-- ── Dimension 1: pending outbox lookup ──────────────────────────────
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM (
    SELECT id FROM platform_outbox_events WHERE status = 'pending' AND next_attempt_at <= now()
    ORDER BY next_attempt_at LIMIT 100
  ) x;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 1 (pending outbox lookup, limit 100, against 100,000-row table with 2,000 pending): % ms, % rows', round(v_ms,2), v_count;
  IF v_ms > 500 THEN RAISE EXCEPTION 'pending outbox lookup took %ms, expected well under 500ms at this scale via the partial index', v_ms; END IF;
END $$;

DO $$
DECLARE v_line TEXT; v_plan TEXT := '';
BEGIN
  FOR v_line IN EXECUTE $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT id FROM platform_outbox_events WHERE status = 'pending' AND next_attempt_at <= now()
    ORDER BY next_attempt_at LIMIT 100$q$
  LOOP
    v_plan := v_plan || v_line || E'\n';
  END LOOP;
  IF v_plan NOT ILIKE '%idx_platform_outbox_events_pending%' AND v_plan ILIKE '%Seq Scan%' THEN
    RAISE EXCEPTION 'expected the pending-outbox partial index to be used, got a sequential scan. Plan: %', v_plan;
  END IF;
  RAISE NOTICE 'Dimension 1 EXPLAIN (idx_platform_outbox_events_pending, 100,000-row table): %', v_plan;
END $$;

-- ── Dimension 2: newest user notifications page (heavy user, 5,000 rows) ──
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"81400000-0002-0000-0000-000000000001"}',false);
  SELECT count(*) INTO v_count FROM (SELECT * FROM list_my_notifications(20, NULL, NULL, FALSE)) x;
  RESET ROLE;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 2 (newest-page list, limit 20, heavy user with 5,000 total notifications): % ms, % rows', round(v_ms,2), v_count;
  IF v_ms > 500 THEN RAISE EXCEPTION 'newest-page list took %ms, expected well under 500ms', v_ms; END IF;
END $$;

DO $$
DECLARE v_line TEXT; v_plan TEXT := '';
BEGIN
  FOR v_line IN EXECUTE $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT * FROM user_notifications
    WHERE recipient_user_id = '81400000-0002-0000-0000-000000000001'
    ORDER BY created_at DESC, id DESC LIMIT 20$q$
  LOOP
    v_plan := v_plan || v_line || E'\n';
  END LOOP;
  IF v_plan ILIKE '%Seq Scan on user_notifications%' THEN
    RAISE EXCEPTION 'expected an index-supported plan for the newest-page list, got a sequential scan. Plan: %', v_plan;
  END IF;
  RAISE NOTICE 'Dimension 2 EXPLAIN (recipient+created_at access path, 1,005,000-row table): %', v_plan;
END $$;

-- ── Dimension 3: unread count (heavy user) ──────────────────────────
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"81400000-0002-0000-0000-000000000001"}',false);
  v_count := count_my_unread_notifications();
  RESET ROLE;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 3 (unread count, heavy user, ~100 unread of 5,000 total): % ms, % unread', round(v_ms,2), v_count;
  IF v_count <> 100 THEN RAISE EXCEPTION 'expected exactly 100 unread for the heavy user fixture, got %', v_count; END IF;
  IF v_ms > 500 THEN RAISE EXCEPTION 'unread count took %ms, expected well under 500ms via the partial unread index', v_ms; END IF;
END $$;

DO $$
DECLARE v_line TEXT; v_plan TEXT := '';
BEGIN
  FOR v_line IN EXECUTE $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT count(*) FROM user_notifications
    WHERE recipient_user_id = '81400000-0002-0000-0000-000000000001' AND read_at IS NULL$q$
  LOOP
    v_plan := v_plan || v_line || E'\n';
  END LOOP;
  IF v_plan ILIKE '%Seq Scan on user_notifications%' THEN
    RAISE EXCEPTION 'expected the partial unread index to be used, got a sequential scan. Plan: %', v_plan;
  END IF;
  RAISE NOTICE 'Dimension 3 EXPLAIN (idx_user_notifications_recipient_unread, 1,005,000-row table): %', v_plan;
END $$;

-- ── Dimension 4: mark-read ──────────────────────────────────────────
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_id UUID; v_updated INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"81400000-0002-0000-0000-000000000001"}',false);
  SELECT id INTO v_id FROM user_notifications
    WHERE recipient_user_id = '81400000-0002-0000-0000-000000000001' AND read_at IS NULL LIMIT 1;
  UPDATE user_notifications SET read_at = now() WHERE id = v_id;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RESET ROLE;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 4 (mark-read, single row, 1,005,000-row table): % ms, % row(s) updated', round(v_ms,2), v_updated;
  IF v_ms > 200 THEN RAISE EXCEPTION 'mark-read took %ms, expected well under 200ms (primary-key UPDATE)', v_ms; END IF;
END $$;

-- ── Dimension 5: dedup lookup ────────────────────────────────────────
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_count INTEGER;
        v_module TEXT; v_rtype TEXT; v_rid UUID; v_etype TEXT; v_idem UUID;
BEGIN
  SELECT source_module, source_record_type, source_record_id, event_type, idempotency_key
    INTO v_module, v_rtype, v_rid, v_etype, v_idem
  FROM platform_outbox_events LIMIT 1;

  SELECT count(*) INTO v_count FROM platform_outbox_events
  WHERE source_module = v_module AND source_record_type = v_rtype AND source_record_id = v_rid
    AND event_type = v_etype AND idempotency_key = v_idem;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 5 (idempotency dedup lookup, 105,000-row table): % ms, % row(s) found', round(v_ms,2), v_count;
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 matching row for the dedup lookup, got %', v_count; END IF;
  IF v_ms > 200 THEN RAISE EXCEPTION 'dedup lookup took %ms, expected well under 200ms via the UNIQUE constraint''s backing index', v_ms; END IF;
END $$;

DO $$
DECLARE v_line TEXT; v_plan TEXT := '';
        v_module TEXT; v_rtype TEXT; v_rid UUID; v_etype TEXT; v_idem UUID;
BEGIN
  SELECT source_module, source_record_type, source_record_id, event_type, idempotency_key
    INTO v_module, v_rtype, v_rid, v_etype, v_idem
  FROM platform_outbox_events LIMIT 1;

  FOR v_line IN EXECUTE format(
    $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
       SELECT id FROM platform_outbox_events
       WHERE source_module = %L AND source_record_type = %L AND source_record_id = %L
         AND event_type = %L AND idempotency_key = %L$q$,
    v_module, v_rtype, v_rid, v_etype, v_idem)
  LOOP
    v_plan := v_plan || v_line || E'\n';
  END LOOP;
  IF v_plan ILIKE '%Seq Scan on platform_outbox_events%' THEN
    RAISE EXCEPTION 'expected the idempotency UNIQUE constraint''s backing index to be used, got a sequential scan. Plan: %', v_plan;
  END IF;
  RAISE NOTICE 'Dimension 5 EXPLAIN (idempotency-unique-backing index, 105,000-row table): %', v_plan;
END $$;

DO $$ BEGIN RAISE NOTICE 'Notification outbox persistence foundation performance probe PASSED'; END $$;
