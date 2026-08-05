-- CAP-002 Phase 2B.1 RLS suite (4 scenarios)
-- Runs in one transaction and leaves no fixtures.
--
-- This milestone adds zero new tables and zero new RLS policies —
-- the Phase 1 SELECT-only posture on the 10 workflow_* tables is
-- completely unchanged (see docs/64 "RLS"). What genuinely needs
-- confirming here is narrower: the one new internal helper function
-- (canonicalize_workflow_definition_payload) must not be directly
-- callable by anon/authenticated, and the existing definition-
-- management RLS/authorization boundary must still gate who can
-- create/publish a schema-version-1 definition exactly as it already
-- gated inert ones.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wfvrls_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfvrls_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfvrls_results, wfvrls_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('63100000-0000-0000-0000-000000000001','WF Validation RLS A','authority','WFVR-A'),
 ('63100000-0000-0000-0000-000000000002','WF Validation RLS B','authority','WFVR-B');
INSERT INTO auth.users(id,email) VALUES
 ('63100000-0001-0000-0000-000000000001','admin@wfvr.local'),
 ('63100000-0001-0000-0000-000000000002','staff@wfvr.local'),
 ('63100000-0001-0000-0000-000000000003','otheradmin@wfvr.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('63100000-0001-0000-0000-000000000001','63100000-0000-0000-0000-000000000001','WFVR-1','Admin','admin@wfvr.local',true),
 ('63100000-0001-0000-0000-000000000002','63100000-0000-0000-0000-000000000001','WFVR-2','Staff','staff@wfvr.local',true),
 ('63100000-0001-0000-0000-000000000003','63100000-0000-0000-0000-000000000002','WFVR-3','Other Admin','otheradmin@wfvr.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('63100000-0001-0000-0000-000000000001','organization','63100000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('63100000-0001-0000-0000-000000000002','organization','63100000-0000-0000-0000-000000000001','staff',true,true),
 ('63100000-0001-0000-0000-000000000003','organization','63100000-0000-0000-0000-000000000002','authority_admin',true,true);

-- ── 1: canonicalize_workflow_definition_payload is not directly
--    executable by authenticated or anon (internal-only). ──────────
DO $$
BEGIN
  IF has_function_privilege('authenticated', 'canonicalize_workflow_definition_payload(jsonb,uuid)'::regprocedure, 'EXECUTE')
     OR has_function_privilege('anon', 'canonicalize_workflow_definition_payload(jsonb,uuid)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'canonicalize_workflow_definition_payload is directly executable';
  END IF;
END $$;
INSERT INTO wfvrls_results VALUES (1,'internal canonicalizer has no direct execute grant');

-- ── 2: an org admin can create+publish a schema-version-1 definition
--    for their own organization (existing can_manage_workflow_
--    definition() authorization, unchanged, now exercised against an
--    executable payload). ───────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"63100000-0001-0000-0000-000000000001"}',true);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '63100000-0000-0000-0000-000000000001','wfvr_flow','WFVR Flow','opaque_case',
  '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"e","type":"end","config":{"outcome_code":"x"}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false}]}'::jsonb,
  '63100000-1000-0000-0000-000000000001'))
INSERT INTO wfvrls_ids SELECT 'definition',definition_id FROM made UNION ALL SELECT 'version',version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfvrls_ids WHERE name='version'),0,'63100000-1000-0000-0000-000000000002');
INSERT INTO wfvrls_results VALUES (2,'org admin creates and publishes a schema-version-1 definition for their own org');

-- ── 3: ordinary staff (not admin) cannot create a workflow definition
--    at all — unchanged from Phase 1, still gates schema-version-1
--    input the same as inert input. ─────────────────────────────────
SELECT set_config('request.jwt.claims','{"sub":"63100000-0001-0000-0000-000000000002"}',true);
DO $$
DECLARE v_rejected BOOLEAN := FALSE;
BEGIN
  BEGIN
    PERFORM create_workflow_definition(
      '63100000-0000-0000-0000-000000000001','wfvr_flow_staff','x','opaque_case',
      '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"e","type":"end","config":{"outcome_code":"x"}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false}]}'::jsonb,
      '63100000-1000-0000-0000-000000000003'
    );
  EXCEPTION WHEN OTHERS THEN v_rejected := TRUE;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'staff should not be able to create a workflow definition'; END IF;
END $$;
INSERT INTO wfvrls_results VALUES (3,'ordinary staff cannot create a workflow definition');

-- ── 4: another organization's admin cannot version or publish this
--    definition — unchanged cross-organization boundary. ───────────
SELECT set_config('request.jwt.claims','{"sub":"63100000-0001-0000-0000-000000000003"}',true);
DO $$
DECLARE v_rejected BOOLEAN := FALSE;
BEGIN
  BEGIN
    PERFORM create_workflow_definition_version(
      (SELECT id FROM wfvrls_ids WHERE name='definition'),
      '{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"e","type":"end","config":{"outcome_code":"y"}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false}]}'::jsonb,
      '63100000-1000-0000-0000-000000000004'
    );
  EXCEPTION WHEN OTHERS THEN v_rejected := TRUE;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'a different organization''s admin should not be able to version this definition'; END IF;
END $$;
INSERT INTO wfvrls_results VALUES (4,'cross-organization admin cannot version another organization''s definition');

RESET ROLE;

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfvrls_results;
  IF v_count <> 4 THEN
    RAISE EXCEPTION 'Workflow executable definition validation RLS tests FAILED: expected 4, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow executable definition validation RLS tests PASSED: %/4', v_count;
END $$;

ROLLBACK;
