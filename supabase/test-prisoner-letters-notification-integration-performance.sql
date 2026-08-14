-- CAP-003 Phase 1.9B performance suite. Disposable local PostgreSQL
-- only. Fixtures use the '99300000-' UUID prefix convention. Builds a
-- realistic-scale historical dataset (thousands of prior prisoner
-- letters) so the new adapter/producer overhead is measured against
-- real index usage, not an empty table.
\set ON_ERROR_STOP on
\timing on

INSERT INTO organizations (id, name, type, code) VALUES
  ('99300000-0000-0000-0000-000000000001', 'Perf Prison Org', 'mcs', 'PL99P'),
  ('99300000-0000-0000-0000-000000000002', 'Perf Authority Org', 'authority', 'PL99PQ');
INSERT INTO commands (id, org_id, name) VALUES
  ('99300000-0001-0000-0000-000000000001', '99300000-0000-0000-0000-000000000001', 'Cmd P'),
  ('99300000-0001-0000-0000-000000000002', '99300000-0000-0000-0000-000000000002', 'Cmd Q');
INSERT INTO departments (id, command_id, name) VALUES
  ('99300000-0002-0000-0000-000000000001', '99300000-0001-0000-0000-000000000001', 'Dept P'),
  ('99300000-0002-0000-0000-000000000002', '99300000-0001-0000-0000-000000000002', 'Dept Q');
INSERT INTO sections (id, department_id, org_id, name, code) VALUES
  ('99300000-0003-0000-0000-000000000001', '99300000-0002-0000-0000-000000000001', '99300000-0000-0000-0000-000000000001', 'Sec P', 'PLP'),
  ('99300000-0003-0000-0000-000000000002', '99300000-0002-0000-0000-000000000002', '99300000-0000-0000-0000-000000000002', 'Sec Q', 'PLQ');
INSERT INTO auth.users (id, email) VALUES
  ('99300000-0004-0000-0000-000000000001', 'perf-mcs@pl99p.local'),
  ('99300000-0004-0000-0000-000000000002', 'perf-authsup@pl99p.local');
INSERT INTO users (id, org_id, service_number, full_name, email, is_active, is_prisoner_letters_staff) VALUES
  ('99300000-0004-0000-0000-000000000001', '99300000-0000-0000-0000-000000000001', 'PL99P-1', 'Perf MCS User', 'perf-mcs@pl99p.local', TRUE, TRUE),
  ('99300000-0004-0000-0000-000000000002', '99300000-0000-0000-0000-000000000002', 'PL99P-2', 'Perf Authority Supervisor', 'perf-authsup@pl99p.local', TRUE, FALSE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_active) VALUES
  ('99300000-0004-0000-0000-000000000001', 'section', '99300000-0003-0000-0000-000000000001', 'staff', TRUE),
  ('99300000-0004-0000-0000-000000000002', 'organization', '99300000-0000-0000-0000-000000000002', 'supervisor', TRUE);
INSERT INTO prisoners (id, org_id, file_number, id_card_number, full_name, address, prison) VALUES
  ('99300000-0005-0000-0000-000000000001', '99300000-0000-0000-0000-000000000001', 'FILE-P99-1', 'PL99P-INMATE-1', 'PL99P Test Inmate', 'Test Address', 'Maafushi Prison');

-- ── Dimension 1: 10,000 historical prisoner_letters rows (already
-- "delivered" history), so the new adapter's own EXISTS(user_
-- assignments ...)/users lookups and the closed source_record_type/
-- target_type CHECK constraints are measured against a realistic table
-- size, not an empty one. ────────────────────────────────────────────
-- Reference numbers use a 'PL-HIST-' prefix (not the real org code
-- 'PL99P') so these manually-seeded historical rows can never collide
-- with the real generate_prisoner_letter_reference()-produced values
-- Dimension 3's own 200 real create_prisoner_letter() calls will
-- generate below (prisoner_letters.reference_number is UNIQUE).
INSERT INTO prisoner_letters (id, prisoner_id, prisoner_name, from_prison_id, to_org_id, body, submitted_by, status, reference_number, assigned_to, created_at)
SELECT gen_random_uuid(), 'PERF-INMATE-'||i, 'Historical Inmate '||i,
  '99300000-0000-0000-0000-000000000001', '99300000-0000-0000-0000-000000000002',
  'Historical letter body '||i,
  '99300000-0004-0000-0000-000000000001', 'delivered', 'PL-HIST-2026-'||lpad(i::text,5,'0'),
  '99300000-0004-0000-0000-000000000002',
  now() - (i || ' minutes')::interval
