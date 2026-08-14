-- CAP-003 Phase 1.4 notification module integration foundation --
-- RLS/authorization test suite. Disposable local PostgreSQL only.
-- Runs in one transaction and leaves no fixtures (rolled back at the
-- end). Uses authenticated non-superuser contexts throughout for
-- every authorization-relevant assertion.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf85r_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
GRANT SELECT, INSERT ON wf85r_results TO authenticated, service_role;

INSERT INTO organizations(id,name,type,code) VALUES ('85100000-0000-0000-0000-000000000001','WF85R Org','authority','WF85RA');
INSERT INTO divisions(id, org_id, name) VALUES ('85100000-0004-0000-0000-000000000001','85100000-0000-0000-0000-000000000001','WF85R Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES ('85100000-0002-0000-0000-000000000001','85100000-0000-0000-0000-000000000001','85100000-0004-0000-0000-000000000001','WF85R Sec','SR1');

INSERT INTO auth.users(id,email) VALUES
 ('85100000-0001-0000-0000-000000000001','creator@wf85rt.local'),
 ('85100000-0001-0000-0000-000000000002','assignee@wf85rt.local'),
 ('85100000-0001-0000-0000-000000000003','unrelated@wf85rt.local'),
 ('85100000-0001-0000-0000-000000000004','unauthorizedactor@wf85rt.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('85100000-0001-0000-0000-000000000001','85100000-0000-0000-0000-000000000001','WF85R-1','Creator','creator@wf85rt.local',true),
 ('85100000-0001-0000-0000-000000000002','85100000-0000-0000-0000-000000000001','WF85R-2','Assignee','assignee@wf85rt.local',true),
 ('85100000-0001-0000-0000-000000000003','85100000-0000-0000-0000-000000000001','WF85R-3','Unrelated','unrelated@wf85rt.local',true),
 ('85100000-0001-0000-0000-000000000004','85100000-0000-0000-0000-000000000001','WF85R-4','Unauthorized Actor (no role)','unauthorizedactor@wf85rt.local',true);

INSERT INTO tasks (id, task_number, title, status, priority, created_by, organization_id, owning_section_id, visibility)
VALUES ('85100000-0007-0000-0000-000000000001','WF85R-T1','WF85R task','open','normal',
        '85100000-0001-0000-0000-000000000001','85100000-0000-0000-0000-000000000001','85100000-0002-0000-0000-000000000001','private');

\set CREATOR '{"sub":"85100000-0001-0000-0000-000000000001"}'
\set ASSIGNEE '{"sub":"85100000-0001-0000-0000-000000000002"}'
\set UNRELATED '{"sub":"85100000-0001-0000-0000-000000000003"}'
\set UNAUTHORIZED '{"sub":"85100000-0001-0000-0000-000000000004"}'

-- ── 1: an ordinary authenticated user cannot call
-- intent_user_can_view_task() directly -- it is granted to no role at
-- all (internal-only, invoked solely from resolve_notification_intent's
-- SECURITY DEFINER body) ──────────────────────────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ASSIGNEE', false);
DO $$ BEGIN
  BEGIN
    PERFORM intent_user_can_view_task('85100000-0007-0000-0000-000000000001','85100000-0001-0000-0000-000000000002');
    RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user could call intent_user_can_view_task() directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf85r_results VALUES (1,'An ordinary authenticated user cannot call intent_user_can_view_task() directly (permission denied) -- it is reachable by no role at all except from inside resolve_notification_intent''s own SECURITY DEFINER body, identical posture to Phase 1.2''s intent_user_can_view_workflow_instance()');

-- ── 2: an ordinary authenticated user cannot call
-- process_platform_outbox_batch() directly ──────────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ASSIGNEE', false);
DO $$ BEGIN
  BEGIN
    PERFORM process_platform_outbox_batch(1, 'attacker');
    RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user could invoke the worker directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf85r_results VALUES (2,'An ordinary authenticated user still cannot invoke process_platform_outbox_batch() directly -- Phase 1.4''s registry-driven dispatch change did not alter its service_role-only grant posture');

-- ── 3: an ordinary authenticated user cannot call
-- create_notification_intent() with source_record_type='task' (or any
-- source_record_type) directly -- the closed dispatch extension did
-- not open a new authenticated-callable surface ────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ASSIGNEE', false);
DO $$
DECLARE v_event_id UUID;
BEGIN
  -- CAP-003 Phase 1.8B reconciliation note: platform_outbox_events'
  -- real production grant posture (patch-notification-outbox-
  -- persistence-foundation.sql's own REVOKE ALL FROM PUBLIC, anon,
  -- authenticated) denies `authenticated` even SELECT -- this SELECT
  -- was previously only succeeding (or cleanly returning zero rows) in
  -- this disposable test harness because 01-grants.sql's own blanket
  -- grant silently reopened it, a harness-only gap fixed during Phase
  -- 1.8B testing (see docs/94). Wrapped here so a genuine permission-
  -- denied error on this lookup falls back to a synthetic id exactly
  -- like a zero-row result already did, preserving this scenario's own
  -- real assertion (create_notification_intent() itself is never
  -- directly callable) unchanged.
  BEGIN
    SELECT id INTO v_event_id FROM platform_outbox_events WHERE event_type='task.assigned.v1' LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_event_id := NULL;
  END;
  BEGIN
    PERFORM create_notification_intent(COALESCE(v_event_id, gen_random_uuid()), 'task.assigned.v1','task.assigned','{}'::JSONB,'normal',
      'specific_users', ARRAY['85100000-0001-0000-0000-000000000002']::UUID[], NULL, NULL, NULL, NULL,NULL,NULL);
    RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user could call create_notification_intent() directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf85r_results VALUES (3,'An ordinary authenticated user cannot call create_notification_intent() directly regardless of source_record_type -- Phase 1.4''s dispatch extension (adding ''task'') did not relax its service_role-only grant');

-- ── 4: assign_task() remains gated by its own pre-existing
-- authorization (unchanged by Phase 1.4) -- a same-org user with no
-- creator/supervisor/admin relationship still cannot assign the task ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'UNAUTHORIZED', false);
DO $$ BEGIN
  BEGIN
    PERFORM assign_task('85100000-0007-0000-0000-000000000001'::UUID, '85100000-0001-0000-0000-000000000002'::UUID);
    RAISE EXCEPTION 'SECURITY HOLE: an unauthorized same-org user was able to assign the task';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%Not authorized to assign this task%' THEN RAISE; END IF;
  END;
END $$;
RESET ROLE;
DO $$ DECLARE v_count INTEGER; BEGIN
  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE event_type='task.assigned.v1' AND source_record_id='85100000-0007-0000-0000-000000000001';
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: an outbox event was enqueued despite assign_task() rejecting the caller'; END IF;
END $$;
INSERT INTO wf85r_results VALUES (4,'assign_task()''s pre-existing authorization boundary (creator, or supervisor-or-above covering the owning section, or super_admin) is completely unchanged by Phase 1.4: an unauthorized same-org user is rejected before any mutation, and critically, before any outbox event is ever enqueued -- the new atomic enqueue is strictly downstream of the existing authorization check, never a bypass path');

-- ── 5: the creator IS authorized to assign, and doing so end-to-end
-- (as an ordinary authenticated user, not superuser) produces a
-- notification the assignee -- and only the assignee -- can read via
-- their own list_my_notifications() ─────────────────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'CREATOR', false);
SELECT assign_task('85100000-0007-0000-0000-000000000001'::UUID, '85100000-0001-0000-0000-000000000002'::UUID);
RESET ROLE;

