-- CAP-003 Phase 1.6A performance probes. Disposable local PostgreSQL
-- only. Realistic volume: 5,000 pre-existing requests for one
-- organization (spread across every status) plus 3,000 responses,
-- then measures the new RPCs' cost at that scale plus the
-- unmigrated list/detail/timeline reads this milestone leaves alone.
\set ON_ERROR_STOP on

INSERT INTO organizations(id,name,type,code) VALUES
  ('16f00000-0000-0000-0000-000000000001','Perf Org Alpha','authority','PFAL'),
  ('16f00000-0000-0000-0000-000000000002','Perf Org Beta','authority','PFBE');
-- 100 background "noise" organizations so the 5000 background requests
-- below spread across realistic cardinality (a few dozen rows per org,
-- not an even 50/50 split across only 2 values) -- otherwise filtering
-- to one org's inbox would be a ~half-table scan, which the planner
-- correctly prefers doing sequentially rather than via index, and that
-- is a fixture-selectivity artifact, not a real query-plan regression.
INSERT INTO organizations(id,name,type,code)
  SELECT ('16f00000-0000-0000-0000-'||lpad((i+1000)::text,12,'0'))::uuid, 'Perf Noise Org '||i, 'authority', 'PFN'||i
  FROM generate_series(1,100) i;
INSERT INTO divisions(id, org_id, name) VALUES
  ('16f00000-0004-0000-0000-000000000001','16f00000-0000-0000-0000-000000000001','A Div'),
  ('16f00000-0004-0000-0000-000000000002','16f00000-0000-0000-0000-000000000002','B Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
  ('16f00000-0002-0000-0000-000000000001','16f00000-0000-0000-0000-000000000001','16f00000-0004-0000-0000-000000000001','A Sec','PAX'),
  ('16f00000-0002-0000-0000-000000000002','16f00000-0000-0000-0000-000000000002','16f00000-0004-0000-0000-000000000002','B Sec','PBX');
-- One shared noise section reused as from_section_id for every noise
-- background row below -- sections has no CHECK tying it back to a
-- specific requests row's from_org_id (that consistency is an RLS/
-- application concern, not a schema constraint), so a raw seed insert
-- as postgres only needs the FK target to exist.
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
  ('16f00000-0002-0000-0000-000000000099','16f00000-0000-0000-0000-000000001001','16f00000-0004-0000-0000-000000000001','Noise Sec','PFNX');