FROM generate_series(1, 10000) i;

INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
SELECT '99300000-0004-0000-0000-000000000001', 'created', 'prisoner_letter', id, 'seed'
FROM prisoner_letters WHERE prisoner_id LIKE 'PERF-INMATE-%';

\echo '=== Dimension 1: 10,000 historical rows seeded ==='

-- ── Dimension 2: adapter lookup cost -- intent_user_can_view_
-- prisoner_letter() against the 10,000-row table, EXPLAIN ANALYZE. ────
\echo '=== Dimension 2: adapter lookup EXPLAIN ANALYZE ==='
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT intent_user_can_view_prisoner_letter(
  (SELECT id FROM prisoner_letters WHERE prisoner_id = 'PERF-INMATE-5000'),
  '99300000-0004-0000-0000-000000000002'
);

-- ── Dimension 3: producer overhead -- 200 real create_prisoner_letter()
-- calls (each including the atomic enqueue), timed as a batch. ───────
\echo '=== Dimension 3: 200 create_prisoner_letter() calls (with atomic enqueue) ==='
DO $$
DECLARE
  i INT;
  v_start TIMESTAMPTZ := clock_timestamp();
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims', '{"sub":"99300000-0004-0000-0000-000000000001"}', true);
  FOR i IN 1..200 LOOP
    PERFORM create_prisoner_letter(
      '99300000-0005-0000-0000-000000000001', '99300000-0000-0000-0000-000000000001',
      '99300000-0000-0000-0000-000000000002', 'Perf letter body ' || i
    );
  END LOOP;
  RESET ROLE;
  RAISE NOTICE 'Dimension 3: 200 create_prisoner_letter() calls took % ms', extract(milliseconds FROM clock_timestamp() - v_start);
END $$;

-- ── Dimension 4: worker drain of the 200 events just enqueued. ───────
\echo '=== Dimension 4: worker drain (200 events) ==='
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp();
BEGIN
  PERFORM process_platform_outbox_batch(500, NULL);
  RAISE NOTICE 'Dimension 4: draining up to 500 events took % ms', extract(milliseconds FROM clock_timestamp() - v_start);
END $$;

-- ── Dimension 5: merged feed read -- list_my_notifications() for the
-- perf authority supervisor, who now has ~200 real prisoner_letter.
-- sent.v1 notifications alongside whatever else exists. ──────────────
\echo '=== Dimension 5: list_my_notifications() EXPLAIN ANALYZE ==='
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"99300000-0004-0000-0000-000000000002"}', false);
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM list_my_notifications(15, NULL, NULL, FALSE);
RESET ROLE;

-- ── Dimension 6: idempotency-key lookup (unique index on platform_
-- outbox_events) at scale -- confirm no sequential scan. ─────────────
\echo '=== Dimension 6: idempotency unique index EXPLAIN ==='
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT 1 FROM platform_outbox_events
WHERE source_module = 'prisoner_letters' AND source_record_type = 'prisoner_letter'
  AND event_type = 'prisoner_letter.sent.v1'
  AND source_record_id = (SELECT id FROM prisoner_letters WHERE reference_number = 'PL-PL99P-2026-0100' AND submitted_by = '99300000-0004-0000-0000-000000000001')
LIMIT 1;

-- No speculative indexes were added by this milestone -- every query
-- above is expected to use existing indexes (idx_prisoner_letters_*,
-- the platform_outbox_events idempotency unique constraint, user_
-- notifications' own recipient index) without a sequential scan on a
-- table of this size.
\echo '=== PERFORMANCE SUITE COMPLETE ==='
