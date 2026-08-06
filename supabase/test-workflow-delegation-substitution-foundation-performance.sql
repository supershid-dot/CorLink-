-- CAP-002 Phase 5.1 delegation/substitution foundation performance
-- probes. Disposable local PostgreSQL only.
\set ON_ERROR_STOP on

INSERT INTO organizations(id,name,type,code) VALUES
 ('65050000-0000-0000-0000-000000000001','WF Delegation Sub Perf','authority','WFDSP');
INSERT INTO auth.users(id,email) VALUES
 ('65050000-0001-0000-0000-000000000001','admin@wfdsp.local'),
 ('65050000-0001-0000-0000-000000000002','alice@wfdsp.local'),
 ('65050000-0001-0000-0000-000000000003','bob@wfdsp.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('65050000-0001-0000-0000-000000000001','65050000-0000-0000-0000-000000000001','WFDSP-1','Admin','admin@wfdsp.local',true),
 ('65050000-0001-0000-0000-000000000002','65050000-0000-0000-0000-000000000001','WFDSP-2','Alice','alice@wfdsp.local',true),
 ('65050000-0001-0000-0000-000000000003','65050000-0000-0000-0000-000000000001','WFDSP-3','Bob','bob@wfdsp.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('65050000-0001-0000-0000-000000000001','organization','65050000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('65050000-0001-0000-0000-000000000002','organization','65050000-0000-0000-0000-000000000001','supervisor',true,true);

-- 10,000 synthetic delegate/substitute users, hand-inserted for
-- scale, mirroring the established "bulk fixture at superuser level"
-- pattern (e.g. Phase 2B.1's 200-node definition, Phase 3.2/4.2's
-- 100,000-event probes).
INSERT INTO auth.users(id, email)
SELECT ('65050000-0002-0000-0000-' || lpad(i::text, 12, '0'))::uuid, 'synth' || i || '@wfdsp.local'
FROM generate_series(1, 10000) i;
INSERT INTO users(id, org_id, service_number, full_name, email, is_active)
SELECT ('65050000-0002-0000-0000-' || lpad(i::text, 12, '0'))::uuid, '65050000-0000-0000-0000-000000000001',
  'WFDSP-S' || i, 'Synth ' || i, 'synth' || i || '@wfdsp.local', true
FROM generate_series(1, 10000) i;

-- ── Dimension 1: 10,000 pre-existing delegation rows; create ─────
--    one more real delegation via the RPC (Alice, a fresh scope) and
--    time it — exercises the overlap EXCLUDE-constraint check and
--    the advisory-lock-scoped serialization at this scale. ────────
INSERT INTO workflow_delegations (
  organization_id, delegator_id, delegate_id, scope_type,
  scope_role_organization_id, scope_role, kind, activation_mode,
  starts_at, ends_at, status, created_by, create_idempotency_key
)
SELECT '65050000-0000-0000-0000-000000000001', '65050000-0001-0000-0000-000000000002',
  ('65050000-0002-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
  'organization_role', '65050000-0000-0000-0000-000000000001', 'supervisor',
  'temporary', 'manual', now() - interval '10 days', now() - interval '5 days',
  'expired', '65050000-0001-0000-0000-000000000002', gen_random_uuid()
FROM generate_series(1, 10000) i;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65050000-0001-0000-0000-000000000002"}',false);
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  v_start := clock_timestamp();
  PERFORM delegation_id FROM create_workflow_delegation(
    '65050000-0000-0000-0000-000000000001','65050000-0001-0000-0000-000000000002','65050000-0001-0000-0000-000000000003',
    '{"type":"organization_role","organization_id":"65050000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
    'temporary','manual', now(), now() + interval '5 days', 'perf probe', gen_random_uuid());
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 1 (create_workflow_delegation against 10,000 pre-existing delegation rows): % ms', round(v_ms, 2);
END $$;
RESET ROLE;

-- ── Dimension 2: 10,000 pre-existing substitution rows; create one
--    more real substitution via the RPC and time it. ──────────────
INSERT INTO workflow_substitutions (
  organization_id, represented_type, represented_role_organization_id, represented_role,
  substitute_id, kind, starts_at, ends_at, status, configured_by, create_idempotency_key
)
SELECT '65050000-0000-0000-0000-000000000001', 'organization_role', '65050000-0000-0000-0000-000000000001', 'supervisor',
  ('65050000-0002-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
  'acting_appointment', now() - interval '10 days', now() - interval '5 days',
  'expired', '65050000-0001-0000-0000-000000000001', gen_random_uuid()
FROM generate_series(1, 10000) i;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65050000-0001-0000-0000-000000000001"}',false);
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC;
BEGIN
  v_start := clock_timestamp();
  PERFORM substitution_id FROM create_workflow_substitution(
    '65050000-0000-0000-0000-000000000001',
    '{"type":"user","user_id":"65050000-0001-0000-0000-000000000002"}'::jsonb,
    '65050000-0001-0000-0000-000000000003','planned_leave', now(), now() + interval '5 days', 'perf probe', gen_random_uuid());
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 2 (create_workflow_substitution against 10,000 pre-existing substitution rows): % ms', round(v_ms, 2);
END $$;
RESET ROLE;

-- ── Dimension 3: 100,000 lifecycle evidence rows; time a history
--    read for one specific delegation, and confirm index usage. ───
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT id INTO v_id FROM workflow_delegations WHERE delegator_id = '65050000-0001-0000-0000-000000000002' LIMIT 1;
  INSERT INTO workflow_delegation_events (delegation_id, event_type, actor_id, previous_status, new_status, idempotency_key, metadata)
  SELECT v_id, 'created', '65050000-0001-0000-0000-000000000002', NULL, 'pending_acceptance', gen_random_uuid(), '{}'::jsonb
  FROM generate_series(1, 100000);
END $$;

DO $$
DECLARE v_id UUID; v_start TIMESTAMPTZ; v_ms NUMERIC; v_count INTEGER;
BEGIN
  SELECT id INTO v_id FROM workflow_delegations WHERE delegator_id = '65050000-0001-0000-0000-000000000002' LIMIT 1;
  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM workflow_delegation_events WHERE delegation_id = v_id;
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 3 (history read for one delegation against 100,000 total evidence rows, % matched): % ms', v_count, round(v_ms, 2);
END $$;

DO $$
DECLARE v_id UUID;
BEGIN
  SELECT id INTO v_id FROM workflow_delegations WHERE delegator_id = '65050000-0001-0000-0000-000000000002' LIMIT 1;
  CREATE TEMP TABLE wfdsperf_explain_target AS SELECT v_id AS id;
END $$;
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM workflow_delegation_events WHERE delegation_id = (SELECT id FROM wfdsperf_explain_target) ORDER BY occurred_at LIMIT 100;
DROP TABLE wfdsperf_explain_target;

-- ── Dimension 4: list_workflow_delegations / list_workflow_
--    substitutions with organization and actor filters at scale.
--    4a/4b use the self-scoped p_role fast path (the common case);
--    4c/4d use the admin-inclusive (p_role IS NULL) path, which still
--    pays the non-inlined SECURITY DEFINER visibility-check cost per
--    candidate row — see docs/74 "Performance" for why. ────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65050000-0001-0000-0000-000000000002"}',false);
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_count INTEGER;
BEGIN
  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM list_workflow_delegations('65050000-0000-0000-0000-000000000001','delegator',50,NULL,NULL);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 4a (list_workflow_delegations, self-scoped p_role fast path, page of %): % ms', v_count, round(v_ms, 2);
END $$;
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_count INTEGER;
BEGIN
  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM list_workflow_delegations('65050000-0000-0000-0000-000000000001',NULL,50,NULL,NULL);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 4c (list_workflow_delegations, admin-inclusive p_role IS NULL path over 10,001 candidate rows, page of %): % ms', v_count, round(v_ms, 2);
END $$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65050000-0001-0000-0000-000000000001"}',false);
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_count INTEGER;
BEGIN
  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM list_workflow_substitutions('65050000-0000-0000-0000-000000000001','substitute',50,NULL,NULL);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 4b (list_workflow_substitutions, self-scoped p_role fast path, page of %): % ms', v_count, round(v_ms, 2);
END $$;
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_count INTEGER;
BEGIN
  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM list_workflow_substitutions('65050000-0000-0000-0000-000000000001',NULL,50,NULL,NULL);
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 4d (list_workflow_substitutions, admin-inclusive p_role IS NULL path over 10,001 candidate rows, page of %): % ms', v_count, round(v_ms, 2);
END $$;
RESET ROLE;

DO $$ BEGIN RAISE NOTICE 'Workflow delegation/substitution foundation performance probe PASSED'; END $$;

-- ── Cleanup ──────────────────────────────────────────────────────
ALTER TABLE workflow_delegation_events DISABLE TRIGGER workflow_delegation_events_immutable;
DELETE FROM workflow_delegation_events WHERE delegation_id IN (SELECT id FROM workflow_delegations WHERE organization_id = '65050000-0000-0000-0000-000000000001');
ALTER TABLE workflow_delegation_events ENABLE TRIGGER workflow_delegation_events_immutable;
ALTER TABLE workflow_delegations DISABLE TRIGGER workflow_delegations_immutable_after_terminal;
DELETE FROM workflow_delegations WHERE organization_id = '65050000-0000-0000-0000-000000000001';
ALTER TABLE workflow_delegations ENABLE TRIGGER workflow_delegations_immutable_after_terminal;
ALTER TABLE workflow_substitution_events DISABLE TRIGGER workflow_substitution_events_immutable;
DELETE FROM workflow_substitution_events WHERE substitution_id IN (SELECT id FROM workflow_substitutions WHERE organization_id = '65050000-0000-0000-0000-000000000001');
ALTER TABLE workflow_substitution_events ENABLE TRIGGER workflow_substitution_events_immutable;
ALTER TABLE workflow_substitutions DISABLE TRIGGER workflow_substitutions_immutable_after_terminal;
DELETE FROM workflow_substitutions WHERE organization_id = '65050000-0000-0000-0000-000000000001';
ALTER TABLE workflow_substitutions ENABLE TRIGGER workflow_substitutions_immutable_after_terminal;
DELETE FROM user_assignments WHERE user_id::text LIKE '65050000-%';
DELETE FROM users WHERE id::text LIKE '65050000-%';
DELETE FROM auth.users WHERE id::text LIKE '65050000-%';
DELETE FROM organizations WHERE id::text LIKE '65050000-%';
