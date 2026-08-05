-- CAP-002 Phase 2B.1 executable definition validation structural validator (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  IF to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)') IS NULL THEN
    v_missing := v_missing || 'canonicalize_workflow_definition_payload ';
  ELSE
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)'))
       OR NOT EXISTS (
         SELECT 1 FROM pg_proc p
         WHERE p.oid = to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)')
           AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
       ) THEN
      v_missing := v_missing || 'canonicalize-security ';
    END IF;
  END IF;

  -- Not granted to PUBLIC, anon, or authenticated — internal only.
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'canonicalize_workflow_definition_payload'
      AND (
        has_function_privilege('anon', p.oid, 'EXECUTE')
        OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
      )
  ) THEN v_missing := v_missing || 'canonicalize-execute-leak '; END IF;

  -- Existing RPC signatures unchanged (CREATE OR REPLACE preserves them).
  FOREACH v_def IN ARRAY ARRAY[
    'create_workflow_definition(uuid,text,text,text,jsonb,uuid)',
    'create_workflow_definition_version(uuid,jsonb,uuid)',
    'publish_workflow_definition_version(uuid,bigint,uuid)'
  ] LOOP
    IF to_regprocedure('public.' || v_def) IS NULL THEN
      v_missing := v_missing || v_def || '-missing ';
    ELSIF NOT has_function_privilege('authenticated', to_regprocedure('public.' || v_def), 'EXECUTE') THEN
      v_missing := v_missing || v_def || '-not-granted ';
    ELSIF has_function_privilege('anon', to_regprocedure('public.' || v_def), 'EXECUTE') THEN
      v_missing := v_missing || v_def || '-anon-leak ';
    END IF;
  END LOOP;

  -- The legacy Phase 1 inert-only publish rule is still present verbatim
  -- (byte-for-byte, gated behind an ELSE branch) — the exact same
  -- structural fingerprint validate-workflow-backend-foundation.sql's
  -- own "inert-publish-boundary" check already looks for.
  SELECT pg_get_functiondef('publish_workflow_definition_version(uuid,bigint,uuid)'::regprocedure) INTO v_def;
  IF v_def NOT ILIKE '%jsonb_array_length%nodes%'
     OR v_def NOT ILIKE '%jsonb_array_length%edges%'
     OR v_def NOT ILIKE '%Phase 1 may publish only an inert workflow definition%'
     OR v_def NOT ILIKE '%schema_version%'
     OR v_def NOT ILIKE '%canonicalize_workflow_definition_payload%'
     OR v_def ILIKE '%advance_workflow%'
     OR v_def ILIKE '%create_workflow_instance%'
  THEN v_missing := v_missing || 'publish-dual-branch '; END IF;

  -- create_workflow_definition/_version must gate canonicalization
  -- strictly on the payload's own 'schema_version' key, never on
  -- emptiness of nodes/edges (that would collide with legacy Phase 1
  -- inputs and regress the approved Phase 1 behavioral suite).
  SELECT pg_get_functiondef('create_workflow_definition(uuid,text,text,text,jsonb,uuid)'::regprocedure) INTO v_def;
  IF v_def NOT ILIKE '%? ''schema_version''%'
     OR v_def NOT ILIKE '%canonicalize_workflow_definition_payload%'
  THEN v_missing := v_missing || 'create-definition-gate '; END IF;

  SELECT pg_get_functiondef('create_workflow_definition_version(uuid,jsonb,uuid)'::regprocedure) INTO v_def;
  IF v_def NOT ILIKE '%? ''schema_version''%'
     OR v_def NOT ILIKE '%canonicalize_workflow_definition_payload%'
  THEN v_missing := v_missing || 'create-version-gate '; END IF;

  -- No new tables, no new RLS policies, no widened grants — THIS
  -- milestone (Phase 2B.1) touches zero storage shape. Asserts a
  -- lower bound (>= 10, the Phase 1 baseline), not an exact count —
  -- docs/63 itself explicitly defers workflow_approval_rounds/
  -- workflow_approval_positions DDL to "that [activation] implementation"
  -- (Phase 2B.2), so a later, separately-approved milestone legitimately
  -- growing the table count is not a Phase 2B.1 regression. What this
  -- validator guarantees is narrower and still fully intact: Phase
  -- 2B.1 itself added none, and whatever exists keeps SELECT-only
  -- posture (checked immediately below).
  IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'workflow\_%' ESCAPE '\') < 10
  THEN v_missing := v_missing || 'unexpected-new-table '; END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema = 'public'
      AND table_name LIKE 'workflow\_%' ESCAPE '\'
      AND grantee IN ('anon','authenticated')
      AND privilege_type <> 'SELECT'
  ) THEN v_missing := v_missing || 'direct-write-grant '; END IF;

  -- No runtime/activation/token/graph-advancement RPCs were added —
  -- this milestone is validation-only.
  IF to_regprocedure('public.activate_workflow_definition(uuid)') IS NOT NULL
     OR to_regprocedure('public.advance_workflow_instance(uuid)') IS NOT NULL
     OR to_regprocedure('public.decide_workflow_work_item(uuid,text)') IS NOT NULL
  THEN v_missing := v_missing || 'runtime-rpc-present '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid = 'workflow_definition_versions'::regclass
      AND conname = 'workflow_definition_versions_hash_check'
  ) THEN v_missing := v_missing || 'hash-check-constraint '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Workflow executable definition validation structural check FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Workflow executable definition validation structural check PASSED (1 internal validator function, pinned definer/search_path, no execute leak, dual legacy/executable publish branch, schema_version-gated canonicalization, zero new storage, unchanged grants, no runtime RPCs).';
END $$;
