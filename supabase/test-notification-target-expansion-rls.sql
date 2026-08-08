-- CAP-003 Phase 1.4A notification target expansion -- RLS/
-- authorization test suite. Disposable local PostgreSQL only. Runs
-- in one transaction and leaves no fixtures (rolled back at the end).
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf86r_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf86r_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf86r_results, wf86r_ids TO authenticated, service_role;

INSERT INTO organizations(id,name,type,code) VALUES
 ('86100000-0000-0000-0000-000000000001','WF86R Org A','authority','WF86RA'),
 ('86100000-0000-0000-0000-000000000002','WF86R Org B','authority','WF86RB');
INSERT INTO divisions(id, org_id, name) VALUES ('86100000-0004-0000-0000-000000000001','86100000-0000-0000-0000-000000000001','WF86R Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES ('86100000-0002-0000-0000-000000000001','86100000-0000-0000-0000-000000000001','86100000-0004-0000-0000-000000000001','WF86R Sec','SR1');

INSERT INTO auth.users(id,email) VALUES
 ('86100000-0001-0000-0000-000000000001','creator@wf86rt.local'),
 ('86100000-0001-0000-0000-000000000002','watcher@wf86rt.local'),
 ('86100000-0001-0000-0000-000000000003','unrelated@wf86rt.local'),
 ('86100000-0001-0000-0000-000000000004','crossorgparticipant@wf86rt.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('86100000-0001-0000-0000-000000000001','86100000-0000-0000-0000-000000000001','WF86R-1','Creator','creator@wf86rt.local',true),
 ('86100000-0001-0000-0000-000000000002','86100000-0000-0000-0000-000000000001','WF86R-2','Watcher','watcher@wf86rt.local',true),
 ('86100000-0001-0000-0000-000000000003','86100000-0000-0000-0000-000000000001','WF86R-3','Unrelated','unrelated@wf86rt.local',true),
 ('86100000-0001-0000-0000-000000000004','86100000-0000-0000-0000-000000000002','WF86R-4','Cross-Org Participant','crossorgparticipant@wf86rt.local',true);

INSERT INTO tasks (id, task_number, title, status, priority, created_by, organization_id, owning_section_id, visibility)
VALUES ('86100000-0007-0000-0000-000000000001','WF86R-T1','WF86R task','open','normal',
        '86100000-0001-0000-0000-000000000001','86100000-0000-0000-0000-000000000001','86100000-0002-0000-0000-000000000001','private');
INSERT INTO task_watchers (task_id, user_id) VALUES ('86100000-0007-0000-0000-000000000001','86100000-0001-0000-0000-000000000002');

INSERT INTO meetings (id, organization_id, created_by, title, meeting_type, status, visibility, timezone, start_at, end_at)
VALUES ('86100000-0008-0000-0000-000000000001','86100000-0000-0000-0000-000000000001','86100000-0001-0000-0000-000000000001',
        'WF86R Meeting','general','scheduled','participants','Indian/Maldives', now()+interval '1 day', now()+interval '1 day 1 hour');
INSERT INTO meeting_participants (meeting_id, user_id, participant_role, invited_by)
VALUES ('86100000-0008-0000-0000-000000000001','86100000-0001-0000-0000-000000000004','attendee','86100000-0001-0000-0000-000000000001');

\set CREATOR '{"sub":"86100000-0001-0000-0000-000000000001"}'
\set WATCHER '{"sub":"86100000-0001-0000-0000-000000000002"}'
\set UNRELATED '{"sub":"86100000-0001-0000-0000-000000000003"}'
\set CROSSORG '{"sub":"86100000-0001-0000-0000-000000000004"}'

-- ── 1: ordinary user cannot directly INSERT notification_intents
-- with a task_watchers/meeting_participants target ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'CREATOR', false);
DO $$ BEGIN
  BEGIN
    INSERT INTO notification_intents (
      outbox_event_id, organization_id, notification_type, title_template_key,
      source_module, source_record_type, source_record_id, target_type, target_task_id, target_key
    ) VALUES (
      gen_random_uuid(), '86100000-0000-0000-0000-000000000001', 'wf86r.forged.v1', 'x',
      'tasks', 'task', '86100000-0007-0000-0000-000000000001', 'task_watchers', '86100000-0007-0000-0000-000000000001', 'forged'
    );
    RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user directly INSERTed a notification_intents row';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf86r_results VALUES (1,'An ordinary authenticated user cannot directly INSERT a notification_intents row with a task_watchers (or any) target -- notification_intents remains zero-policy RLS (Phase 1.2''s own posture, unchanged)');

-- ── 2: ordinary user cannot mutate an existing intent's target
-- descriptor ──
SET ROLE service_role;
DO $$ DECLARE v_id UUID; BEGIN
  v_id := create_notification_intent(
    platform_enqueue_outbox_event('wf86r.d2.v1','tasks','task','86100000-0007-0000-0000-000000000001','86100000-0000-0000-0000-000000000001',NULL,gen_random_uuid(),NULL,NOW(),'{}'::JSONB,gen_random_uuid()),
    'wf86r.d2.v1','x','{}'::JSONB,'normal','task_watchers',NULL,NULL,NULL,NULL,NULL,'86100000-0007-0000-0000-000000000001'::UUID,NULL);
  INSERT INTO wf86r_ids VALUES ('intent2', v_id);
END $$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'CREATOR', false);
DO $$ DECLARE v_id UUID; BEGIN
  SELECT id INTO v_id FROM wf86r_ids WHERE name='intent2';
  BEGIN
    UPDATE notification_intents SET target_task_id = gen_random_uuid() WHERE id = v_id;
    -- RLS-enabled-zero-policy tables silently filter UPDATE's WHERE
    -- clause to zero rows for a non-privileged role rather than
    -- raising -- unlike INSERT (which DOES raise, scenario 1) -- so
    -- "no rows affected" is itself the denial signal here, matching
    -- the established repo convention for this exact RLS shape.
    IF FOUND THEN RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user mutated an existing intent''s target_task_id'; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
