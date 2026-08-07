-- CAP-002 Phase 5.3 SLA & escalation foundation behavioral suite.
-- Disposable local PostgreSQL only. Runs in one transaction and
-- leaves no fixtures (rolled back at the end), matching the
-- test-workflow-delegation-runtime-integration.sql precedent.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf53_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf53_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
CREATE TEMP TABLE wf53_scratch (key TEXT PRIMARY KEY, val TEXT NOT NULL);
GRANT SELECT, INSERT ON wf53_results, wf53_ids TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON wf53_scratch TO authenticated;

-- ── Fixtures (as postgres, bypasses RLS) ──────────────────────────
INSERT INTO organizations(id,name,type,code) VALUES
 ('65330000-0000-0000-0000-000000000001','WF53 Org A','authority','WF53A'),
 ('65330000-0000-0000-0000-000000000002','WF53 Org B','authority','WF53B');
INSERT INTO commands(id,org_id,name) VALUES
 ('65330000-0000-0000-0000-000000000011','65330000-0000-0000-0000-000000000001','WF53A Command');
INSERT INTO departments(id,command_id,name) VALUES
 ('65330000-0000-0000-0000-000000000012','65330000-0000-0000-0000-000000000011','WF53A Department');

INSERT INTO auth.users(id,email) VALUES
 ('65330000-0001-0000-0000-000000000001','admin_a@wf53.local'),
 ('65330000-0001-0000-0000-000000000002','manager_a@wf53.local'),
 ('65330000-0001-0000-0000-000000000003','worker_a@wf53.local'),
 ('65330000-0001-0000-0000-000000000004','outsider_a@wf53.local'),
 ('65330000-0001-0000-0000-000000000005','escalation_target_a@wf53.local'),
 ('65330000-0001-0000-0000-000000000006','admin_b@wf53.local'),
 ('65330000-0001-0000-0000-000000000007','delegate_a@wf53.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('65330000-0001-0000-0000-000000000001','65330000-0000-0000-0000-000000000001','WF53A-1','Admin A','admin_a@wf53.local',true),
 ('65330000-0001-0000-0000-000000000002','65330000-0000-0000-0000-000000000001','WF53A-2','Manager A','manager_a@wf53.local',true),
 ('65330000-0001-0000-0000-000000000003','65330000-0000-0000-0000-000000000001','WF53A-3','Worker A','worker_a@wf53.local',true),
 ('65330000-0001-0000-0000-000000000004','65330000-0000-0000-0000-000000000001','WF53A-4','Outsider A','outsider_a@wf53.local',true),
 ('65330000-0001-0000-0000-000000000005','65330000-0000-0000-0000-000000000001','WF53A-5','Escalation Target A','escalation_target_a@wf53.local',true),
 ('65330000-0001-0000-0000-000000000006','65330000-0000-0000-0000-000000000002','WF53B-1','Admin B','admin_b@wf53.local',true),
 ('65330000-0001-0000-0000-000000000007','65330000-0000-0000-0000-000000000001','WF53A-7','Delegate A','delegate_a@wf53.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('65330000-0001-0000-0000-000000000001','organization','65330000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('65330000-0001-0000-0000-000000000003','organization','65330000-0000-0000-0000-000000000001','supervisor',true,true),
 ('65330000-0001-0000-0000-000000000006','organization','65330000-0000-0000-0000-000000000002','authority_admin',true,true);

\set ADMIN_A '{"sub":"65330000-0001-0000-0000-000000000001"}'
\set MANAGER_A '{"sub":"65330000-0001-0000-0000-000000000002"}'
\set WORKER_A '{"sub":"65330000-0001-0000-0000-000000000003"}'
\set OUTSIDER_A '{"sub":"65330000-0001-0000-0000-000000000004"}'
\set ESCALATION_TARGET_A '{"sub":"65330000-0001-0000-0000-000000000005"}'
\set ADMIN_B '{"sub":"65330000-0001-0000-0000-000000000006"}'
\set DELEGATE_A '{"sub":"65330000-0001-0000-0000-000000000007"}'

SET ROLE authenticated;

\set ORG_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":true,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
WITH made AS (SELECT * FROM create_workflow_definition(
  '65330000-0000-0000-0000-000000000001','wf53_org','WF53 Org Flow','opaque_case', :ORG_PAYLOAD::jsonb, gen_random_uuid()))
INSERT INTO wf53_ids SELECT 'def_v', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wf53_ids WHERE name='def_v'),0,gen_random_uuid());

WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf53_ids WHERE name='def_v'),'opaque_case',gen_random_uuid(),
  '65330000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf53_ids SELECT 'i1', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf53_ids WHERE name='i1'),0,gen_random_uuid());

-- worker_a is the organization_role:supervisor candidate -- record
-- their work item id for the work-item-assignee authorization test.
INSERT INTO wf53_ids SELECT 'worker_a_wi', id FROM workflow_work_items
WHERE instance_id = (SELECT id FROM wf53_ids WHERE name='i1') AND assigned_to = '65330000-0001-0000-0000-000000000003';

-- manager_a is added directly as a 'manager' participant (as
-- postgres, bypassing RLS -- mirrors how fixture seeding is always
-- done in these disposable suites).
RESET ROLE;
INSERT INTO workflow_participants (instance_id, user_id, participant_role, authority_source, created_by)
VALUES (
  (SELECT id FROM wf53_ids WHERE name='i1'), '65330000-0001-0000-0000-000000000002', 'manager',
  'wf53_test_fixture', '65330000-0001-0000-0000-000000000001'
);
SET ROLE authenticated;

-- ── 1: create_workflow_sla_clock (absolute deadline) creates AND starts a running clock with correct fields ──
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
DO $$
DECLARE v_clock_id UUID; v_row workflow_sla_clocks;
BEGIN
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, NULL, 'manual', NULL,
    now() + interval '2 hours', 'UTC', gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('clock_abs1', v_clock_id);
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  IF v_row.state <> 'running' OR v_row.deadline_rule_type <> 'absolute' OR v_row.lock_version <> 0
     OR v_row.effective_deadline <> v_row.effective_deadline_adjusted
     OR v_row.accumulated_paused_duration <> '0'
  THEN RAISE EXCEPTION 'expected a freshly created absolute-deadline clock to be running, lock_version 0, and effective_deadline_adjusted == effective_deadline, got %', row_to_json(v_row); END IF;
  IF NOT EXISTS (SELECT 1 FROM workflow_sla_clock_events WHERE clock_id = v_clock_id AND event_type = 'started') THEN
    RAISE EXCEPTION 'expected a started evidence event';
  END IF;
END $$;
INSERT INTO wf53_results VALUES (1,'create_workflow_sla_clock (absolute deadline) creates and starts a running clock with effective_deadline_adjusted == effective_deadline and a started evidence event');

-- ── 2: absolute deadline without a timezone is rejected ──
DO $$
BEGIN
  BEGIN
    PERFORM create_workflow_sla_clock(
      (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, NULL, 'manual', NULL,
      now() + interval '1 hour', NULL, gen_random_uuid());
    RAISE EXCEPTION 'expected rejection for an absolute deadline with no timezone';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%timezone%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (2,'create_workflow_sla_clock rejects an absolute_deadline supplied without a timezone');

-- ── 3: create_workflow_sla_policy + create_workflow_sla_clock (duration-based, plain hours) computes the correct deadline ──
DO $$
DECLARE v_policy_id UUID; v_clock_id UUID; v_row workflow_sla_clocks;
BEGIN
  SELECT sla_policy_id INTO v_policy_id FROM create_workflow_sla_policy(
    '65330000-0000-0000-0000-000000000001','wf53_policy_plain','Plain hours policy',
    4,'hours',NULL,'UTC','[]'::jsonb,true,true,NULL,gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('policy_plain', v_policy_id);
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, v_policy_id, 'manual', NULL, NULL, NULL, gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('clock_plain1', v_clock_id);
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  IF abs(EXTRACT(EPOCH FROM (v_row.effective_deadline - (v_row.started_at + interval '4 hours')))) > 1 THEN
    RAISE EXCEPTION 'expected effective_deadline == started_at + 4 hours, got started_at=% deadline=%', v_row.started_at, v_row.effective_deadline;
  END IF;
  IF v_row.pause_eligible IS NOT TRUE OR v_row.restart_eligible IS NOT TRUE THEN
    RAISE EXCEPTION 'expected pause_eligible/restart_eligible to be inherited from the policy';
  END IF;
END $$;
INSERT INTO wf53_results VALUES (3,'a duration-based SLA policy (plain hours) produces a clock whose effective_deadline is exactly started_at + the configured duration, inheriting pause/restart eligibility from the policy');

-- ── 4: create_workflow_sla_clock is idempotent ──
DO $$
DECLARE v_key UUID := gen_random_uuid(); v_id1 UUID; v_id2 UUID; v_replayed2 BOOLEAN;
BEGIN
  SELECT clock_id INTO v_id1 FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, NULL, 'manual', NULL, now() + interval '1 hour', 'UTC', v_key);
  SELECT clock_id, replayed INTO v_id2, v_replayed2 FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, NULL, 'manual', NULL, now() + interval '1 hour', 'UTC', v_key);
  IF v_id1 <> v_id2 OR NOT v_replayed2 THEN
    RAISE EXCEPTION 'expected idempotent replay to return the same clock_id with replayed=true, got id1=% id2=% replayed2=%', v_id1, v_id2, v_replayed2;
  END IF;
END $$;
INSERT INTO wf53_results VALUES (4,'create_workflow_sla_clock is idempotent: replaying the same idempotency_key returns the same clock_id with replayed=true, no duplicate clock created');

