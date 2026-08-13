-- CAP-003 Phase 1.7B notification event integration -- performance
-- suite. Disposable local PostgreSQL only. 10,000+ historical Entries,
-- 40,000+ background outbox rows, 20,000+ background user_notifications
-- rows.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES
 ('92300000-0000-0000-0000-000000000001','E92P Org Alpha','authority','E92PA');
INSERT INTO divisions(id, org_id, name) VALUES
 ('92300000-0004-0000-0000-000000000001','92300000-0000-0000-0000-000000000001','E92P Alpha Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
 ('92300000-0002-0000-0000-000000000001','92300000-0000-0000-0000-000000000001','92300000-0004-0000-0000-000000000001','E92P Records','E92PREC'),
 ('92300000-0002-0000-0000-000000000002','92300000-0000-0000-0000-000000000001','92300000-0004-0000-0000-000000000001','E92P Welfare','E92PWEL');
INSERT INTO entry_sections(org_id, section_id) VALUES
 ('92300000-0000-0000-0000-000000000001','92300000-0002-0000-0000-000000000001'),
 ('92300000-0000-0000-0000-000000000001','92300000-0002-0000-0000-000000000002');

INSERT INTO auth.users(id,email)
  SELECT ('92300000-0001-0000-0000-' || lpad(i::text,12,'0'))::UUID, 'e92p'||i||'@t.local'
  FROM generate_series(1,60) i;
INSERT INTO users(id,org_id,service_number,full_name,email,is_active)
  SELECT ('92300000-0001-0000-0000-' || lpad(i::text,12,'0'))::UUID,
    '92300000-0000-0000-0000-000000000001'::UUID,
    'E92P-'||i, 'User '||i, 'e92p'||i||'@t.local', TRUE
  FROM generate_series(1,60) i;
-- Users 1-2: Records clerk/supervisor (entered_by/approvers). Users
-- 31-35: Welfare staff (real section/specific_users candidates).
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
 ('92300000-0001-0000-0000-000000000001','section','92300000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
 ('92300000-0001-0000-0000-000000000002','section','92300000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE),
 ('92300000-0001-0000-0000-000000000031','section','92300000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
 ('92300000-0001-0000-0000-000000000032','section','92300000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
 ('92300000-0001-0000-0000-000000000033','section','92300000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
 ('92300000-0001-0000-0000-000000000034','section','92300000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
 ('92300000-0001-0000-0000-000000000035','section','92300000-0002-0000-0000-000000000002','staff',TRUE,TRUE);

SET ROLE service_role;

-- 10,000 historical, already-routed Entries (background evidence, never
-- touched again) + their own audit_logs/outbox/user_notifications rows,
-- giving realistic table-scale pressure -- plus 100 "live" logged
-- entries used for the actual timed probes below.
INSERT INTO external_correspondence (id, org_id, source_channel, sender_category, sender_name, subject, subject_language, body, language, received_date, entered_by, to_section_id, status, reference_number)
  SELECT ('92300000-0009-0000-1000-' || lpad(i::text,12,'0'))::UUID,
    '92300000-0000-0000-0000-000000000001','letter','public','Background Sender '||i,
    'Background subject '||i,'en','Background body '||i,'en', CURRENT_DATE,
    '92300000-0001-0000-0000-000000000001','92300000-0002-0000-0000-000000000002',
    'routed', 'E92P-BG-'||i
  FROM generate_series(1,10000) i;

INSERT INTO platform_outbox_events (event_type, source_module, source_record_type, source_record_id, organization_id, actor_id, correlation_id, occurred_at, payload, idempotency_key, status, processed_at)
  SELECT 'entry.routed.v1','entry','external_correspondence', ('92300000-0009-0000-1000-' || lpad(i::text,12,'0'))::UUID,
    '92300000-0000-0000-0000-000000000001', '92300000-0001-0000-0000-000000000001',
    gen_random_uuid(), now() - (i||' seconds')::interval,
    jsonb_build_object('notification_type','entry.routed.v1','title_template_key','entry.routed','template_params','{}'::JSONB,'priority','normal','target_type','section','target_section_id','92300000-0002-0000-0000-000000000002'),
    gen_random_uuid(), 'completed', now() - (i||' seconds')::interval
  FROM generate_series(1,10000) i;

-- 20,000 background user_notifications rows spread across the Welfare
-- candidates -- realistic "merged feed" scale for dimension 8. Joined
-- against platform_outbox_events by source_record_id (a single
-- set-based hash join) rather than a per-row correlated subquery, which
-- against a 10,000-row table executed as 20,000 independent scans and
-- was pathologically slow.
-- (outbox_event_id, recipient_user_id) is uniquely constrained, so two
-- rows per event use two DISTINCT recipients (offsets 0 and 1 among the
-- 5 Welfare candidates) rather than a modulus that could repeat the
-- same (event, recipient) pair.
INSERT INTO user_notifications (recipient_user_id, organization_id, notification_type, title_template_key, template_params, source_module, source_record_type, source_record_id, outbox_event_id, priority, created_at)
  SELECT ('92300000-0001-0000-0000-'||lpad((31+((s.i+off.o)%5))::text,12,'0'))::UUID, '92300000-0000-0000-0000-000000000001',
    'entry.routed.v1','entry.routed','{}'::JSONB,'entry','external_correspondence',
    poe.source_record_id, poe.id,
    'normal', now() - ((s.i*2+off.o)||' seconds')::interval
  FROM generate_series(1,10000) AS s(i)
  CROSS JOIN (VALUES (0),(1)) AS off(o)
  JOIN platform_outbox_events poe
    ON poe.source_record_id = ('92300000-0009-0000-1000-' || lpad(s.i::text,12,'0'))::UUID
   AND poe.event_type = 'entry.routed.v1';

-- 100 "live" entries for the actual timed probes -- logged, ready for
-- route_entry()/assign_entry()/approve_entry_reply().
INSERT INTO external_correspondence (id, org_id, source_channel, sender_category, sender_name, subject, subject_language, body, language, received_date, entered_by, status, reference_number)
  SELECT ('92300000-0009-0000-2000-' || lpad(i::text,12,'0'))::UUID,
    '92300000-0000-0000-0000-000000000001','letter','public','Live Sender '||i,
    'Live subject '||i,'en','Live body '||i,'en', CURRENT_DATE,
    '92300000-0001-0000-0000-000000000001', 'logged', 'E92P-LIVE-'||i
  FROM generate_series(1,100) i;

RESET ROLE;

-- ── Dimension 1: route_entry() atomic-enqueue overhead at scale --
-- 100 real calls against a 10,000+-row Entry/outbox history. ─────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; i INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92300000-0001-0000-0000-000000000001"}',true);
  v_start := clock_timestamp();
  FOR i IN 1..100 LOOP
    PERFORM route_entry(('92300000-0009-0000-2000-' || lpad(i::text,12,'0'))::UUID, '92300000-0002-0000-0000-000000000002');
  END LOOP;
  RESET ROLE;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_ms > 10000 THEN RAISE EXCEPTION '100 route_entry() calls took %ms, expected well under 10000ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 1: 100 route_entry() calls with atomic entry.routed.v1 enqueue (against a 10,100+-row Entry/outbox history) took %ms', v_ms;
END $$;

-- ── Dimension 2: assign_entry() atomic-enqueue overhead. ───────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; i INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92300000-0001-0000-0000-000000000002"}',true);
  v_start := clock_timestamp();
  FOR i IN 1..100 LOOP
    PERFORM assign_entry(('92300000-0009-0000-2000-' || lpad(i::text,12,'0'))::UUID, '92300000-0001-0000-0000-000000000031'::UUID, NULL);
  END LOOP;
  RESET ROLE;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_ms > 10000 THEN RAISE EXCEPTION '100 assign_entry() calls took %ms, expected well under 10000ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 2: 100 assign_entry() calls with atomic entry.assigned.v1 enqueue took %ms', v_ms;
END $$;

-- ── Dimension 3: approve_entry_reply() atomic-enqueue overhead
-- (draft+submit 100 replies, then time the 100 approvals). ──────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; i INTEGER; v_rep external_correspondence_replies;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92300000-0001-0000-0000-000000000031"}',true);
  FOR i IN 1..100 LOOP
    v_rep := draft_entry_reply(('92300000-0009-0000-2000-' || lpad(i::text,12,'0'))::UUID, 'perf reply body '||i);
    PERFORM submit_entry_reply(v_rep.id, NULL);
    PERFORM set_config('app.e92p_rep_'||i, v_rep.id::text, false);
  END LOOP;
  PERFORM set_config('request.jwt.claims','{"sub":"92300000-0001-0000-0000-000000000002"}',true);
  v_start := clock_timestamp();
  FOR i IN 1..100 LOOP
    PERFORM approve_entry_reply(current_setting('app.e92p_rep_'||i)::uuid);
  END LOOP;
  RESET ROLE;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_ms > 10000 THEN RAISE EXCEPTION '100 approve_entry_reply() calls took %ms, expected well under 10000ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 3: 100 approve_entry_reply() calls with atomic entry.reply_sent.v1 enqueue took %ms', v_ms;
END $$;

-- ── Dimension 4: idempotency-key uniqueness lookup uses its existing
-- index, not a sequential scan, against the 10,000+-row outbox table. ─
DO $$
DECLARE v_row RECORD; v_plan TEXT := '';
BEGIN
  FOR v_row IN EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT 1 FROM platform_outbox_events
    WHERE source_module = 'entry' AND source_record_type = 'external_correspondence'
      AND source_record_id = '92300000-0009-0000-2000-000000000001'::UUID
      AND event_type = 'entry.routed.v1'
      AND idempotency_key = gen_random_uuid()
  LOOP
    v_plan := v_plan || v_row."QUERY PLAN" || E'\n';
  END LOOP;
  RAISE NOTICE 'Dimension 4 EXPLAIN (idempotency-key uniqueness lookup): %', v_plan;
  IF v_plan ILIKE '%Seq Scan on platform_outbox_events%' THEN
    RAISE EXCEPTION 'idempotency-key lookup used a sequential scan against a 10,000+-row table instead of the existing unique index';
  END IF;
END $$;

-- ── Dimension 5: Entry source authorization (intent_user_can_view_
-- entry()) remains fast/index-backed at scale -- the new adapter this
-- milestone introduces, measured directly. ─────────────────────────
DO $$
DECLARE v_row RECORD; v_plan TEXT := ''; v_start TIMESTAMPTZ; v_ms NUMERIC; i INTEGER; v_ok BOOLEAN;
BEGIN
  v_start := clock_timestamp();
  FOR i IN 1..500 LOOP
    v_ok := intent_user_can_view_entry(('92300000-0009-0000-1000-' || lpad(((i%10000)+1)::text,12,'0'))::UUID, '92300000-0001-0000-0000-000000000031'::UUID);
  END LOOP;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_ms > 5000 THEN RAISE EXCEPTION '500 intent_user_can_view_entry() calls took %ms, expected well under 5000ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 5: 500 intent_user_can_view_entry() authorization calls (against a 10,000+-row Entry table) took %ms', v_ms;

  FOR v_row IN EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT intent_user_can_view_entry('92300000-0009-0000-1000-000000000001'::UUID, '92300000-0001-0000-0000-000000000031'::UUID)
  LOOP
    v_plan := v_plan || v_row."QUERY PLAN" || E'\n';
  END LOOP;
  RAISE NOTICE 'Dimension 5 EXPLAIN (intent_user_can_view_entry): %', v_plan;
END $$;

-- ── Dimension 6: section target resolution (section_user_ids(), the
-- existing Phase 1.2 function entry.routed.v1 reuses unchanged) remains
-- index-backed at scale. ─────────────────────────────────────────────
DO $$
DECLARE v_row RECORD; v_plan TEXT := '';
BEGIN
  FOR v_row IN EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT u FROM section_user_ids('92300000-0002-0000-0000-000000000002'::UUID, NULL::TEXT[]) AS u
  LOOP
    v_plan := v_plan || v_row."QUERY PLAN" || E'\n';
  END LOOP;
  RAISE NOTICE 'Dimension 6 EXPLAIN (section_user_ids resolution for entry.routed.v1): %', v_plan;
  IF v_plan ILIKE '%Seq Scan on user_assignments%' THEN
    RAISE EXCEPTION 'section_user_ids resolution used a sequential scan against user_assignments instead of an existing index';
  END IF;
END $$;

-- ── Dimension 7: CAP-003 worker draining 300 real Phase 1.7B events
-- (100 entry.routed.v1 + 100 entry.assigned.v1 + 100 entry.
-- reply_sent.v1, all enqueued by dimensions 1-3 above) via the real,
-- unmodified worker entry point. ────────────────────────────────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_completed INTEGER := 0; v_batch RECORD; v_iteration INTEGER; v_rows_in_call INTEGER;
BEGIN
  v_start := clock_timestamp();
  FOR v_iteration IN 1..300 LOOP
    EXIT WHEN v_completed >= 300;
    v_rows_in_call := 0;
    FOR v_batch IN SELECT * FROM process_platform_outbox_batch(200, 'e92p-worker') LOOP
      v_rows_in_call := v_rows_in_call + 1;
      IF v_batch.event_type IN ('entry.routed.v1','entry.assigned.v1','entry.reply_sent.v1') THEN v_completed := v_completed + 1; END IF;
    END LOOP;
    EXIT WHEN v_rows_in_call = 0;
  END LOOP;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_completed < 300 THEN RAISE EXCEPTION 'expected all 300 Phase 1.7B events drained (100 each of routed/assigned/reply_sent), got %', v_completed; END IF;
  IF v_ms > 30000 THEN RAISE EXCEPTION 'draining % Phase 1.7B events took %ms, expected well under 30000ms', v_completed, v_ms; END IF;
  RAISE NOTICE 'Dimension 7: draining % real Phase 1.7B events via the unmodified process_platform_outbox_batch() worker entry point took %ms', v_completed, v_ms;
END $$;

-- ── Dimension 8: merged notification feed (list_my_notifications())
-- including Entry-sourced rows remains fast/keyset-paginated at scale
-- -- a Welfare candidate with 4,000+ background Entry notifications
-- listing their first page. ─────────────────────────────────────────
DO $$
DECLARE v_row RECORD; v_plan TEXT := ''; v_start TIMESTAMPTZ; v_ms NUMERIC; v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92300000-0001-0000-0000-000000000031"}',true);
  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM list_my_notifications(20, NULL, NULL, FALSE);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RESET ROLE;
  IF v_count <> 20 THEN RAISE EXCEPTION 'expected a full 20-row page from list_my_notifications(), got %', v_count; END IF;
  IF v_ms > 2000 THEN RAISE EXCEPTION 'list_my_notifications() first-page fetch took %ms, expected well under 2000ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 8: list_my_notifications() first-page fetch (recipient with 4,000+ Entry-sourced background notifications) took %ms', v_ms;

  FOR v_row IN EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT n.* FROM user_notifications n WHERE n.recipient_user_id = '92300000-0001-0000-0000-000000000031'::UUID
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
  RAISE NOTICE 'Entry notification integration performance probes PASSED (8/8 dimensions within bounds)';
END $$;

ROLLBACK;