DO $$ DECLARE v_id UUID; v_task_id UUID; BEGIN
  SELECT ni.id, ni.target_task_id INTO v_id, v_task_id FROM wf86r_ids ids JOIN notification_intents ni ON ni.id = ids.id WHERE ids.name='intent2';
  IF v_task_id <> '86100000-0007-0000-0000-000000000001' THEN
    RAISE EXCEPTION 'SECURITY HOLE: target_task_id was actually changed by the denied UPDATE attempt, now %', v_task_id;
  END IF;
END $$;
INSERT INTO wf86r_results VALUES (2,'An ordinary authenticated user cannot mutate an existing intent''s target descriptor: the UPDATE affects zero rows (RLS-enabled, zero-policy table -- the WHERE clause itself matches nothing for a non-privileged role), verified by re-reading the row as service_role afterward and confirming target_task_id is unchanged');

-- ── 3: ordinary user cannot invoke the private resolvers directly ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'CREATOR', false);
DO $$ BEGIN
  BEGIN
    PERFORM intent_user_can_view_meeting('86100000-0008-0000-0000-000000000001'::UUID, '86100000-0001-0000-0000-000000000001'::UUID);
    RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user could call intent_user_can_view_meeting() directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM create_notification_intent(gen_random_uuid(),'x.v1','x','{}'::JSONB,'normal','task_watchers',NULL,NULL,NULL,NULL,NULL,'86100000-0007-0000-0000-000000000001'::UUID,NULL);
    RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user could call create_notification_intent() directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf86r_results VALUES (3,'An ordinary authenticated user cannot call intent_user_can_view_meeting() or create_notification_intent() directly -- both remain service_role-only/internal-only, identical posture to every other CAP-003 recipient-resolution primitive');

-- ── 4: ordinary user cannot invoke the worker ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'CREATOR', false);
DO $$ BEGIN
  BEGIN
    PERFORM process_platform_outbox_batch(1, 'attacker');
    RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user could invoke the worker directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf86r_results VALUES (4,'An ordinary authenticated user still cannot invoke process_platform_outbox_batch() directly -- the 13-arg create_notification_intent() signature change did not alter the worker''s own grant posture');

-- ── 5: user_notifications remain recipient-scoped end to end (the
-- watcher sees their own notification; nobody else does) ──
SET ROLE service_role;
DO $$ DECLARE v_id UUID; BEGIN PERFORM resolve_notification_intent((SELECT id FROM wf86r_ids WHERE name='intent2')); END $$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'WATCHER', false);
DO $$ DECLARE v_count INTEGER; BEGIN
  SELECT count(*) INTO v_count FROM list_my_notifications(50, NULL) WHERE notification_type = 'wf86r.d2.v1';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected the watcher to see exactly 1 notification via list_my_notifications(), got %', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf86r_results VALUES (5,'The task_watchers-targeted notification is visible to the watcher via their own list_my_notifications() -- Phase 1.1''s existing recipient-scoped RLS on user_notifications is completely unaffected');