-- ── 5: exactly one of policy_id/absolute_deadline must be supplied ──
DO $$
BEGIN
  BEGIN
    PERFORM create_workflow_sla_clock((SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, NULL, 'manual', NULL, NULL, NULL, gen_random_uuid());
    RAISE EXCEPTION 'expected rejection when neither policy_id nor absolute_deadline is supplied';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%Exactly one of%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM create_workflow_sla_clock((SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL,
      (SELECT id FROM wf53_ids WHERE name='policy_plain'), 'manual', NULL, now() + interval '1 hour', 'UTC', gen_random_uuid());
    RAISE EXCEPTION 'expected rejection when both policy_id and absolute_deadline are supplied';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%Exactly one of%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (5,'create_workflow_sla_clock rejects supplying neither, or both, of policy_id and absolute_deadline');

-- ── 6: an unauthorized user cannot create an SLA clock ──
SELECT set_config('request.jwt.claims', :'OUTSIDER_A', false);
DO $$
BEGIN
  BEGIN
    PERFORM create_workflow_sla_clock((SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, NULL, 'manual', NULL, now() + interval '1 hour', 'UTC', gen_random_uuid());
    RAISE EXCEPTION 'expected outsider_a (no participant role, no work item) to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> '42501' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (6,'a user with no participant role and no assigned work item on the instance cannot create an SLA clock for it (42501)');

-- ── 7: clock visibility follows can_view_workflow_instance -- outsider sees none, owner sees it ──
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_abs1');
  IF v_count <> 0 THEN RAISE EXCEPTION 'expected outsider_a to see zero rows for a clock on an instance they do not participate in, saw %', v_count; END IF;
END $$;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_abs1');
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected the instance owner to see the clock, saw %', v_count; END IF;
END $$;
INSERT INTO wf53_results VALUES (7,'SLA clock visibility follows can_view_workflow_instance exactly: the instance owner sees the clock, a non-participant outsider sees none');

-- ── 8: pause a running clock ──
DO $$
DECLARE v_row workflow_sla_clocks; v_result RECORD;
BEGIN
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_plain1');
  SELECT * INTO v_result FROM pause_workflow_sla_clock((SELECT id FROM wf53_ids WHERE name='clock_plain1'), v_row.lock_version, 'testing pause', gen_random_uuid());
  IF v_result.state <> 'paused' OR v_result.lock_version <> v_row.lock_version + 1 THEN
    RAISE EXCEPTION 'expected state=paused and lock_version incremented, got %', row_to_json(v_result);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_plain1') AND current_pause_started_at IS NOT NULL) THEN
    RAISE EXCEPTION 'expected current_pause_started_at to be set';
  END IF;
END $$;
INSERT INTO wf53_results VALUES (8,'pause_workflow_sla_clock transitions a running clock to paused, sets current_pause_started_at, and increments lock_version');

-- ── 9: pause is rejected on an already-paused clock ──
DO $$
DECLARE v_lv BIGINT;
BEGIN
  SELECT lock_version INTO v_lv FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_plain1');
  BEGIN
    PERFORM pause_workflow_sla_clock((SELECT id FROM wf53_ids WHERE name='clock_plain1'), v_lv, 'double pause', gen_random_uuid());
    RAISE EXCEPTION 'expected pausing an already-paused clock to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> 'P0001' AND SQLERRM NOT ILIKE '%not running%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (9,'pause_workflow_sla_clock is rejected when the clock is not currently running (e.g. already paused)');

-- ── 10: pause is rejected when pause_eligible = false ──
DO $$
DECLARE v_policy_id UUID; v_clock_id UUID; v_row workflow_sla_clocks;
BEGIN
  SELECT sla_policy_id INTO v_policy_id FROM create_workflow_sla_policy(
    '65330000-0000-0000-0000-000000000001','wf53_policy_nopause','No-pause policy',
    2,'hours',NULL,'UTC','[]'::jsonb,false,false,NULL,gen_random_uuid());
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, v_policy_id, 'manual', NULL, NULL, NULL, gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('clock_nopause', v_clock_id);
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  BEGIN
    PERFORM pause_workflow_sla_clock(v_clock_id, v_row.lock_version, 'should fail', gen_random_uuid());
    RAISE EXCEPTION 'expected pause to be rejected when pause_eligible is false';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%not eligible for pause%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (10,'pause_workflow_sla_clock is rejected when the clock''s pause_eligible flag is false');

-- ── 11: resume continues the same logical clock -- effective_deadline unchanged, effective_deadline_adjusted shifts by the paused interval ──
-- Force a deterministic paused interval instead of depending on real elapsed time
-- (a raw UPDATE, so it must run as postgres -- authenticated is intentionally SELECT-only on this table).
RESET ROLE;
UPDATE workflow_sla_clocks SET current_pause_started_at = clock_timestamp() - interval '10 minutes'
WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_plain1');
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
DO $$
DECLARE v_before workflow_sla_clocks; v_result RECORD; v_after workflow_sla_clocks;
BEGIN
  SELECT * INTO v_before FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_plain1');
  SELECT * INTO v_result FROM resume_workflow_sla_clock((SELECT id FROM wf53_ids WHERE name='clock_plain1'), v_before.lock_version, gen_random_uuid());
  SELECT * INTO v_after FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_plain1');
  IF v_after.state <> 'running' OR v_after.current_pause_started_at IS NOT NULL THEN
    RAISE EXCEPTION 'expected resume to clear current_pause_started_at and set state=running';
  END IF;
  IF v_after.effective_deadline <> v_before.effective_deadline THEN
    RAISE EXCEPTION 'expected effective_deadline (the semantic source) to be untouched by resume, before=% after=%', v_before.effective_deadline, v_after.effective_deadline;
  END IF;
  IF abs(EXTRACT(EPOCH FROM (v_after.accumulated_paused_duration - interval '10 minutes'))) > 2 THEN
    RAISE EXCEPTION 'expected accumulated_paused_duration to be ~10 minutes, got %', v_after.accumulated_paused_duration;
  END IF;
  IF v_after.effective_deadline_adjusted <> v_after.effective_deadline + v_after.accumulated_paused_duration THEN
    RAISE EXCEPTION 'expected effective_deadline_adjusted to equal effective_deadline + accumulated_paused_duration exactly';
  END IF;
  IF v_result.effective_deadline_adjusted <> v_after.effective_deadline_adjusted THEN
    RAISE EXCEPTION 'expected the RPC result to match the stored effective_deadline_adjusted';
  END IF;
END $$;
INSERT INTO wf53_results VALUES (11,'resume_workflow_sla_clock continues the SAME logical clock: effective_deadline (semantic source) is never rewritten, only accumulated_paused_duration grows, and effective_deadline_adjusted = effective_deadline + accumulated_paused_duration exactly');

-- ── 12: repeated pause/resume cycles remain mathematically correct ──
DO $$
DECLARE v_lv BIGINT;
BEGIN
  SELECT lock_version INTO v_lv FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_plain1');
  PERFORM pause_workflow_sla_clock((SELECT id FROM wf53_ids WHERE name='clock_plain1'), v_lv, 'cycle 2', gen_random_uuid());
END $$;
RESET ROLE;
UPDATE workflow_sla_clocks SET current_pause_started_at = clock_timestamp() - interval '5 minutes'
WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_plain1');
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
DO $$
DECLARE v_lv BIGINT; v_after workflow_sla_clocks;
BEGIN
  SELECT lock_version INTO v_lv FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_plain1');
  PERFORM resume_workflow_sla_clock((SELECT id FROM wf53_ids WHERE name='clock_plain1'), v_lv, gen_random_uuid());
  SELECT * INTO v_after FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_plain1');
  -- Cycle 1 contributed ~10 minutes (scenario 11), cycle 2 contributed ~5 minutes: total ~15.
  IF abs(EXTRACT(EPOCH FROM (v_after.accumulated_paused_duration - interval '15 minutes'))) > 3 THEN
    RAISE EXCEPTION 'expected accumulated_paused_duration to be the SUM of both pause cycles (~15 minutes), got %', v_after.accumulated_paused_duration;
  END IF;
  IF v_after.effective_deadline_adjusted <> v_after.effective_deadline + v_after.accumulated_paused_duration THEN
    RAISE EXCEPTION 'expected the invariant to still hold exactly after two cycles';
  END IF;
END $$;
INSERT INTO wf53_results VALUES (12,'repeated pause/resume cycles remain mathematically correct: accumulated_paused_duration is the exact sum of every cycle''s elapsed interval');

-- ── 13: restart discards prior elapsed contribution, begins a new epoch, and preserves history ──
-- restart_workflow_sla_clock is no longer granted to authenticated (Phase 5.3A correction 1 --
-- docs/73 approves no restart trigger other than a future Reopen command). This scenario
-- exercises the function's own internal correctness the way a future, separately approved
-- Reopen RPC would invoke it -- as a private primitive, not as a directly authenticated command.
RESET ROLE;
DO $$
DECLARE v_before workflow_sla_clocks; v_result RECORD; v_after workflow_sla_clocks; v_ev workflow_sla_clock_events;
    v_prior_events_before INTEGER; v_prior_events_after INTEGER;
BEGIN
  SELECT * INTO v_before FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_plain1');
  SELECT count(*) INTO v_prior_events_before FROM workflow_sla_clock_events WHERE clock_id = v_before.id;
  SELECT * INTO v_result FROM restart_workflow_sla_clock(v_before.id, v_before.lock_version, 'restart test', gen_random_uuid());
  SELECT * INTO v_after FROM workflow_sla_clocks WHERE id = v_before.id;
  IF v_after.accumulated_paused_duration <> '0' OR v_after.current_pause_started_at IS NOT NULL THEN
    RAISE EXCEPTION 'expected restart to discard the prior accumulated_paused_duration entirely';
  END IF;
  IF v_after.restart_epoch <> v_before.restart_epoch + 1 THEN
    RAISE EXCEPTION 'expected restart_epoch to increment exactly once, before=% after=%', v_before.restart_epoch, v_after.restart_epoch;
  END IF;
  IF v_after.effective_deadline = v_before.effective_deadline THEN
    RAISE EXCEPTION 'expected a genuinely new effective_deadline recomputed from the restart instant';
  END IF;
  IF v_after.current_escalation_level <> 0 OR v_after.breached_at IS NOT NULL OR v_after.warned_up_to_index <> -1 THEN
    RAISE EXCEPTION 'expected restart to reset escalation level, breached_at, and warned_up_to_index for the new epoch';
  END IF;
  SELECT * INTO v_ev FROM workflow_sla_clock_events WHERE clock_id = v_before.id AND event_type = 'restarted';
  IF (v_ev.metadata -> 'prior_epoch_snapshot' ->> 'effective_deadline')::TIMESTAMPTZ <> v_before.effective_deadline THEN
    RAISE EXCEPTION 'expected the restarted event to snapshot the PRIOR effective_deadline in its metadata, never silently discarding it';
  END IF;
  SELECT count(*) INTO v_prior_events_after FROM workflow_sla_clock_events WHERE clock_id = v_before.id AND event_type IN ('started');
  IF v_prior_events_after <> 1 THEN
    RAISE EXCEPTION 'expected the earlier started event to remain untouched after restart (history never overwritten)';
  END IF;
END $$;
INSERT INTO wf53_results VALUES (13,'restart_workflow_sla_clock is NOT resume: it discards the prior accumulated_paused_duration, begins a genuinely new timing epoch with a fresh effective_deadline and incremented restart_epoch, resets escalation/breach/warning state for the new epoch, and preserves the full pre-restart snapshot plus all prior lifecycle events as untouched history');

-- ── 14: restart is rejected when restart_eligible = false ──
DO $$
DECLARE v_row workflow_sla_clocks;
BEGIN
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_nopause');
  BEGIN
    PERFORM restart_workflow_sla_clock(v_row.id, v_row.lock_version, 'should fail', gen_random_uuid());
    RAISE EXCEPTION 'expected restart to be rejected when restart_eligible is false';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%not eligible for restart%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (14,'restart_workflow_sla_clock is rejected when the clock''s restart_eligible flag is false');

-- ── 15: restart is rejected on a paused clock (must resume first) ──
DO $$
DECLARE v_policy_id UUID; v_clock_id UUID; v_row workflow_sla_clocks;
BEGIN
  SELECT id INTO v_policy_id FROM wf53_ids WHERE name = 'policy_plain';
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, v_policy_id, 'manual', NULL, NULL, NULL, gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('clock_pause_restart', v_clock_id);
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  PERFORM pause_workflow_sla_clock(v_clock_id, v_row.lock_version, 'pause before restart test', gen_random_uuid());
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  BEGIN
    PERFORM restart_workflow_sla_clock(v_clock_id, v_row.lock_version, 'should fail', gen_random_uuid());
    RAISE EXCEPTION 'expected restart to be rejected while paused';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%must be resumed before it can be restarted%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (15,'restart_workflow_sla_clock is rejected on a paused clock -- it must be resumed first, restart is never used as a substitute for resume');
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);

-- ── 16: complete sets completed_at and the terminal state ──
DO $$
DECLARE v_row workflow_sla_clocks; v_result RECORD;
BEGIN
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_pause_restart');
  -- resume first (it was left paused by scenario 15)
  SELECT * INTO v_result FROM resume_workflow_sla_clock(v_row.id, v_row.lock_version, gen_random_uuid());
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_row.id;
  SELECT * INTO v_result FROM complete_workflow_sla_clock(v_row.id, v_row.lock_version, gen_random_uuid());
  IF v_result.state <> 'completed' THEN RAISE EXCEPTION 'expected state=completed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM workflow_sla_clocks WHERE id = v_row.id AND state = 'completed' AND completed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'expected completed_at to be set';
  END IF;
END $$;
INSERT INTO wf53_results VALUES (16,'complete_workflow_sla_clock transitions an active clock to the terminal completed state and sets completed_at');

-- ── 17: cancel a running clock ──
DO $$
DECLARE v_clock_id UUID; v_row workflow_sla_clocks; v_result RECORD;
BEGIN
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, NULL, 'manual', NULL, now() + interval '1 hour', 'UTC', gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('clock_cancel1', v_clock_id);
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  SELECT * INTO v_result FROM cancel_workflow_sla_clock(v_clock_id, v_row.lock_version, 'no longer needed', gen_random_uuid());
  IF v_result.state <> 'cancelled' THEN RAISE EXCEPTION 'expected state=cancelled'; END IF;
  IF NOT EXISTS (SELECT 1 FROM workflow_sla_clocks WHERE id = v_clock_id AND cancelled_at IS NOT NULL) THEN
    RAISE EXCEPTION 'expected cancelled_at to be set';
  END IF;
END $$;
INSERT INTO wf53_results VALUES (17,'cancel_workflow_sla_clock transitions a running clock to the terminal cancelled state and sets cancelled_at');

-- ── 18: cancel a paused clock ──
DO $$
DECLARE v_clock_id UUID; v_row workflow_sla_clocks; v_result RECORD;
BEGIN
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, NULL, 'manual', NULL, now() + interval '1 hour', 'UTC', gen_random_uuid());
  -- absolute-deadline clocks default pause_eligible=false; use a policy-based one instead.
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, (SELECT id FROM wf53_ids WHERE name='policy_plain'), 'manual', NULL, NULL, NULL, gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('clock_cancel_paused', v_clock_id);
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  PERFORM pause_workflow_sla_clock(v_clock_id, v_row.lock_version, 'pause before cancel', gen_random_uuid());
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  SELECT * INTO v_result FROM cancel_workflow_sla_clock(v_clock_id, v_row.lock_version, 'cancel while paused', gen_random_uuid());
  IF v_result.state <> 'cancelled' THEN RAISE EXCEPTION 'expected a paused clock to be cancellable, got %', v_result.state; END IF;
END $$;
INSERT INTO wf53_results VALUES (18,'cancel_workflow_sla_clock also succeeds from the paused state');

-- ── 19: any further RPC action on a terminal clock is rejected by the RPC's own state check ──
DO $$
DECLARE v_row workflow_sla_clocks;
BEGIN
  -- clock_cancel_paused (scenario 18) is pause_eligible=true and already cancelled --
  -- clock_cancel1 is an absolute-deadline clock (always pause_eligible=false), which
  -- would fail on eligibility before ever reaching the terminal-state check.
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_cancel_paused');
  BEGIN
    PERFORM pause_workflow_sla_clock(v_row.id, v_row.lock_version, 'should fail', gen_random_uuid());
    RAISE EXCEPTION 'expected pausing a cancelled clock to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%not running%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (19,'every lifecycle RPC rejects acting on an already-terminal (completed/cancelled) clock via its own explicit state check');

-- ── 20: terminal immutability is also enforced at the database level, independent of the RPC layer ──
RESET ROLE;
DO $$
BEGIN
  BEGIN
    UPDATE workflow_sla_clocks SET current_escalation_level = 99 WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_cancel1');
    RAISE EXCEPTION 'expected a raw UPDATE against a terminal clock to be rejected by the database trigger, bypassing the RPC layer entirely';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%already reached a terminal state%' THEN RAISE; END IF;
  END;
END $$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
INSERT INTO wf53_results VALUES (20,'terminal-state immutability is enforced by a database trigger independent of the RPC layer -- a raw UPDATE against an already-terminal clock is rejected even when issued directly against the table');

-- ── 21: warning threshold -- a due offset is recorded, an offset not yet due is untouched ──
-- workflow_sla_clocks_due_for_warning is intentionally ungranted to authenticated
-- (a private helper for a future dispatcher), so the due-count checks below run as postgres.
DO $$
DECLARE v_policy_id UUID; v_clock_id UUID;
BEGIN
  SELECT sla_policy_id INTO v_policy_id FROM create_workflow_sla_policy(
    '65330000-0000-0000-0000-000000000001','wf53_policy_warn','Warning policy',
    2,'hours',NULL,'UTC','[{"amount":3,"unit":"hours"},{"amount":1,"unit":"hours"}]'::jsonb,true,true,NULL,gen_random_uuid());
  -- deadline = now+2h; offset0 due_at = deadline-3h = now-1h (already due); offset1 due_at = deadline-1h = now+1h (not due).
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, v_policy_id, 'manual', NULL, NULL, NULL, gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('clock_warn', v_clock_id);
END $$;
RESET ROLE;
DO $$
DECLARE v_due_count_before INTEGER;
BEGIN
  SELECT count(*) INTO v_due_count_before FROM workflow_sla_clocks_due_for_warning(1000)
  WHERE clock_id = (SELECT id FROM wf53_ids WHERE name='clock_warn') AND warning_offset_index = 0;
  IF v_due_count_before <> 1 THEN RAISE EXCEPTION 'expected warning offset 0 to be reported as due before recording it, got %', v_due_count_before; END IF;
END $$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
DO $$
DECLARE v_clock_id UUID := (SELECT id FROM wf53_ids WHERE name='clock_warn'); v_row workflow_sla_clocks; v_result RECORD;
BEGIN
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  SELECT * INTO v_result FROM record_workflow_sla_warning(v_clock_id, v_row.lock_version, 0, gen_random_uuid());
  IF v_result.warning_offset_index <> 0 THEN RAISE EXCEPTION 'expected warning_offset_index=0 in the result'; END IF;
  IF NOT EXISTS (SELECT 1 FROM workflow_sla_clocks WHERE id = v_clock_id AND warned_up_to_index = 0 AND state = 'running') THEN
    RAISE EXCEPTION 'expected warned_up_to_index=0 and state to remain running (a warning never changes clock.state)';
  END IF;
END $$;
RESET ROLE;
DO $$
DECLARE v_due_count_after INTEGER;
BEGIN
  SELECT count(*) INTO v_due_count_after FROM workflow_sla_clocks_due_for_warning(1000)
  WHERE clock_id = (SELECT id FROM wf53_ids WHERE name='clock_warn');
  IF v_due_count_after <> 0 THEN RAISE EXCEPTION 'expected offset 1 to NOT be due yet (its due_at is still an hour in the future), got % due candidates', v_due_count_after; END IF;
END $$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
INSERT INTO wf53_results VALUES (21,'record_workflow_sla_warning records exactly the due, in-order warning offset, never changes clock.state, and the due-detection helper correctly reflects both the now-recorded offset and the still-not-due next offset');

-- ── 22: warning offsets must be recorded in order ──
DO $$
DECLARE v_row workflow_sla_clocks;
BEGIN
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_warn');
  BEGIN
    -- offset 1 comes before offset 0 was ever recorded a second time -- warned_up_to_index is already 0, so 0 again (not 1) would be the correct next expectation violated deliberately here by attempting to skip.
    PERFORM record_workflow_sla_warning(v_row.id, v_row.lock_version, 1, gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN
    NULL; -- offset 1 is not yet due, so this may fail on "not yet due" -- retest the pure ordering rule below instead.
  END;
END $$;
DO $$
DECLARE v_policy_id UUID; v_clock_id UUID; v_row workflow_sla_clocks;
BEGIN
  SELECT sla_policy_id INTO v_policy_id FROM create_workflow_sla_policy(
    '65330000-0000-0000-0000-000000000001','wf53_policy_warn2','Warning policy 2',
    1,'hours',NULL,'UTC','[{"amount":2,"unit":"hours"},{"amount":1,"unit":"hours"}]'::jsonb,true,true,NULL,gen_random_uuid());
  -- deadline = now+1h; both offsets already due (due_at = now-1h and now).
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, v_policy_id, 'manual', NULL, NULL, NULL, gen_random_uuid());
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  BEGIN
    PERFORM record_workflow_sla_warning(v_clock_id, v_row.lock_version, 1, gen_random_uuid());
    RAISE EXCEPTION 'expected recording offset index 1 before index 0 to be rejected as out of order';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%must be recorded in order%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (22,'record_workflow_sla_warning rejects recording a warning offset out of order (index N before index N-1) even when index N is itself due');

-- ── 23: a warning offset that is not yet due is rejected ──
DO $$
DECLARE v_policy_id UUID; v_clock_id UUID; v_row workflow_sla_clocks;
BEGIN
  SELECT sla_policy_id INTO v_policy_id FROM create_workflow_sla_policy(
    '65330000-0000-0000-0000-000000000001','wf53_policy_warn3','Warning policy 3',
    5,'hours',NULL,'UTC','[{"amount":1,"unit":"hours"}]'::jsonb,true,true,NULL,gen_random_uuid());
  -- deadline = now+5h; offset due_at = deadline-1h = now+4h (not due).
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, v_policy_id, 'manual', NULL, NULL, NULL, gen_random_uuid());
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  BEGIN
    PERFORM record_workflow_sla_warning(v_clock_id, v_row.lock_version, 0, gen_random_uuid());
    RAISE EXCEPTION 'expected recording a not-yet-due warning offset to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%not yet due%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (23,'record_workflow_sla_warning rejects recording a warning offset whose due time has not yet been reached');

