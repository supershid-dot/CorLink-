-- CAP-002 Phase 4.1 routing validation and variable foundation
-- RLS suite (6 scenarios). Runs in one transaction and leaves no
-- fixtures.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wfrvr_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfrvr_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfrvr_results, wfrvr_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('64920000-0000-0000-0000-000000000001','WF Routing Val RLS A','authority','WFRVR-A'),
 ('64920000-0000-0000-0000-000000000002','WF Routing Val RLS B','authority','WFRVR-B');
INSERT INTO auth.users(id,email) VALUES
 ('64920000-0001-0000-0000-000000000001','admin@wfrvr.local'),
 ('64920000-0001-0000-0000-000000000002','outsider@wfrvr.local'),
 ('64920000-0001-0000-0000-000000000003','otherorg@wfrvr.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('64920000-0001-0000-0000-000000000001','64920000-0000-0000-0000-000000000001','WFRVR-1','Admin','admin@wfrvr.local',true),
 ('64920000-0001-0000-0000-000000000002','64920000-0000-0000-0000-000000000001','WFRVR-2','Outsider','outsider@wfrvr.local',true),
 ('64920000-0001-0000-0000-000000000003','64920000-0000-0000-0000-000000000002','WFRVR-3','OtherOrg','otherorg@wfrvr.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('64920000-0001-0000-0000-000000000001','organization','64920000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('64920000-0001-0000-0000-000000000002','organization','64920000-0000-0000-0000-000000000001','staff',true,true),
 ('64920000-0001-0000-0000-000000000003','organization','64920000-0000-0000-0000-000000000002','authority_admin',true,true);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64920000-0001-0000-0000-000000000001"}',true);
WITH made AS (SELECT * FROM create_workflow_definition(
  '64920000-0000-0000-0000-000000000001','wfrvr_flow','WFRVR Flow','opaque_case',
  '{"nodes":[],"edges":[]}'::jsonb, gen_random_uuid()))
INSERT INTO wfrvr_ids SELECT 'v', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wfrvr_ids WHERE name='v'),0,gen_random_uuid());
INSERT INTO wfrvr_ids SELECT 'i', create_workflow_instance(
  (SELECT id FROM wfrvr_ids WHERE name='v'),'opaque_case',gen_random_uuid(),
  '64920000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
RESET ROLE;

-- ── 1: the instance owner/manager can write an instance variable. ─
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64920000-0001-0000-0000-000000000001"}',true);
SELECT * FROM set_workflow_instance_variable(
  (SELECT id FROM wfrvr_ids WHERE name='i'),'x','boolean','true'::jsonb,'restricted',gen_random_uuid());
INSERT INTO wfrvr_results VALUES (1,'the instance owner/manager can write an instance variable via can_manage_workflow_instance authorization');
RESET ROLE;

-- ── 2: a same-organization non-manager outsider cannot write an
--    instance variable. ────────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64920000-0001-0000-0000-000000000002"}',true);
DO $$
BEGIN
  BEGIN
    PERFORM set_workflow_instance_variable((SELECT id FROM wfrvr_ids WHERE name='i'),'y','boolean','true'::jsonb,'restricted',gen_random_uuid());
    RAISE EXCEPTION 'outsider was able to write a variable';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%not found or not manageable%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfrvr_results VALUES (2,'a same-organization non-manager outsider cannot write an instance variable');
RESET ROLE;

-- ── 3: a cross-organization actor cannot write an instance
--    variable. ──────────────────────────────────────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64920000-0001-0000-0000-000000000003"}',true);
DO $$
BEGIN
  BEGIN
    PERFORM set_workflow_instance_variable((SELECT id FROM wfrvr_ids WHERE name='i'),'z','boolean','true'::jsonb,'restricted',gen_random_uuid());
    RAISE EXCEPTION 'cross-org actor was able to write a variable';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%not found or not manageable%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wfrvr_results VALUES (3,'a cross-organization actor cannot write an instance variable');
RESET ROLE;

-- ── 4: written variables remain visible only through the existing
--    Phase 1 SELECT-only RLS policy (owner/manager authority) — the
--    outsider still cannot read them either. ─────────────────────
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64920000-0001-0000-0000-000000000001"}',true);
DO $$ BEGIN IF (SELECT count(*) FROM workflow_variables WHERE instance_id=(SELECT id FROM wfrvr_ids WHERE name='i')) <> 1
  THEN RAISE EXCEPTION 'manager should see the one written variable'; END IF; END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"64920000-0001-0000-0000-000000000002"}',true);
DO $$ BEGIN IF (SELECT count(*) FROM workflow_variables WHERE instance_id=(SELECT id FROM wfrvr_ids WHERE name='i')) <> 0
  THEN RAISE EXCEPTION 'outsider should not see any variable row'; END IF; END $$;
INSERT INTO wfrvr_results VALUES (4,'variable visibility remains governed by the existing Phase 1 SELECT-only workflow_variables_select policy, unmodified');
RESET ROLE;

-- ── 5: no direct write grant exists on workflow_variables —
--    mutation is only possible through set_workflow_instance_variable. ─
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema='public' AND table_name='workflow_variables'
      AND grantee IN ('anon','authenticated') AND privilege_type <> 'SELECT'
  ) THEN RAISE EXCEPTION 'workflow_variables has a direct write grant'; END IF;
END $$;
INSERT INTO wfrvr_results VALUES (5,'workflow_variables has no direct INSERT/UPDATE/DELETE grant; mutation is possible only through set_workflow_instance_variable');

-- ── 6: set_workflow_instance_variable reuses can_manage_workflow_instance,
--    not a duplicated authorization model. ────────────────────────
DO $$
BEGIN
  IF (SELECT pg_get_functiondef('set_workflow_instance_variable(uuid,text,text,jsonb,text,uuid)'::regprocedure)) NOT ILIKE '%can_manage_workflow_instance%'
  THEN RAISE EXCEPTION 'set_workflow_instance_variable does not reuse can_manage_workflow_instance'; END IF;
END $$;
INSERT INTO wfrvr_results VALUES (6,'existing can_manage_workflow_instance() authorization is reused by set_workflow_instance_variable, not duplicated');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfrvr_results;
  IF v_count <> 6 THEN
    RAISE EXCEPTION 'Workflow routing validation foundation RLS tests FAILED: expected 6, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow routing validation foundation RLS tests PASSED: %/6', v_count;
END $$;

ROLLBACK;
