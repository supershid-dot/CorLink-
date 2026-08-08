-- CAP-003 Phase 1.4 notification module integration foundation --
-- performance probes. Disposable local PostgreSQL only.
--
-- Scoped to what Phase 1.4 actually adds on top of Phase 1.1/1.2/1.3's
-- already-measured infrastructure (100k-row outbox/intent history,
-- 1M-row user_notifications -- not re-proven here): assign_task()'s
-- new atomic enqueue call at realistic assignment volume, intent_user_
-- can_view_task()'s query cost at realistic task/section/assignment
-- scale, the worker's registry-driven dispatch check overhead, and
-- draining a real batch of task.assigned.v1 events end to end.
\set ON_ERROR_STOP on

INSERT INTO organizations(id,name,type,code) VALUES ('85400000-0000-0000-0000-000000000001','WF85P Org','authority','WF85P');
INSERT INTO divisions(id, org_id, name) VALUES ('85400000-0004-0000-0000-000000000001','85400000-0000-0000-0000-000000000001','WF85P Div');
INSERT INTO sections(id, org_id, division_id, name, code)
SELECT ('85400000-0002-0000-0000-'||lpad(i::text,12,'0'))::uuid,'85400000-0000-0000-0000-000000000001','85400000-0004-0000-0000-000000000001','WF85P Sec '||i,'SP'||i
FROM generate_series(1,20) i;

INSERT INTO auth.users(id,email)
SELECT ('85400000-0001-0000-0000-'||lpad(i::text,12,'0'))::uuid, 'u'||i||'@wf85pt.local'
FROM generate_series(1,2000) i;
INSERT INTO users(id,org_id,service_number,full_name,email,is_active)
SELECT ('85400000-0001-0000-0000-'||lpad(i::text,12,'0'))::uuid,'85400000-0000-0000-0000-000000000001','WF85P-'||i,'User '||i,'u'||i||'@wf85pt.local',true
FROM generate_series(1,2000) i;
-- Assign each user to one of the 20 sections (round-robin) as staff.
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active)
SELECT ('85400000-0001-0000-0000-'||lpad(i::text,12,'0'))::uuid, 'section',
       ('85400000-0002-0000-0000-'||lpad(((i % 20)+1)::text,12,'0'))::uuid, 'staff', true, true
FROM generate_series(1,2000) i;

