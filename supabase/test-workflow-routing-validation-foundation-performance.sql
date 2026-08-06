-- CAP-002 Phase 4.1 routing validation and variable foundation
-- disposable performance probe (3 dimensions).
--
-- Dimension 1 mirrors test-workflow-executable-definition-validation-
-- performance.sql's own maximal 200-node/395-edge chain exactly
-- (same node/edge counts), swapping approval nodes for
-- gateway_exclusive nodes (each with the minimum 2 outbound edges:
-- one conditional, one default) — a direct, apples-to-apples
-- comparison of gateway validation cost against the already-measured
-- Phase 2B.1 approval-validation baseline at the same scale.
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO organizations(id,name,type,code) VALUES ('64940000-0000-0000-0000-000000000001','WF Routing Val Performance','authority','WFRVP');
INSERT INTO auth.users(id,email) VALUES ('64940000-0001-0000-0000-000000000001','perf@wfrvp.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('64940000-0001-0000-0000-000000000001','64940000-0000-0000-0000-000000000001','WFRVP-1','WFRVP Admin','perf@wfrvp.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('64940000-0001-0000-0000-000000000001','organization','64940000-0000-0000-0000-000000000001','authority_admin',true,true);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64940000-0001-0000-0000-000000000001"}',true);

-- ── Dimension 1: maximal 200-node/395-edge gateway chain. ─────────
DO $$
DECLARE
  v_nodes JSONB := '[]'::JSONB;
  v_edges JSONB := '[]'::JSONB;
  v_payload JSONB;
  v_g INTEGER;
  v_key TEXT;
  v_next TEXT;
  v_start_ts TIMESTAMPTZ;
  v_create_ms NUMERIC;
  v_publish_ms NUMERIC;
  v_def_id UUID;
  v_ver_id UUID;
BEGIN
  v_nodes := v_nodes || jsonb_build_object('key','start','type','start','config','{}'::jsonb);
  v_nodes := v_nodes || jsonb_build_object('key','end_default','type','end','config',jsonb_build_object('outcome_code','d'));
  v_nodes := v_nodes || jsonb_build_object('key','end_matched','type','end','config',jsonb_build_object('outcome_code','m'));
  v_edges := v_edges || jsonb_build_object('source','start','target','g1','outcome','started','priority',0,'default',false);

  FOR v_g IN 1..197 LOOP
    v_key := 'g' || v_g;
    v_next := CASE WHEN v_g = 197 THEN 'end_default' ELSE 'g' || (v_g + 1) END;
    v_nodes := v_nodes || jsonb_build_object('key', v_key, 'type', 'gateway_exclusive', 'config', '{}'::jsonb);
    v_edges := v_edges || jsonb_build_object(
      'source', v_key, 'target', 'end_matched', 'outcome', 'routed', 'priority', 0, 'default', false,
      'condition', jsonb_build_object('source','instance_variable','variable_name','v'||v_g,'operator','is_null')
    );
    v_edges := v_edges || jsonb_build_object('source', v_key, 'target', v_next, 'outcome', 'routed', 'priority', 1, 'default', true);
  END LOOP;

  IF jsonb_array_length(v_nodes) <> 200 THEN
    RAISE EXCEPTION 'fixture node count is not exactly 200: %', jsonb_array_length(v_nodes);
  END IF;
  IF jsonb_array_length(v_edges) <> 395 THEN
    RAISE EXCEPTION 'fixture edge count is not exactly 395: %', jsonb_array_length(v_edges);
  END IF;

  v_payload := jsonb_build_object('schema_version',2,'entry_node','start','nodes',v_nodes,'edges',v_edges);

  v_start_ts := clock_timestamp();
  SELECT definition_id, version_id INTO v_def_id, v_ver_id FROM create_workflow_definition(
    '64940000-0000-0000-0000-000000000001','wfrvp_max_flow','WFRVP Max Flow','opaque_case',
    v_payload, '64940000-1000-0000-0000-000000000001'
  );
  v_create_ms := extract(epoch FROM clock_timestamp() - v_start_ts) * 1000;

  v_start_ts := clock_timestamp();
  PERFORM publish_workflow_definition_version(v_ver_id, 0, '64940000-1000-0000-0000-000000000002');
  v_publish_ms := extract(epoch FROM clock_timestamp() - v_start_ts) * 1000;

  RAISE NOTICE 'Dimension 1 (maximal 200-node/395-edge gateway_exclusive chain): create+canonicalize % ms, publish (re-canonicalize+verify) % ms', round(v_create_ms,2), round(v_publish_ms,2);

  IF v_create_ms > 5000 OR v_publish_ms > 5000 THEN
    RAISE EXCEPTION 'gateway validation performance regression: create=% ms publish=% ms', v_create_ms, v_publish_ms;
  END IF;
END $$;

-- ── Dimension 2: a single instance-variable write against a fresh
--    instance. ─────────────────────────────────────────────────────
DO $$
DECLARE
  v_ver_id UUID;
  v_inst_id UUID;
  v_start_ts TIMESTAMPTZ;
  v_write_ms NUMERIC;
BEGIN
  SELECT version_id INTO v_ver_id FROM create_workflow_definition(
    '64940000-0000-0000-0000-000000000001','wfrvp_var_flow','WFRVP Var Flow','opaque_case',
    '{"nodes":[],"edges":[]}'::jsonb,'64940000-1000-0000-0000-000000000003');
  PERFORM publish_workflow_definition_version(v_ver_id, 0, '64940000-1000-0000-0000-000000000004');
  v_inst_id := create_workflow_instance(
    v_ver_id,'opaque_case','64940000-2000-0000-0000-000000000001',
    '64940000-0000-0000-0000-000000000001','64940000-1000-0000-0000-000000000005',NULL);

  v_start_ts := clock_timestamp();
  PERFORM set_workflow_instance_variable(v_inst_id,'priority_band','string','"urgent"'::jsonb,'restricted','64940000-1000-0000-0000-000000000006');
  v_write_ms := extract(epoch FROM clock_timestamp() - v_start_ts) * 1000;

  RAISE NOTICE 'Dimension 2 (single instance-variable write against a fresh instance): % ms', round(v_write_ms,2);
  IF v_write_ms > 1000 THEN
    RAISE EXCEPTION 'variable write performance regression: % ms', v_write_ms;
  END IF;
END $$;

-- ── Dimension 3: a variable write/lookup against an instance that
--    already has 1,000 pre-existing variable rows, confirming the
--    existing idx_workflow_variables_instance (instance_id,
--    variable_name) index is used for the lookup inside
--    set_workflow_instance_variable, not a sequential scan.
--    workflow_variables has no direct write grant for authenticated,
--    so the bulk fixture insert below runs as the connecting
--    superuser, matching the established pattern in
--    test-workflow-approval-round-lifecycle-performance.sql. ──────
CREATE TEMP TABLE wfrvp_bulk_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '64940000-0000-0000-0000-000000000001','wfrvp_bulk_flow','WFRVP Bulk Flow','opaque_case',
  '{"nodes":[],"edges":[]}'::jsonb,'64940000-1000-0000-0000-000000000007'))