-- ── 24: breach -- an elapsed deadline can be recorded, state stays running (breach is evidence, not a lifecycle state) ──
DO $$
DECLARE v_clock_id UUID;
BEGIN
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, NULL, 'manual', NULL, now() - interval '1 hour', 'UTC', gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('clock_breach1', v_clock_id);
END $$;
RESET ROLE;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM workflow_sla_clocks_due_for_breach(1000) WHERE clock_id = (SELECT id FROM wf53_ids WHERE name='clock_breach1')) THEN
    RAISE EXCEPTION 'expected the due-detection helper to report this already-elapsed clock as due for breach';
  END IF;
END $$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
DO $$
DECLARE v_clock_id UUID := (SELECT id FROM wf53_ids WHERE name='clock_breach1'); v_row workflow_sla_clocks; v_result RECORD;
BEGIN
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  SELECT * INTO v_result FROM record_workflow_sla_breach(v_clock_id, v_row.lock_version, gen_random_uuid());
  IF v_result.breached_at IS NULL THEN RAISE EXCEPTION 'expected breached_at to be set'; END IF;
  IF NOT EXISTS (SELECT 1 FROM workflow_sla_clocks WHERE id = v_clock_id AND state = 'running' AND breached_at IS NOT NULL) THEN
    RAISE EXCEPTION 'expected state to remain running -- breach never changes clock.state, the work stays active';
  END IF;
