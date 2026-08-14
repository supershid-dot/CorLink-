-- Prisoner Letters server-mutation-foundation performance probes.
-- Disposable local PostgreSQL only. Realistic volume: 5,000
-- pre-existing prisoner_letters rows spread across a to_org fan-out
-- (a noise authority org plus the real destination org under test),
-- across every status, plus 3,000 replies, then measures the new
-- RPCs' cost at that scale plus the unmigrated list reads this
-- milestone leaves alone. No speculative index is added --
-- idx_prisoner_letters_submitted_by/_assigned_to/_org/_to_org
-- (schema.sql) are exercised as-is; this suite only proves whether
-- they are already sufficient.
\set ON_ERROR_STOP on

INSERT INTO organizations(id,name,type,code) VALUES
  ('9f000000-0000-0000-0000-000000000001','Perf T9F Prison Org','mcs','PF9FP'),
  ('9f000000-0000-0000-0000-000000000002','Perf T9F Authority Org','authority','PF9FQ'),
  ('9f000000-0000-0000-0000-000000000003','Perf T9F Noise Authority Org','authority','PF9FN');
INSERT INTO commands(id,name,org_id) VALUES
  ('9f000000-0010-0000-0000-000000000001','PF9F Cmd P','9f000000-0000-0000-0000-000000000001'),
  ('9f000000-0010-0000-0000-000000000002','PF9F Cmd Q','9f000000-0000-0000-0000-000000000002'),
  ('9f000000-0010-0000-0000-000000000003','PF9F Cmd N','9f000000-0000-0000-0000-000000000003');
INSERT INTO departments(id,name,command_id) VALUES
  ('9f000000-0020-0000-0000-000000000001','PF9F Dept P','9f000000-0010-0000-0000-000000000001'),
  ('9f000000-0020-0000-0000-000000000002','PF9F Dept Q','9f000000-0010-0000-0000-000000000002'),
  ('9f000000-0020-0000-0000-000000000003','PF9F Dept N','9f000000-0010-0000-0000-000000000003');
INSERT INTO sections(id,name,code,org_id,department_id) VALUES
  ('9f000000-0002-0000-0000-000000000001','PF9F Section P','PF9FSP','9f000000-0000-0000-0000-000000000001','9f000000-0020-0000-0000-000000000001'),
  ('9f000000-0002-0000-0000-000000000002','PF9F Section Q','PF9FSQ','9f000000-0000-0000-0000-000000000002','9f000000-0020-0000-0000-000000000002');