-- 20,000 tasks (1,000 per section), each with one active assignee and
-- one creator drawn from the same 2,000-user pool -- a realistic
-- production-scale slice of the tasks table for intent_user_can_view_task()
-- to search against.
INSERT INTO tasks (id, task_number, title, status, priority, created_by, organization_id, owning_section_id, visibility)
SELECT
  ('85400000-0007-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'WF85P-T'||i, 'WF85P bulk task '||i, 'open', 'normal',
  ('85400000-0001-0000-0000-'||lpad(((i % 2000)+1)::text,12,'0'))::uuid,
  '85400000-0000-0000-0000-000000000001',
  ('85400000-0002-0000-0000-'||lpad(((i % 20)+1)::text,12,'0'))::uuid,
  'section'
FROM generate_series(1,20000) i;

INSERT INTO task_assignments (task_id, user_id, assigned_by, assigned_at, is_active)
SELECT
  ('85400000-0007-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  ('85400000-0001-0000-0000-'||lpad(((i % 2000)+1)::text,12,'0'))::uuid,
  ('85400000-0001-0000-0000-'||lpad(((i % 2000)+1)::text,12,'0'))::uuid,
  now() - (i || ' seconds')::interval, true
FROM generate_series(1,20000) i;

-- A dedicated task/user pair, far from the front of the id space, for
-- the single-lookup latency probes below.
INSERT INTO tasks (id, task_number, title, status, priority, created_by, organization_id, owning_section_id, visibility)
VALUES ('85400000-0007-0000-0000-999999999999','WF85P-TX','WF85P probe task','open','normal',
        '85400000-0001-0000-0000-000000000001','85400000-0000-0000-0000-000000000001',
        '85400000-0002-0000-0000-000000000001','organization');
INSERT INTO task_assignments (task_id, user_id, assigned_by, is_active)
VALUES ('85400000-0007-0000-0000-999999999999','85400000-0001-0000-0000-000000000002','85400000-0001-0000-0000-000000000001',true);

ANALYZE tasks; ANALYZE task_assignments; ANALYZE user_assignments; ANALYZE users;

SET ROLE service_role;

-- ── Dimension 1: intent_user_can_view_task() single-candidate lookup
-- latency against the 20,000-row tasks table, exercised the ONLY way
-- it is ever reachable (through resolve_notification_intent, per the
-- test-suite convention already established by scenarios 7-16 of the
-- behavioral suite) ──────────────────────────────────────────────────
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC;
  v_event_id UUID; v_intent_id UUID; v_resolved INTEGER;
BEGIN
  v_event_id := platform_enqueue_outbox_event('task.assigned.v1','tasks','task','85400000-0007-0000-0000-999999999999',
    '85400000-0000-0000-0000-000000000001', NULL, gen_random_uuid(), NULL, NOW(),
    jsonb_build_object('notification_type','task.assigned.v1','title_template_key','task.assigned',
      'template_params','{}'::JSONB,'priority','normal','target_type','specific_users',
      'target_user_ids', jsonb_build_array('85400000-0001-0000-0000-000000000002')),
    gen_random_uuid());
  v_intent_id := create_notification_intent(v_event_id, 'task.assigned.v1','task.assigned','{}'::JSONB,'normal',
    'specific_users', ARRAY['85400000-0001-0000-0000-000000000002']::UUID[], NULL, NULL, NULL, NULL);
  SELECT resolved_count INTO v_resolved FROM resolve_notification_intent(v_intent_id);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  IF v_resolved <> 1 THEN RAISE EXCEPTION 'expected the probe assignee to resolve, got resolved_count=%', v_resolved; END IF;
  IF v_ms > 500 THEN RAISE EXCEPTION 'single-candidate task-sourced intent resolution took %ms against a 20,000-row tasks table, expected well under 500ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 1: single-candidate task.assigned.v1 resolution against 20,000 tasks took %ms', v_ms;
END $$;

-- ── Dimension 2: EXPLAIN on intent_user_can_view_task()'s own
-- task_assignments lookup -- confirms it uses the existing
-- task_assignments(task_id) index rather than a sequential scan ──────
DO $$
DECLARE v_plan TEXT; v_line TEXT;
BEGIN
  FOR v_line IN EXECUTE $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT 1 FROM task_assignments ta WHERE ta.task_id = '85400000-0007-0000-0000-999999999999'::uuid
      AND ta.user_id = '85400000-0001-0000-0000-000000000002'::uuid AND ta.is_active$q$
  LOOP v_plan := coalesce(v_plan,'') || v_line || E'\n'; END LOOP;
  IF v_plan ~* 'Seq Scan on task_assignments' THEN
    RAISE EXCEPTION 'task_assignments membership lookup used a sequential scan at 20,000-row scale: %', v_plan;
  END IF;
  RAISE NOTICE 'Dimension 2 EXPLAIN (task_assignments membership lookup, 20,000-row table): %', v_plan;
END $$;

-- ── Dimension 3: draining a batch of 1,000 real task.assigned.v1
-- outbox events end to end (enqueue already done in bulk below,
-- draining timed separately) ─────────────────────────────────────────
INSERT INTO platform_outbox_events (
  id, event_type, source_module, source_record_type, source_record_id, organization_id,
  correlation_id, occurred_at, created_at, payload, status, idempotency_key
)
SELECT
  ('85400000-0009-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'task.assigned.v1','tasks','task', ('85400000-0007-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  '85400000-0000-0000-0000-000000000001',
  gen_random_uuid(), now(), now(),
  jsonb_build_object('notification_type','task.assigned.v1','title_template_key','task.assigned',
    'template_params','{}'::JSONB,'priority','normal','target_type','specific_users',
    'target_user_ids', jsonb_build_array(('85400000-0001-0000-0000-'||lpad(((i % 2000)+1)::text,12,'0'))::text)),
  'pending', ('85400000-0009-0000-0000-'||lpad(i::text,12,'0'))::uuid
FROM generate_series(1,1000) i;

-- process_platform_outbox_batch()'s own p_limit is hard-clamped to
-- [1,200] regardless of caller input (Phase 1.3's own bound, unchanged
-- by Phase 1.4) -- draining 1000 events therefore takes multiple
-- calls, exactly as a real scheduler would.
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_batch INTEGER; v_completed INTEGER;
BEGIN
  LOOP
    SELECT count(*) INTO v_batch FROM process_platform_outbox_batch(200, 'wf85p-worker');
    EXIT WHEN v_batch = 0;
  END LOOP;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  -- Scoped to this dimension's own fixture id prefix (85400000-0009-...)
  -- rather than a blanket count, since Dimension 1's own probe event
  -- (created via direct create_notification_intent/resolve_notification_
  -- intent calls, never drained by the worker) is also still pending
  -- task.assigned.v1 at this point and would otherwise pollute the count.
  SELECT count(*) INTO v_completed FROM platform_outbox_events
    WHERE event_type = 'task.assigned.v1' AND status = 'completed'
      AND id::text LIKE '85400000-0009-0000-0000-%';
  IF v_completed <> 1000 THEN RAISE EXCEPTION 'expected all 1000 dimension-3 task.assigned.v1 events to complete, got %', v_completed; END IF;
  IF v_ms > 15000 THEN RAISE EXCEPTION 'draining 1000 real task.assigned.v1 events took %ms, expected well under 15000ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 3: draining 1000 real task.assigned.v1 events across hard-capped 200-event batches (registry-driven dispatch + task authorization adapter, each against a 20,000-row tasks table) took %ms', v_ms;
END $$;

-- ── Dimension 4: the registry-driven dispatch check itself
-- (EXISTS ... platform_event_type_registry WHERE event_type = ...)
-- uses the table's primary key, not a sequential scan -- proving the
-- Phase 1.4 dispatch change adds negligible per-event overhead ──────
DO $$
DECLARE v_plan TEXT; v_line TEXT;
BEGIN
  FOR v_line IN EXECUTE $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT 1 FROM platform_event_type_registry r
    WHERE r.event_type = 'task.assigned.v1' AND r.uses_generic_notification_envelope = TRUE$q$
  LOOP v_plan := coalesce(v_plan,'') || v_line || E'\n'; END LOOP;
  IF v_plan ~* 'Seq Scan' THEN
    RAISE EXCEPTION 'the registry-driven generic-envelope dispatch check did not use the primary key index: %', v_plan;
  END IF;
  RAISE NOTICE 'Dimension 4 EXPLAIN (registry-driven dispatch check, primary-key lookup): %', v_plan;
END $$;

-- ── Dimension 5: assign_task() end-to-end latency (new atomic
-- enqueue included) for 500 fresh assignments against the same
-- 20,000-row tasks table, called as an ordinary authenticated actor ──
RESET ROLE;
INSERT INTO tasks (id, task_number, title, status, priority, created_by, organization_id, owning_section_id, visibility)
SELECT
  ('85400000-0007-0000-0000-'||lpad((20000+i)::text,12,'0'))::uuid,
  'WF85P-D5-'||i, 'WF85P dim5 task '||i, 'open', 'normal',
  '85400000-0001-0000-0000-000000000001', '85400000-0000-0000-0000-000000000001',
  ('85400000-0002-0000-0000-'||lpad(((i % 20)+1)::text,12,'0'))::uuid, 'organization'
FROM generate_series(1,500) i;

-- The timed loop itself runs as an ordinary authenticated actor
-- (assign_task()'s only real caller shape); the completion count below
-- deliberately runs AFTER RESET ROLE, since platform_outbox_events has
-- RLS enabled with zero policies for authenticated (Phase 1.1's own
-- posture) -- an authenticated-role SELECT against it is silently
-- empty regardless of the table's actual contents, same class of
-- pitfall the RLS suite's own scenario 1 exercises deliberately.
CREATE TEMP TABLE wf85p_dim5_timing (elapsed_ms NUMERIC);
GRANT SELECT, INSERT ON wf85p_dim5_timing TO authenticated, service_role;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"85400000-0001-0000-0000-000000000001"}',false);
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; i INTEGER;
BEGIN
  v_start := clock_timestamp();
  FOR i IN 1..500 LOOP
    PERFORM assign_task(
      ('85400000-0007-0000-0000-'||lpad((20000+i)::text,12,'0'))::uuid,
      ('85400000-0001-0000-0000-'||lpad(((i % 2000)+1)::text,12,'0'))::uuid
    );
  END LOOP;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  INSERT INTO wf85p_dim5_timing VALUES (v_ms);
END $$;
RESET ROLE;

DO $$
DECLARE v_ms NUMERIC; v_count INTEGER;
BEGIN
  SELECT elapsed_ms INTO v_ms FROM wf85p_dim5_timing;
  SELECT count(*) INTO v_count FROM platform_outbox_events e
    WHERE e.event_type = 'task.assigned.v1'
      AND e.source_record_id IN (SELECT id FROM tasks WHERE task_number LIKE 'WF85P-D5-%');
  IF v_count <> 500 THEN RAISE EXCEPTION 'expected 500 new task.assigned.v1 outbox events from the assign_task() loop, got %', v_count; END IF;
  IF v_ms > 10000 THEN RAISE EXCEPTION '500 assign_task() calls (each including the new atomic outbox enqueue) took %ms, expected well under 10000ms', v_ms; END IF;
  RAISE NOTICE 'Dimension 5: 500 assign_task() calls (including the new atomic outbox enqueue each) took %ms total', v_ms;
END $$;

DO $$ BEGIN
  RAISE NOTICE 'Notification module integration foundation performance probes PASSED (5/5 dimensions within bounds)';
END $$;
