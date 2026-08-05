-- CAP-002 Phase 2B.1 repeatable concurrency suite (3 scenarios)
-- Disposable local PostgreSQL only; requires dblink.
--
-- This milestone adds no new locking primitive — publication and
-- draft creation still serialize on the existing definition-family
-- row lock (FOR UPDATE) established in Phase 1. What these scenarios
-- confirm is that adding canonicalization/validation INSIDE that
-- existing lock scope did not introduce a new race window: exactly
-- one winner, no duplicate published/draft version, and identical
-- concurrent commands still converge on one shared result.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE TEMP TABLE wfvc_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);

INSERT INTO organizations(id,name,type,code) VALUES
 ('63200000-0000-0000-0000-000000000001','WF Validation Concurrency','authority','WFVC-A');
INSERT INTO auth.users(id,email) VALUES
 ('63200000-0001-0000-0000-000000000001','a@wfvc.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('63200000-0001-0000-0000-000000000001','63200000-0000-0000-0000-000000000001','WFVC-1','Concurrency Admin','a@wfvc.local',true,false);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('63200000-0001-0000-0000-000000000001','organization','63200000-0000-0000-0000-000000000001','authority_admin',true,true);

\set PAYLOAD1 '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"e","type":"end","config":{"outcome_code":"x"}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false}]}\''

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"63200000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '63200000-0000-0000-0000-000000000001','wfvc_flow','WFVC Flow','opaque_case',
  :PAYLOAD1::jsonb, '63200000-1000-0000-0000-000000000001'))
SELECT definition_id, version_id INTO TEMP wfvc_ids FROM made;
RESET ROLE;

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"63200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"63200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);

-- ── 1: two concurrent PUBLISH attempts on the same schema-version-1
--    draft, with DIFFERENT idempotency keys, forcing a genuine race
--    (not an idempotent replay) — exactly one wins, the other sees a
--    stale-lock-version conflict, and the definition ends up
--    published exactly once. ─────────────────────────────────────
SELECT dblink_send_query('w1', format(
  $q$SELECT publish_workflow_definition_version('%s'::uuid,0,'63200000-1000-0000-0000-000000000002'::uuid)::text$q$,
  (SELECT version_id FROM wfvc_ids)));
SELECT dblink_send_query('w2', format(
  $q$SELECT publish_workflow_definition_version('%s'::uuid,0,'63200000-1000-0000-0000-000000000003'::uuid)::text$q$,
  (SELECT version_id FROM wfvc_ids)));
CREATE TEMP TABLE wfvc_c1_result(v text, err text);
CREATE TEMP TABLE wfvc_c2_result(v text, err text);
DO $$
DECLARE v_val TEXT; v_err TEXT;
BEGIN
  BEGIN
    SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
  END;
  INSERT INTO wfvc_c1_result VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_val TEXT; v_err TEXT;
BEGIN
  BEGIN
    SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
  END;
  INSERT INTO wfvc_c2_result VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_winners INTEGER;
BEGIN
  SELECT count(*) INTO v_winners FROM (
    SELECT v FROM wfvc_c1_result WHERE v IS NOT NULL
    UNION ALL
    SELECT v FROM wfvc_c2_result WHERE v IS NOT NULL
  ) w;
  IF v_winners <> 1 THEN
    RAISE EXCEPTION 'expected exactly one publish winner, got %', v_winners;
  END IF;
  IF (SELECT count(*) FROM workflow_definition_versions WHERE id = (SELECT version_id FROM wfvc_ids) AND status = 'published') <> 1 THEN
    RAISE EXCEPTION 'definition version is not published exactly once';
  END IF;
END $$;
INSERT INTO wfvc_results VALUES (1,'concurrent racing publish attempts converge on exactly one winner, no duplicate publication');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 2: two concurrent create_workflow_definition_version calls
--    trying to create a SECOND (schema-version-1) draft for the same
--    now-published family — exactly one succeeds, the other still
--    hits the pre-existing "already has a draft" rule (unchanged by
--    this milestone; canonicalization runs before that check, but
--    the family row lock still serializes the two attempts). ──────
SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"63200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"63200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);