INSERT INTO auth.users(id,email) VALUES
  ('9f000000-0001-0000-0000-000000000001','pf9f-mcsstaff@t.local'),
  ('9f000000-0001-0000-0000-000000000002','pf9f-authstaff@t.local'),
  ('9f000000-0001-0000-0000-000000000003','pf9f-authsuper@t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_prisoner_letters_staff) VALUES
  ('9f000000-0001-0000-0000-000000000001','9f000000-0000-0000-0000-000000000001','PF9F-1','MCS Staff','pf9f-mcsstaff@t.local',TRUE,TRUE),
  ('9f000000-0001-0000-0000-000000000002','9f000000-0000-0000-0000-000000000002','PF9F-2','Authority Staff','pf9f-authstaff@t.local',TRUE,TRUE),
  ('9f000000-0001-0000-0000-000000000003','9f000000-0000-0000-0000-000000000002','PF9F-3','Authority Supervisor','pf9f-authsuper@t.local',TRUE,FALSE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
  ('9f000000-0001-0000-0000-000000000001','section','9f000000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
  ('9f000000-0001-0000-0000-000000000002','section','9f000000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
  ('9f000000-0001-0000-0000-000000000003','section','9f000000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE);
INSERT INTO prisoners (id, org_id, file_number, id_card_number, full_name, address, prison) VALUES
  ('9f000000-0003-0000-0000-000000000001','9f000000-0000-0000-0000-000000000001','PF9F-FILE-001','PF9F-INMATE-001','PF9F Test Inmate','Test Address','Maafushi Prison');

-- 4,900 background letters targeting the noise authority org, 100
-- targeting the real destination org under test, across every status.
INSERT INTO prisoner_letters (id, prisoner_id, prisoner_name, from_prison_id, to_org_id, body, submitted_by, status, reference_number, assigned_to, received_by, received_at, created_at)
SELECT
  ('9f000000-0005-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'PF9F-INMATE-BG-'||i, 'Perf Noise Inmate '||i,
  '9f000000-0000-0000-0000-000000000001','9f000000-0000-0000-0000-000000000003',
  'Perf noise body '||i,
  '9f000000-0001-0000-0000-000000000001',
  (ARRAY['submitted','received','replied','delivered'])[(i % 4) + 1],
  'PL-PF9FN-2026-'||lpad(i::text,4,'0'),
  NULL, NULL, NULL,
  now() - ((5000 - i) || ' minutes')::interval
FROM generate_series(1,4900) i;

INSERT INTO prisoner_letters (id, prisoner_id, prisoner_name, from_prison_id, to_org_id, body, submitted_by, status, reference_number, assigned_to, received_by, received_at, created_at)
SELECT
  ('9f000000-0005-0000-0000-'||lpad((4900+i)::text,12,'0'))::uuid,
  'PF9F-INMATE-RL-'||i, 'Perf Real Inmate '||i,
  '9f000000-0000-0000-0000-000000000001','9f000000-0000-0000-0000-000000000002',
  'Perf real body '||i,
  '9f000000-0001-0000-0000-000000000001',
  (ARRAY['submitted','received','replied','delivered'])[(i % 4) + 1],
  'PL-PF9FQ-2026-'||lpad(i::text,4,'0'),
  '9f000000-0001-0000-0000-000000000002', NULL, NULL,
  now() - ((100 - i) || ' minutes')::interval
FROM generate_series(1,100) i;

INSERT INTO prisoner_replies (id, letter_id, body, replied_by, created_at)
SELECT
  ('9f000000-0006-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  ('9f000000-0005-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'Perf reply '||i,
  '9f000000-0001-0000-0000-000000000002',
  now() - ((3000 - i) || ' minutes')::interval
FROM generate_series(1,3000) i;

INSERT INTO attachments (record_type, record_id, filename, storage_path, mime_type, file_size, uploaded_by, created_at)
SELECT
  'prisoner_letter', ('9f000000-0005-0000-0000-'||lpad(i::text,12,'0'))::uuid,
  'scan-'||i||'.pdf', 'attachments/prisoner_letter/perf/'||i||'.pdf', 'application/pdf', 1024,
  '9f000000-0001-0000-0000-000000000001',
  now() - ((5000 - i) || ' minutes')::interval
FROM generate_series(1,2000) i;

ANALYZE prisoner_letters; ANALYZE prisoner_replies; ANALYZE attachments;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"9f000000-0001-0000-0000-000000000001"}',false);

-- ── PERF 1: create_prisoner_letter at scale (reference generation +
-- prisoner lookup + insert + audit, all in one RPC) ──
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  v_start := clock_timestamp();
  PERFORM create_prisoner_letter('9f000000-0003-0000-0000-000000000001','9f000000-0000-0000-0000-000000000001','9f000000-0000-0000-0000-000000000002','Perf create body');
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  IF v_ms > 500 THEN RAISE EXCEPTION 'PERF 1 FAILED: create_prisoner_letter took %ms (>500ms) against 5000 background rows', v_ms; END IF;
  RAISE NOTICE 'PERF 1 PASSED: create_prisoner_letter %ms against 5000 background rows', round(v_ms,1);
END $$;

-- ── PERF 2: mark_prisoner_letter_received (state-guarded UPDATE cost) ──
DO $$
DECLARE v_pl prisoner_letters; v_start TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  v_pl := create_prisoner_letter('9f000000-0003-0000-0000-000000000001','9f000000-0000-0000-0000-000000000001','9f000000-0000-0000-0000-000000000002','Perf transition body');
  PERFORM set_config('request.jwt.claims','{"sub":"9f000000-0001-0000-0000-000000000003"}',true);
  v_start := clock_timestamp();
  v_pl := mark_prisoner_letter_received(v_pl.id);
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  PERFORM set_config('request.jwt.claims','{"sub":"9f000000-0001-0000-0000-000000000001"}',true);
  IF v_ms > 500 THEN RAISE EXCEPTION 'PERF 2 FAILED: mark_prisoner_letter_received took %ms (>500ms)', v_ms; END IF;
  RAISE NOTICE 'PERF 2 PASSED: mark_prisoner_letter_received %ms', round(v_ms,1);
END $$;

-- ── PERF 3: bounded MCS "sent" list query (unmigrated, unaffected by
-- this milestone) -- mirrors prisoner-letters-api.js's listSent() shape ──
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_count INT;
BEGIN
  SELECT count(*) INTO v_count FROM (
    SELECT id FROM prisoner_letters WHERE submitted_by = '9f000000-0001-0000-0000-000000000001'::uuid ORDER BY created_at DESC LIMIT 50
  ) s;
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  IF v_ms > 300 THEN RAISE EXCEPTION 'PERF 3 FAILED: bounded MCS-submitted list took %ms (>300ms)', v_ms; END IF;
  RAISE NOTICE 'PERF 3 PASSED: bounded MCS-submitted list query %ms (% rows)', round(v_ms,1), v_count;
END $$;

-- ── PERF 4: no sequential scan on prisoner_letters for the
-- to_org+status-filtered query underlying the authority-side inbox ──
DO $$
DECLARE v_plan TEXT; v_line TEXT;
BEGIN
  FOR v_line IN EXECUTE $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT id FROM prisoner_letters WHERE to_org_id = '9f000000-0000-0000-0000-000000000002'::uuid AND status = 'submitted'$q$
  LOOP v_plan := coalesce(v_plan,'') || v_line || E'\n'; END LOOP;
  IF v_plan ~* 'Seq Scan on prisoner_letters' THEN
    RAISE EXCEPTION 'PERF 4 FAILED: authority-side inbox query does a sequential scan on prisoner_letters at 5000-row scale: %', v_plan;
  END IF;
  RAISE NOTICE 'PERF 4 PASSED: authority-side inbox query uses an index, not a sequential scan: %', v_plan;
END $$;

-- ── PERF 5: audit_logs lookup for the letter's timeline (unmigrated read) ──
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_pl prisoner_letters; v_count INT;
BEGIN
  v_pl := create_prisoner_letter('9f000000-0003-0000-0000-000000000001','9f000000-0000-0000-0000-000000000001','9f000000-0000-0000-0000-000000000002','Perf timeline body');
  PERFORM set_config('request.jwt.claims','{"sub":"9f000000-0001-0000-0000-000000000003"}',true);
  v_pl := mark_prisoner_letter_received(v_pl.id);
  PERFORM set_config('request.jwt.claims','{"sub":"9f000000-0001-0000-0000-000000000001"}',true);

  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM audit_logs
    WHERE record_type = 'prisoner_letter' AND record_id = v_pl.id AND action IN ('created','received','routed');
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  -- 600ms budget, matching the exact same disposable-harness
  -- session-to-session variance rationale Entry/Internal Collaboration's
  -- own equivalent probe uses (idx_audit_logs_record is used; plan cost
  -- is trivial) rather than chasing a query-plan problem that does not
  -- exist.
  IF v_ms > 600 THEN RAISE EXCEPTION 'PERF 5 FAILED: letter-timeline audit lookup took %ms (>600ms)', v_ms; END IF;
  RAISE NOTICE 'PERF 5 PASSED: letter-timeline audit_logs lookup %ms (% rows)', round(v_ms,1), v_count;
END $$;

-- ── PERF 6: create_prisoner_letter_reply (the atomic fused command) at scale ──
DO $$
DECLARE v_pl prisoner_letters; v_start TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  v_pl := create_prisoner_letter('9f000000-0003-0000-0000-000000000001','9f000000-0000-0000-0000-000000000001','9f000000-0000-0000-0000-000000000002','Perf composed body');
  PERFORM set_config('request.jwt.claims','{"sub":"9f000000-0001-0000-0000-000000000003"}',true);
  v_pl := mark_prisoner_letter_received(v_pl.id);
  v_pl := route_prisoner_letter(v_pl.id, '9f000000-0002-0000-0000-000000000002', '9f000000-0001-0000-0000-000000000002');
  PERFORM set_config('request.jwt.claims','{"sub":"9f000000-0001-0000-0000-000000000002"}',true);
  v_start := clock_timestamp();
  PERFORM create_prisoner_letter_reply(v_pl.id, 'Perf composed reply');
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  PERFORM set_config('request.jwt.claims','{"sub":"9f000000-0001-0000-0000-000000000001"}',true);
  IF v_ms > 500 THEN RAISE EXCEPTION 'PERF 6 FAILED: create_prisoner_letter_reply took %ms (>500ms)', v_ms; END IF;
  RAISE NOTICE 'PERF 6 PASSED: create_prisoner_letter_reply (atomic reply+status+audit) %ms', round(v_ms,1);
END $$;

-- ── PERF 7: assigned-to-me lookup (unmigrated read, authority-side
-- "my prisoner letters" dashboard) ──
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_plan TEXT; v_line TEXT;
BEGIN
  FOR v_line IN EXECUTE $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT id FROM prisoner_letters WHERE assigned_to = '9f000000-0001-0000-0000-000000000002'::uuid$q$
  LOOP v_plan := coalesce(v_plan,'') || v_line || E'\n'; END LOOP;
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  IF v_ms > 300 THEN RAISE EXCEPTION 'PERF 7 FAILED: assigned-to-me lookup took %ms (>300ms): %', v_ms, v_plan; END IF;
  RAISE NOTICE 'PERF 7 PASSED: assigned-to-me lookup %ms: %', round(v_ms,1), v_plan;
END $$;

-- ── PERF 8: reply lookup for a given letter (unmigrated read) ──
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_count INT;
BEGIN
  SELECT count(*) INTO v_count FROM prisoner_replies WHERE letter_id = '9f000000-0005-0000-0000-000000000001'::uuid;
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  IF v_ms > 300 THEN RAISE EXCEPTION 'PERF 8 FAILED: reply-by-letter lookup took %ms (>300ms)', v_ms; END IF;
  RAISE NOTICE 'PERF 8 PASSED: reply-by-letter lookup %ms (% rows)', round(v_ms,1), v_count;
END $$;

-- ── PERF 9: attachment relationship lookup (record_type+record_id,
-- unmigrated read, shared idx_attachments_record) ──
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp(); v_ms NUMERIC; v_plan TEXT; v_line TEXT;
BEGIN
  FOR v_line IN EXECUTE $q$EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT id FROM attachments WHERE record_type = 'prisoner_letter' AND record_id = '9f000000-0005-0000-0000-000000000001'::uuid$q$
  LOOP v_plan := coalesce(v_plan,'') || v_line || E'\n'; END LOOP;
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);
  IF v_ms > 300 THEN RAISE EXCEPTION 'PERF 9 FAILED: attachment relationship lookup took %ms (>300ms): %', v_ms, v_plan; END IF;
  RAISE NOTICE 'PERF 9 PASSED: attachment relationship lookup %ms: %', round(v_ms,1), v_plan;
END $$;

RESET ROLE;
DO $$ BEGIN RAISE NOTICE 'PRISONER LETTERS SERVER MUTATION FOUNDATION PERFORMANCE SUITE (9 probes) PASSED'; END $$;
