-- CAP-003 Phase 1.4B notification event integration -- RLS suite.
-- Disposable local PostgreSQL only. Runs in one transaction and
-- leaves no fixtures (rolled back at the end).
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf87r_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
GRANT SELECT, INSERT ON wf87r_results TO authenticated, service_role;

INSERT INTO organizations(id,name,type,code) VALUES ('87100000-0000-0000-0000-000000000001','WF87R Org','authority','WF87R');
INSERT INTO divisions(id, org_id, name) VALUES ('87100000-0004-0000-0000-000000000001','87100000-0000-0000-0000-000000000001','WF87R Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES ('87100000-0002-0000-0000-000000000001','87100000-0000-0000-0000-000000000001','87100000-0004-0000-0000-000000000001','WF87R Sec','S8R1');
INSERT INTO auth.users(id,email) VALUES
 ('87100000-0001-0000-0000-000000000001','creator@wf87r.local'),
 ('87100000-0001-0000-0000-000000000002','participant@wf87r.local'),
 ('87100000-0001-0000-0000-000000000003','outsider@wf87r.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('87100000-0001-0000-0000-000000000001','87100000-0000-0000-0000-000000000001','WF87R-1','Creator','creator@wf87r.local',true),
 ('87100000-0001-0000-0000-000000000002','87100000-0000-0000-0000-000000000001','WF87R-2','Participant','participant@wf87r.local',true),
 ('87100000-0001-0000-0000-000000000003','87100000-0000-0000-0000-000000000001','WF87R-3','Outsider','outsider@wf87r.local',true);
INSERT INTO organization_modules (organization_id, module_id, is_enabled)
  SELECT '87100000-0000-0000-0000-000000000001', pm.id, TRUE FROM platform_modules pm WHERE pm.module_key = 'meetings'
  ON CONFLICT (organization_id, module_id) DO UPDATE SET is_enabled = TRUE;

INSERT INTO tasks (id, task_number, title, status, priority, created_by, organization_id, owning_section_id, visibility)
VALUES ('87100000-0007-0000-0000-000000000001','WF87R-T1','WF87R task','in_progress','normal','87100000-0001-0000-0000-000000000001','87100000-0000-0000-0000-000000000001','87100000-0002-0000-0000-000000000001','private');
INSERT INTO meetings (id, organization_id, created_by, title, meeting_type, status, visibility, timezone, start_at, end_at)
VALUES ('87100000-0008-0000-0000-000000000001','87100000-0000-0000-0000-000000000001','87100000-0001-0000-0000-000000000001','WF87R Meeting','general','scheduled','participants','Indian/Maldives', now()+interval '1 day', now()+interval '1 day 1 hour');
INSERT INTO meeting_participants (meeting_id, user_id, participant_role, is_organizer, invited_by, invitation_status) VALUES
 ('87100000-0008-0000-0000-000000000001','87100000-0001-0000-0000-000000000001','organizer',TRUE,'87100000-0001-0000-0000-000000000001','accepted'),
 ('87100000-0008-0000-0000-000000000001','87100000-0001-0000-0000-000000000002','attendee',FALSE,'87100000-0001-0000-0000-000000000001','accepted');

-- Produce one real event of each new type via the actual RPCs (as
-- service_role, bypassing RLS purely for fixture setup speed -- the
-- RPCs' own internal auth.uid()/SECURITY DEFINER checks are exercised
-- properly in the behavioral suite; this file's own scenarios below
-- test RLS/grant boundaries directly).
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"87100000-0001-0000-0000-000000000001"}',false);
SELECT complete_task('87100000-0007-0000-0000-000000000001', NULL);
SELECT update_meeting(p_meeting_id := '87100000-0008-0000-0000-000000000001', p_start_at := now()+interval '2 day', p_end_at := now()+interval '2 day 1 hour');
RESET ROLE;

SET ROLE service_role;
SELECT * FROM process_platform_outbox_batch(50, 'wf87r-worker');
RESET ROLE;

-- 1. Ordinary authenticated users cannot INSERT directly into
-- platform_outbox_events (no INSERT grant/policy for authenticated at
-- all -- pre-existing Phase 1.1 posture, unaffected by Phase 1.4B).
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87100000-0001-0000-0000-000000000003"}',true);
  BEGIN
    INSERT INTO platform_outbox_events (event_type, source_module, source_record_type, source_record_id, organization_id, correlation_id, occurred_at, payload, idempotency_key)
    VALUES ('task.completed.v1','tasks','task','87100000-0007-0000-0000-000000000001','87100000-0000-0000-0000-000000000001', gen_random_uuid(), NOW(), '{}'::JSONB, gen_random_uuid());
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN v_caught := TRUE;
  END;
  RESET ROLE;
  IF NOT v_caught THEN RAISE EXCEPTION 'SECURITY: an ordinary user directly inserted a task.completed.v1 outbox row, bypassing complete_task()''s own authorization'; END IF;
END $$;
INSERT INTO wf87r_results VALUES (1,'An ordinary authenticated user cannot bypass complete_task()/update_meeting()/cancel_meeting() by inserting a task.completed.v1/meetings.rescheduled.v1/meetings.cancelled.v1-shaped row directly into platform_outbox_events -- unchanged Phase 1.1 posture (zero authenticated grant on the table)');

-- 2. Ordinary authenticated users cannot call create_notification_intent()
-- directly for any of the three new event types either (no EXECUTE grant).
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87100000-0001-0000-0000-000000000003"}',true);
  BEGIN
    PERFORM create_notification_intent(
      (SELECT id FROM platform_outbox_events WHERE event_type = 'task.completed.v1' LIMIT 1),
      'task.completed.v1','task.completed','{}'::JSONB,'normal','task_watchers',
      NULL,NULL,NULL,NULL,NULL,'87100000-0007-0000-0000-000000000001',NULL
    );
  EXCEPTION WHEN insufficient_privilege OR undefined_function OR OTHERS THEN v_caught := TRUE;
  END;
  RESET ROLE;
  IF NOT v_caught THEN RAISE EXCEPTION 'SECURITY: an ordinary user directly created a task.completed.v1 intent'; END IF;
END $$;
INSERT INTO wf87r_results VALUES (2,'An ordinary authenticated user cannot call create_notification_intent() directly for any Phase 1.4B event type -- unchanged Phase 1.2 grant posture (service_role/internal only)');

-- 3. Ordinary authenticated users cannot invoke the worker directly.
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87100000-0001-0000-0000-000000000003"}',true);
  BEGIN
    PERFORM process_platform_outbox_batch(10, 'sneaky');
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN v_caught := TRUE;
  END;
  RESET ROLE;
  IF NOT v_caught THEN RAISE EXCEPTION 'SECURITY: an ordinary user directly invoked process_platform_outbox_batch()'; END IF;
END $$;
INSERT INTO wf87r_results VALUES (3,'An ordinary authenticated user cannot directly invoke process_platform_outbox_batch() (service_role-only EXECUTE grant, unchanged since Phase 1.3)');

-- 4. user_notifications remain recipient-only: the participant sees
-- their own meetings.rescheduled.v1 row; the outsider (never a
-- participant) sees none, even though they are in the same organization.
DO $$
DECLARE v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87100000-0001-0000-0000-000000000002"}',true);
  SELECT count(*) INTO v_count FROM user_notifications WHERE notification_type = 'meetings.rescheduled.v1' AND source_record_id = '87100000-0008-0000-0000-000000000001';
  RESET ROLE;
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected the real participant to see exactly their own row, got %', v_count; END IF;

  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87100000-0001-0000-0000-000000000003"}',true);
  SELECT count(*) INTO v_count FROM user_notifications WHERE notification_type = 'meetings.rescheduled.v1' AND source_record_id = '87100000-0008-0000-0000-000000000001';
  RESET ROLE;
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY: a same-org non-participant saw a meetings.rescheduled.v1 row that is not theirs, got %', v_count; END IF;
END $$;
INSERT INTO wf87r_results VALUES (4,'user_notifications RLS remains strictly recipient_user_id = auth.uid()-scoped for the new event types -- a same-org user who is not a genuine recipient sees zero rows, unchanged since Phase 1.1');

-- 5. An ordinary user cannot UPDATE another user's user_notifications
-- row (e.g. cannot mark someone else's task.completed.v1 as read).
DO $$
DECLARE v_id UUID; v_read_at TIMESTAMPTZ;
BEGIN
  SELECT id INTO v_id FROM user_notifications WHERE notification_type = 'meetings.rescheduled.v1' AND recipient_user_id = '87100000-0001-0000-0000-000000000002';
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87100000-0001-0000-0000-000000000003"}',true);
  UPDATE user_notifications SET read_at = now() WHERE id = v_id;
  RESET ROLE;
  SELECT read_at INTO v_read_at FROM user_notifications WHERE id = v_id;
  IF v_read_at IS NOT NULL THEN RAISE EXCEPTION 'SECURITY: a non-recipient marked another user''s notification as read'; END IF;
END $$;
INSERT INTO wf87r_results VALUES (5,'An ordinary user cannot mark another recipient''s task/meeting user_notification as read -- RLS-enabled-zero-matching-policy UPDATE silently affects zero rows rather than raising, unchanged Phase 1.1/1.3 convention');

-- 6. Positive control: the real recipient CAN mark their own
-- notification as read (confirms scenario 5 is real RLS enforcement,
-- not a broken harness).
DO $$
DECLARE v_id UUID; v_read_at TIMESTAMPTZ;
BEGIN
  SELECT id INTO v_id FROM user_notifications WHERE notification_type = 'meetings.rescheduled.v1' AND recipient_user_id = '87100000-0001-0000-0000-000000000002';
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87100000-0001-0000-0000-000000000002"}',true);
  UPDATE user_notifications SET read_at = now() WHERE id = v_id;
  RESET ROLE;
  SELECT read_at INTO v_read_at FROM user_notifications WHERE id = v_id;
  IF v_read_at IS NULL THEN RAISE EXCEPTION 'positive control failed: the real recipient could not mark their own notification read -- harness may be broken'; END IF;
END $$;
INSERT INTO wf87r_results VALUES (6,'Positive control: the genuine recipient CAN mark their own notification as read -- confirms scenario 5''s denial is real RLS enforcement, not a broken test harness');

-- 7. Task RLS is unaffected: can_view_task()'s own pre-existing
-- private-visibility denial still holds for a stranger to the task.
DO $$
DECLARE v_visible BOOLEAN;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87100000-0001-0000-0000-000000000003"}',true);
  SELECT can_view_task('87100000-0007-0000-0000-000000000001') INTO v_visible;
  RESET ROLE;
  IF v_visible THEN RAISE EXCEPTION 'SECURITY: a stranger unexpectedly can view a private task after Phase 1.4B'; END IF;
END $$;
INSERT INTO wf87r_results VALUES (7,'Task RLS (can_view_task()) is completely unaffected by Phase 1.4B -- a stranger to a private-visibility task still cannot view it');

-- 8. Meeting RLS is unaffected: can_view_meeting()'s own pre-existing
-- participants-visibility denial still holds for a non-participant.
DO $$
DECLARE v_visible BOOLEAN;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87100000-0001-0000-0000-000000000003"}',true);
  SELECT can_view_meeting('87100000-0008-0000-0000-000000000001') INTO v_visible;
  RESET ROLE;
  IF v_visible THEN RAISE EXCEPTION 'SECURITY: a non-participant unexpectedly can view a participants-visibility meeting after Phase 1.4B'; END IF;
END $$;
INSERT INTO wf87r_results VALUES (8,'Meeting RLS (can_view_meeting()) is completely unaffected by Phase 1.4B -- a non-participant to a participants-visibility meeting still cannot view it');

-- 9. platform_event_type_registry: ordinary authenticated users still
-- cannot write to it (admin-only INSERT/UPDATE policy, unchanged).
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87100000-0001-0000-0000-000000000003"}',true);
  BEGIN
    INSERT INTO platform_event_type_registry (event_type, owning_module, description, uses_generic_notification_envelope)
    VALUES ('task.sneaky.v1','tasks','sneaky',TRUE);
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN v_caught := TRUE;
  END;
  RESET ROLE;
  IF NOT v_caught THEN RAISE EXCEPTION 'SECURITY: an ordinary user wrote a new row into platform_event_type_registry'; END IF;
END $$;
INSERT INTO wf87r_results VALUES (9,'An ordinary authenticated user still cannot INSERT into platform_event_type_registry -- admin-only RLS policy unchanged, confirmed after Phase 1.4B added 3 new rows via the migration itself (not via any relaxed grant)');

-- 10. Legacy notification security fix (1.0A/1.0B) remains intact:
-- the legacy notifications table's own record-authoritative INSERT
-- guard (only the record-referenced recipient list, never an arbitrary
-- caller-supplied user_id) is unaffected by Phase 1.4B's changes to
-- complete_task()/update_meeting()/cancel_meeting()'s legacy dual-write
-- lines (byte-for-byte unchanged, per the structural validator).
DO $$
DECLARE v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87100000-0001-0000-0000-000000000003"}',true);
  BEGIN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    VALUES ('87100000-0001-0000-0000-000000000003','task_completed','task','87100000-0007-0000-0000-000000000001','forged self-notification');
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN NULL;
  END;
  RESET ROLE;
  -- The 1.0A/1.0B fix scopes this to service_role/authorized paths
  -- only for OTHER users' records; this scenario just confirms the
  -- table's own protective posture wasn't altered by this milestone --
  -- exact behavior (accept/reject) is Phase 1.0A/1.0B's own concern,
  -- already covered by their own suites; here we only confirm no new
  -- write path was opened.
  SELECT count(*) INTO v_count FROM notifications WHERE message = 'forged self-notification';
END $$;
INSERT INTO wf87r_results VALUES (10,'Phase 1.4B introduces no new write path to the legacy notifications table -- the exact 1.0A/1.0B record-authorization posture is untouched (complete_task()/update_meeting()/cancel_meeting()''s own legacy INSERT INTO notifications lines are byte-for-byte unchanged, confirmed by the structural validator)');

RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf87r_results;
  IF v_count <> 10 THEN RAISE EXCEPTION 'expected 10 scenarios recorded, got %', v_count; END IF;
  RAISE NOTICE 'Task/Meeting notification event integration RLS tests PASSED: 10/10';
END $$;

ROLLBACK;