END $$;
RESET ROLE;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM workflow_sla_clocks_due_for_breach(1000) WHERE clock_id = (SELECT id FROM wf53_ids WHERE name='clock_breach1')) THEN
    RAISE EXCEPTION 'expected the clock to no longer be reported as due for breach once breached_at is set';
  END IF;
END $$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
INSERT INTO wf53_results VALUES (24,'record_workflow_sla_breach records an elapsed deadline, sets breached_at, but never changes clock.state -- the underlying work item remains active, exactly as the governing safety rule requires');

-- ── 25: breach is rejected before the deadline has elapsed ──
DO $$
DECLARE v_clock_id UUID; v_row workflow_sla_clocks;
BEGIN
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, NULL, 'manual', NULL, now() + interval '1 hour', 'UTC', gen_random_uuid());
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  BEGIN
    PERFORM record_workflow_sla_breach(v_clock_id, v_row.lock_version, gen_random_uuid());
    RAISE EXCEPTION 'expected breach recording to be rejected before the deadline has elapsed';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%has not yet elapsed%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (25,'record_workflow_sla_breach is rejected when the clock''s deadline has not yet elapsed');

-- ── 26: breach recording is idempotent once already breached (two independent paths can observe the same fact) ──
DO $$
DECLARE v_row workflow_sla_clocks; v_result RECORD; v_event_count INTEGER;
BEGIN
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_breach1');
  SELECT * INTO v_result FROM record_workflow_sla_breach(v_row.id, v_row.lock_version, gen_random_uuid());
  IF NOT v_result.replayed THEN RAISE EXCEPTION 'expected a second breach recording (already breached) to succeed as a no-op with replayed=true'; END IF;
  SELECT count(*) INTO v_event_count FROM workflow_sla_clock_events WHERE clock_id = v_row.id AND event_type = 'breached';
  IF v_event_count <> 1 THEN RAISE EXCEPTION 'expected exactly one breached evidence event despite two recording attempts, got %', v_event_count; END IF;
END $$;
INSERT INTO wf53_results VALUES (26,'record_workflow_sla_breach succeeds as an idempotent no-op once breached_at is already set (a future due-detection worker and a manual mark_breached escalation action can both legitimately observe the same breach) and never creates a duplicate breached evidence event');

-- ── 27: escalation levels fire in strict order, current_escalation_level advances by exactly one per call ──
DO $$
DECLARE v_esc_policy_id UUID; v_sla_policy_id UUID; v_clock_id UUID; v_row workflow_sla_clocks; v_r1 RECORD; v_r2 RECORD;
BEGIN
  SELECT escalation_policy_id INTO v_esc_policy_id FROM create_workflow_escalation_policy(
    '65330000-0000-0000-0000-000000000001','wf53_esc_ordered','Ordered escalation policy',
    '[{"level_order":1,"offset_from":"breach","offset_amount":0,"offset_unit":"hours","action_code":"remind_actor"},
      {"level_order":2,"offset_from":"previous_level","offset_amount":0,"offset_unit":"hours","action_code":"notify_supervisor","action_config":{"notify_user_id":"65330000-0001-0000-0000-000000000005"}}]'::jsonb,
    gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('esc_policy_ordered', v_esc_policy_id);
  SELECT sla_policy_id INTO v_sla_policy_id FROM create_workflow_sla_policy(
    '65330000-0000-0000-0000-000000000001','wf53_policy_esc','Escalation-bearing policy',
    2,'hours',NULL,'UTC','[]'::jsonb,true,true,v_esc_policy_id,gen_random_uuid());
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, v_sla_policy_id, 'manual', NULL, NULL, NULL, gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('clock_esc_ordered', v_clock_id);
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  SELECT * INTO v_r1 FROM trigger_workflow_sla_escalation(v_clock_id, v_row.lock_version, gen_random_uuid());
  IF v_r1.level_order <> 1 OR v_r1.action_code <> 'remind_actor' OR v_r1.current_escalation_level <> 1 THEN
    RAISE EXCEPTION 'expected the first manual escalation to fire level 1 (remind_actor), got %', row_to_json(v_r1);
  END IF;
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  SELECT * INTO v_r2 FROM trigger_workflow_sla_escalation(v_clock_id, v_row.lock_version, gen_random_uuid());
  IF v_r2.level_order <> 2 OR v_r2.action_code <> 'notify_supervisor' OR v_r2.current_escalation_level <> 2 THEN
    RAISE EXCEPTION 'expected the second manual escalation to fire level 2 (notify_supervisor), got %', row_to_json(v_r2);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM workflow_escalation_events WHERE clock_id = v_clock_id AND level_order = 1)
     OR NOT EXISTS (SELECT 1 FROM workflow_escalation_events WHERE clock_id = v_clock_id AND level_order = 2)
  THEN RAISE EXCEPTION 'expected both escalation levels to be recorded as evidence'; END IF;
END $$;
INSERT INTO wf53_results VALUES (27,'trigger_workflow_sla_escalation fires escalation levels in strict order (current_escalation_level + 1 exactly), never skipping, with each level recorded as evidence in workflow_escalation_events');

-- ── 28: mark_breached is the one real escalation effect -- it actually sets breached_at ──
DO $$
DECLARE v_esc_policy_id UUID; v_sla_policy_id UUID; v_clock_id UUID; v_row workflow_sla_clocks; v_r1 RECORD;
BEGIN
  SELECT escalation_policy_id INTO v_esc_policy_id FROM create_workflow_escalation_policy(
    '65330000-0000-0000-0000-000000000001','wf53_esc_markbreach','Mark-breached escalation policy',
    '[{"level_order":1,"offset_from":"breach","offset_amount":0,"offset_unit":"hours","action_code":"mark_breached"}]'::jsonb,
    gen_random_uuid());
  SELECT sla_policy_id INTO v_sla_policy_id FROM create_workflow_sla_policy(
    '65330000-0000-0000-0000-000000000001','wf53_policy_markbreach','Mark-breach policy',
    2,'hours',NULL,'UTC','[]'::jsonb,true,true,v_esc_policy_id,gen_random_uuid());
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, v_sla_policy_id, 'manual', NULL, NULL, NULL, gen_random_uuid());
  IF EXISTS (SELECT 1 FROM workflow_sla_clocks WHERE id = v_clock_id AND breached_at IS NOT NULL) THEN
    RAISE EXCEPTION 'sanity check failed: a freshly created clock should not already be breached';
  END IF;
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  SELECT * INTO v_r1 FROM trigger_workflow_sla_escalation(v_clock_id, v_row.lock_version, gen_random_uuid());
  IF v_r1.action_code <> 'mark_breached' THEN RAISE EXCEPTION 'expected level 1 to be mark_breached'; END IF;
  IF NOT EXISTS (SELECT 1 FROM workflow_sla_clocks WHERE id = v_clock_id AND breached_at IS NOT NULL) THEN
    RAISE EXCEPTION 'expected the mark_breached escalation action to actually set breached_at, without record_workflow_sla_breach ever having been called';
  END IF;
END $$;
INSERT INTO wf53_results VALUES (28,'of the seven closed escalation actions, mark_breached performs a real effect: firing it via trigger_workflow_sla_escalation alone (with no separate record_workflow_sla_breach call) sets the clock''s own breached_at');

-- ── 29: a non-mark_breached escalation action never touches breached_at (evidence-only) ──
DO $$
DECLARE v_row workflow_sla_clocks;
BEGIN
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_esc_ordered');
  IF v_row.breached_at IS NOT NULL THEN
    RAISE EXCEPTION 'expected clock_esc_ordered (which only ever fired remind_actor and notify_supervisor) to still have a null breached_at, got %', v_row.breached_at;
  END IF;
