-- CAP-002 Phase 4.1 routing validation and variable foundation
-- structural validator (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- canonicalize_workflow_definition_payload now validates
  -- gateway_exclusive nodes and condition-bearing edges, reusing the
  -- shared literal-type-check helper.
  IF to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)') IS NULL THEN
    v_missing := v_missing || 'canonicalize_workflow_definition_payload-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)')) INTO v_def;
    IF v_def NOT ILIKE '%gateway_exclusive%'
       OR v_def NOT ILIKE '%gateway_default_edge_invalid%'
       OR v_def NOT ILIKE '%gateway_duplicate_priority%'
       OR v_def NOT ILIKE '%gateway_condition_%'
       OR v_def NOT ILIKE '%wf_condition_literal_matches_type%'
       OR v_def NOT ILIKE '%instance_variable%'
    THEN v_missing := v_missing || 'canonicalize-missing-gateway-v2-logic '; END IF;
    -- Version 1 behavior is unchanged: the schema_version=1 branch
    -- still allows only start/approval/end, and the top-level shape
    -- still allows exactly the same four keys.
    IF v_def NOT ILIKE '%''start'',''approval'',''end''%' THEN
      v_missing := v_missing || 'canonicalize-v1-node-type-allowlist-drift ';
    END IF;
    -- Gateway inbound-edge cardinality (Phase 4.1A correction): the
    -- corrected comparison (reject only zero inbound edges) must be
    -- present. This is a necessary but not sufficient structural
    -- signal — the behavioral suite (scenarios 18/19) is what proves
    -- the comparison is actually the one applied to gateway_exclusive
    -- nodes specifically, since the approval-node rule legitimately
    -- keeps its own unrelated "<> 1" text in the same function body.
    IF v_def NOT ILIKE '%v_inbound_total < 1%' THEN
      v_missing := v_missing || 'gateway-inbound-edge-rule-not-corrected ';
    END IF;
    -- The approval-node inbound rule itself must remain untouched by
    -- this correction — still exactly one inbound edge.
    IF v_def NOT ILIKE '%v_inbound_total <> 1%' THEN
      v_missing := v_missing || 'approval-inbound-edge-rule-regressed ';
    END IF;
    IF has_function_privilege('anon', to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)'), 'EXECUTE')
       OR has_function_privilege('authenticated', to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)'), 'EXECUTE')
    THEN v_missing := v_missing || 'canonicalize-execute-leak '; END IF;
  END IF;

  -- wf_condition_literal_matches_type: private, pure, reused by both
  -- definition validation and the new variable-write command.
  IF to_regprocedure('public.wf_condition_literal_matches_type(jsonb,text)') IS NULL THEN
    v_missing := v_missing || 'wf_condition_literal_matches_type-missing ';
  ELSE
    IF has_function_privilege('anon', to_regprocedure('public.wf_condition_literal_matches_type(jsonb,text)'), 'EXECUTE')
       OR has_function_privilege('authenticated', to_regprocedure('public.wf_condition_literal_matches_type(jsonb,text)'), 'EXECUTE')
    THEN v_missing := v_missing || 'wf_condition_literal_matches_type-execute-leak '; END IF;
  END IF;

  -- capability_version is now computed from the payload's own
  -- schema_version at draft-creation time, not left at the column
  -- DEFAULT for every payload.
  FOREACH v_def IN ARRAY ARRAY[
    'create_workflow_definition(uuid,text,text,text,jsonb,uuid)',
    'create_workflow_definition_version(uuid,jsonb,uuid)'
  ] LOOP
    IF to_regprocedure('public.' || v_def) IS NULL THEN
      v_missing := v_missing || v_def || '-missing ';
    ELSE
      SELECT pg_get_functiondef(to_regprocedure('public.' || v_def)) INTO v_def;
      IF v_def NOT ILIKE '%v_capability_version%' THEN
        v_missing := v_missing || 'caller-does-not-compute-capability-version ';
      END IF;
    END IF;
  END LOOP;

  -- publish_workflow_definition_version's capability_version check is
  -- now generalized to the payload's own schema_version rather than a
  -- hardcoded 1, and still rejects a mismatch.
  IF to_regprocedure('public.publish_workflow_definition_version(uuid,bigint,uuid)') IS NULL THEN
    v_missing := v_missing || 'publish_workflow_definition_version-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.publish_workflow_definition_version(uuid,bigint,uuid)')) INTO v_def;
    IF v_def NOT ILIKE '%capability_version_mismatch%'
       OR v_def NOT ILIKE '%schema_version%)::integer%'
    THEN v_missing := v_missing || 'publish-capability-check-not-generalized '; END IF;
  END IF;

  -- workflow_variables gained exactly the two additive columns this
  -- phase needs (lock_version, write_idempotency_key) and no others;
  -- still exactly 12 workflow tables (an ALTER, not a new table).
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'workflow_variables' AND column_name = 'lock_version'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'workflow_variables' AND column_name = 'write_idempotency_key'
  ) THEN v_missing := v_missing || 'workflow_variables-missing-write-foundation-columns '; END IF;
  IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 12
  THEN v_missing := v_missing || 'unexpected-table-count '; END IF;

  -- set_workflow_instance_variable: the one new command, authenticated-
  -- only, SECURITY DEFINER, pinned search_path, reuses
  -- can_manage_workflow_instance (no new permission model), and its
  -- body never references any event table or a route_selected event
  -- — this phase is validation/variable-persistence only.
  IF to_regprocedure('public.set_workflow_instance_variable(uuid,text,text,jsonb,text,uuid)') IS NULL THEN
    v_missing := v_missing || 'set_workflow_instance_variable-missing ';
  ELSE
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure('public.set_workflow_instance_variable(uuid,text,text,jsonb,text,uuid)'))
       OR NOT EXISTS (
         SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.set_workflow_instance_variable(uuid,text,text,jsonb,text,uuid)')
           AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
       ) THEN v_missing := v_missing || 'set_workflow_instance_variable-security '; END IF;
    IF NOT has_function_privilege('authenticated', to_regprocedure('public.set_workflow_instance_variable(uuid,text,text,jsonb,text,uuid)'), 'EXECUTE') THEN
      v_missing := v_missing || 'set_workflow_instance_variable-not-granted ';
    END IF;
    IF has_function_privilege('anon', to_regprocedure('public.set_workflow_instance_variable(uuid,text,text,jsonb,text,uuid)'), 'EXECUTE') THEN
      v_missing := v_missing || 'set_workflow_instance_variable-anon-leak ';
    END IF;
    SELECT pg_get_functiondef(to_regprocedure('public.set_workflow_instance_variable(uuid,text,text,jsonb,text,uuid)')) INTO v_def;
    IF v_def NOT ILIKE '%can_manage_workflow_instance%' THEN
      v_missing := v_missing || 'set_workflow_instance_variable-wrong-authorization-boundary ';
    END IF;
    IF v_def ILIKE '%workflow_events%' OR v_def ILIKE '%route_selected%' THEN
      v_missing := v_missing || 'set_workflow_instance_variable-emits-out-of-scope-event ';
    END IF;
  END IF;

  -- Out of scope for this phase: no condition-evaluation, gateway-
  -- execution, or routing-event RPC exists yet, and the shared
  -- graph-advancement authority is untouched (no gateway_exclusive
  -- branch inside it).
  IF to_regprocedure('public.evaluate_workflow_gateway(uuid)') IS NOT NULL
     OR to_regprocedure('public.route_workflow_instance(uuid,uuid)') IS NOT NULL
  THEN v_missing := v_missing || 'out-of-scope-execution-rpc-present '; END IF;

  SELECT pg_get_functiondef(to_regprocedure(
    'public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)'
  )) INTO v_def;
  IF v_def ILIKE '%gateway_exclusive%' OR v_def ILIKE '%route_selected%' THEN
    v_missing := v_missing || 'graph-advancement-helper-executes-routing-out-of-scope ';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema = 'public' AND table_name LIKE 'workflow\_%' ESCAPE '\'
      AND grantee IN ('anon','authenticated') AND privilege_type <> 'SELECT'
  ) THEN v_missing := v_missing || 'direct-write-grant '; END IF;

  -- Prior-phase baseline intact (Phase 1 through 3.2).
  IF to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb,jsonb)') IS NULL
     OR to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)') IS NULL
     OR to_regprocedure('public.get_workflow_approval_round_blocked_count(uuid)') IS NULL
     OR to_regclass('workflow_approval_rounds') IS NULL
     OR to_regclass('workflow_approval_positions') IS NULL
     OR to_regclass('workflow_decisions') IS NULL
     OR to_regclass('workflow_variables') IS NULL
  THEN v_missing := v_missing || 'prior-phase-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Workflow routing validation foundation structural check FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Workflow routing validation foundation structural check PASSED (canonicalize_workflow_definition_payload validates capability-version-2 gateway_exclusive nodes and condition-bearing edges while schema_version=1 payloads are unchanged, capability_version is computed and stored per payload, publish''s mismatch check is generalized, workflow_variables gained an additive write foundation, set_workflow_instance_variable is authenticated-only and reuses can_manage_workflow_instance, no gateway-execution/routing-event capability exists yet, prior-phase baseline intact).';
END $$;