SET ROLE service_role;
DO $$ BEGIN
  PERFORM process_platform_outbox_batch(50, 'wf85r-worker');
END $$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ASSIGNEE', false);
DO $$ DECLARE v_count INTEGER; BEGIN
  SELECT count(*) INTO v_count FROM list_my_notifications(50, NULL) WHERE notification_type = 'task.assigned.v1';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected the assignee to see exactly 1 task.assigned.v1 notification via list_my_notifications(), got %', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf85r_results VALUES (5,'End to end, as an ordinary authenticated user (not superuser): the authorized creator assigns the task, the worker resolves the resulting intent, and the assignee can read their own notification via the existing list_my_notifications() RLS-backed API -- Phase 1.1''s own read-path RLS is completely unaffected');

-- ── 6: an unrelated user cannot see the assignee's notification via
-- their own list_my_notifications() (existing Phase 1.1 RLS: a user
-- only ever sees their own recipient_user_id rows) ──────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'UNRELATED', false);
DO $$ DECLARE v_count INTEGER; BEGIN
  SELECT count(*) INTO v_count FROM list_my_notifications(50, NULL) WHERE notification_type = 'task.assigned.v1';
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: an unrelated user saw another user''s task.assigned.v1 notification, count=%', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf85r_results VALUES (6,'An unrelated authenticated user sees zero rows for the assignee''s task.assigned.v1 notification via their own list_my_notifications() -- Phase 1.1''s existing recipient_user_id=auth.uid() RLS policy on user_notifications is completely unaffected by Phase 1.4''s new event source');

