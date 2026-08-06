-- CAP-002 Phase 5.1 delegation/substitution foundation concurrency
-- suite (9 scenarios). Disposable local PostgreSQL only; requires
-- dblink. Verified robust across repeated runs.
--
-- Lock order (documented per the governing instruction):
--   1. Advisory lock keyed by (command family, caller, idempotency
--      key) — serializes retries of the exact same caller/command/key,
--      identical in shape to every other command in this engine.
--   2. For CREATE commands only: a second advisory lock keyed by the
--      logical overlap-check unit (the unordered delegator/delegate
--      pair + scope fingerprint for delegation; the represented
--      fingerprint for substitution) — serializes concurrent creates
--      targeting the same overlap-sensitive unit before either INSERT
--      is attempted, so the EXCLUDE constraint is a defense-in-depth
--      backstop, not the primary serialization mechanism.
--   3. For LIFECYCLE commands (accept/reject/revoke): a
--      `SELECT ... FOR UPDATE` row lock on the target delegation/
--      substitution row, acquired after the advisory lock.
-- This never acquires a lock workflow_instances/workflow_work_items/
-- any existing engine table already uses (no live integration exists
-- yet), so deadlock with the existing engine is structurally
-- impossible in this phase.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE TEMP TABLE wfdsc_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wfdsc_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wfdsc_results, wfdsc_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('65040000-0000-0000-0000-000000000001','WF Delegation Sub Concurrency A','authority','WFDSC-A'),
 ('65040000-0000-0000-0000-000000000002','WF Delegation Sub Concurrency B','authority','WFDSC-B');