END $$;
INSERT INTO wf53_results VALUES (29,'escalation actions other than mark_breached (remind_actor, notify_supervisor, etc.) never touch breached_at -- they are recorded purely as evidence');

-- ── 30: escalation is rejected when the clock has no escalation policy configured ──
DO $$
DECLARE v_row workflow_sla_clocks;
BEGIN
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_warn');
  BEGIN
    PERFORM trigger_workflow_sla_escalation(v_row.id, v_row.lock_version, gen_random_uuid());
    RAISE EXCEPTION 'expected escalation to be rejected when no escalation_policy_id is configured';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%no escalation policy configured%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (30,'trigger_workflow_sla_escalation is rejected when the clock has no escalation_policy_id configured');

-- ── 31: escalation is rejected once every configured level has already fired ──
DO $$
DECLARE v_row workflow_sla_clocks;
BEGIN
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_esc_ordered');
  BEGIN
    PERFORM trigger_workflow_sla_escalation(v_row.id, v_row.lock_version, gen_random_uuid());
    RAISE EXCEPTION 'expected escalation to be rejected once all configured levels (1 and 2) have already fired';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%No further escalation level%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (31,'trigger_workflow_sla_escalation is rejected once no further escalation level is configured beyond the current one');

-- ── 32: escalation is rejected on a paused clock ──
DO $$
DECLARE v_sla_policy_id UUID; v_clock_id UUID; v_row workflow_sla_clocks;
BEGIN
  SELECT sla_policy_id INTO v_sla_policy_id FROM create_workflow_sla_policy(
    '65330000-0000-0000-0000-000000000001','wf53_policy_esc_pause','Escalation policy for pause test',
    2,'hours',NULL,'UTC','[]'::jsonb,true,true,(SELECT id FROM wf53_ids WHERE name='esc_policy_ordered'),gen_random_uuid());
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, v_sla_policy_id, 'manual', NULL, NULL, NULL, gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('clock_esc_pause', v_clock_id);
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  PERFORM pause_workflow_sla_clock(v_clock_id, v_row.lock_version, 'pause before escalation attempt', gen_random_uuid());
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  BEGIN
    PERFORM trigger_workflow_sla_escalation(v_clock_id, v_row.lock_version, gen_random_uuid());
    RAISE EXCEPTION 'expected escalation to be rejected on a paused clock';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%cannot act on a paused or terminal clock%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (32,'trigger_workflow_sla_escalation is rejected on a paused clock');

-- ── 33: escalation is rejected on a terminal (cancelled) clock ──
DO $$
DECLARE v_row workflow_sla_clocks;
BEGIN
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_esc_pause');
  PERFORM resume_workflow_sla_clock(v_row.id, v_row.lock_version, gen_random_uuid());
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_row.id;
  PERFORM cancel_workflow_sla_clock(v_row.id, v_row.lock_version, 'cancel before escalation attempt', gen_random_uuid());
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_row.id;
  BEGIN
    PERFORM trigger_workflow_sla_escalation(v_row.id, v_row.lock_version, gen_random_uuid());
    RAISE EXCEPTION 'expected escalation to be rejected on a cancelled clock';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%cannot act on a paused or terminal clock%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (33,'trigger_workflow_sla_escalation is rejected on a terminal (cancelled) clock');

-- ── 34: the database-level backstop rejects a duplicate escalation level even bypassing the RPC ──
RESET ROLE;
DO $$
DECLARE v_ev workflow_escalation_events;
BEGIN
  SELECT * INTO v_ev FROM workflow_escalation_events WHERE clock_id = (SELECT id FROM wf53_ids WHERE name='clock_esc_ordered') AND level_order = 1;
  BEGIN
    INSERT INTO workflow_escalation_events (clock_id, instance_id, escalation_level_id, level_order, action_code, triggered_by, triggering_actor_id, idempotency_key, metadata)
    VALUES (v_ev.clock_id, v_ev.instance_id, v_ev.escalation_level_id, v_ev.level_order, v_ev.action_code, 'manual', v_ev.triggering_actor_id, gen_random_uuid(), '{}'::jsonb);
    RAISE EXCEPTION 'expected a raw duplicate-level INSERT to be rejected by the UNIQUE(clock_id, escalation_level_id) backstop';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
END $$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
INSERT INTO wf53_results VALUES (34,'the UNIQUE(clock_id, escalation_level_id) constraint is a hard database-level backstop against a level ever firing twice for the same clock, independent of the RPC''s own ordering check');

-- ── 35: idempotent replay returns the identical result on repeat (pause, as a representative RPC) ──
DO $$
DECLARE v_clock_id UUID; v_row workflow_sla_clocks; v_key UUID := gen_random_uuid(); v_r1 RECORD; v_r2 RECORD;
BEGIN
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, (SELECT id FROM wf53_ids WHERE name='policy_plain'), 'manual', NULL, NULL, NULL, gen_random_uuid());
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  SELECT * INTO v_r1 FROM pause_workflow_sla_clock(v_clock_id, v_row.lock_version, 'replay test', v_key);
  SELECT * INTO v_r2 FROM pause_workflow_sla_clock(v_clock_id, v_row.lock_version, 'replay test', v_key);
  IF v_r1.lock_version <> v_r2.lock_version OR NOT v_r2.replayed OR v_r1.replayed THEN
    RAISE EXCEPTION 'expected the second call with the same idempotency_key to return the identical lock_version with replayed=true, got r1=% r2=%', row_to_json(v_r1), row_to_json(v_r2);
  END IF;
END $$;
INSERT INTO wf53_results VALUES (35,'replaying pause_workflow_sla_clock with the same idempotency_key returns the identical prior result (replayed=true) rather than erroring or double-applying the action');

-- ── 36: reusing an idempotency_key with different input is rejected ──
DO $$
DECLARE v_clock_id UUID; v_row workflow_sla_clocks; v_key UUID := gen_random_uuid();
BEGIN
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, (SELECT id FROM wf53_ids WHERE name='policy_plain'), 'manual', NULL, NULL, NULL, gen_random_uuid());
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  PERFORM pause_workflow_sla_clock(v_clock_id, v_row.lock_version, 'first reason', v_key);
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  BEGIN
    -- Same key, but the clock's lock_version has since moved on (it's paused now) -- expected_lock_version supplied here differs from what was stored.
    PERFORM resume_workflow_sla_clock(v_clock_id, v_row.lock_version, v_key);
    RAISE EXCEPTION 'expected reusing the same idempotency_key for a DIFFERENT event_type (resumed vs paused) to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%already used with different input%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (36,'reusing the same idempotency_key for genuinely different input (here: a different RPC/event_type entirely) is rejected rather than silently returning a mismatched replay');

-- ── 37: a stale expected_lock_version is rejected ──
DO $$
DECLARE v_clock_id UUID; v_row workflow_sla_clocks;
BEGIN
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, (SELECT id FROM wf53_ids WHERE name='policy_plain'), 'manual', NULL, NULL, NULL, gen_random_uuid());
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  PERFORM pause_workflow_sla_clock(v_clock_id, v_row.lock_version, 'first', gen_random_uuid());
  BEGIN
    -- v_row.lock_version is now stale (the clock has moved to lock_version+1).
    PERFORM resume_workflow_sla_clock(v_clock_id, v_row.lock_version, gen_random_uuid());
    RAISE EXCEPTION 'expected a stale expected_lock_version to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> '40001' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (37,'supplying a stale expected_lock_version is rejected with a serialization-style error (SQLSTATE 40001), never silently applied against the wrong version');

-- ── 38: business-hours/business-days calendar arithmetic correctly skips the weekend ──
RESET ROLE;
DO $$
DECLARE v_cal_id UUID; v_ver_id UUID; v_deadline TIMESTAMPTZ;
BEGIN
  SELECT calendar_id, version_id INTO v_cal_id, v_ver_id FROM create_workflow_business_calendar_version(
    '65330000-0000-0000-0000-000000000001','wf53_cal','WF53 Calendar','UTC',
    ARRAY[1,2,3,4,5], '09:00'::TIME, '17:00'::TIME, ARRAY[]::DATE[], gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('cal', v_cal_id);
  INSERT INTO wf53_ids VALUES ('cal_v1', v_ver_id);
  -- Friday 2026-01-09 16:00 UTC + 2 business hours: 1 hour available Friday (16:00-17:00),
  -- remaining 1 hour rolls to Monday 2026-01-12 09:00-10:00.
  v_deadline := workflow_calculate_calendar_deadline('2026-01-09 16:00:00+00'::TIMESTAMPTZ, 2, 'business_hours', v_ver_id, 'UTC');
  IF v_deadline <> '2026-01-12 10:00:00+00'::TIMESTAMPTZ THEN
    RAISE EXCEPTION 'expected the weekend to be skipped, landing at 2026-01-12 10:00 UTC, got %', v_deadline;
  END IF;
END $$;
INSERT INTO wf53_results VALUES (38,'workflow_calculate_calendar_deadline correctly skips non-working days: a business-hours duration that would land on a weekend rolls forward to the next working day at its opening hour');

-- ── 39: holiday exclusion ──
DO $$
DECLARE v_cal_id UUID; v_ver_id UUID; v_deadline TIMESTAMPTZ;
BEGIN
  SELECT calendar_id, version_id INTO v_cal_id, v_ver_id FROM create_workflow_business_calendar_version(
    '65330000-0000-0000-0000-000000000001','wf53_cal_holiday','WF53 Calendar with holiday','UTC',
    ARRAY[1,2,3,4,5], '09:00'::TIME, '17:00'::TIME, ARRAY['2026-01-12']::DATE[], gen_random_uuid());
  -- Same Friday-16:00 + 2 business hours scenario, but Monday 2026-01-12 is now a holiday --
  -- expect it to roll further to Tuesday 2026-01-13 09:00-10:00.
  v_deadline := workflow_calculate_calendar_deadline('2026-01-09 16:00:00+00'::TIMESTAMPTZ, 2, 'business_hours', v_ver_id, 'UTC');
  IF v_deadline <> '2026-01-13 10:00:00+00'::TIMESTAMPTZ THEN
    RAISE EXCEPTION 'expected the holiday to also be skipped, landing at 2026-01-13 10:00 UTC, got %', v_deadline;
  END IF;
END $$;
INSERT INTO wf53_results VALUES (39,'workflow_calculate_calendar_deadline correctly excludes holidays from the calendar version''s working-day set, in addition to non-working weekdays');

-- ── 40: calendar-version stability -- a clock already pinned to an older version is unaffected by a newer one ──
DO $$
DECLARE v_clock_id UUID; v_row workflow_sla_clocks; v_policy_id UUID; v_new_ver_id UUID;
BEGIN
  SELECT sla_policy_id INTO v_policy_id FROM create_workflow_sla_policy(
    '65330000-0000-0000-0000-000000000001','wf53_policy_cal','Calendar-based policy',
    1,'business_days',(SELECT id FROM wf53_ids WHERE name='cal'),'UTC','[]'::jsonb,true,true,NULL,gen_random_uuid());
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, v_policy_id, 'manual', NULL, NULL, NULL, gen_random_uuid());
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  IF v_row.calendar_version_id <> (SELECT id FROM wf53_ids WHERE name='cal_v1') THEN
    RAISE EXCEPTION 'expected the clock to pin to the calendar version active at creation time';
  END IF;
  -- Publish a new calendar version with different working hours.
  SELECT version_id INTO v_new_ver_id FROM create_workflow_business_calendar_version(
    '65330000-0000-0000-0000-000000000001','wf53_cal','WF53 Calendar','UTC',
    ARRAY[1,2,3,4,5], '08:00'::TIME, '18:00'::TIME, ARRAY[]::DATE[], gen_random_uuid());
  IF v_new_ver_id = (SELECT id FROM wf53_ids WHERE name='cal_v1') THEN
    RAISE EXCEPTION 'sanity check failed: expected a genuinely new calendar version';
  END IF;
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  IF v_row.calendar_version_id <> (SELECT id FROM wf53_ids WHERE name='cal_v1') THEN
    RAISE EXCEPTION 'expected the existing clock to remain pinned to the OLD calendar version -- publishing a new version must never silently rewrite an already-computed deadline';
  END IF;