-- ── 7: an ordinary authenticated user cannot write directly to
-- platform_event_type_registry (the new column does not open a new
-- write surface) ────────────────────────────────────────────────────
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'CREATOR', false);
DO $$ BEGIN
  BEGIN
    UPDATE platform_event_type_registry SET uses_generic_notification_envelope = TRUE WHERE event_type = 'wf85r.forged.v1';
    IF NOT FOUND THEN NULL; END IF;
    INSERT INTO platform_event_type_registry (event_type, owning_module, uses_generic_notification_envelope)
      VALUES ('wf85r.forged.v1','attacker_module',TRUE);
    RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user could register a forged event_type in platform_event_type_registry';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf85r_results VALUES (7,'An ordinary authenticated user cannot INSERT/UPDATE platform_event_type_registry directly -- the new uses_generic_notification_envelope column does not open any new write surface; registry rows remain server/migration-authored only, identical posture to every other Phase 1.1 configuration table');

-- ── 8: service_role (the legitimate caller for the worker entry
-- point) CAN reach process_platform_outbox_batch() -- a positive
-- control proving scenario 2's denial came from genuine grant
-- enforcement, not a broken test environment. intent_user_can_view_task()
-- itself is intentionally reachable by NO role directly (not even
-- service_role) -- it is invoked exclusively from inside
-- resolve_notification_intent()'s own SECURITY DEFINER body, executing
-- as that function's owner, identical posture to Phase 1.2's own
-- intent_user_can_view_workflow_instance() (verified structurally by
-- the validator, exercised indirectly by behavioral scenarios 7-16) ──
SET ROLE service_role;
DO $$ BEGIN
  PERFORM process_platform_outbox_batch(1, 'wf85r-control');
END $$;
RESET ROLE;
INSERT INTO wf85r_results VALUES (8,'service_role (the legitimate caller for the worker entry point) can reach process_platform_outbox_batch() without error -- a positive control confirming scenario 2''s denial came from genuine grant enforcement, not a misconfigured test environment');

-- ── 9: assign_task()'s own pre-existing anon rejection (an internal
-- auth.uid() IS NULL check, the same convention every task/meeting RPC
-- in this codebase uses -- not a REVOKE/GRANT boundary) is completely
-- unchanged by Phase 1.4's CREATE OR REPLACE ─────────────────────────
SELECT set_config('request.jwt.claims', NULL, false);
SET ROLE anon;
DO $$ BEGIN
  BEGIN
    PERFORM assign_task('85100000-0007-0000-0000-000000000001'::UUID, '85100000-0001-0000-0000-000000000002'::UUID);
    RAISE EXCEPTION 'SECURITY HOLE: assign_task() succeeded for an unauthenticated (anon) caller';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%requires an authenticated caller%' THEN RAISE; END IF;
  END;
END $$;
RESET ROLE;
INSERT INTO wf85r_results VALUES (9,'assign_task()''s own pre-existing "requires an authenticated caller" auth.uid() IS NULL check (the same convention every task/meeting RPC in this codebase relies on, not a REVOKE/GRANT-level boundary) is preserved byte-for-byte by Phase 1.4''s CREATE OR REPLACE -- an anon-context call is still rejected before any mutation or outbox enqueue is attempted');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf85r_results;
  IF v_count <> 9 THEN
    RAISE EXCEPTION 'Expected 9 scenarios to record a result, found %', v_count;
  END IF;
  RAISE NOTICE 'Notification module integration foundation RLS tests PASSED: %/9', v_count;
END $$;

ROLLBACK;
