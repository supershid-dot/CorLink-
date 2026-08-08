-- CAP-003 Phase 1.2 notification recipient resolution -- performance
-- probes. Disposable local PostgreSQL only. Scale: 100,000
-- notification_intents (bulk, already 'resolved' -- historical
-- volume/dedup-index scale) backed by 100,000 platform_outbox_events,
-- 200,000 user_notifications alongside (background volume, on top of
-- Phase 1.1's own already-measured 1M-row scale), plus ONE realistic
-- large-fan-out scenario: a 500-member section and a 500-participant
-- workflow instance, each resolved for real via
-- resolve_notification_intent() and timed directly -- "materialization
-- of tens/hundreds of recipients" exercised as an actual resolution
-- call, not merely simulated.
\set ON_ERROR_STOP on

INSERT INTO organizations(id,name,type,code) VALUES
 ('82300000-0000-0000-0000-000000000001','WF82P Org','authority','WF82P');
INSERT INTO divisions(id, org_id, name) VALUES ('82300000-0004-0000-0000-000000000001','82300000-0000-0000-0000-000000000001','WF82P Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES ('82300000-0002-0000-0000-000000000001','82300000-0000-0000-0000-000000000001','82300000-0004-0000-0000-000000000001','WF82P Big Section','BS1');

-- 501 users: 1 admin (creates the workflow) + 500 bulk section members.
INSERT INTO auth.users(id,email) VALUES ('82300000-0001-0000-0000-000000000001','admin@wf82pt.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('82300000-0001-0000-0000-000000000001','82300000-0000-0000-0000-000000000001','WF82P-ADMIN','Admin','admin@wf82pt.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('82300000-0001-0000-0000-000000000001','organization','82300000-0000-0000-0000-000000000001','authority_admin',true,true);

INSERT INTO auth.users(id,email)
  SELECT ('82300000-0001-'||lpad(i::text,4,'0')||'-0000-000000000002')::uuid, 'bulk'||i||'@wf82pt.local'
  FROM generate_series(1,500) i;
INSERT INTO users(id,org_id,service_number,full_name,email,is_active)
  SELECT ('82300000-0001-'||lpad(i::text,4,'0')||'-0000-000000000002')::uuid,
         '82300000-0000-0000-0000-000000000001','WF82P-B'||i,'Bulk Section Member '||i,'bulk'||i||'@wf82pt.local',true
  FROM generate_series(1,500) i;
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active)
  SELECT ('82300000-0001-'||lpad(i::text,4,'0')||'-0000-000000000002')::uuid,
         'section','82300000-0002-0000-0000-000000000001','staff',true,true
  FROM generate_series(1,500) i;

-- One real workflow instance (create_workflow_instance auto-seeds a
-- participant row for Admin), then 500 more participant rows bulk-
-- inserted directly (the same 500 bulk users, as viewers).
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"82300000-0001-0000-0000-000000000001"}',false);
\set ORG_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}}],"edges":[{"source":"start","target":"a_end","outcome":"started","priority":0,"default":false}]}\''
WITH made AS (SELECT * FROM create_workflow_definition(
  '82300000-0000-0000-0000-000000000001','wf82p_org','WF82P Flow','opaque_case', :ORG_PAYLOAD::jsonb, gen_random_uuid()))
SELECT version_id AS v INTO TEMP wf82p_def FROM made;
SELECT publish_workflow_definition_version((SELECT v FROM wf82p_def),0,gen_random_uuid());
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT v FROM wf82p_def),'opaque_case',gen_random_uuid(),
  '82300000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
SELECT create_workflow_instance AS id INTO TEMP wf82p_i1 FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf82p_i1),0,gen_random_uuid());
GRANT SELECT ON wf82p_i1 TO service_role;
RESET ROLE;

INSERT INTO workflow_participants (instance_id, user_id, participant_role, authority_source, created_by)
SELECT (SELECT id FROM wf82p_i1), ('82300000-0001-'||lpad(i::text,4,'0')||'-0000-000000000002')::uuid,
       'viewer', 'wf82p-perf-fixture', '82300000-0001-0000-0000-000000000001'
FROM generate_series(1,500) i;

