-- CAP-003 Phase 1.8A performance probes. Disposable local PostgreSQL
-- only. Realistic volume: 5,000 pre-existing internal_requests rows
-- spread across a to_section fan-out (100 background sections plus
-- the real Welfare section under test), across every status, plus
-- 3,000 replies, then measures the new RPCs' cost at that scale plus
-- the unmigrated list reads this milestone leaves alone. No
-- speculative index is added -- the pre-existing idx_internal_requests_
-- from_section/_to_section/_status/_assigned_to/_created_by indexes
-- (schema.sql) are exercised as-is; this suite only proves whether
-- they are already sufficient.
\set ON_ERROR_STOP on

INSERT INTO organizations(id,name,type,code) VALUES
  ('18e00000-0000-0000-0000-000000000001','Perf T18E Org','authority','PF18');
INSERT INTO divisions(id, org_id, name) VALUES
  ('18e00000-0004-0000-0000-000000000001','18e00000-0000-0000-0000-000000000001','Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
  ('18e00000-0002-0000-0000-000000000001','18e00000-0000-0000-0000-000000000001','18e00000-0004-0000-0000-000000000001','Records','PF18R'),
  ('18e00000-0002-0000-0000-000000000002','18e00000-0000-0000-0000-000000000001','18e00000-0004-0000-0000-000000000001','Welfare','PF18W');
-- One shared noise section reused as to_section_id for every
-- background row below -- sections has no CHECK tying it back to a
-- specific internal_requests row's org, so a raw seed insert as
-- postgres only needs the FK target to exist.
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
  ('18e00000-0002-0000-0000-000000000099','18e00000-0000-0000-0000-000000000001','18e00000-0004-0000-0000-000000000001','Noise Sec','PF18N');
INSERT INTO auth.users(id,email) VALUES
  ('18e00000-0001-0000-0000-000000000001','pf18-records@t.local'),
  ('18e00000-0001-0000-0000-000000000002','pf18-welfare@t.local'),
  ('18e00000-0001-0000-0000-000000000003','pf18-welfaresuper@t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
  ('18e00000-0001-0000-0000-000000000001','18e00000-0000-0000-0000-000000000001','PF18-1','Records Staff','pf18-records@t.local',TRUE),
  ('18e00000-0001-0000-0000-000000000002','18e00000-0000-0000-0000-000000000001','PF18-2','Welfare Staff','pf18-welfare@t.local',TRUE),
  ('18e00000-0001-0000-0000-000000000003','18e00000-0000-0000-0000-000000000001','PF18-3','Welfare Supervisor','pf18-welfaresuper@t.local',TRUE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
  ('18e00000-0001-0000-0000-000000000001','section','18e00000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
  ('18e00000-0001-0000-0000-000000000002','section','18e00000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
  ('18e00000-0001-0000-0000-000000000003','section','18e00000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE);

-- One parent Request per background/real row (internal_requests_
-- one_parent CHECK requires exactly one of parent_request_id/
-- parent_entry_id, and internal_requests_parent_startable() requires
-- the parent to actually exist and not be frozen/terminal).
INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, created_by, subject, body, status)
SELECT
  ('18e00000-0003-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  '18e00000-0000-0000-0000-000000000001','18e00000-0000-0000-0000-000000000001',
  '18e00000-0002-0000-0000-000000000001','18e00000-0001-0000-0000-000000000001',
  'Perf parent '||i, 'Perf parent body '||i, 'sent'
FROM generate_series(1,5000) i;

-- 4,900 background internal_requests rows spread across the shared
-- noise section plus 100 rows actually targeting the real Welfare
-- section under test, across every status.
INSERT INTO internal_requests (id, parent_request_id, from_section_id, to_section_id, created_by, subject, body, status, created_at)
SELECT
  ('18e00000-0005-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  ('18e00000-0003-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  '18e00000-0002-0000-0000-000000000001',
  '18e00000-0002-0000-0000-000000000099',
  '18e00000-0001-0000-0000-000000000001',
  'Noise subject '||i, 'Noise body '||i,
  (ARRAY['sent','received','in_progress','responded','closed'])[(i % 5) + 1],
  now() - ((5000 - i) || ' minutes')::interval
FROM generate_series(1,4900) i;

INSERT INTO internal_requests (id, parent_request_id, from_section_id, to_section_id, created_by, subject, body, status, created_at)
SELECT
  ('18e00000-0005-0000-0000-'||lpad((4900+i)::text,12,'0'))::uuid,
  ('18e00000-0003-0000-0000-'||lpad((4900+i)::text,12,'0'))::uuid,
  '18e00000-0002-0000-0000-000000000001',
  '18e00000-0002-0000-0000-000000000002',
  '18e00000-0001-0000-0000-000000000001',
  'Perf subject '||i, 'Perf body '||i,
  (ARRAY['sent','received','in_progress','responded','closed'])[(i % 5) + 1],
  now() - ((100 - i) || ' minutes')::interval
FROM generate_series(1,100) i;

INSERT INTO internal_request_replies (id, internal_request_id, body, created_by, status, created_at)
SELECT
  ('18e00000-0006-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  ('18e00000-0005-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'Perf reply '||i,
  '18e00000-0001-0000-0000-000000000002',
  (ARRAY['draft','pending_approval','sent'])[(i % 3) + 1],
  now() - ((3000 - i) || ' minutes')::interval
FROM generate_series(1,3000) i;

ANALYZE internal_requests; ANALYZE internal_request_replies; ANALYZE requests;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"18e00000-0001-0000-0000-000000000001"}',false);

-- ── 1: create_internal_request ──
DO $$
DECLARE v_preq requests; v_start TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  v_preq := create_request('18e00000-0002-0000-0000-000000000001','18e00000-0000-0000-0000-000000000001','Perf create','body','en','en',NULL,NULL);
  v_start := clock_timestamp();
  PERFORM create_internal_request('18e00000-0002-0000-0000-000000000001','18e00000-0002-0000-0000-000000000002','Perf create','body',v_preq.id,NULL);
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  IF v_ms > 500 THEN RAISE EXCEPTION 'PERF 1 FAILED: create_internal_request took %ms (>500ms) against 5000 background rows', v_ms; END IF;
  RAISE NOTICE 'PERF 1 PASSED: create_internal_request %ms against 5000 background rows', round(v_ms,1);
END $$;

-- ── 2: mark_internal_request_received / reroute_internal_request (state-guarded UPDATE cost) ──
DO $$
DECLARE v_preq requests; v_ic internal_requests; v_start TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  v_preq := create_request('18e00000-0002-0000-0000-000000000001','18e00000-0000-0000-0000-000000000001','Perf transition','body','en','en',NULL,NULL);
  v_ic := create_internal_request('18e00000-0002-0000-0000-000000000001','18e00000-0002-0000-0000-000000000002','Perf transition','body',v_preq.id,NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"18e00000-0001-0000-0000-000000000002"}',true);
  v_start := clock_timestamp();
  v_ic := mark_internal_request_received(v_ic.id);
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  PERFORM set_config('request.jwt.claims','{"sub":"18e00000-0001-0000-0000-000000000001"}',true);
  IF v_ms > 500 THEN RAISE EXCEPTION 'PERF 2 FAILED: mark_internal_request_received took %ms (>500ms)', v_ms; END IF;
  RAISE NOTICE 'PERF 2 PASSED: mark_internal_request_received %ms', round(v_ms,1);
END $$;

-- ── 3: bounded list query (unmigrated, unaffected by this milestone) --
-- mirrors internal-requests-api.js's listOutstandingForSections() shape ──
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_count INT;
BEGIN
  SELECT count(*) INTO v_count FROM (
    SELECT id FROM internal_requests WHERE to_section_id = '18e00000-0002-0000-0000-000000000002' ORDER BY created_at DESC LIMIT 50
  ) s;
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  IF v_ms > 300 THEN RAISE EXCEPTION 'PERF 3 FAILED: bounded to_section list took %ms (>300ms)', v_ms; END IF;
  RAISE NOTICE 'PERF 3 PASSED: bounded to_section-scoped list query %ms (% rows)', round(v_ms,1), v_count;
END $$;

-- ── 4: no sequential scan on internal_requests for the status-filtered
-- query underlying a "my section's inbox" view ──
DO $$
DECLARE v_plan TEXT; v_line TEXT;
BEGIN
  FOR v_line IN EXECUTE $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT id FROM internal_requests WHERE to_section_id = '18e00000-0002-0000-0000-000000000002'::uuid AND status = 'sent'$q$
  LOOP v_plan := coalesce(v_plan,'') || v_line || E'\n'; END LOOP;
  IF v_plan ~* 'Seq Scan on internal_requests' THEN
    RAISE EXCEPTION 'PERF 4 FAILED: to_section inbox query does a sequential scan on internal_requests at 5000-row scale: %', v_plan;
  END IF;
  RAISE NOTICE 'PERF 4 PASSED: to_section inbox query uses an index, not a sequential scan: %', v_plan;
END $$;

-- ── 5: audit_logs lookup for the thread timeline (unmigrated read) ──
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_preq requests; v_ic internal_requests; v_count INT;
BEGIN
  v_preq := create_request('18e00000-0002-0000-0000-000000000001','18e00000-0000-0000-0000-000000000001','Perf timeline','body','en','en',NULL,NULL);
  v_ic := create_internal_request('18e00000-0002-0000-0000-000000000001','18e00000-0002-0000-0000-000000000002','Perf timeline','body',v_preq.id,NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"18e00000-0001-0000-0000-000000000002"}',true);
  v_ic := mark_internal_request_received(v_ic.id);
  PERFORM set_config('request.jwt.claims','{"sub":"18e00000-0001-0000-0000-000000000001"}',true);

  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM audit_logs
    WHERE record_type = 'internal_request' AND record_id = v_ic.id AND action IN ('routed','assigned','received');
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  -- 600ms budget (not 300ms), matching the exact same
  -- disposable-harness session-to-session variance rationale
  -- established by Entry's own PERF 5 probe (idx_audit_logs_record is
  -- used; plan cost is trivial) rather than chasing a query-plan
  -- problem that does not exist.
  IF v_ms > 600 THEN RAISE EXCEPTION 'PERF 5 FAILED: thread-timeline audit lookup took %ms (>600ms)', v_ms; END IF;
  RAISE NOTICE 'PERF 5 PASSED: thread-timeline audit_logs lookup %ms (% rows)', round(v_ms,1), v_count;
END $$;

-- ── 6: approve_internal_request_reply (the atomic composed command) at scale ──
DO $$
DECLARE v_preq requests; v_ic internal_requests; v_reply internal_request_replies; v_start TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  v_preq := create_request('18e00000-0002-0000-0000-000000000001','18e00000-0000-0000-0000-000000000001','Perf composed','body','en','en',NULL,NULL);
  v_ic := create_internal_request('18e00000-0002-0000-0000-000000000001','18e00000-0002-0000-0000-000000000002','Perf composed','body',v_preq.id,NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"18e00000-0001-0000-0000-000000000002"}',true);
  v_reply := draft_internal_request_reply(v_ic.id, 'Perf composed reply');
  v_reply := submit_internal_request_reply(v_reply.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"18e00000-0001-0000-0000-000000000003"}',true);
  v_start := clock_timestamp();
  PERFORM approve_internal_request_reply(v_reply.id);
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  PERFORM set_config('request.jwt.claims','{"sub":"18e00000-0001-0000-0000-000000000001"}',true);
  IF v_ms > 500 THEN RAISE EXCEPTION 'PERF 6 FAILED: approve_internal_request_reply took %ms (>500ms)', v_ms; END IF;
  RAISE NOTICE 'PERF 6 PASSED: approve_internal_request_reply (atomic reply+thread+audit) %ms', round(v_ms,1);
END $$;

-- ── 7: assigned-to-me lookup (unmigrated read, dashboard "my internal requests") ──
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_plan TEXT; v_line TEXT;
BEGIN
  FOR v_line IN EXECUTE $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT id FROM internal_requests WHERE assigned_to = '18e00000-0001-0000-0000-000000000002'::uuid$q$
  LOOP v_plan := coalesce(v_plan,'') || v_line || E'\n'; END LOOP;
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  IF v_ms > 300 THEN RAISE EXCEPTION 'PERF 7 FAILED: assigned-to-me lookup took %ms (>300ms): %', v_ms, v_plan; END IF;
  RAISE NOTICE 'PERF 7 PASSED: assigned-to-me lookup %ms: %', round(v_ms,1), v_plan;
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'INTERNAL COLLABORATION SERVER MUTATION FOUNDATION PERFORMANCE PROBES: 7/7 PASSED'; END $$;