SELECT dblink_send_query('w1', format(
  $q$SELECT version_id::text FROM create_workflow_definition_version('%s'::uuid, %L::jsonb, '63200000-1000-0000-0000-000000000004'::uuid)$q$,
  (SELECT definition_id FROM wfvc_ids),
  $j${"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"e","type":"end","config":{"outcome_code":"y"}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false}]}$j$));
SELECT dblink_send_query('w2', format(
  $q$SELECT version_id::text FROM create_workflow_definition_version('%s'::uuid, %L::jsonb, '63200000-1000-0000-0000-000000000005'::uuid)$q$,
  (SELECT definition_id FROM wfvc_ids),
  $j${"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"e","type":"end","config":{"outcome_code":"y"}}],"edges":[{"source":"start","target":"e","outcome":"started","priority":0,"default":false}]}$j$));
TRUNCATE wfvc_c1_result, wfvc_c2_result;
DO $$
DECLARE v_val TEXT; v_err TEXT;
BEGIN
  BEGIN
    SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
  END;
  INSERT INTO wfvc_c1_result VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_val TEXT; v_err TEXT;
BEGIN
  BEGIN
    SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v text);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
  END;
  INSERT INTO wfvc_c2_result VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_winners INTEGER;
BEGIN
  SELECT count(*) INTO v_winners FROM (
    SELECT v FROM wfvc_c1_result WHERE v IS NOT NULL
    UNION ALL
    SELECT v FROM wfvc_c2_result WHERE v IS NOT NULL
  ) w;
  IF v_winners <> 1 THEN
    RAISE EXCEPTION 'expected exactly one second-draft winner, got %', v_winners;
  END IF;
  IF (SELECT count(*) FROM workflow_definition_versions WHERE definition_id = (SELECT definition_id FROM wfvc_ids) AND status = 'draft') <> 1 THEN
    RAISE EXCEPTION 'definition family does not have exactly one draft after the race';
  END IF;
END $$;
INSERT INTO wfvc_results VALUES (2,'concurrent racing second-draft creation converges on exactly one draft, no duplicate executable version');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

-- ── 3: the SAME publish command (identical idempotency key, same
--    actor) issued concurrently converges on the identical result —
--    a true idempotent replay under concurrency, not just when
--    called sequentially. ───────────────────────────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"63200000-0001-0000-0000-000000000001"}',false);
WITH made AS (
 SELECT * FROM create_workflow_definition(
  '63200000-0000-0000-0000-000000000001','wfvc_flow2','WFVC Flow 2','opaque_case',
  :PAYLOAD1::jsonb, '63200000-1000-0000-0000-000000000006'))
SELECT version_id INTO TEMP wfvc_ids2 FROM made;
RESET ROLE;

SELECT dblink_connect('w1','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_connect('w2','host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
SELECT dblink_exec('w1','SET ROLE authenticated'); SELECT dblink_exec('w2','SET ROLE authenticated');
SELECT * FROM dblink('w1',$q$SELECT set_config('request.jwt.claims','{"sub":"63200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);
SELECT * FROM dblink('w2',$q$SELECT set_config('request.jwt.claims','{"sub":"63200000-0001-0000-0000-000000000001"}',false)$q$) AS t(v text);

SELECT dblink_send_query('w1', format(
  $q$SELECT publish_workflow_definition_version('%s'::uuid,0,'63200000-1000-0000-0000-000000000007'::uuid)::text$q$,
  (SELECT version_id FROM wfvc_ids2)));
SELECT dblink_send_query('w2', format(
  $q$SELECT publish_workflow_definition_version('%s'::uuid,0,'63200000-1000-0000-0000-000000000007'::uuid)::text$q$,
  (SELECT version_id FROM wfvc_ids2)));
TRUNCATE wfvc_c1_result, wfvc_c2_result;
INSERT INTO wfvc_c1_result SELECT t.v, NULL FROM dblink_get_result('w1',false) AS t(v text);
INSERT INTO wfvc_c2_result SELECT t.v, NULL FROM dblink_get_result('w2',false) AS t(v text);
DO $$
BEGIN
  IF (SELECT v FROM wfvc_c1_result) IS DISTINCT FROM (SELECT v FROM wfvc_c2_result)
     OR (SELECT v FROM wfvc_c1_result) IS NULL THEN
    RAISE EXCEPTION 'identical concurrent publish commands did not converge: % vs %',
      (SELECT v FROM wfvc_c1_result), (SELECT v FROM wfvc_c2_result);
  END IF;
  IF (SELECT count(*) FROM workflow_definition_versions WHERE id = (SELECT version_id FROM wfvc_ids2) AND status = 'published') <> 1 THEN
    RAISE EXCEPTION 'definition version is not published exactly once after identical concurrent replay';
  END IF;
END $$;
INSERT INTO wfvc_results VALUES (3,'identical concurrent publish commands converge on the same result, published exactly once');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfvc_results;
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'Workflow executable definition validation concurrency tests FAILED: expected 3, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow executable definition validation concurrency tests PASSED: %/3', v_count;
END $$;