-- ── Bulk fixture: 100,000 outbox events + 100,000 already-resolved
--    notification_intents (historical volume). ─────────────────────
INSERT INTO platform_outbox_events (
  id, event_type, source_module, source_record_type, source_record_id, organization_id,
  correlation_id, occurred_at, created_at, payload, status, processed_at, idempotency_key
)
SELECT
  ('82300000-0005-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'platform.wf82p_bulk.v1','platform','platform', gen_random_uuid(),
  '82300000-0000-0000-0000-000000000001',
  gen_random_uuid(), now() - (i || ' seconds')::interval, now() - (i || ' seconds')::interval,
  '{}'::JSONB, 'completed', now() - (i || ' seconds')::interval, gen_random_uuid()
FROM generate_series(1, 100000) i;

INSERT INTO notification_intents (
  id, outbox_event_id, organization_id, notification_type, title_template_key, template_params,
  source_module, source_record_type, source_record_id, priority,
  target_type, target_user_ids, target_key, status, resolved_at, resolved_count, skipped_count, created_at
)
SELECT
  ('82300000-0006-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  ('82300000-0005-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  '82300000-0000-0000-0000-000000000001',
  'platform.wf82p_bulk.v1','x.title','{}'::JSONB,
  'platform','platform', gen_random_uuid(), 'normal',
  'specific_users', ARRAY['82300000-0001-0000-0000-000000000001']::UUID[],
  '82300000-0001-0000-0000-000000000001',
  'resolved', now() - (i || ' seconds')::interval, 1, 0, now() - (i || ' seconds')::interval
FROM generate_series(1, 100000) i;

-- ── Bulk fixture: 200,000 user_notifications alongside (background
--    volume -- Phase 1.1's own performance suite already measures the
--    1M-row scale for user_notifications' own access paths; this is
--    enough to confirm Phase 1.2's own queries aren't accidentally
--    scanning it). ────────────────────────────────────────────────
INSERT INTO user_notifications (
  recipient_user_id, organization_id, notification_type, title_template_key, template_params,
  source_module, source_record_type, source_record_id, outbox_event_id, priority, created_at, read_at
)
SELECT
  '82300000-0001-0000-0000-000000000001',
  '82300000-0000-0000-0000-000000000001',
  'platform.wf82p_bulk.v1','x.title','{}'::JSONB,
  'platform','platform', gen_random_uuid(),
  ('82300000-0005-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'normal', now() - (i || ' seconds')::interval, now() - (i || ' seconds')::interval
FROM generate_series(1, 100000) i;
INSERT INTO user_notifications (
  recipient_user_id, organization_id, notification_type, title_template_key, template_params,
  source_module, source_record_type, source_record_id, outbox_event_id, priority, created_at, read_at
)
SELECT
  ('82300000-0001-'||lpad((1 + (i % 500))::text,4,'0')||'-0000-000000000002')::uuid,
  '82300000-0000-0000-0000-000000000001',
  'platform.wf82p_bulk.v1','x.title','{}'::JSONB,
  'platform','platform', gen_random_uuid(),
  ('82300000-0005-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'normal', now() - (i || ' seconds')::interval, now() - (i || ' seconds')::interval
FROM generate_series(1, 100000) i;

ANALYZE notification_intents;
ANALYZE platform_outbox_events;
ANALYZE user_notifications;
ANALYZE workflow_participants;
ANALYZE user_assignments;

DO $$ DECLARE v_count BIGINT; BEGIN
  SELECT count(*) INTO v_count FROM notification_intents; RAISE NOTICE 'notification_intents rows: %', v_count;
  SELECT count(*) INTO v_count FROM user_notifications; RAISE NOTICE 'user_notifications rows: %', v_count;
  SELECT count(*) INTO v_count FROM workflow_participants; RAISE NOTICE 'workflow_participants rows: %', v_count;
END $$;

-- ── Dimension 1: intent lookup ───────────────────────────────────────
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_id UUID;
BEGIN
  SELECT id INTO v_id FROM notification_intents WHERE id = '82300000-0006-0000-0000-000000050000';
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 1 (intent lookup by id, 100,000-row table): % ms', round(v_ms,2);
  IF v_ms > 200 THEN RAISE EXCEPTION 'intent lookup took %ms, expected well under 200ms (primary key)', v_ms; END IF;
END $$;

-- ── Dimension 2: dedup lookup ────────────────────────────────────────
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM notification_intents
    WHERE outbox_event_id = '82300000-0005-0000-0000-000000050000'
      AND target_type = 'specific_users' AND target_key = '82300000-0001-0000-0000-000000000001';
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 2 (intent dedup lookup, 100,000-row table): % ms, % row(s)', round(v_ms,2), v_count;
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 matching row, got %', v_count; END IF;
  IF v_ms > 200 THEN RAISE EXCEPTION 'dedup lookup took %ms, expected well under 200ms via the UNIQUE constraint''s backing index', v_ms; END IF;
END $$;

DO $$
DECLARE v_line TEXT; v_plan TEXT := '';
BEGIN
  FOR v_line IN EXECUTE $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT id FROM notification_intents
    WHERE outbox_event_id = '82300000-0005-0000-0000-000000050000'
      AND target_type = 'specific_users' AND target_key = '82300000-0001-0000-0000-000000000001'$q$
  LOOP
    v_plan := v_plan || v_line || E'\n';
  END LOOP;
  IF v_plan ILIKE '%Seq Scan on notification_intents%' THEN
    RAISE EXCEPTION 'expected the dedup UNIQUE constraint''s backing index to be used, got a sequential scan. Plan: %', v_plan;
  END IF;
  RAISE NOTICE 'Dimension 2 EXPLAIN (intent dedup UNIQUE-backing index, 100,000-row table): %', v_plan;
END $$;

-- ── Dimension 3: target resolution + authorization revalidation +
--    dedup + materialization of hundreds of recipients (section,
--    500 members) -- a REAL resolve_notification_intent() call. ────
SET ROLE service_role;
DO $$
DECLARE v_outbox_id UUID; v_intent_id UUID; v_start TIMESTAMPTZ; v_ms NUMERIC; v_result RECORD;
BEGIN
  v_outbox_id := platform_enqueue_outbox_event(
    'platform.wf82p_section.v1','platform','platform',gen_random_uuid(),
    '82300000-0000-0000-0000-000000000001'::UUID,NULL,gen_random_uuid(),NULL,now(),'{}'::JSONB,gen_random_uuid());
  v_intent_id := create_notification_intent(
    v_outbox_id,'platform.wf82p_section.v1','x.title','{}'::JSONB,'normal',
    'section', NULL, NULL, '82300000-0002-0000-0000-000000000001', NULL, NULL);

  v_start := clock_timestamp();
  SELECT * INTO v_result FROM resolve_notification_intent(v_intent_id);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;

  -- 501, not 500: section_user_ids()' own existing scope expansion
  -- (reused as-is) also includes Admin, whose org-wide authority_admin
  -- assignment covers every section in the org -- the same behavior
  -- already confirmed in the behavioral suite's scenario 7.
  RAISE NOTICE 'Dimension 3 (resolve_notification_intent, section target, 501 candidates, platform-sourced): % ms, status=%, resolved=%, skipped=%', round(v_ms,2), v_result.status, v_result.resolved_count, v_result.skipped_count;
  IF v_result.resolved_count <> 501 THEN RAISE EXCEPTION 'expected 501 resolved recipients (500 bulk section members + Admin via org-wide scope), got %', v_result.resolved_count; END IF;
  IF v_ms > 5000 THEN RAISE EXCEPTION 'resolving a 501-recipient section target took %ms, expected well under 5000ms', v_ms; END IF;
END $$;
RESET ROLE;

-- ── Dimension 4: target resolution + authorization revalidation +
--    dedup + materialization of hundreds of recipients
--    (workflow_participants, 501 members incl. Admin) -- a REAL
--    resolve_notification_intent() call, source_record_type=
--    workflow_instance (exercises the per-candidate
--    intent_user_can_view_workflow_instance revalidation, not merely
--    the platform-sourced always-true path Dimension 3 used). ──────
SET ROLE service_role;
DO $$
DECLARE v_instance_id UUID; v_outbox_id UUID; v_intent_id UUID; v_start TIMESTAMPTZ; v_ms NUMERIC; v_result RECORD;
BEGIN
  SELECT id INTO v_instance_id FROM wf82p_i1;
  v_outbox_id := platform_enqueue_outbox_event(
    'workflow.wf82p_participants.v1','workflow','workflow_instance',v_instance_id,
    '82300000-0000-0000-0000-000000000001'::UUID,NULL,gen_random_uuid(),NULL,now(),'{}'::JSONB,gen_random_uuid());
  v_intent_id := create_notification_intent(
    v_outbox_id,'workflow.wf82p_participants.v1','x.title','{}'::JSONB,'normal',
    'workflow_participants', NULL, NULL, NULL, v_instance_id, NULL);

  v_start := clock_timestamp();
  SELECT * INTO v_result FROM resolve_notification_intent(v_intent_id);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;

  RAISE NOTICE 'Dimension 4 (resolve_notification_intent, workflow_participants target, 501 candidates, per-candidate revalidation via intent_user_can_view_workflow_instance): % ms, status=%, resolved=%, skipped=%', round(v_ms,2), v_result.status, v_result.resolved_count, v_result.skipped_count;
  IF v_result.resolved_count <> 501 THEN RAISE EXCEPTION 'expected 501 resolved participants (Admin + 500 bulk viewers), got %', v_result.resolved_count; END IF;
  IF v_ms > 5000 THEN RAISE EXCEPTION 'resolving a 501-participant workflow_participants target took %ms, expected well under 5000ms', v_ms; END IF;
END $$;
RESET ROLE;

-- ── Dimension 5: EXPLAIN on the underlying per-candidate
--    authorization-revalidation query at scale (501-participant
--    instance, alongside 100,000 unrelated intents/outbox events). ──
DO $$
DECLARE v_instance_id UUID; v_line TEXT; v_plan TEXT := '';
BEGIN
  SELECT id INTO v_instance_id FROM wf82p_i1;
  FOR v_line IN EXECUTE format(
    $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
       SELECT 1 FROM workflow_participants p
       WHERE p.instance_id = %L AND p.user_id = %L AND p.ended_at IS NULL$q$,
    v_instance_id, '82300000-0001-0000-0000-000000000001')
  LOOP
    v_plan := v_plan || v_line || E'\n';
  END LOOP;
  IF v_plan ILIKE '%Seq Scan on workflow_participants%' THEN
    RAISE EXCEPTION 'expected an index-supported plan for per-candidate authorization revalidation, got a sequential scan. Plan: %', v_plan;
  END IF;
  RAISE NOTICE 'Dimension 5 EXPLAIN (per-candidate workflow_participants revalidation lookup, 501-participant instance): %', v_plan;
END $$;

DO $$ BEGIN RAISE NOTICE 'Notification recipient resolution performance probe PASSED'; END $$;