INSERT INTO wfrvp_bulk_ids SELECT 'ver', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfrvp_bulk_ids WHERE name='ver'),0,'64940000-1000-0000-0000-000000000008');
INSERT INTO wfrvp_bulk_ids SELECT 'inst', create_workflow_instance(
  (SELECT id FROM wfrvp_bulk_ids WHERE name='ver'),'opaque_case','64940000-2000-0000-0000-000000000002',
  '64940000-0000-0000-0000-000000000001','64940000-1000-0000-0000-000000000009',NULL);
RESET ROLE;

INSERT INTO workflow_variables (instance_id, variable_name, value_type, variable_value, classification, lock_version, created_by, updated_by)
SELECT (SELECT id FROM wfrvp_bulk_ids WHERE name='inst'), 'bulk_var_' || g, 'number', to_jsonb(g), 'restricted', 1,
       '64940000-0001-0000-0000-000000000001', '64940000-0001-0000-0000-000000000001'
FROM generate_series(1,1000) g;

DO $$
DECLARE
  v_inst_id UUID := (SELECT id FROM wfrvp_bulk_ids WHERE name='inst');
  v_start_ts TIMESTAMPTZ;
  v_write_ms NUMERIC;
  v_plan TEXT;
  v_line TEXT;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"64940000-0001-0000-0000-000000000001"}',true);

  v_start_ts := clock_timestamp();
  PERFORM set_workflow_instance_variable(v_inst_id,'priority_band','string','"urgent"'::jsonb,'restricted','64940000-1000-0000-0000-000000000010');
  v_write_ms := extract(epoch FROM clock_timestamp() - v_start_ts) * 1000;

  RAISE NOTICE 'Dimension 3 (variable write against an instance with 1,000 pre-existing variables): % ms', round(v_write_ms,2);
  IF v_write_ms > 1000 THEN
    RAISE EXCEPTION 'variable write performance regression under bulk pre-existing rows: % ms', v_write_ms;
  END IF;

  -- Plain SELECT (not FOR UPDATE, which requires UPDATE privilege
  -- the authenticated role deliberately lacks on this SELECT-only
  -- table) — the index choice for this lookup is identical to the
  -- locked SELECT ... FOR UPDATE performed inside the SECURITY
  -- DEFINER set_workflow_instance_variable function above.
  v_plan := '';
  FOR v_line IN EXECUTE
    'EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) SELECT * FROM workflow_variables WHERE instance_id = $1 AND variable_name = $2'
    USING v_inst_id, 'bulk_var_500'
  LOOP
    v_plan := v_plan || v_line || E'\n';
  END LOOP;
  RAISE NOTICE 'Lookup plan: %', v_plan;
  IF v_plan NOT ILIKE '%Index%' THEN
    RAISE EXCEPTION 'expected the variable lookup to use idx_workflow_variables_instance, plan was: %', v_plan;
  END IF;
END $$;

RESET ROLE;
ROLLBACK;

DO $$ BEGIN RAISE NOTICE 'Workflow routing validation foundation performance probe PASSED'; END $$;