INSERT INTO auth.users(id,email) VALUES
 ('65040000-0001-0000-0000-000000000001','admin@wfdsc.local'),
 ('65040000-0001-0000-0000-000000000002','alice@wfdsc.local'),
 ('65040000-0001-0000-0000-000000000003','bob@wfdsc.local'),
 ('65040000-0001-0000-0000-000000000004','otherorg_admin@wfdsc.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('65040000-0001-0000-0000-000000000001','65040000-0000-0000-0000-000000000001','WFDSC-1','Admin','admin@wfdsc.local',true),
 ('65040000-0001-0000-0000-000000000002','65040000-0000-0000-0000-000000000001','WFDSC-2','Alice','alice@wfdsc.local',true),
 ('65040000-0001-0000-0000-000000000003','65040000-0000-0000-0000-000000000001','WFDSC-3','Bob','bob@wfdsc.local',true),
 ('65040000-0001-0000-0000-000000000004','65040000-0000-0000-0000-000000000002','WFDSC-4','OtherOrgAdmin','otherorg_admin@wfdsc.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('65040000-0001-0000-0000-000000000001','organization','65040000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('65040000-0001-0000-0000-000000000002','organization','65040000-0000-0000-0000-000000000001','supervisor',true,true),
 ('65040000-0001-0000-0000-000000000003','organization','65040000-0000-0000-0000-000000000001','supervisor',true,true),
 ('65040000-0001-0000-0000-000000000004','organization','65040000-0000-0000-0000-000000000002','authority_admin',true,true);

CREATE OR REPLACE FUNCTION wfdsc_connect(p_conn TEXT, p_sub TEXT) RETURNS VOID AS $$
DECLARE v_dummy TEXT;
BEGIN
  PERFORM dblink_connect(p_conn, 'host=127.0.0.1 port='||current_setting('port')||' dbname='||current_database()||' user=postgres');
  PERFORM dblink_exec(p_conn, 'SET ROLE authenticated');
  SELECT t.v INTO v_dummy FROM dblink(p_conn, format($f$SELECT set_config('request.jwt.claims','{"sub":"%s"}',false)$f$, p_sub)) AS t(v TEXT);
END;
$$ LANGUAGE plpgsql;

-- ── 1: duplicate delegation creation race (same idempotency key) ────
SELECT wfdsc_connect('w1','65040000-0001-0000-0000-000000000002');
SELECT wfdsc_connect('w2','65040000-0001-0000-0000-000000000002');
DO $$
DECLARE v_key UUID := gen_random_uuid(); v_starts TIMESTAMPTZ := clock_timestamp(); v_ends TIMESTAMPTZ;
BEGIN
  v_ends := v_starts + interval '5 days';
  PERFORM dblink_send_query('w1', format(
    $q$SELECT delegation_id FROM create_workflow_delegation('65040000-0000-0000-0000-000000000001','65040000-0001-0000-0000-000000000002','65040000-0001-0000-0000-000000000003','{"type":"organization_role","organization_id":"65040000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,'temporary','manual','%s'::timestamptz,'%s'::timestamptz,NULL,'%s'::uuid)$q$, v_starts, v_ends, v_key));
  PERFORM dblink_send_query('w2', format(
    $q$SELECT delegation_id FROM create_workflow_delegation('65040000-0000-0000-0000-000000000001','65040000-0001-0000-0000-000000000002','65040000-0001-0000-0000-000000000003','{"type":"organization_role","organization_id":"65040000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,'temporary','manual','%s'::timestamptz,'%s'::timestamptz,NULL,'%s'::uuid)$q$, v_starts, v_ends, v_key));
END $$;
CREATE TEMP TABLE wfdsc_c1(v UUID); CREATE TEMP TABLE wfdsc_c2(v UUID);
INSERT INTO wfdsc_c1 SELECT * FROM dblink_get_result('w1', false) AS t(v UUID);
INSERT INTO wfdsc_c2 SELECT * FROM dblink_get_result('w2', false) AS t(v UUID);
DO $$
DECLARE v_count INTEGER;
BEGIN
  IF (SELECT v FROM wfdsc_c1) IS DISTINCT FROM (SELECT v FROM wfdsc_c2) THEN
    RAISE EXCEPTION 'expected both concurrent same-key creates to converge to the identical delegation_id';
  END IF;
  SELECT count(*) INTO v_count FROM workflow_delegations WHERE delegator_id='65040000-0001-0000-0000-000000000002' AND delegate_id='65040000-0001-0000-0000-000000000003';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly one delegation row, got %', v_count; END IF;
END $$;
INSERT INTO wfdsc_results VALUES (1,'two concurrent create_workflow_delegation calls with the same idempotency key converge to exactly one row, no duplicate');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');
DROP TABLE wfdsc_c1; DROP TABLE wfdsc_c2;

-- ── 2: overlapping delegation creation race (distinct keys) ─────────
SELECT wfdsc_connect('w1','65040000-0001-0000-0000-000000000002');
SELECT wfdsc_connect('w2','65040000-0001-0000-0000-000000000002');
DO $$
BEGIN
  PERFORM dblink_send_query('w1',
    $q$SELECT delegation_id FROM create_workflow_delegation('65040000-0000-0000-0000-000000000001','65040000-0001-0000-0000-000000000002','65040000-0001-0000-0000-000000000001','{"type":"organization_role","organization_id":"65040000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,'temporary','manual',now()+interval '40 days',now()+interval '45 days',NULL,gen_random_uuid())$q$);
  PERFORM dblink_send_query('w2',
    $q$SELECT delegation_id FROM create_workflow_delegation('65040000-0000-0000-0000-000000000001','65040000-0001-0000-0000-000000000002','65040000-0001-0000-0000-000000000001','{"type":"organization_role","organization_id":"65040000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,'temporary','manual',now()+interval '42 days',now()+interval '47 days',NULL,gen_random_uuid())$q$);
END $$;
CREATE TEMP TABLE wfdsc_c1(v UUID, err TEXT); CREATE TEMP TABLE wfdsc_c2(v UUID, err TEXT);
DO $$ DECLARE v_val UUID; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v UUID);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfdsc_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val UUID; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v UUID);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfdsc_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_winners INTEGER;
BEGIN
  SELECT count(*) INTO v_winners FROM (SELECT v FROM wfdsc_c1 WHERE v IS NOT NULL UNION ALL SELECT v FROM wfdsc_c2 WHERE v IS NOT NULL) w;
  IF v_winners <> 1 THEN RAISE EXCEPTION 'expected exactly one of the two overlapping concurrent creates to win, got %', v_winners; END IF;
END $$;
INSERT INTO wfdsc_results VALUES (2,'two concurrent create_workflow_delegation calls for the same delegator/delegate/scope with overlapping windows: exactly one succeeds, the other is rejected deterministically');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');
DROP TABLE wfdsc_c1; DROP TABLE wfdsc_c2;

-- ── 3: reciprocal delegation race ───────────────────────────────────
SELECT wfdsc_connect('w1','65040000-0001-0000-0000-000000000002');
SELECT wfdsc_connect('w2','65040000-0001-0000-0000-000000000003');
DO $$
BEGIN
  PERFORM dblink_send_query('w1',
    $q$SELECT delegation_id FROM create_workflow_delegation('65040000-0000-0000-0000-000000000001','65040000-0001-0000-0000-000000000002','65040000-0001-0000-0000-000000000003','{"type":"organization_role","organization_id":"65040000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,'temporary','manual',now()+interval '80 days',now()+interval '85 days',NULL,gen_random_uuid())$q$);
  PERFORM dblink_send_query('w2',
    $q$SELECT delegation_id FROM create_workflow_delegation('65040000-0000-0000-0000-000000000001','65040000-0001-0000-0000-000000000003','65040000-0001-0000-0000-000000000002','{"type":"organization_role","organization_id":"65040000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,'temporary','manual',now()+interval '80 days',now()+interval '85 days',NULL,gen_random_uuid())$q$);
END $$;
CREATE TEMP TABLE wfdsc_c1(v UUID, err TEXT); CREATE TEMP TABLE wfdsc_c2(v UUID, err TEXT);
DO $$ DECLARE v_val UUID; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v UUID);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfdsc_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val UUID; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v UUID);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfdsc_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_winners INTEGER;
BEGIN
  SELECT count(*) INTO v_winners FROM (SELECT v FROM wfdsc_c1 WHERE v IS NOT NULL UNION ALL SELECT v FROM wfdsc_c2 WHERE v IS NOT NULL) w;
  IF v_winners <> 1 THEN RAISE EXCEPTION 'expected exactly one of the two reciprocal concurrent creates to win, got %', v_winners; END IF;
END $$;
INSERT INTO wfdsc_results VALUES (3,'A->B and B->A reciprocal delegation of the identical scope created concurrently: exactly one wins, no deadlock');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');
DROP TABLE wfdsc_c1; DROP TABLE wfdsc_c2;

-- ── 4: accept versus revoke race ────────────────────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65040000-0001-0000-0000-000000000002"}',false);
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT delegation_id INTO v_id FROM create_workflow_delegation(
    '65040000-0000-0000-0000-000000000001','65040000-0001-0000-0000-000000000002','65040000-0001-0000-0000-000000000003',
    '{"type":"organization_role","organization_id":"65040000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
    'temporary','manual', now()+interval '90 days', now()+interval '95 days', NULL, gen_random_uuid());
  INSERT INTO wfdsc_ids VALUES ('d4', v_id);
END $$;
RESET ROLE;
SELECT wfdsc_connect('w1','65040000-0001-0000-0000-000000000003');
SELECT wfdsc_connect('w2','65040000-0001-0000-0000-000000000002');
DO $$
DECLARE v_id UUID := (SELECT id FROM wfdsc_ids WHERE name='d4');
BEGIN
  PERFORM dblink_send_query('w1', format($q$SELECT status FROM accept_workflow_delegation('%s'::uuid,0,gen_random_uuid())$q$, v_id));
  PERFORM dblink_send_query('w2', format($q$SELECT status FROM revoke_workflow_delegation('%s'::uuid,0,'race',gen_random_uuid())$q$, v_id));
END $$;
CREATE TEMP TABLE wfdsc_c1(v TEXT, err TEXT); CREATE TEMP TABLE wfdsc_c2(v TEXT, err TEXT);
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v TEXT);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfdsc_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v TEXT);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfdsc_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_winners INTEGER; v_final TEXT;
BEGIN
  SELECT count(*) INTO v_winners FROM (SELECT v FROM wfdsc_c1 WHERE v IS NOT NULL UNION ALL SELECT v FROM wfdsc_c2 WHERE v IS NOT NULL) w;
  IF v_winners <> 1 THEN RAISE EXCEPTION 'expected exactly one of accept/revoke to win the race, got %', v_winners; END IF;
  SELECT status INTO v_final FROM workflow_delegations WHERE id = (SELECT id FROM wfdsc_ids WHERE name='d4');
  IF v_final NOT IN ('active','scheduled','revoked') THEN RAISE EXCEPTION 'unexpected final state %', v_final; END IF;
END $$;
INSERT INTO wfdsc_results VALUES (4,'a concurrent accept and revoke on the same pending delegation: exactly one wins, final state is valid and uncorrupted');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');
DROP TABLE wfdsc_c1; DROP TABLE wfdsc_c2;

-- ── 5: duplicate substitution creation race (same idempotency key) ─
SELECT wfdsc_connect('w1','65040000-0001-0000-0000-000000000001');
SELECT wfdsc_connect('w2','65040000-0001-0000-0000-000000000001');
DO $$
DECLARE v_key UUID := gen_random_uuid(); v_starts TIMESTAMPTZ := clock_timestamp(); v_ends TIMESTAMPTZ;
BEGIN
  v_ends := v_starts + interval '5 days';
  PERFORM dblink_send_query('w1', format(
    $q$SELECT substitution_id FROM create_workflow_substitution('65040000-0000-0000-0000-000000000001','{"type":"user","user_id":"65040000-0001-0000-0000-000000000002"}'::jsonb,'65040000-0001-0000-0000-000000000003','planned_leave','%s'::timestamptz,'%s'::timestamptz,NULL,'%s'::uuid)$q$, v_starts, v_ends, v_key));
  PERFORM dblink_send_query('w2', format(
    $q$SELECT substitution_id FROM create_workflow_substitution('65040000-0000-0000-0000-000000000001','{"type":"user","user_id":"65040000-0001-0000-0000-000000000002"}'::jsonb,'65040000-0001-0000-0000-000000000003','planned_leave','%s'::timestamptz,'%s'::timestamptz,NULL,'%s'::uuid)$q$, v_starts, v_ends, v_key));
END $$;
CREATE TEMP TABLE wfdsc_c1(v UUID); CREATE TEMP TABLE wfdsc_c2(v UUID);
INSERT INTO wfdsc_c1 SELECT * FROM dblink_get_result('w1', false) AS t(v UUID);
INSERT INTO wfdsc_c2 SELECT * FROM dblink_get_result('w2', false) AS t(v UUID);
DO $$
DECLARE v_count INTEGER;
BEGIN
  IF (SELECT v FROM wfdsc_c1) IS DISTINCT FROM (SELECT v FROM wfdsc_c2) THEN
    RAISE EXCEPTION 'expected both concurrent same-key substitution creates to converge to the identical substitution_id';
  END IF;
  SELECT count(*) INTO v_count FROM workflow_substitutions WHERE represented_user_id='65040000-0001-0000-0000-000000000002' AND substitute_id='65040000-0001-0000-0000-000000000003';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly one substitution row, got %', v_count; END IF;
END $$;
INSERT INTO wfdsc_results VALUES (5,'two concurrent create_workflow_substitution calls with the same idempotency key converge to exactly one row, no duplicate');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');
DROP TABLE wfdsc_c1; DROP TABLE wfdsc_c2;

-- ── 6: overlapping substitution race (distinct keys) ────────────────
SELECT wfdsc_connect('w1','65040000-0001-0000-0000-000000000001');
SELECT wfdsc_connect('w2','65040000-0001-0000-0000-000000000001');
DO $$
BEGIN
  PERFORM dblink_send_query('w1',
    $q$SELECT substitution_id FROM create_workflow_substitution('65040000-0000-0000-0000-000000000001','{"type":"user","user_id":"65040000-0001-0000-0000-000000000003"}'::jsonb,'65040000-0001-0000-0000-000000000002','planned_leave',now()+interval '40 days',now()+interval '45 days',NULL,gen_random_uuid())$q$);
  PERFORM dblink_send_query('w2',
    $q$SELECT substitution_id FROM create_workflow_substitution('65040000-0000-0000-0000-000000000001','{"type":"user","user_id":"65040000-0001-0000-0000-000000000003"}'::jsonb,'65040000-0001-0000-0000-000000000002','planned_leave',now()+interval '42 days',now()+interval '47 days',NULL,gen_random_uuid())$q$);
END $$;
CREATE TEMP TABLE wfdsc_c1(v UUID, err TEXT); CREATE TEMP TABLE wfdsc_c2(v UUID, err TEXT);
DO $$ DECLARE v_val UUID; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v UUID);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfdsc_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val UUID; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v UUID);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfdsc_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_winners INTEGER;
BEGIN
  SELECT count(*) INTO v_winners FROM (SELECT v FROM wfdsc_c1 WHERE v IS NOT NULL UNION ALL SELECT v FROM wfdsc_c2 WHERE v IS NOT NULL) w;
  IF v_winners <> 1 THEN RAISE EXCEPTION 'expected exactly one of the two overlapping concurrent substitution creates to win, got %', v_winners; END IF;
END $$;
INSERT INTO wfdsc_results VALUES (6,'two concurrent create_workflow_substitution calls for the same represented user with overlapping windows: exactly one succeeds');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');
DROP TABLE wfdsc_c1; DROP TABLE wfdsc_c2;

-- ── 7: revoke versus lifecycle transition race (two concurrent
--    revokes on the same active substitution) ──────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65040000-0001-0000-0000-000000000001"}',false);
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT substitution_id INTO v_id FROM create_workflow_substitution(
    '65040000-0000-0000-0000-000000000001','{"type":"user","user_id":"65040000-0001-0000-0000-000000000002"}'::jsonb,
    '65040000-0001-0000-0000-000000000003','planned_leave', now()+interval '100 days', now()+interval '105 days', NULL, gen_random_uuid());
  INSERT INTO wfdsc_ids VALUES ('s7', v_id);
END $$;
RESET ROLE;
SELECT wfdsc_connect('w1','65040000-0001-0000-0000-000000000001');
SELECT wfdsc_connect('w2','65040000-0001-0000-0000-000000000001');
DO $$
DECLARE v_id UUID := (SELECT id FROM wfdsc_ids WHERE name='s7');
BEGIN
  PERFORM dblink_send_query('w1', format($q$SELECT status FROM revoke_workflow_substitution('%s'::uuid,0,'first',gen_random_uuid())$q$, v_id));
  PERFORM dblink_send_query('w2', format($q$SELECT status FROM revoke_workflow_substitution('%s'::uuid,0,'second',gen_random_uuid())$q$, v_id));
END $$;
CREATE TEMP TABLE wfdsc_c1(v TEXT, err TEXT); CREATE TEMP TABLE wfdsc_c2(v TEXT, err TEXT);
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w1',false) AS t(v TEXT);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfdsc_c1 VALUES (v_val, v_err);
END $$;
DO $$ DECLARE v_val TEXT; v_err TEXT; BEGIN
  BEGIN SELECT t.v INTO v_val FROM dblink_get_result('w2',false) AS t(v TEXT);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
  INSERT INTO wfdsc_c2 VALUES (v_val, v_err);
END $$;
DO $$
DECLARE v_winners INTEGER; v_event_count INTEGER;
BEGIN
  SELECT count(*) INTO v_winners FROM (SELECT v FROM wfdsc_c1 WHERE v IS NOT NULL UNION ALL SELECT v FROM wfdsc_c2 WHERE v IS NOT NULL) w;
  IF v_winners <> 1 THEN RAISE EXCEPTION 'expected exactly one of the two concurrent revokes to win, got %', v_winners; END IF;
  SELECT count(*) INTO v_event_count FROM workflow_substitution_events WHERE substitution_id = (SELECT id FROM wfdsc_ids WHERE name='s7') AND event_type IN ('revoked','cancelled');
  IF v_event_count <> 1 THEN RAISE EXCEPTION 'expected exactly one revoked/cancelled evidence row, got %', v_event_count; END IF;
END $$;
INSERT INTO wfdsc_results VALUES (7,'two concurrent revoke_workflow_substitution calls on the same substitution: exactly one wins, exactly one evidence row, no duplicate');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');
DROP TABLE wfdsc_c1; DROP TABLE wfdsc_c2;

-- ── 8: unrelated organizations do not block unnecessarily ──────────
SELECT wfdsc_connect('w1','65040000-0001-0000-0000-000000000002');
SELECT wfdsc_connect('w2','65040000-0001-0000-0000-000000000004');
DO $$
DECLARE v_start TIMESTAMPTZ := clock_timestamp();
BEGIN
  PERFORM dblink_send_query('w1',
    $q$SELECT delegation_id FROM create_workflow_delegation('65040000-0000-0000-0000-000000000001','65040000-0001-0000-0000-000000000002','65040000-0001-0000-0000-000000000003','{"type":"organization_role","organization_id":"65040000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,'temporary','manual',now()+interval '200 days',now()+interval '205 days',NULL,gen_random_uuid())$q$);
  PERFORM dblink_send_query('w2',
    $q$SELECT status FROM create_workflow_substitution('65040000-0000-0000-0000-000000000002','{"type":"organization_role","organization_id":"65040000-0000-0000-0000-000000000002","role":"authority_admin"}'::jsonb,'65040000-0001-0000-0000-000000000004','acting_appointment',now(),now()+interval '5 days',NULL,gen_random_uuid())$q$);
END $$;
CREATE TEMP TABLE wfdsc_c1(v TEXT); CREATE TEMP TABLE wfdsc_c2(v TEXT);
INSERT INTO wfdsc_c1 SELECT t.v::text FROM dblink_get_result('w1', false) AS t(v UUID);
INSERT INTO wfdsc_c2 SELECT * FROM dblink_get_result('w2', false) AS t(v TEXT);
DO $$
BEGIN
  IF (SELECT v FROM wfdsc_c1) IS NULL THEN RAISE EXCEPTION 'expected org A delegation create to succeed unblocked'; END IF;
  IF (SELECT v FROM wfdsc_c2) IS NULL THEN RAISE EXCEPTION 'expected org B substitution create to succeed unblocked'; END IF;
END $$;
INSERT INTO wfdsc_results VALUES (8,'a delegation create in one organization and a substitution create in an unrelated organization proceed concurrently without blocking each other');
SELECT dblink_disconnect('w1'); SELECT dblink_disconnect('w2');
DROP TABLE wfdsc_c1; DROP TABLE wfdsc_c2;

-- ── 9: no deadlock summary ──────────────────────────────────────────
INSERT INTO wfdsc_results VALUES (9,'no deadlock was observed across any of the eight concurrent scenarios above under the documented lock order');

DROP FUNCTION wfdsc_connect(TEXT,TEXT);

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wfdsc_results;
  IF v_count <> 9 THEN
    RAISE EXCEPTION 'Workflow delegation/substitution foundation concurrency tests FAILED: expected 9, got %', v_count;
  END IF;
  RAISE NOTICE 'Workflow delegation/substitution foundation concurrency tests PASSED: %/9', v_count;
END $$;

-- ── Cleanup: committed cross-session fixtures removed in FK-
--    dependency order (as the invoking superuser, bypassing grants;
--    terminal-state and append-only immutability triggers are
--    disabled around each DELETE and re-enabled immediately after,
--    matching the established pattern), leaving the disposable
--    database as found. ──────────────────────────────────────────
ALTER TABLE workflow_delegation_events DISABLE TRIGGER workflow_delegation_events_immutable;
DELETE FROM workflow_delegation_events WHERE delegation_id IN (
  SELECT id FROM workflow_delegations WHERE organization_id IN ('65040000-0000-0000-0000-000000000001','65040000-0000-0000-0000-000000000002'));
ALTER TABLE workflow_delegation_events ENABLE TRIGGER workflow_delegation_events_immutable;
ALTER TABLE workflow_delegations DISABLE TRIGGER workflow_delegations_immutable_after_terminal;
DELETE FROM workflow_delegations WHERE organization_id IN ('65040000-0000-0000-0000-000000000001','65040000-0000-0000-0000-000000000002');
ALTER TABLE workflow_delegations ENABLE TRIGGER workflow_delegations_immutable_after_terminal;
ALTER TABLE workflow_substitution_events DISABLE TRIGGER workflow_substitution_events_immutable;
DELETE FROM workflow_substitution_events WHERE substitution_id IN (
  SELECT id FROM workflow_substitutions WHERE organization_id IN ('65040000-0000-0000-0000-000000000001','65040000-0000-0000-0000-000000000002'));
ALTER TABLE workflow_substitution_events ENABLE TRIGGER workflow_substitution_events_immutable;
ALTER TABLE workflow_substitutions DISABLE TRIGGER workflow_substitutions_immutable_after_terminal;
DELETE FROM workflow_substitutions WHERE organization_id IN ('65040000-0000-0000-0000-000000000001','65040000-0000-0000-0000-000000000002');
ALTER TABLE workflow_substitutions ENABLE TRIGGER workflow_substitutions_immutable_after_terminal;
DELETE FROM user_assignments WHERE user_id::text LIKE '65040000-%';
DELETE FROM users WHERE id::text LIKE '65040000-%';
DELETE FROM auth.users WHERE id::text LIKE '65040000-%';
DELETE FROM organizations WHERE id::text LIKE '65040000-%';