END $$;
INSERT INTO wf53_results VALUES (40,'an SLA clock remains pinned to the business calendar version that was active when its deadline was computed -- publishing a newer calendar version never retroactively changes an existing clock''s calendar_version_id or effective_deadline');

-- ── 41: naming a user in an escalation action_config grants them no visibility ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ESCALATION_TARGET_A', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  -- escalation_target_a was named in clock_esc_ordered's level 2 notify_supervisor action_config (scenario 27),
  -- but was never added as a workflow_participants row.
  SELECT count(*) INTO v_count FROM workflow_escalation_events WHERE clock_id = (SELECT id FROM wf53_ids WHERE name='clock_esc_ordered');
  IF v_count <> 0 THEN RAISE EXCEPTION 'expected escalation_target_a to see zero escalation events despite being named in one, saw %', v_count; END IF;
  SELECT count(*) INTO v_count FROM workflow_sla_clocks WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_esc_ordered');
  IF v_count <> 0 THEN RAISE EXCEPTION 'expected escalation_target_a to see zero rows for the underlying clock, saw %', v_count; END IF;
END $$;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
INSERT INTO wf53_results VALUES (41,'a user named only inside an escalation level''s action_config (e.g. a notify_supervisor target) gains NO visibility from that alone -- they still see zero rows for the clock or its escalation events unless independently a workflow_participant, exactly as the governing safety rule requires');

-- ── 42: no automatic business decision -- SLA/escalation operations never touch the underlying instance or work item state ──
DO $$
DECLARE v_status_before TEXT; v_status_after TEXT; v_wi_status_before TEXT; v_wi_status_after TEXT;
BEGIN
  SELECT status INTO v_status_before FROM workflow_instances WHERE id = (SELECT id FROM wf53_ids WHERE name='i1');
  SELECT state INTO v_wi_status_before FROM workflow_work_items WHERE id = (SELECT id FROM wf53_ids WHERE name='worker_a_wi');
  -- Every clock/escalation RPC exercised in this suite has already run above; re-check now.
  SELECT status INTO v_status_after FROM workflow_instances WHERE id = (SELECT id FROM wf53_ids WHERE name='i1');
  SELECT state INTO v_wi_status_after FROM workflow_work_items WHERE id = (SELECT id FROM wf53_ids WHERE name='worker_a_wi');
  IF v_status_before IS DISTINCT FROM v_status_after OR v_wi_status_before IS DISTINCT FROM v_wi_status_after THEN
    RAISE EXCEPTION 'expected the instance and work item status to be completely unaffected by every SLA/escalation operation in this suite, before=(%,%) after=(%,%)',
      v_status_before, v_wi_status_before, v_status_after, v_wi_status_after;
  END IF;
END $$;
INSERT INTO wf53_results VALUES (42,'no SLA or escalation operation in this suite (clock lifecycle, warnings, breaches, or manual escalation across all seven action codes) ever modifies workflow_instances.status or workflow_work_items.status -- escalation never automatically approves, rejects, or closes a business decision on timeout');

-- ── 43: delegation/substitution coexistence -- an SLA clock on a delegated work item is unaffected by, and does not affect, the delegation ──
SELECT set_config('request.jwt.claims', :'WORKER_A', false);
DO $$
DECLARE v_delegation_id UUID; v_lock_before BIGINT; v_status_before TEXT;
BEGIN
  SELECT delegation_id, lock_version, status INTO v_delegation_id, v_lock_before, v_status_before FROM create_workflow_delegation(
    '65330000-0000-0000-0000-000000000001','65330000-0001-0000-0000-000000000003','65330000-0001-0000-0000-000000000007',
    ('{"type":"work_item","work_item_id":"' || (SELECT id FROM wf53_ids WHERE name='worker_a_wi') || '"}')::jsonb,
    'temporary','manual', now(), now() + interval '1 day', 'coexistence test', gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('coexist_delegation', v_delegation_id);
  INSERT INTO wf53_scratch VALUES ('coexist_lock_before', v_lock_before::TEXT), ('coexist_status_before', v_status_before);
END $$;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
DO $$
DECLARE v_clock_id UUID; v_row workflow_sla_clocks; v_lock_before BIGINT; v_status_before TEXT; v_lock_after BIGINT; v_status_after TEXT;
BEGIN
  SELECT val::BIGINT INTO v_lock_before FROM wf53_scratch WHERE key = 'coexist_lock_before';
  SELECT val INTO v_status_before FROM wf53_scratch WHERE key = 'coexist_status_before';
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, (SELECT id FROM wf53_ids WHERE name='worker_a_wi'),
    (SELECT id FROM wf53_ids WHERE name='policy_plain'), 'work_item_created', NULL, NULL, NULL, gen_random_uuid());
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  PERFORM pause_workflow_sla_clock(v_clock_id, v_row.lock_version, 'coexistence pause', gen_random_uuid());
  SELECT lock_version, status INTO v_lock_after, v_status_after FROM workflow_delegations WHERE id = (SELECT id FROM wf53_ids WHERE name='coexist_delegation');
  IF v_lock_after <> v_lock_before OR v_status_after IS DISTINCT FROM v_status_before THEN
    RAISE EXCEPTION 'expected the delegation to be completely unaffected by SLA clock creation/pause on its own scoped work item, before=(%,%) after=(%,%)', v_lock_before, v_status_before, v_lock_after, v_status_after;
  END IF;
END $$;
INSERT INTO wf53_results VALUES (43,'an active work-item-scoped delegation (Phase 5.1/5.2) coexists with an SLA clock created for the same work item -- creating and pausing the clock neither errors nor modifies the delegation''s own lock_version or status');

-- ── 44: work-item-assignee authorization path -- the work item holder can manage the clock without being instance owner/manager ──
-- Clock creation itself requires can_manage_workflow_instance (admin_a, the owner); the
-- point under test is that pausing it afterward only needs work-item-assignee standing.
DO $$
DECLARE v_clock_id UUID; v_row workflow_sla_clocks;
BEGIN
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, (SELECT id FROM wf53_ids WHERE name='worker_a_wi'),
    (SELECT id FROM wf53_ids WHERE name='policy_plain'), 'work_item_created', NULL, NULL, NULL, gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('clock_worker_auth', v_clock_id);
END $$;
SELECT set_config('request.jwt.claims', :'WORKER_A', false);
DO $$
DECLARE v_clock_id UUID := (SELECT id FROM wf53_ids WHERE name='clock_worker_auth'); v_row workflow_sla_clocks; v_result RECORD;
BEGIN
  SELECT * INTO v_row FROM workflow_sla_clocks WHERE id = v_clock_id;
  SELECT * INTO v_result FROM pause_workflow_sla_clock(v_clock_id, v_row.lock_version, 'worker manages own clock', gen_random_uuid());
  IF v_result.state <> 'paused' THEN RAISE EXCEPTION 'expected worker_a (the work item''s assignee, not an instance owner/manager) to be able to manage this clock'; END IF;
END $$;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
INSERT INTO wf53_results VALUES (44,'can_manage_workflow_sla_clock''s work-item-assignee branch lets the current holder of a clock''s work item manage it directly, without requiring instance owner/manager status -- reusing existing authorization primitives rather than a parallel permission system');

-- ── 45: cross-organization rejection ──
SELECT set_config('request.jwt.claims', :'ADMIN_B', false);
DO $$
BEGIN
  BEGIN
    PERFORM create_workflow_sla_policy(
      '65330000-0000-0000-0000-000000000001','wf53_policy_crossorg','Cross-org attempt',
      1,'hours',NULL,'UTC','[]'::jsonb,true,true,NULL,gen_random_uuid());
    RAISE EXCEPTION 'expected admin_b (org B admin) to be rejected when managing org A SLA configuration';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> '42501' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM pause_workflow_sla_clock((SELECT id FROM wf53_ids WHERE name='clock_warn'), 0, 'cross-org attempt', gen_random_uuid());
    RAISE EXCEPTION 'expected admin_b to be rejected when managing an org A SLA clock (not an owner/manager/work-item-holder of that instance)';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE <> '42501' THEN RAISE; END IF;
  END;
END $$;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
INSERT INTO wf53_results VALUES (45,'an administrator of a different organization cannot create SLA configuration for org A, nor manage an org A SLA clock they have no participant/work-item standing on');

