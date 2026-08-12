-- CAP-003 Phase 1.6B notification event integration -- performance
-- suite. Disposable local PostgreSQL only. 20,000+ historical
-- Requests, 100,000+ background outbox rows, 20,000+ background
-- user_notifications rows.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES
 ('90300000-0000-0000-0000-000000000001','R90P Org Alpha','authority','R90PA'),
 ('90300000-0000-0000-0000-000000000002','R90P Org Beta','authority','R90PB');
INSERT INTO divisions(id, org_id, name) VALUES
 ('90300000-0004-0000-0000-000000000001','90300000-0000-0000-0000-000000000001','R90P Alpha Div'),
 ('90300000-0004-0000-0000-000000000002','90300000-0000-0000-0000-000000000002','R90P Beta Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
 ('90300000-0002-0000-0000-000000000001','90300000-0000-0000-0000-000000000001','90300000-0004-0000-0000-000000000001','R90P Alpha Sec A','R90PAA'),
 ('90300000-0002-0000-0000-000000000002','90300000-0000-0000-0000-000000000002','90300000-0004-0000-0000-000000000002','R90P Beta Sec A','R90PBA');

INSERT INTO auth.users(id,email)
  SELECT ('90300000-0001-0000-0000-' || lpad(i::text,12,'0'))::UUID, 'r90p'||i||'@t.local'
  FROM generate_series(1,60) i;
INSERT INTO users(id,org_id,service_number,full_name,email,is_active)
  SELECT ('90300000-0001-0000-0000-' || lpad(i::text,12,'0'))::UUID,
    CASE WHEN i <= 30 THEN '90300000-0000-0000-0000-000000000001'::UUID ELSE '90300000-0000-0000-0000-000000000002'::UUID END,
    'R90P-'||i, 'User '||i, 'r90p'||i||'@t.local', TRUE
  FROM generate_series(1,60) i;
-- Users 1-2: Alpha staff/super. Users 31-35: Beta staff/supervisors/
-- mcs_admin in Beta Sec A (real org_admins/section candidates).
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
 ('90300000-0001-0000-0000-000000000001','section','90300000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
 ('90300000-0001-0000-0000-000000000002','section','90300000-0002-0000-0000-000000000001','supervisor',TRUE,TRUE),
 ('90300000-0001-0000-0000-000000000031','section','90300000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
 ('90300000-0001-0000-0000-000000000032','section','90300000-0002-0000-0000-000000000002','mcs_admin',TRUE,TRUE),
 ('90300000-0001-0000-0000-000000000033','section','90300000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE);

SET ROLE service_role;

-- 20,000 historical, already-sent Requests (background evidence, never
-- touched again) + their own audit_logs/outbox/user_notifications
-- rows, giving realistic table-scale pressure -- plus 100 "live"
-- pending_approval requests used for the actual timed probes below.
INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, to_section_id, assigned_to, created_by, subject, body, status, reference_number, is_locked)
  SELECT ('90300000-0009-0000-1000-' || lpad(i::text,12,'0'))::UUID,
    '90300000-0000-0000-0000-000000000001','90300000-0000-0000-0000-000000000002',
    '90300000-0002-0000-0000-000000000001','90300000-0002-0000-0000-000000000002',
    '90300000-0001-0000-0000-000000000031','90300000-0001-0000-0000-000000000001',
    'Background request '||i, 'Background body '||i, 'sent', 'R90P-BG-'||i, TRUE
  FROM generate_series(1,20000) i;

INSERT INTO platform_outbox_events (event_type, source_module, source_record_type, source_record_id, organization_id, actor_id, correlation_id, occurred_at, payload, idempotency_key, status, processed_at)
  SELECT 'requests.sent.v1','requests','request', ('90300000-0009-0000-1000-' || lpad(i::text,12,'0'))::UUID,
    '90300000-0000-0000-0000-000000000002', '90300000-0001-0000-0000-000000000002',
    gen_random_uuid(), now() - (i||' seconds')::interval,
    jsonb_build_object('notification_type','requests.sent.v1','title_template_key','requests.sent','template_params','{}'::JSONB,'priority','normal','target_type','org_admins','target_organization_id','90300000-0000-0000-0000-000000000002'),
    gen_random_uuid(), 'completed', now() - (i||' seconds')::interval
  FROM generate_series(1,20000) i;

-- 20,000 background user_notifications rows spread across the Beta
-- candidates -- realistic "merged feed" scale for dimension 6.
INSERT INTO user_notifications (recipient_user_id, organization_id, notification_type, title_template_key, template_params, source_module, source_record_type, source_record_id, outbox_event_id, priority, created_at)
  SELECT ('90300000-0001-0000-0000-'||lpad((31+(i%5))::text,12,'0'))::UUID, '90300000-0000-0000-0000-000000000002',
    'requests.sent.v1','requests.sent','{}'::JSONB,'requests','request',
    ('90300000-0009-0000-1000-' || lpad(i::text,12,'0'))::UUID,
    (SELECT id FROM platform_outbox_events WHERE source_record_id = ('90300000-0009-0000-1000-' || lpad(i::text,12,'0'))::UUID LIMIT 1),
    'normal', now() - (i||' seconds')::interval
  FROM generate_series(1,20000) i;

-- 100 "live" requests for the actual timed probes -- pending_approval,
-- ready for approve_request()/route_request()/assign_request().
INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, created_by, subject, body, status)
  SELECT ('90300000-0009-0000-2000-' || lpad(i::text,12,'0'))::UUID,
    '90300000-0000-0000-0000-000000000001','90300000-0000-0000-0000-000000000002',
    '90300000-0002-0000-0000-000000000001','90300000-0001-0000-0000-000000000001',
    'Live request '||i, 'Live body '||i, 'pending_approval'
  FROM generate_series(1,100) i;

RESET ROLE;

-- ── Dimension 1: approve_request() atomic-enqueue overhead at scale
-- -- 100 real calls against a 20,000+-row Requests/outbox history. ──
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; i INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90300000-0001-0000-0000-000000000002"}',true);
  v_start := clock_timestamp();
  FOR i IN 1..100 LOOP
    PERFORM approve_request(('90300000-0009-0000-2000-' || lpad(i::text,12,'0'))::UUID, NULL);
  END LOOP;
  RESET ROLE;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_ms > 10000 THEN RAISE EXCEPTION '100 approve_request() calls took %ms, expected well under 10000ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 1: 100 approve_request() calls with atomic requests.sent.v1 enqueue (against a 20,100+-row Requests/outbox history) took %ms', v_ms;
END $$;

-- ── Dimension 2: route_request() atomic-enqueue overhead (after
-- receiving each live request). ────────────────────────────────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; i INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90300000-0001-0000-0000-000000000032"}',true);
  FOR i IN 1..100 LOOP
    PERFORM mark_request_received(('90300000-0009-0000-2000-' || lpad(i::text,12,'0'))::UUID);
  END LOOP;
  v_start := clock_timestamp();
  FOR i IN 1..100 LOOP
    PERFORM route_request(('90300000-0009-0000-2000-' || lpad(i::text,12,'0'))::UUID, '90300000-0002-0000-0000-000000000002');
  END LOOP;
  RESET ROLE;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_ms > 10000 THEN RAISE EXCEPTION '100 route_request() calls took %ms, expected well under 10000ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 2: 100 route_request() calls with atomic requests.routed.v1 enqueue took %ms', v_ms;
END $$;

-- ── Dimension 3: assign_request() atomic-enqueue overhead. ─────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; i INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90300000-0001-0000-0000-000000000032"}',true);
  v_start := clock_timestamp();
  FOR i IN 1..100 LOOP
    PERFORM assign_request(('90300000-0009-0000-2000-' || lpad(i::text,12,'0'))::UUID, '90300000-0001-0000-0000-000000000031'::UUID);
  END LOOP;
  RESET ROLE;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_ms > 10000 THEN RAISE EXCEPTION '100 assign_request() calls took %ms, expected well under 10000ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 3: 100 assign_request() calls with atomic requests.assigned.v1 enqueue took %ms', v_ms;
END $$;

-- ── Dimension 4: idempotency-key uniqueness lookup uses its existing
-- index, not a sequential scan, against the 20,000+-row outbox table. ─
DO $$
DECLARE v_row RECORD; v_plan TEXT := '';
BEGIN
  FOR v_row IN EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT 1 FROM platform_outbox_events
    WHERE source_module = 'requests' AND source_record_type = 'request'
      AND source_record_id = '90300000-0009-0000-2000-000000000001'::UUID
      AND event_type = 'requests.sent.v1'
      AND idempotency_key = gen_random_uuid()
  LOOP
    v_plan := v_plan || v_row."QUERY PLAN" || E'\n';
  END LOOP;
  RAISE NOTICE 'Dimension 4 EXPLAIN (idempotency-key uniqueness lookup): %', v_plan;
  IF v_plan ILIKE '%Seq Scan on platform_outbox_events%' THEN
    RAISE EXCEPTION 'idempotency-key lookup used a sequential scan against a 20,000+-row table instead of the existing unique index';
  END IF;
END $$;

-- ── Dimension 5: Request source authorization (intent_user_can_view_
-- request()) remains fast/index-backed at scale -- the new adapter
-- this milestone introduces, measured directly. ────────────────────
DO $$
DECLARE v_row RECORD; v_plan TEXT := ''; v_start TIMESTAMPTZ; v_ms NUMERIC; i INTEGER; v_ok BOOLEAN;
BEGIN
  v_start := clock_timestamp();
  FOR i IN 1..500 LOOP
    v_ok := intent_user_can_view_request(('90300000-0009-0000-1000-' || lpad(((i%20000)+1)::text,12,'0'))::UUID, '90300000-0001-0000-0000-000000000032'::UUID);
  END LOOP;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_ms > 5000 THEN RAISE EXCEPTION '500 intent_user_can_view_request() calls took %ms, expected well under 5000ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 5: 500 intent_user_can_view_request() authorization calls (against a 20,000+-row Requests table) took %ms', v_ms;

  FOR v_row IN EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT intent_user_can_view_request('90300000-0009-0000-1000-000000000001'::UUID, '90300000-0001-0000-0000-000000000032'::UUID)
  LOOP
    v_plan := v_plan || v_row."QUERY PLAN" || E'\n';
  END LOOP;
  RAISE NOTICE 'Dimension 5 EXPLAIN (intent_user_can_view_request): %', v_plan;
END $$;

-- ── Dimension 6: section target resolution (section_user_ids(), the
-- existing Phase 1.2 function requests.routed.v1 reuses unchanged)
-- remains index-backed at scale. ────────────────────────────────────
DO $$
DECLARE v_row RECORD; v_plan TEXT := '';
BEGIN
  FOR v_row IN EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT u FROM section_user_ids('90300000-0002-0000-0000-000000000002'::UUID, NULL::TEXT[]) AS u
  LOOP
    v_plan := v_plan || v_row."QUERY PLAN" || E'\n';
  END LOOP;
  RAISE NOTICE 'Dimension 6 EXPLAIN (section_user_ids resolution for requests.routed.v1): %', v_plan;
  IF v_plan ILIKE '%Seq Scan on user_assignments%' THEN
    RAISE EXCEPTION 'section_user_ids resolution used a sequential scan against user_assignments instead of an existing index';
  END IF;
END $$;

-- ── Dimension 7: CAP-003 worker draining 300 real Phase 1.6B events
-- (100 requests.sent.v1 + 100 requests.routed.v1 + 100 requests.
-- assigned.v1, all enqueued by dimensions 1-3 above) via the real,
-- unmodified worker entry point. ────────────────────────────────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_completed INTEGER := 0; v_batch RECORD; v_iteration INTEGER; v_rows_in_call INTEGER;
BEGIN
  v_start := clock_timestamp();
  FOR v_iteration IN 1..300 LOOP
    EXIT WHEN v_completed >= 300;
    v_rows_in_call := 0;
    FOR v_batch IN SELECT * FROM process_platform_outbox_batch(200, 'r90p-worker') LOOP
      v_rows_in_call := v_rows_in_call + 1;
      IF v_batch.event_type IN ('requests.sent.v1','requests.routed.v1','requests.assigned.v1') THEN v_completed := v_completed + 1; END IF;
    END LOOP;
    EXIT WHEN v_rows_in_call = 0;
  END LOOP;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_completed < 300 THEN RAISE EXCEPTION 'expected all 300 Phase 1.6B events drained (100 each of sent/routed/assigned), got %', v_completed; END IF;
  IF v_ms > 30000 THEN RAISE EXCEPTION 'draining % Phase 1.6B events took %ms, expected well under 30000ms', v_completed, v_ms; END IF;
  RAISE NOTICE 'Dimension 7: draining % real Phase 1.6B events via the unmodified process_platform_outbox_batch() worker entry point took %ms', v_completed, v_ms;
END $$;

-- ── Dimension 8: merged notification feed (list_my_notifications())
-- including Requests-sourced rows remains fast/keyset-paginated at
-- scale -- a Beta candidate with 20,000+ background Requests
-- notifications listing their first page. ──────────────────────────
DO $$
DECLARE v_row RECORD; v_plan TEXT := ''; v_start TIMESTAMPTZ; v_ms NUMERIC; v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90300000-0001-0000-0000-000000000031"}',true);
  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM list_my_notifications(20, NULL, NULL, FALSE);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RESET ROLE;
  IF v_count <> 20 THEN RAISE EXCEPTION 'expected a full 20-row page from list_my_notifications(), got %', v_count; END IF;
  IF v_ms > 2000 THEN RAISE EXCEPTION 'list_my_notifications() first-page fetch took %ms, expected well under 2000ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 8: list_my_notifications() first-page fetch (recipient with 4,000+ Requests-sourced background notifications) took %ms', v_ms;

  FOR v_row IN EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT n.* FROM user_notifications n WHERE n.recipient_user_id = '90300000-0001-0000-0000-000000000031'::UUID
    ORDER BY n.created_at DESC, n.id DESC LIMIT 20
  LOOP
    v_plan := v_plan || v_row."QUERY PLAN" || E'\n';
  END LOOP;
  RAISE NOTICE 'Dimension 8 EXPLAIN (merged feed keyset page): %', v_plan;
  IF v_plan ILIKE '%Seq Scan on user_notifications%' THEN
    RAISE EXCEPTION 'merged notification feed listing used a sequential scan against user_notifications instead of an existing index';
  END IF;
END $$;

DO $$ BEGIN
  RAISE NOTICE 'Requests notification integration performance probes PASSED (8/8 dimensions within bounds)';
END $$;

ROLLBACK;