-- ── 6: an unrelated user cannot see it ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'UNRELATED', false);
DO $$ DECLARE v_count INTEGER; BEGIN
  SELECT count(*) INTO v_count FROM list_my_notifications(50, NULL) WHERE notification_type = 'wf86r.d2.v1';
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: an unrelated user saw the watcher''s notification, count=%', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf86r_results VALUES (6,'An unrelated authenticated user (same org, no watcher/participant relationship) sees zero rows for the task_watchers-targeted notification via their own list_my_notifications()');

-- ── 7: Task visibility is not broadened -- the unrelated user still
-- cannot see the underlying private task itself via can_view_task() ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'UNRELATED', false);
DO $$ DECLARE v_count INTEGER; BEGIN
  SELECT count(*) INTO v_count FROM tasks WHERE id = '86100000-0007-0000-0000-000000000001';
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: Task RLS was broadened -- an unrelated user could see the private task directly'; END IF;
END $$;
RESET ROLE;
INSERT INTO wf86r_results VALUES (7,'tasks'' own RLS (can_view_task()) is completely unaffected by this milestone -- an unrelated user still cannot SELECT the private task directly, exactly as before');

-- ── 8: Meeting visibility is not broadened ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'UNRELATED', false);
DO $$ DECLARE v_count INTEGER; BEGIN
  SELECT count(*) INTO v_count FROM meetings WHERE id = '86100000-0008-0000-0000-000000000001';
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: Meeting RLS was broadened -- an unrelated user could see the meeting directly'; END IF;
END $$;
RESET ROLE;
INSERT INTO wf86r_results VALUES (8,'meetings'' own RLS (can_view_meeting()) is completely unaffected by this milestone -- an unrelated user still cannot SELECT the meeting directly');

-- ── 9: a cross-org participant receives a notification ONLY because
-- they are a legitimate participant (meetings are explicitly cross-org
-- capable) -- proven end to end as an ordinary authenticated user ──
SET ROLE service_role;
DO $$ DECLARE v_event_id UUID; v_intent_id UUID; BEGIN
  v_event_id := platform_enqueue_outbox_event('wf86r.d9.v1','meetings','meeting','86100000-0008-0000-0000-000000000001','86100000-0000-0000-0000-000000000001',NULL,gen_random_uuid(),NULL,NOW(),'{}'::JSONB,gen_random_uuid());
  v_intent_id := create_notification_intent(v_event_id,'wf86r.d9.v1','x','{}'::JSONB,'normal','meeting_participants',NULL,NULL,NULL,NULL,NULL,NULL,'86100000-0008-0000-0000-000000000001'::UUID);
  PERFORM resolve_notification_intent(v_intent_id);
END $$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'CROSSORG', false);
DO $$ DECLARE v_count INTEGER; BEGIN
  SELECT count(*) INTO v_count FROM list_my_notifications(50, NULL) WHERE notification_type = 'wf86r.d9.v1';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected the legitimate cross-org participant to receive the notification, got %', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf86r_results VALUES (9,'A cross-organization user (Org B) who is a genuine, currently-active meeting participant of an Org A meeting DOES receive the notification -- meetings are explicitly cross-org capable in this data model, and CAP-003 does not weaken that by imposing a same-org requirement it was never given');

-- ── 10: anonymous access denied throughout ──
SELECT set_config('request.jwt.claims', NULL, false);
SET ROLE anon;
DO $$ BEGIN
  BEGIN
    PERFORM process_platform_outbox_batch(1, 'anon-attacker');
    RAISE EXCEPTION 'SECURITY HOLE: anon could invoke the worker';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  DECLARE v_count INTEGER; BEGIN
    -- RLS-enabled-zero-policy tables filter SELECT to zero rows for a
    -- non-privileged role rather than raising -- "count=0" IS the
    -- denial signal here (the query itself succeeds; anon simply
    -- cannot see the table has ANY rows), matching scenario 2's own
    -- UPDATE-affects-zero-rows convention.
    SELECT count(*) INTO v_count FROM notification_intents;
    IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: anon read % notification_intents rows', v_count; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf86r_results VALUES (10,'Anonymous (anon role, no JWT claims) access is denied throughout: cannot invoke the worker, cannot read notification_intents -- identical posture to every prior CAP-003 phase');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf86r_results;
  IF v_count <> 10 THEN
    RAISE EXCEPTION 'Expected 10 scenarios to record a result, found %', v_count;
  END IF;
  RAISE NOTICE 'Notification target expansion RLS tests PASSED: %/10', v_count;
END $$;

ROLLBACK;