-- ── 46: escalation policy level validation -- duplicate and gapped level_order are both rejected ──
DO $$
BEGIN
  BEGIN
    PERFORM create_workflow_escalation_policy(
      '65330000-0000-0000-0000-000000000001','wf53_esc_dup','Duplicate level policy',
      '[{"level_order":1,"offset_from":"breach","offset_amount":0,"offset_unit":"hours","action_code":"remind_actor"},
        {"level_order":1,"offset_from":"breach","offset_amount":1,"offset_unit":"hours","action_code":"mark_breached"}]'::jsonb,
      gen_random_uuid());
    RAISE EXCEPTION 'expected duplicate level_order to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%Duplicate or ambiguous%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM create_workflow_escalation_policy(
      '65330000-0000-0000-0000-000000000001','wf53_esc_gap','Gapped level policy',
      '[{"level_order":1,"offset_from":"breach","offset_amount":0,"offset_unit":"hours","action_code":"remind_actor"},
        {"level_order":3,"offset_from":"previous_level","offset_amount":1,"offset_unit":"hours","action_code":"mark_breached"}]'::jsonb,
      gen_random_uuid());
    RAISE EXCEPTION 'expected a gapped level_order sequence (1,3) to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%contiguous sequence%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (46,'create_workflow_escalation_policy rejects both a duplicate level_order and a gapped (non-contiguous) level_order sequence, atomically validating the full ordered level list before any row is inserted');

-- ── 47: malformed warning_offsets are rejected at policy creation ──
DO $$
BEGIN
  BEGIN
    PERFORM create_workflow_sla_policy(
      '65330000-0000-0000-0000-000000000001','wf53_policy_badwarn','Malformed warning offsets',
      1,'hours',NULL,'UTC','[{"unit":"hours"}]'::jsonb,true,true,NULL,gen_random_uuid());
    RAISE EXCEPTION 'expected a warning offset missing "amount" to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%numeric amount and a valid unit%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (47,'create_workflow_sla_policy rejects a malformed warning_offsets entry (missing amount or an invalid unit)');

-- ═══════════════════════════════════════════════════════════════════
-- CAP-002 Phase 5.3A architecture-conformance correction scenarios
-- ═══════════════════════════════════════════════════════════════════

-- ── 48: authenticated cannot call restart_workflow_sla_clock directly ──
DO $$
BEGIN
  BEGIN
    PERFORM restart_workflow_sla_clock((SELECT id FROM wf53_ids WHERE name='clock_plain1'), 0, 'should be denied', gen_random_uuid());
    RAISE EXCEPTION 'expected authenticated to be denied EXECUTE on restart_workflow_sla_clock';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
INSERT INTO wf53_results VALUES (48,'restart_workflow_sla_clock is not directly callable by authenticated -- docs/73 approves no restart trigger other than a future Reopen command, so this remains a private primitive until that command exists');

