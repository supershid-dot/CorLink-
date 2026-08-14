-- CAP-003 Phase 1.8B performance suite. Disposable local PostgreSQL
-- only. Fixtures use the '98300000-' UUID prefix convention. Builds a
-- realistic-scale historical dataset (thousands of prior internal
-- collaboration threads) so the new adapter/producer overhead is
-- measured against real index usage, not an empty table.
\set ON_ERROR_STOP on
\timing on

INSERT INTO organizations (id, name, type, code) VALUES ('98300000-0000-0000-0000-000000000001', 'Perf Org', 'mcs', 'IC98P');
INSERT INTO commands (id, org_id, name) VALUES ('98300000-0001-0000-0000-000000000001', '98300000-0000-0000-0000-000000000001', 'Cmd');
INSERT INTO departments (id, command_id, name) VALUES ('98300000-0002-0000-0000-000000000001', '98300000-0001-0000-0000-000000000001', 'Dept');
INSERT INTO sections (id, department_id, org_id, name, code) VALUES
  ('98300000-0003-0000-0000-000000000001', '98300000-0002-0000-0000-000000000001', '98300000-0000-0000-0000-000000000001', 'Sec A', 'PA'),
  ('98300000-0003-0000-0000-000000000002', '98300000-0002-0000-0000-000000000001', '98300000-0000-0000-0000-000000000001', 'Sec B', 'PB');
INSERT INTO auth.users (id, email) VALUES ('98300000-0004-0000-0000-000000000001', 'perf@ic98p.local');
INSERT INTO users (id, org_id, service_number, full_name, email, is_active) VALUES
  ('98300000-0004-0000-0000-000000000001', '98300000-0000-0000-0000-000000000001', 'IC98P-1', 'Perf User', 'perf@ic98p.local', TRUE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_active) VALUES
  ('98300000-0004-0000-0000-000000000001', 'section', '98300000-0003-0000-0000-000000000001', 'staff', TRUE);
INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, subject, body, status, created_by, reference_number)
  VALUES ('98300000-0005-0000-0000-000000000001', '98300000-0000-0000-0000-000000000001', '98300000-0000-0000-0000-000000000001', '98300000-0003-0000-0000-000000000001', 'Perf parent', 'body', 'sent', '98300000-0004-0000-0000-000000000001', 'REQ-IC98P-1');

-- ── Dimension 1: 10,000 historical internal_requests rows (already
-- "completed" audit history), so the new adapter's EXISTS(user_
-- assignments ... scope_section_ids ...) branches and the closed
-- source_record_type/target_type CHECK constraints are measured against
-- a realistic table size, not an empty one. ─────────────────────────
INSERT INTO internal_requests (id, parent_request_id, from_section_id, to_section_id, created_by, subject, body, status, created_at)
SELECT gen_random_uuid(), '98300000-0005-0000-0000-000000000001', '98300000-0003-0000-0000-000000000001', '98300000-0003-0000-0000-000000000002',
  '98300000-0004-0000-0000-000000000001', 'Historical thread ' || i, 'body', 'closed', now() - (i || ' minutes')::interval
FROM generate_series(1, 10000) i;

INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
SELECT '98300000-0004-0000-0000-000000000001', 'created', 'internal_request', id, 'seed'
FROM internal_requests WHERE subject LIKE 'Historical thread %';

\echo '=== Dimension 1: 10,000 historical rows seeded ==='

-- ── Dimension 2: adapter lookup cost -- intent_user_can_view_
-- internal_request() against the 10,000-row table, EXPLAIN ANALYZE. ──
\echo '=== Dimension 2: adapter lookup EXPLAIN ANALYZE ==='
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT intent_user_can_view_internal_request(
  (SELECT id FROM internal_requests WHERE subject = 'Historical thread 5000'),
  '98300000-0004-0000-0000-000000000001'
);

-- ── Dimension 3: producer overhead -- 200 real create_internal_request()
-- calls (each including the atomic enqueue), timed as a batch. ───────
\echo '=== Dimension 3: 200 create_internal_request() calls (with atomic enqueue) ==='
DO $$
DECLARE
  i INT;
  v_start TIMESTAMPTZ := clock_timestamp();
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims', '{"sub":"98300000-0004-0000-0000-000000000001"}', true);
  FOR i IN 1..200 LOOP
    PERFORM create_internal_request(
      '98300000-0003-0000-0000-000000000001', '98300000-0003-0000-0000-000000000002',
      'Perf thread ' || i, 'body', '98300000-0005-0000-0000-000000000001', NULL, 'en', 'en', NULL
    );
  END LOOP;
  RESET ROLE;
  RAISE NOTICE 'Dimension 3: 200 create_internal_request() calls took % ms', extract(milliseconds FROM clock_timestamp() - v_start);
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
-- perf user, who now has ~200 real internal_collaboration.routed.v1
-- notifications alongside whatever else exists. ─────────────────────
\echo '=== Dimension 5: list_my_notifications() EXPLAIN ANALYZE ==='
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"98300000-0004-0000-0000-000000000001"}', false);
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM list_my_notifications(15, NULL, NULL, FALSE);
RESET ROLE;

-- ── Dimension 6: idempotency-key lookup (unique index on platform_
-- outbox_events) at scale -- confirm no sequential scan. ─────────────
\echo '=== Dimension 6: idempotency unique index EXPLAIN ==='
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT 1 FROM platform_outbox_events
WHERE source_module = 'internal_collaboration' AND source_record_type = 'internal_request'
  AND event_type = 'internal_collaboration.routed.v1'
  AND source_record_id = (SELECT id FROM internal_requests WHERE subject = 'Perf thread 100')
LIMIT 1;

-- No speculative indexes were added by this milestone -- every query
-- above is expected to use existing indexes (idx_internal_requests_*,
-- the platform_outbox_events idempotency unique constraint, user_
-- notifications' own recipient index) without a sequential scan on a
-- table of this size.
\echo '=== PERFORMANCE SUITE COMPLETE ==='