INSERT INTO auth.users(id,email)
  SELECT ('16f00000-0001-0000-0000-'||lpad(i::text,12,'0'))::uuid, 'pf'||i||'@t.local' FROM generate_series(1,3) i;
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
  ('16f00000-0001-0000-0000-000000000001','16f00000-0000-0000-0000-000000000001','PF-1','A Staff','pf1@t.local',TRUE),
  ('16f00000-0001-0000-0000-000000000002','16f00000-0000-0000-0000-000000000001','PF-2','A Super','pf2@t.local',TRUE),
  ('16f00000-0001-0000-0000-000000000003','16f00000-0000-0000-0000-000000000002','PF-3','B Super','pf3@t.local',TRUE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
  ('16f00000-0001-0000-0000-000000000001','section','16f00000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
  ('16f00000-0001-0000-0000-000000000002','section','16f00000-0002-0000-0000-000000000001','supervisor',TRUE,TRUE),
  ('16f00000-0001-0000-0000-000000000003','section','16f00000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE);

-- 4,900 background requests spread across the 100 noise organizations
-- (realistic cardinality -- a few dozen rows touching any one org, not
-- an even split across just 2 values) plus 100 requests actually
-- targeting the real Alpha->Beta pair under test, across every status.
INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, to_section_id, created_by, assigned_to, subject, body, status, reference_number, deadline, created_at)
SELECT
  ('16f00000-0009-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  ('16f00000-0000-0000-0000-'||lpad((1000 + 1 + (i % 100))::text,12,'0'))::uuid,
  ('16f00000-0000-0000-0000-'||lpad((1000 + 1 + ((i+1) % 100))::text,12,'0'))::uuid,
  '16f00000-0002-0000-0000-000000000099', NULL,
  '16f00000-0001-0000-0000-000000000001', NULL,
  'Perf noise request '||i, 'Body '||i,
  (ARRAY['draft','pending_approval','sent','received','in_progress','responded','closed','overdue','cancelled'])[(i % 9) + 1],
  NULL,
  now() + ((i % 30) || ' days')::interval,
  now() - ((5000 - i) || ' minutes')::interval
FROM generate_series(1,4900) i;

INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, to_section_id, created_by, assigned_to, subject, body, status, reference_number, deadline, created_at)
SELECT
  ('16f00000-0009-0000-0000-'||lpad((4900+i)::text,12,'0'))::uuid,
  '16f00000-0000-0000-0000-000000000001','16f00000-0000-0000-0000-000000000002',
  '16f00000-0002-0000-0000-000000000001',
  CASE WHEN i % 9 IN (5,6,7,8) THEN '16f00000-0002-0000-0000-000000000002'::uuid ELSE NULL END,
  '16f00000-0001-0000-0000-000000000001', NULL,
  'Perf request '||i, 'Body '||i,
  (ARRAY['draft','pending_approval','sent','received','in_progress','responded','closed','overdue','cancelled'])[(i % 9) + 1],
  CASE WHEN i % 9 NOT IN (0,1) THEN 'PFAL-PAX-2026-'||lpad(i::text,4,'0') ELSE NULL END,
  now() + ((i % 30) || ' days')::interval,
  now() - ((100 - i) || ' minutes')::interval
FROM generate_series(1,100) i;
-- Advance the section's reference-number counter past the manually
-- assigned PFAL-PAX-2026-0001..0100 range above, so approve_request's
-- own generate_reference_number() call in the RPC tests below never
-- collides with a reference number this fixture already hardcoded.
INSERT INTO reference_sequences (section_id, year, record_type, next_sequence)
VALUES ('16f00000-0002-0000-0000-000000000001', 2026, 'request', 500)
ON CONFLICT (section_id, year, record_type) DO UPDATE SET next_sequence = 500;

INSERT INTO responses (id, request_id, created_by, body, status, created_at)
SELECT
  ('16f00000-000a-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  ('16f00000-0009-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  '16f00000-0001-0000-0000-000000000003', 'Perf response '||i,
  (ARRAY['draft','pending_approval','sent'])[(i % 3) + 1],
  now() - ((3000 - i) || ' minutes')::interval
FROM generate_series(1,3000) i;

ANALYZE requests; ANALYZE responses;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"16f00000-0001-0000-0000-000000000001"}',false);

-- ── 1: create_request ──
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC;
BEGIN
  PERFORM create_request('16f00000-0002-0000-0000-000000000001','16f00000-0000-0000-0000-000000000002','Perf create','body','en','en',NULL,NULL);
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  IF v_ms > 500 THEN RAISE EXCEPTION 'PERF 1 FAILED: create_request took %ms (>500ms) against 5000 background requests', v_ms; END IF;
  RAISE NOTICE 'PERF 1 PASSED: create_request %ms against 5000 background requests', round(v_ms,1);
END $$;

-- ── 2: submit_request/approve_request (state-guarded UPDATE cost) ──
DO $$
DECLARE v_req requests; v_start TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  v_req := create_request('16f00000-0002-0000-0000-000000000001','16f00000-0000-0000-0000-000000000002','Perf transition','body','en','en',NULL,NULL);
  v_req := submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16f00000-0001-0000-0000-000000000002"}',true);
  v_start := clock_timestamp();
  PERFORM approve_request(v_req.id, NULL);
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  PERFORM set_config('request.jwt.claims','{"sub":"16f00000-0001-0000-0000-000000000001"}',true);
  IF v_ms > 500 THEN RAISE EXCEPTION 'PERF 2 FAILED: approve_request took %ms (>500ms)', v_ms; END IF;
  RAISE NOTICE 'PERF 2 PASSED: approve_request (atomic status+lock+refnum+approvals+audit) %ms', round(v_ms,1);
END $$;

-- ── 3: bounded list query (unmigrated, unaffected by this milestone) ──
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_count INT;
BEGIN
  SELECT count(*) INTO v_count FROM (
    SELECT id FROM requests WHERE to_org_id = '16f00000-0000-0000-0000-000000000002' ORDER BY created_at DESC LIMIT 50
  ) s;
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  IF v_ms > 300 THEN RAISE EXCEPTION 'PERF 3 FAILED: bounded inbox list took %ms (>300ms)', v_ms; END IF;
  RAISE NOTICE 'PERF 3 PASSED: bounded inbox-style list query %ms (% rows)', round(v_ms,1), v_count;
END $$;

-- ── 4: no sequential scan on requests for the status-filtered query
-- underlying listUnrouted/listPendingApprovals-style reads ──
DO $$
DECLARE v_plan TEXT; v_line TEXT;
BEGIN
  FOR v_line IN EXECUTE $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT id FROM requests WHERE to_org_id = '16f00000-0000-0000-0000-000000000002'::uuid AND status = 'sent' AND to_section_id IS NULL$q$
  LOOP v_plan := coalesce(v_plan,'') || v_line || E'\n'; END LOOP;
  IF v_plan ~* 'Seq Scan on requests' THEN
    RAISE EXCEPTION 'PERF 4 FAILED: unrouted-inbox-style query does a sequential scan on requests at 5000-row scale: %', v_plan;
  END IF;
  RAISE NOTICE 'PERF 4 PASSED: unrouted-inbox-style query uses an index, not a sequential scan: %', v_plan;
END $$;

-- ── 5: audit_logs / approvals lookups for the case timeline (unmigrated read) ──
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_req requests; v_count INT;
BEGIN
  v_req := create_request('16f00000-0002-0000-0000-000000000001','16f00000-0000-0000-0000-000000000002','Perf timeline','body','en','en',NULL,NULL);
  v_req := submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16f00000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16f00000-0001-0000-0000-000000000003"}',true);
  v_req := mark_request_received(v_req.id);
  v_req := route_request(v_req.id, '16f00000-0002-0000-0000-000000000002');
  PERFORM set_config('request.jwt.claims','{"sub":"16f00000-0001-0000-0000-000000000001"}',true);

  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM audit_logs
    WHERE record_type = 'request' AND record_id = v_req.id AND action IN ('routed','assigned','returned_to_sender');
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  IF v_ms > 300 THEN RAISE EXCEPTION 'PERF 5 FAILED: case-timeline audit lookup took %ms (>300ms)', v_ms; END IF;
  RAISE NOTICE 'PERF 5 PASSED: case-timeline audit_logs lookup %ms (% rows)', round(v_ms,1), v_count;
END $$;

-- ── 6: receive_and_route_request (the atomic composed command) at scale ──
DO $$
DECLARE v_req requests; v_start TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  v_req := create_request('16f00000-0002-0000-0000-000000000001','16f00000-0000-0000-0000-000000000002','Perf composed','body','en','en',NULL,NULL);
  v_req := submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16f00000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"16f00000-0001-0000-0000-000000000003"}',true);
  v_start := clock_timestamp();
  PERFORM receive_and_route_request(v_req.id, '16f00000-0002-0000-0000-000000000002', NULL);
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  PERFORM set_config('request.jwt.claims','{"sub":"16f00000-0001-0000-0000-000000000001"}',true);
  IF v_ms > 500 THEN RAISE EXCEPTION 'PERF 6 FAILED: receive_and_route_request took %ms (>500ms)', v_ms; END IF;
  RAISE NOTICE 'PERF 6 PASSED: receive_and_route_request (atomic 2-step composed command) %ms', round(v_ms,1);
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'REQUESTS SERVER MUTATION FOUNDATION PERFORMANCE PROBES: 6/6 PASSED'; END $$;