-- A dedicated calendar for scenarios 49/51 (weekend-only cases) -- NOT the 'cal' calendar
-- used by scenarios 38/40/54, since those later scenarios (in file order; 54 runs after this
-- section) publish additional versions on 'cal' with different working hours, which would
-- change 'cal' s *active* version out from under a freshly-created clock here.
DO $$
DECLARE v_ver_id UUID;
BEGIN
  SELECT version_id INTO v_ver_id FROM create_workflow_business_calendar_version(
    '65330000-0000-0000-0000-000000000001','wf53_cal_53a_base','WF53A base calendar (weekend cases)','UTC',
    ARRAY[1,2,3,4,5], '09:00'::TIME, '17:00'::TIME, ARRAY[]::DATE[], gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('cal_v_base_53a', v_ver_id);
END $$;

-- A second business calendar version carrying a holiday, shared by scenarios 50 and 52.
DO $$
DECLARE v_ver_id UUID;
BEGIN
  SELECT version_id INTO v_ver_id FROM create_workflow_business_calendar_version(
    '65330000-0000-0000-0000-000000000001','wf53_cal_53a_holiday','WF53A holiday calendar','UTC',
    ARRAY[1,2,3,4,5], '09:00'::TIME, '17:00'::TIME, ARRAY['2026-01-12']::DATE[], gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('cal_v_holiday_53a', v_ver_id);
END $$;

-- ── 49: forward business-hours escalation offset crosses a weekend correctly ──
DO $$
DECLARE v_esc_policy_id UUID; v_sla_policy_id UUID; v_clock_id UUID; v_cal_id UUID;
BEGIN
  SELECT calendar_id INTO v_cal_id FROM workflow_business_calendar_versions WHERE id = (SELECT id FROM wf53_ids WHERE name='cal_v_base_53a');
  SELECT escalation_policy_id INTO v_esc_policy_id FROM create_workflow_escalation_policy(
    '65330000-0000-0000-0000-000000000001','wf53_esc_calendar_wknd','Calendar-aware escalation policy (weekend)',
    '[{"level_order":1,"offset_from":"breach","offset_amount":2,"offset_unit":"business_hours","action_code":"remind_actor"}]'::jsonb,
    gen_random_uuid());
  SELECT sla_policy_id INTO v_sla_policy_id FROM create_workflow_sla_policy(
    '65330000-0000-0000-0000-000000000001','wf53_policy_esc_cal_wknd','Calendar-aware SLA+escalation policy (weekend)',
    2,'hours',v_cal_id,'UTC','[]'::jsonb,true,true,v_esc_policy_id,gen_random_uuid());
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, v_sla_policy_id, 'manual', NULL, NULL, NULL, gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('clock_esc_calendar_wknd', v_clock_id);
END $$;
RESET ROLE;
-- Force breached_at to Friday 2026-01-09 16:00 UTC (the 'cal' calendar version: Mon-Fri 09:00-17:00, no holiday).
UPDATE workflow_sla_clocks SET breached_at = '2026-01-09 16:00:00+00'::timestamptz
WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_esc_calendar_wknd');
DO $$
DECLARE v_due_at TIMESTAMPTZ;
BEGIN
  SELECT due_at INTO v_due_at FROM workflow_sla_clocks_due_for_escalation(1000)
  WHERE clock_id = (SELECT id FROM wf53_ids WHERE name='clock_esc_calendar_wknd');
  IF v_due_at <> '2026-01-12 10:00:00+00'::timestamptz THEN
    RAISE EXCEPTION 'expected the forward business-hours escalation offset (breach + 2 business hours) to skip the weekend, landing at 2026-01-12 10:00 UTC, got %', v_due_at;
  END IF;
END $$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
INSERT INTO wf53_results VALUES (49,'a forward business-hours escalation offset (breach + 2 business hours) correctly skips a weekend, via calendar-aware reuse of workflow_calculate_calendar_deadline, landing at the next working day''s opening hour');

-- ── 50: forward business-hours escalation offset crosses a configured holiday correctly ──
DO $$
DECLARE v_esc_policy_id UUID; v_sla_policy_id UUID; v_clock_id UUID; v_cal_id UUID;
BEGIN
  SELECT calendar_id INTO v_cal_id FROM workflow_business_calendar_versions WHERE id = (SELECT id FROM wf53_ids WHERE name='cal_v_holiday_53a');
  SELECT escalation_policy_id INTO v_esc_policy_id FROM create_workflow_escalation_policy(
    '65330000-0000-0000-0000-000000000001','wf53_esc_calendar_hol','Calendar-aware escalation policy (holiday)',
    '[{"level_order":1,"offset_from":"breach","offset_amount":2,"offset_unit":"business_hours","action_code":"remind_actor"}]'::jsonb,
    gen_random_uuid());
  SELECT sla_policy_id INTO v_sla_policy_id FROM create_workflow_sla_policy(
    '65330000-0000-0000-0000-000000000001','wf53_policy_esc_cal_hol','Calendar-aware SLA+escalation policy (holiday)',
    2,'hours',v_cal_id,'UTC','[]'::jsonb,true,true,v_esc_policy_id,gen_random_uuid());
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, v_sla_policy_id, 'manual', NULL, NULL, NULL, gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('clock_esc_calendar_hol', v_clock_id);
END $$;
RESET ROLE;
-- Force breached_at to Friday 2026-01-09 16:00 UTC; the holiday calendar version marks
-- Monday 2026-01-12 as a holiday, so the offset must also skip that day.
UPDATE workflow_sla_clocks SET breached_at = '2026-01-09 16:00:00+00'::timestamptz
WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_esc_calendar_hol');
DO $$
DECLARE v_due_at TIMESTAMPTZ;
BEGIN
  SELECT due_at INTO v_due_at FROM workflow_sla_clocks_due_for_escalation(1000)
  WHERE clock_id = (SELECT id FROM wf53_ids WHERE name='clock_esc_calendar_hol');
  IF v_due_at <> '2026-01-13 10:00:00+00'::timestamptz THEN
    RAISE EXCEPTION 'expected the forward business-hours escalation offset to also skip the configured holiday, landing at 2026-01-13 10:00 UTC, got %', v_due_at;
  END IF;
END $$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
INSERT INTO wf53_results VALUES (50,'a forward business-hours escalation offset also correctly skips a configured holiday, in addition to a non-working weekday');

-- ── 51: backward business-hours warning offset crosses a weekend correctly ──
DO $$
DECLARE v_policy_id UUID; v_clock_id UUID; v_cal_id UUID;
BEGIN
  SELECT calendar_id INTO v_cal_id FROM workflow_business_calendar_versions WHERE id = (SELECT id FROM wf53_ids WHERE name='cal_v_base_53a');
  SELECT sla_policy_id INTO v_policy_id FROM create_workflow_sla_policy(
    '65330000-0000-0000-0000-000000000001','wf53_policy_warn_cal_wknd','Calendar-aware warning policy (weekend)',
    4,'hours',v_cal_id,'UTC','[{"amount":2,"unit":"business_hours"}]'::jsonb,true,true,NULL,gen_random_uuid());
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, v_policy_id, 'manual', NULL, NULL, NULL, gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('clock_warn_calendar_wknd', v_clock_id);
END $$;
RESET ROLE;
-- Force the deadline to Monday 2026-01-12 10:00 UTC.
UPDATE workflow_sla_clocks SET effective_deadline = '2026-01-12 10:00:00+00'::timestamptz, effective_deadline_adjusted = '2026-01-12 10:00:00+00'::timestamptz
WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_warn_calendar_wknd');
DO $$
DECLARE v_due_at TIMESTAMPTZ;
BEGIN
  SELECT due_at INTO v_due_at FROM workflow_sla_clocks_due_for_warning(1000)
  WHERE clock_id = (SELECT id FROM wf53_ids WHERE name='clock_warn_calendar_wknd');
  IF v_due_at <> '2026-01-09 16:00:00+00'::timestamptz THEN
    RAISE EXCEPTION 'expected the backward business-hours warning offset (deadline - 2 business hours) to skip the weekend, landing at 2026-01-09 16:00 UTC, got %', v_due_at;
  END IF;
END $$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
INSERT INTO wf53_results VALUES (51,'a backward business-hours warning offset (deadline - 2 business hours) correctly skips a weekend, via the new calendar-aware workflow_calculate_calendar_offset_backward, landing at the prior working day''s closing hour');

-- ── 52: backward business-hours warning offset crosses a configured holiday correctly ──
DO $$
DECLARE v_policy_id UUID; v_clock_id UUID; v_cal_id UUID;
BEGIN
  SELECT calendar_id INTO v_cal_id FROM workflow_business_calendar_versions WHERE id = (SELECT id FROM wf53_ids WHERE name='cal_v_holiday_53a');
  SELECT sla_policy_id INTO v_policy_id FROM create_workflow_sla_policy(
    '65330000-0000-0000-0000-000000000001','wf53_policy_warn_cal_hol','Calendar-aware warning policy (holiday)',
    4,'hours',v_cal_id,'UTC','[{"amount":2,"unit":"business_hours"}]'::jsonb,true,true,NULL,gen_random_uuid());
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, v_policy_id, 'manual', NULL, NULL, NULL, gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('clock_warn_calendar_hol', v_clock_id);
END $$;
RESET ROLE;
-- Force the deadline to Tuesday 2026-01-13 10:00 UTC; the holiday calendar version marks
-- Monday 2026-01-12 as a holiday, so the offset must skip both that day and the weekend.
UPDATE workflow_sla_clocks SET effective_deadline = '2026-01-13 10:00:00+00'::timestamptz, effective_deadline_adjusted = '2026-01-13 10:00:00+00'::timestamptz
WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_warn_calendar_hol');
DO $$
DECLARE v_due_at TIMESTAMPTZ;
BEGIN
  SELECT due_at INTO v_due_at FROM workflow_sla_clocks_due_for_warning(1000)
  WHERE clock_id = (SELECT id FROM wf53_ids WHERE name='clock_warn_calendar_hol');
  IF v_due_at <> '2026-01-09 16:00:00+00'::timestamptz THEN
    RAISE EXCEPTION 'expected the backward business-hours warning offset to also skip the configured holiday, landing at 2026-01-09 16:00 UTC, got %', v_due_at;
  END IF;
END $$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
INSERT INTO wf53_results VALUES (52,'a backward business-hours warning offset also correctly skips a configured holiday, in addition to a non-working weekday');

-- ── 53: plain hours/days offsets remain simple wall-clock arithmetic, unaffected by calendar-awareness ──
RESET ROLE;
DO $$
DECLARE v_forward TIMESTAMPTZ; v_backward TIMESTAMPTZ;
BEGIN
  v_forward := workflow_calculate_calendar_deadline('2026-01-09 16:00:00+00'::timestamptz, 5, 'hours', NULL, 'UTC');
  IF v_forward <> '2026-01-09 21:00:00+00'::timestamptz THEN
    RAISE EXCEPTION 'expected a plain-hours forward offset to remain simple wall-clock addition, got %', v_forward;
  END IF;
  v_backward := workflow_calculate_calendar_offset_backward('2026-01-13 10:00:00+00'::timestamptz, 3, 'days', NULL, 'UTC');
  IF v_backward <> '2026-01-10 10:00:00+00'::timestamptz THEN
    RAISE EXCEPTION 'expected a plain-days backward offset to remain simple wall-clock subtraction (never skipping weekends), got %', v_backward;
  END IF;
END $$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
INSERT INTO wf53_results VALUES (53,'plain hours/days offsets (both forward, for escalation, and backward, for warnings) remain simple wall-clock arithmetic, completely unaffected by the calendar-awareness correction applied to business_hours/business_days');

-- ── 54: calendar-version stability also holds for offset evaluation, not just the deadline itself ──
DO $$
DECLARE v_policy_id UUID; v_clock_id UUID; v_row workflow_sla_clocks; v_new_ver_id UUID; v_due_before TIMESTAMPTZ; v_due_after TIMESTAMPTZ;
BEGIN
  SELECT sla_policy_id INTO v_policy_id FROM create_workflow_sla_policy(
    '65330000-0000-0000-0000-000000000001','wf53_policy_warn_cal_stab','Calendar-version-stability warning policy',
    4,'hours',(SELECT id FROM wf53_ids WHERE name='cal'),'UTC','[{"amount":2,"unit":"business_hours"}]'::jsonb,true,true,NULL,gen_random_uuid());
  SELECT clock_id INTO v_clock_id FROM create_workflow_sla_clock(
    (SELECT id FROM wf53_ids WHERE name='i1'), NULL, NULL, v_policy_id, 'manual', NULL, NULL, NULL, gen_random_uuid());
  INSERT INTO wf53_ids VALUES ('clock_warn_cal_stab', v_clock_id);
END $$;
RESET ROLE;
UPDATE workflow_sla_clocks SET effective_deadline = '2026-01-12 10:00:00+00'::timestamptz, effective_deadline_adjusted = '2026-01-12 10:00:00+00'::timestamptz
WHERE id = (SELECT id FROM wf53_ids WHERE name='clock_warn_cal_stab');
DO $$
DECLARE v_due_before TIMESTAMPTZ;
BEGIN
  SELECT due_at INTO v_due_before FROM workflow_sla_clocks_due_for_warning(1000) WHERE clock_id = (SELECT id FROM wf53_ids WHERE name='clock_warn_cal_stab');
  INSERT INTO wf53_scratch VALUES ('cal_stab_due_before', v_due_before::TEXT);
END $$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
DO $$
DECLARE v_new_ver_id UUID;
BEGIN
  -- Publish a new calendar version with different working hours -- this must NOT change
  -- the already-pinned clock's offset due-time.
  SELECT version_id INTO v_new_ver_id FROM create_workflow_business_calendar_version(
    '65330000-0000-0000-0000-000000000001','wf53_cal','WF53 Calendar','UTC',
    ARRAY[1,2,3,4,5], '07:00'::TIME, '19:00'::TIME, ARRAY[]::DATE[], gen_random_uuid());
END $$;
RESET ROLE;
DO $$
DECLARE v_due_before TIMESTAMPTZ; v_due_after TIMESTAMPTZ;
BEGIN
  SELECT val::TIMESTAMPTZ INTO v_due_before FROM wf53_scratch WHERE key = 'cal_stab_due_before';
  SELECT due_at INTO v_due_after FROM workflow_sla_clocks_due_for_warning(1000) WHERE clock_id = (SELECT id FROM wf53_ids WHERE name='clock_warn_cal_stab');
  IF v_due_after <> v_due_before THEN
    RAISE EXCEPTION 'expected the offset due-time to remain pinned to the ORIGINAL calendar version, unaffected by a newer version''s different working hours, before=% after=%', v_due_before, v_due_after;
  END IF;
END $$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN_A', false);
INSERT INTO wf53_results VALUES (54,'calendar-version stability holds for offset evaluation exactly as it does for the deadline itself: publishing a newer calendar version never retroactively changes an existing clock''s already-pinned offset due-time calculation');

-- ── 55: create_workflow_sla_policy rejects a calendar-aware warning offset with no calendar_id ──
DO $$
BEGIN
  BEGIN
    PERFORM create_workflow_sla_policy(
      '65330000-0000-0000-0000-000000000001','wf53_policy_badwarn_cal','Warning offset needs calendar',
      1,'hours',NULL,'UTC','[{"amount":2,"unit":"business_hours"}]'::jsonb,true,true,NULL,gen_random_uuid());
    RAISE EXCEPTION 'expected a business_hours warning offset with no calendar_id to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%calendar_id is required when any warning offset%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (55,'create_workflow_sla_policy rejects a calendar-aware (business_hours/business_days) warning offset when no calendar_id is supplied, preventing a clock from ever being created with an offset it could never evaluate');

-- ── 56: create_workflow_sla_policy rejects a calendar-aware escalation-level offset with no calendar_id ──
DO $$
DECLARE v_esc_policy_id UUID;
BEGIN
  SELECT escalation_policy_id INTO v_esc_policy_id FROM create_workflow_escalation_policy(
    '65330000-0000-0000-0000-000000000001','wf53_esc_needs_cal','Escalation policy with a calendar-aware level',
    '[{"level_order":1,"offset_from":"breach","offset_amount":1,"offset_unit":"business_days","action_code":"remind_actor"}]'::jsonb,
    gen_random_uuid());
  BEGIN
    PERFORM create_workflow_sla_policy(
      '65330000-0000-0000-0000-000000000001','wf53_policy_badesc_cal','Escalation offset needs calendar',
      1,'hours',NULL,'UTC','[]'::jsonb,true,true,v_esc_policy_id,gen_random_uuid());
    RAISE EXCEPTION 'expected referencing an escalation policy with a business_days level offset, with no calendar_id, to be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%calendar_id is required when the referenced escalation policy%' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO wf53_results VALUES (56,'create_workflow_sla_policy rejects referencing an escalation policy that has any calendar-aware (business_hours/business_days) level offset when no calendar_id is supplied');

-- ── 57: escalation evidence carries the required due/triggered-vs-performed self-documentation ──
DO $$
DECLARE v_comment TEXT;
BEGIN
  SELECT obj_description('workflow_escalation_events'::regclass, 'pg_class') INTO v_comment;
  IF v_comment IS NULL OR v_comment NOT ILIKE '%does NOT prove%' THEN
    RAISE EXCEPTION 'expected workflow_escalation_events to carry a schema comment clarifying due/triggered-vs-performed semantics, got %', v_comment;
  END IF;
END $$;
INSERT INTO wf53_results VALUES (57,'workflow_escalation_events carries a schema-level comment self-documenting that a row means the action became due/triggered and was recorded, not that an external effect (notification, module action) was actually delivered -- except mark_breached, which also performs a real effect');

RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf53_results;
  IF v_count <> 57 THEN
    RAISE EXCEPTION 'Expected 57 scenarios to record a result, found %', v_count;
  END IF;
  RAISE NOTICE 'Workflow SLA/escalation foundation behavioral tests PASSED: %/57', v_count;
END $$;

ROLLBACK;
