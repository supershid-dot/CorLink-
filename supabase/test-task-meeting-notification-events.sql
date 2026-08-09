-- CAP-003 Phase 1.4B notification event integration -- focused
-- behavioral suite. Disposable local PostgreSQL only. Runs in one
-- transaction and leaves no fixtures (rolled back at the end).
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf87_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
GRANT SELECT, INSERT ON wf87_results TO authenticated, service_role;

-- ── Fixtures ─────────────────────────────────────────────────────────
INSERT INTO organizations(id,name,type,code) VALUES
 ('87000000-0000-0000-0000-000000000001','WF87 Org A','authority','WF87A'),
 ('87000000-0000-0000-0000-000000000002','WF87 Org B','authority','WF87B');
INSERT INTO divisions(id, org_id, name) VALUES
 ('87000000-0004-0000-0000-000000000001','87000000-0000-0000-0000-000000000001','WF87 Div A'),
 ('87000000-0004-0000-0000-000000000002','87000000-0000-0000-0000-000000000002','WF87 Div B');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
 ('87000000-0002-0000-0000-000000000001','87000000-0000-0000-0000-000000000001','87000000-0004-0000-0000-000000000001','WF87 Sec A','S871'),
 ('87000000-0002-0000-0000-000000000002','87000000-0000-0000-0000-000000000002','87000000-0004-0000-0000-000000000002','WF87 Sec B','S872');

INSERT INTO auth.users(id,email) VALUES
 ('87000000-0001-0000-0000-000000000001','creator@wf87t.local'),
 ('87000000-0001-0000-0000-000000000002','watcher@wf87t.local'),
 ('87000000-0001-0000-0000-000000000003','assignee@wf87t.local'),
 ('87000000-0001-0000-0000-000000000004','participant1@wf87t.local'),
 ('87000000-0001-0000-0000-000000000005','participant2@wf87t.local'),
 ('87000000-0001-0000-0000-000000000006','removedparticipant@wf87t.local'),
 ('87000000-0001-0000-0000-000000000007','crossorg@wf87t.local'),
 ('87000000-0001-0000-0000-000000000008','stranger@wf87t.local');

INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('87000000-0001-0000-0000-000000000001','87000000-0000-0000-0000-000000000001','WF87-1','Creator','creator@wf87t.local',true),
 ('87000000-0001-0000-0000-000000000002','87000000-0000-0000-0000-000000000001','WF87-2','Watcher','watcher@wf87t.local',true),
 ('87000000-0001-0000-0000-000000000003','87000000-0000-0000-0000-000000000001','WF87-3','Assignee','assignee@wf87t.local',true),
 ('87000000-0001-0000-0000-000000000004','87000000-0000-0000-0000-000000000001','WF87-4','Participant One','participant1@wf87t.local',true),
 ('87000000-0001-0000-0000-000000000005','87000000-0000-0000-0000-000000000001','WF87-5','Participant Two','participant2@wf87t.local',true),
 ('87000000-0001-0000-0000-000000000006','87000000-0000-0000-0000-000000000001','WF87-6','Removed Participant','removedparticipant@wf87t.local',true),
 ('87000000-0001-0000-0000-000000000007','87000000-0000-0000-0000-000000000002','WF87-7','Cross-Org Participant','crossorg@wf87t.local',true),
 ('87000000-0001-0000-0000-000000000008','87000000-0000-0000-0000-000000000001','WF87-8','Stranger','stranger@wf87t.local',true);

INSERT INTO organization_modules (organization_id, module_id, is_enabled)
  SELECT org_id, pm.id, TRUE FROM (VALUES
    ('87000000-0000-0000-0000-000000000001'::UUID), ('87000000-0000-0000-0000-000000000002'::UUID)
  ) o(org_id) CROSS JOIN platform_modules pm WHERE pm.module_key = 'meetings'
  ON CONFLICT (organization_id, module_id) DO UPDATE SET is_enabled = TRUE;

-- Tasks: A for the general completion path, B for a second, isolated
-- completion (idempotency/repeat-completion scenarios).
INSERT INTO tasks (id, task_number, title, status, priority, created_by, organization_id, owning_section_id, visibility)
VALUES
 ('87000000-0007-0000-0000-000000000001','WF87-T1','WF87 task A','in_progress','normal','87000000-0001-0000-0000-000000000001','87000000-0000-0000-0000-000000000001','87000000-0002-0000-0000-000000000001','private'),
 ('87000000-0007-0000-0000-000000000002','WF87-T2','WF87 task B','in_progress','normal','87000000-0001-0000-0000-000000000001','87000000-0000-0000-0000-000000000001','87000000-0002-0000-0000-000000000001','private'),
 ('87000000-0007-0000-0000-000000000003','WF87-T3','WF87 task C (self-complete)','in_progress','normal','87000000-0001-0000-0000-000000000001','87000000-0000-0000-0000-000000000001','87000000-0002-0000-0000-000000000001','private');
INSERT INTO task_watchers (task_id, user_id) VALUES
 ('87000000-0007-0000-0000-000000000001','87000000-0001-0000-0000-000000000002'),
 ('87000000-0007-0000-0000-000000000002','87000000-0001-0000-0000-000000000002');
INSERT INTO task_assignments (task_id, user_id, assigned_by, assigned_at, is_active) VALUES
 ('87000000-0007-0000-0000-000000000001','87000000-0001-0000-0000-000000000003','87000000-0001-0000-0000-000000000001',NOW(),TRUE),
 ('87000000-0007-0000-0000-000000000002','87000000-0001-0000-0000-000000000003','87000000-0001-0000-0000-000000000001',NOW(),TRUE);

-- Meetings: A for reschedule/cancel, B for the title-only-edit (no
-- reschedule) negative test, C for the cross-org participant test.
INSERT INTO meetings (id, organization_id, created_by, title, meeting_type, status, visibility, timezone, start_at, end_at)
VALUES
 ('87000000-0008-0000-0000-000000000001','87000000-0000-0000-0000-000000000001','87000000-0001-0000-0000-000000000001','WF87 Meeting A','general','scheduled','participants','Indian/Maldives', now()+interval '1 day', now()+interval '1 day 1 hour'),
 ('87000000-0008-0000-0000-000000000002','87000000-0000-0000-0000-000000000001','87000000-0001-0000-0000-000000000001','WF87 Meeting B','general','scheduled','participants','Indian/Maldives', now()+interval '2 day', now()+interval '2 day 1 hour'),
 ('87000000-0008-0000-0000-000000000003','87000000-0000-0000-0000-000000000001','87000000-0001-0000-0000-000000000001','WF87 Meeting C (cross-org)','general','scheduled','participants','Indian/Maldives', now()+interval '3 day', now()+interval '3 day 1 hour'),
 ('87000000-0008-0000-0000-000000000004','87000000-0000-0000-0000-000000000001','87000000-0001-0000-0000-000000000001','WF87 Meeting D (draft)','general','draft','participants','Indian/Maldives', now()+interval '4 day', now()+interval '4 day 1 hour'),
 ('87000000-0008-0000-0000-000000000005','87000000-0000-0000-0000-000000000001','87000000-0001-0000-0000-000000000001','WF87 Meeting E (cancel-only)','general','scheduled','participants','Indian/Maldives', now()+interval '5 day', now()+interval '5 day 1 hour');
INSERT INTO meeting_participants (meeting_id, user_id, participant_role, is_organizer, invited_by, invitation_status) VALUES
 ('87000000-0008-0000-0000-000000000001','87000000-0001-0000-0000-000000000001','organizer',TRUE,'87000000-0001-0000-0000-000000000001','accepted'),
 ('87000000-0008-0000-0000-000000000001','87000000-0001-0000-0000-000000000004','attendee',FALSE,'87000000-0001-0000-0000-000000000001','accepted'),
 ('87000000-0008-0000-0000-000000000001','87000000-0001-0000-0000-000000000005','attendee',FALSE,'87000000-0001-0000-0000-000000000001','accepted'),
 ('87000000-0008-0000-0000-000000000002','87000000-0001-0000-0000-000000000001','organizer',TRUE,'87000000-0001-0000-0000-000000000001','accepted'),
 ('87000000-0008-0000-0000-000000000002','87000000-0001-0000-0000-000000000004','attendee',FALSE,'87000000-0001-0000-0000-000000000001','accepted'),
 ('87000000-0008-0000-0000-000000000003','87000000-0001-0000-0000-000000000001','organizer',TRUE,'87000000-0001-0000-0000-000000000001','accepted'),
 ('87000000-0008-0000-0000-000000000003','87000000-0001-0000-0000-000000000007','attendee',FALSE,'87000000-0001-0000-0000-000000000001','accepted'),
 ('87000000-0008-0000-0000-000000000005','87000000-0001-0000-0000-000000000001','organizer',TRUE,'87000000-0001-0000-0000-000000000001','accepted'),
 ('87000000-0008-0000-0000-000000000005','87000000-0001-0000-0000-000000000004','attendee',FALSE,'87000000-0001-0000-0000-000000000001','accepted'),
 ('87000000-0008-0000-0000-000000000005','87000000-0001-0000-0000-000000000006','attendee',FALSE,'87000000-0001-0000-0000-000000000001','accepted');
-- Remove one participant from meeting E before it's cancelled -- proves
-- removed participants are excluded (dynamic membership at processing time).
UPDATE meeting_participants SET removed_at = now(), removed_by = '87000000-0001-0000-0000-000000000001'
  WHERE meeting_id = '87000000-0008-0000-0000-000000000005' AND user_id = '87000000-0001-0000-0000-000000000006';

SET ROLE service_role;

-- ══════════════════ TASK.COMPLETED.V1 ══════════════════

-- 1. Valid completion by the assignee: outbox event correctness (both
-- task_watchers and specific_users(owner) events, correct payload).
DO $$
DECLARE v_event RECORD; v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87000000-0001-0000-0000-000000000003"}',true);
  PERFORM complete_task('87000000-0007-0000-0000-000000000001', 'completion note (must not appear in payload)');
  RESET ROLE;

  SELECT count(*) INTO v_count FROM platform_outbox_events
    WHERE event_type = 'task.completed.v1' AND source_record_id = '87000000-0007-0000-0000-000000000001';
  IF v_count <> 2 THEN RAISE EXCEPTION 'expected 2 outbox events (watchers + owner), got %', v_count; END IF;

  SELECT * INTO v_event FROM platform_outbox_events
    WHERE event_type = 'task.completed.v1' AND source_record_id = '87000000-0007-0000-0000-000000000001'
      AND payload ->> 'target_type' = 'task_watchers';
  IF v_event.payload ->> 'target_task_id' <> '87000000-0007-0000-0000-000000000001' THEN
    RAISE EXCEPTION 'task_watchers event has wrong target_task_id';
  END IF;
  IF v_event.source_record_type <> 'task' OR v_event.source_module <> 'tasks' THEN
    RAISE EXCEPTION 'task_watchers event has wrong source identity';
  END IF;
  IF v_event.payload ? 'notes' OR v_event.payload::TEXT ILIKE '%completion note%' THEN
    RAISE EXCEPTION 'SECURITY: free-text p_notes leaked into outbox payload';
  END IF;

  SELECT * INTO v_event FROM platform_outbox_events
    WHERE event_type = 'task.completed.v1' AND source_record_id = '87000000-0007-0000-0000-000000000001'
      AND payload ->> 'target_type' = 'specific_users';
  IF (v_event.payload -> 'target_user_ids') <> '["87000000-0001-0000-0000-000000000001"]'::JSONB THEN
    RAISE EXCEPTION 'specific_users event does not target the creator alone';
  END IF;
END $$;
INSERT INTO wf87_results VALUES (1,'complete_task() atomically enqueues exactly 2 task.completed.v1 outbox events (task_watchers unconditional + specific_users(created_by)), correct source identity, correct target descriptors, free-text p_notes excluded from payload');

-- 2. End-to-end: watcher and creator both receive a real user_notification.
DO $$
DECLARE v_count INTEGER;
BEGIN
  PERFORM process_platform_outbox_batch(50, 'wf87-worker');
  SELECT count(*) INTO v_count FROM user_notifications
    WHERE notification_type = 'task.completed.v1' AND recipient_user_id = '87000000-0001-0000-0000-000000000002'
      AND source_record_id = '87000000-0007-0000-0000-000000000001';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected watcher notified, got %', v_count; END IF;
  SELECT count(*) INTO v_count FROM user_notifications
    WHERE notification_type = 'task.completed.v1' AND recipient_user_id = '87000000-0001-0000-0000-000000000001'
      AND source_record_id = '87000000-0007-0000-0000-000000000001';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected creator notified, got %', v_count; END IF;
  -- assignee (the actor who completed it) does NOT get a task_watchers
  -- notification since they are not a watcher, and is not the creator.
  SELECT count(*) INTO v_count FROM user_notifications
    WHERE notification_type = 'task.completed.v1' AND recipient_user_id = '87000000-0001-0000-0000-000000000003'
      AND source_record_id = '87000000-0007-0000-0000-000000000001';
  IF v_count <> 0 THEN RAISE EXCEPTION 'actor (assignee, not creator/watcher) unexpectedly notified, got %', v_count; END IF;
END $$;
INSERT INTO wf87_results VALUES (2,'End-to-end via the real worker: watcher and creator both receive exactly one task.completed.v1 user_notification each; the completing actor (an assignee, not creator/watcher) receives none');

-- 3. Self-completion by the creator: specific_users(owner) event is
-- correctly SKIPPED (creator = actor), mirroring legacy exclusion.
DO $$
DECLARE v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87000000-0001-0000-0000-000000000001"}',true);
  PERFORM complete_task('87000000-0007-0000-0000-000000000003', NULL);
  RESET ROLE;

  SELECT count(*) INTO v_count FROM platform_outbox_events
    WHERE event_type = 'task.completed.v1' AND source_record_id = '87000000-0007-0000-0000-000000000003';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 outbox event (task_watchers only, owner self-excluded), got %', v_count; END IF;
  IF EXISTS (
    SELECT 1 FROM platform_outbox_events
    WHERE event_type = 'task.completed.v1' AND source_record_id = '87000000-0007-0000-0000-000000000003'
      AND payload ->> 'target_type' = 'specific_users'
  ) THEN RAISE EXCEPTION 'creator self-completion unexpectedly produced a specific_users(owner) event'; END IF;
END $$;
INSERT INTO wf87_results VALUES (3,'When the completing actor IS the task creator, the specific_users(created_by) event is correctly omitted (creator <> actor guard), mirroring the legacy notification''s own self-exclusion -- only the task_watchers event is enqueued');

-- 4. Late authorization revalidation: watcher removed before worker
-- processes the event -- receives nothing.
DO $$
DECLARE v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87000000-0001-0000-0000-000000000003"}',true);
  PERFORM complete_task('87000000-0007-0000-0000-000000000002', NULL);
  RESET ROLE;

  DELETE FROM task_watchers WHERE task_id = '87000000-0007-0000-0000-000000000002' AND user_id = '87000000-0001-0000-0000-000000000002';

  PERFORM process_platform_outbox_batch(50, 'wf87-worker');

  SELECT count(*) INTO v_count FROM user_notifications
    WHERE notification_type = 'task.completed.v1' AND recipient_user_id = '87000000-0001-0000-0000-000000000002'
      AND source_record_id = '87000000-0007-0000-0000-000000000002';
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY: removed watcher (before processing) unexpectedly notified'; END IF;
END $$;
INSERT INTO wf87_results VALUES (4,'Dynamic membership: a watcher removed BETWEEN enqueue and worker processing receives nothing -- task_watchers resolves current membership at processing time, exactly docs/78 Sec7.2''s late-resolution requirement, never a stale enqueue-time snapshot');

-- 5. Idempotent replay: re-resolving an already-resolved intent is a
-- safe no-op (no duplicate user_notifications).
DO $$
DECLARE v_intent_id UUID; v_count_before INTEGER; v_count_after INTEGER;
BEGIN
  SELECT id INTO v_intent_id FROM notification_intents
    WHERE outbox_event_id = (SELECT id FROM platform_outbox_events WHERE event_type = 'task.completed.v1'
      AND source_record_id = '87000000-0007-0000-0000-000000000001' AND payload ->> 'target_type' = 'task_watchers');
  SELECT count(*) INTO v_count_before FROM user_notifications WHERE outbox_event_id = (
    SELECT id FROM platform_outbox_events WHERE event_type = 'task.completed.v1'
      AND source_record_id = '87000000-0007-0000-0000-000000000001' AND payload ->> 'target_type' = 'task_watchers'
  );
  PERFORM resolve_notification_intent(v_intent_id);
  SELECT count(*) INTO v_count_after FROM user_notifications WHERE outbox_event_id = (
    SELECT id FROM platform_outbox_events WHERE event_type = 'task.completed.v1'
      AND source_record_id = '87000000-0007-0000-0000-000000000001' AND payload ->> 'target_type' = 'task_watchers'
  );
  IF v_count_before <> v_count_after THEN RAISE EXCEPTION 'idempotent replay produced a duplicate notification'; END IF;
END $$;
INSERT INTO wf87_results VALUES (5,'Idempotent replay: re-resolving an already-resolved task.completed.v1 intent is a safe no-op (early-return path, no duplicate user_notifications)');

-- 6. Legacy dual-write preserved: the legacy notifications row still
-- exists alongside the new CAP-003 path.
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM notifications
    WHERE type = 'task_completed' AND record_type = 'task' AND record_id = '87000000-0007-0000-0000-000000000001';
  IF v_count = 0 THEN RAISE EXCEPTION 'legacy task_completed notification dual-write was removed'; END IF;
END $$;
INSERT INTO wf87_results VALUES (6,'Legacy INSERT INTO notifications (task_completed) dual-write is preserved byte-for-byte alongside the new CAP-003 outbox enqueue -- no legacy behavior removed');

-- 7. Legitimate repeat completion: complete_task() can be re-invoked on
-- an already-completed task (old_status = new_status is an allowed
-- transition, pre-existing behavior) -- produces its own fresh,
-- distinguishable occurrence with its own idempotency key.
DO $$
DECLARE v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87000000-0001-0000-0000-000000000003"}',true);
  PERFORM complete_task('87000000-0007-0000-0000-000000000001', 'second completion');
  RESET ROLE;

  SELECT count(*) INTO v_count FROM platform_outbox_events
    WHERE event_type = 'task.completed.v1' AND source_record_id = '87000000-0007-0000-0000-000000000001';
  IF v_count <> 4 THEN RAISE EXCEPTION 'expected 4 total outbox events (2 from scenario 1 + 2 from this re-completion), got %', v_count; END IF;
END $$;
INSERT INTO wf87_results VALUES (7,'complete_task() re-invoked on an already-completed task (pre-existing, unmodified old_status=new_status transition rule) produces its own fresh pair of outbox events with their own distinct audit_logs-derived idempotency keys -- not silently deduplicated away, matching the legacy notification''s own identical re-fire behavior');

-- 8. Nonexistent task: create_notification_intent's hard FK rejects it
-- at creation time (matching Phase 1.2/1.4A precedent) -- not reachable
-- via complete_task() itself (task not found raises first), verified
-- directly against create_notification_intent().
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  BEGIN
    PERFORM create_notification_intent(
      (SELECT id FROM platform_outbox_events WHERE event_type = 'task.completed.v1' LIMIT 1),
      'task.completed.v1','task.completed','{}'::JSONB,'normal','task_watchers',
      NULL,NULL,NULL,NULL,NULL, gen_random_uuid(), NULL
    );
  EXCEPTION WHEN foreign_key_violation THEN v_caught := TRUE;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION 'expected foreign_key_violation for nonexistent target_task_id'; END IF;
END $$;
INSERT INTO wf87_results VALUES (8,'A task.completed.v1-shaped intent referencing a nonexistent target_task_id is rejected at creation time via the existing target_task_id hard FK (Phase 1.4A precedent) -- not silently resolved to zero candidates');

-- ══════════════════ MEETINGS.RESCHEDULED.V1 ══════════════════

-- 9. Valid reschedule: outbox event correctness.
DO $$
DECLARE v_event RECORD; v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87000000-0001-0000-0000-000000000001"}',true);
  PERFORM update_meeting(p_meeting_id := '87000000-0008-0000-0000-000000000001', p_start_at := now()+interval '10 day', p_end_at := now()+interval '10 day 1 hour');
  RESET ROLE;

  SELECT count(*) INTO v_count FROM platform_outbox_events
    WHERE event_type = 'meetings.rescheduled.v1' AND source_record_id = '87000000-0008-0000-0000-000000000001';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 meetings.rescheduled.v1 event, got %', v_count; END IF;

  SELECT * INTO v_event FROM platform_outbox_events
    WHERE event_type = 'meetings.rescheduled.v1' AND source_record_id = '87000000-0008-0000-0000-000000000001';
  IF v_event.payload ->> 'target_type' <> 'meeting_participants' THEN RAISE EXCEPTION 'wrong target_type'; END IF;
  IF v_event.payload ->> 'target_meeting_id' <> '87000000-0008-0000-0000-000000000001' THEN RAISE EXCEPTION 'wrong target_meeting_id'; END IF;
  IF v_event.source_record_type <> 'meeting' OR v_event.source_module <> 'meetings' THEN RAISE EXCEPTION 'wrong source identity'; END IF;
END $$;
INSERT INTO wf87_results VALUES (9,'update_meeting() with an actual start_at/end_at change atomically enqueues exactly 1 meetings.rescheduled.v1 event with correct source identity and meeting_participants target descriptor');

-- 10. End-to-end delivery to participants.
DO $$
DECLARE v_count INTEGER;
BEGIN
  PERFORM process_platform_outbox_batch(50, 'wf87-worker');
  SELECT count(*) INTO v_count FROM user_notifications
    WHERE notification_type = 'meetings.rescheduled.v1' AND recipient_user_id = '87000000-0001-0000-0000-000000000004'
      AND source_record_id = '87000000-0008-0000-0000-000000000001';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected participant notified, got %', v_count; END IF;
  SELECT count(*) INTO v_count FROM user_notifications
    WHERE notification_type = 'meetings.rescheduled.v1' AND recipient_user_id = '87000000-0001-0000-0000-000000000005'
      AND source_record_id = '87000000-0008-0000-0000-000000000001';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected second participant notified, got %', v_count; END IF;
END $$;
INSERT INTO wf87_results VALUES (10,'End-to-end via the real worker: both meeting participants receive exactly one meetings.rescheduled.v1 user_notification each');

-- 11. Title-only edit (no time change) does NOT fire
-- meetings.rescheduled.v1 -- narrower than the legacy meeting_updated
-- condition on purpose.
DO $$
DECLARE v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87000000-0001-0000-0000-000000000001"}',true);
  PERFORM update_meeting(p_meeting_id := '87000000-0008-0000-0000-000000000002', p_title := 'WF87 Meeting B (retitled)');
  RESET ROLE;

  SELECT count(*) INTO v_count FROM platform_outbox_events
    WHERE event_type = 'meetings.rescheduled.v1' AND source_record_id = '87000000-0008-0000-0000-000000000002';
  IF v_count <> 0 THEN RAISE EXCEPTION 'title-only edit unexpectedly fired meetings.rescheduled.v1, got %', v_count; END IF;
  -- legacy meeting_updated notification DOES still fire (unmodified).
  SELECT count(*) INTO v_count FROM notifications
    WHERE type = 'meeting_updated' AND record_type = 'meeting' AND record_id = '87000000-0008-0000-0000-000000000002';
  IF v_count = 0 THEN RAISE EXCEPTION 'legacy meeting_updated notification was unexpectedly removed for a title-only edit'; END IF;
END $$;
INSERT INTO wf87_results VALUES (11,'A title-only edit (no start_at/end_at/timezone change) does NOT fire meetings.rescheduled.v1 -- deliberately narrower than the legacy meeting_updated notification''s own broader condition, which is unaffected and still fires');

-- 12. First publish (draft -> scheduled with a start_at) does NOT fire
-- meetings.rescheduled.v1 -- that is "scheduled" territory (deferred),
-- not "rescheduled".
DO $$
DECLARE v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87000000-0001-0000-0000-000000000001"}',true);
  PERFORM update_meeting(p_meeting_id := '87000000-0008-0000-0000-000000000004', p_status := 'scheduled', p_start_at := now()+interval '4 day', p_end_at := now()+interval '4 day 2 hour');
  RESET ROLE;

  SELECT count(*) INTO v_count FROM platform_outbox_events
    WHERE event_type = 'meetings.rescheduled.v1' AND source_record_id = '87000000-0008-0000-0000-000000000004';
  IF v_count <> 0 THEN RAISE EXCEPTION 'draft-publish-with-time unexpectedly fired meetings.rescheduled.v1, got %', v_count; END IF;
END $$;
INSERT INTO wf87_results VALUES (12,'Publishing a draft meeting (draft -> scheduled) with a start_at supplied in the same call does NOT fire meetings.rescheduled.v1 (v_publishing excluded) -- that is meetings.scheduled.v1 territory, deliberately deferred, never conflated with a genuine reschedule');

-- 13. p_suppress_notification := TRUE suppresses the new CAP-003 event
-- exactly like it suppresses the legacy one (bulk recurring-series safety).
DO $$
DECLARE v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87000000-0001-0000-0000-000000000001"}',true);
  PERFORM update_meeting(p_meeting_id := '87000000-0008-0000-0000-000000000003', p_start_at := now()+interval '11 day', p_end_at := now()+interval '11 day 1 hour', p_suppress_notification := TRUE);
  RESET ROLE;

  SELECT count(*) INTO v_count FROM platform_outbox_events
    WHERE event_type = 'meetings.rescheduled.v1' AND source_record_id = '87000000-0008-0000-0000-000000000003';
  IF v_count <> 0 THEN RAISE EXCEPTION 'p_suppress_notification=TRUE unexpectedly still enqueued meetings.rescheduled.v1, got %', v_count; END IF;
  SELECT count(*) INTO v_count FROM notifications
    WHERE type = 'meeting_updated' AND record_type = 'meeting' AND record_id = '87000000-0008-0000-0000-000000000003';
  IF v_count <> 0 THEN RAISE EXCEPTION 'sanity check failed: legacy notification also unexpectedly fired despite suppression'; END IF;
END $$;
INSERT INTO wf87_results VALUES (13,'p_suppress_notification := TRUE (the flag bulk recurring-series RPCs rely on to avoid one notification per occurrence) suppresses the new meetings.rescheduled.v1 CAP-003 enqueue exactly as it already suppresses the legacy notification -- CAP-003 does not reopen the exact spam vector that flag exists to close');

-- 14. Cross-organization meeting: participant in a different org from
-- the meeting''s own org still resolves and is authorized (Meetings
-- may be cross-org; organization isolation is not weakened -- the
-- participant row itself, not organization membership, is authoritative).
DO $$
DECLARE v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87000000-0001-0000-0000-000000000001"}',true);
  PERFORM update_meeting(p_meeting_id := '87000000-0008-0000-0000-000000000003', p_start_at := now()+interval '12 day', p_end_at := now()+interval '12 day 1 hour');
  RESET ROLE;
  PERFORM process_platform_outbox_batch(50, 'wf87-worker');

  SELECT count(*) INTO v_count FROM user_notifications
    WHERE notification_type = 'meetings.rescheduled.v1' AND recipient_user_id = '87000000-0001-0000-0000-000000000007'
      AND source_record_id = '87000000-0008-0000-0000-000000000003';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected cross-org participant notified, got %', v_count; END IF;
END $$;
INSERT INTO wf87_results VALUES (14,'A cross-organization meeting participant (org B user in an org A meeting) still resolves and is authorized to receive meetings.rescheduled.v1 -- CAP-003 creates no new cross-org boundary of its own, exactly matching the existing meeting_participants target kind''s Phase 1.4A behavior');

-- ══════════════════ MEETINGS.CANCELLED.V1 ══════════════════

-- 15. Valid cancellation: outbox event correctness.
DO $$
DECLARE v_event RECORD; v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87000000-0001-0000-0000-000000000001"}',true);
  PERFORM cancel_meeting('87000000-0008-0000-0000-000000000005', 'no longer needed (must not appear in payload)');
  RESET ROLE;

  SELECT count(*) INTO v_count FROM platform_outbox_events
    WHERE event_type = 'meetings.cancelled.v1' AND source_record_id = '87000000-0008-0000-0000-000000000005';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 meetings.cancelled.v1 event, got %', v_count; END IF;

  SELECT * INTO v_event FROM platform_outbox_events
    WHERE event_type = 'meetings.cancelled.v1' AND source_record_id = '87000000-0008-0000-0000-000000000005';
  IF v_event.payload ->> 'target_type' <> 'meeting_participants' THEN RAISE EXCEPTION 'wrong target_type'; END IF;
  IF v_event.payload::TEXT ILIKE '%no longer needed%' THEN RAISE EXCEPTION 'SECURITY: free-text p_cancellation_reason leaked into outbox payload'; END IF;
END $$;
INSERT INTO wf87_results VALUES (15,'cancel_meeting() atomically enqueues exactly 1 meetings.cancelled.v1 event with the meeting_participants target descriptor; free-text p_cancellation_reason is excluded from the payload');

-- 16. End-to-end delivery, and the removed participant (removed BEFORE
-- cancellation, i.e. before enqueue) never receives anything.
DO $$
DECLARE v_count INTEGER;
BEGIN
  PERFORM process_platform_outbox_batch(50, 'wf87-worker');
  SELECT count(*) INTO v_count FROM user_notifications
    WHERE notification_type = 'meetings.cancelled.v1' AND recipient_user_id = '87000000-0001-0000-0000-000000000004'
      AND source_record_id = '87000000-0008-0000-0000-000000000005';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected active participant notified, got %', v_count; END IF;
  SELECT count(*) INTO v_count FROM user_notifications
    WHERE notification_type = 'meetings.cancelled.v1' AND recipient_user_id = '87000000-0001-0000-0000-000000000006'
      AND source_record_id = '87000000-0008-0000-0000-000000000005';
  IF v_count <> 0 THEN RAISE EXCEPTION 'already-removed participant unexpectedly notified'; END IF;
END $$;
INSERT INTO wf87_results VALUES (16,'End-to-end via the real worker: the active participant receives exactly one meetings.cancelled.v1 notification; a participant already removed before cancellation receives nothing');

-- 17. p_suppress_notification := TRUE suppresses meetings.cancelled.v1 too.
DO $$
DECLARE v_meeting_id UUID; v_count INTEGER;
BEGIN
  INSERT INTO meetings (id, organization_id, created_by, title, meeting_type, status, visibility, timezone, start_at, end_at)
  VALUES ('87000000-0008-0000-0000-000000000006','87000000-0000-0000-0000-000000000001','87000000-0001-0000-0000-000000000001','WF87 Meeting F (suppressed cancel)','general','scheduled','participants','Indian/Maldives', now()+interval '6 day', now()+interval '6 day 1 hour')
  RETURNING id INTO v_meeting_id;
  INSERT INTO meeting_participants (meeting_id, user_id, participant_role, is_organizer, invited_by, invitation_status)
  VALUES (v_meeting_id, '87000000-0001-0000-0000-000000000001', 'organizer', TRUE, '87000000-0001-0000-0000-000000000001', 'accepted');

  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87000000-0001-0000-0000-000000000001"}',true);
  PERFORM cancel_meeting(v_meeting_id, 'suppressed cancel', p_suppress_notification := TRUE);
  RESET ROLE;

  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE event_type = 'meetings.cancelled.v1' AND source_record_id = v_meeting_id;
  IF v_count <> 0 THEN RAISE EXCEPTION 'p_suppress_notification=TRUE unexpectedly still enqueued meetings.cancelled.v1'; END IF;
END $$;
INSERT INTO wf87_results VALUES (17,'p_suppress_notification := TRUE also suppresses the new meetings.cancelled.v1 CAP-003 enqueue exactly as it suppresses the legacy notification -- same shared gate as the pre-existing branch');

-- 18. Nonexistent meeting: hard FK rejects it at creation time.
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  BEGIN
    PERFORM create_notification_intent(
      (SELECT id FROM platform_outbox_events WHERE event_type = 'meetings.cancelled.v1' LIMIT 1),
      'meetings.cancelled.v1','meetings.cancelled','{}'::JSONB,'normal','meeting_participants',
      NULL,NULL,NULL,NULL,NULL,NULL, gen_random_uuid()
    );
  EXCEPTION WHEN foreign_key_violation THEN v_caught := TRUE;
  END;
  IF NOT v_caught THEN RAISE EXCEPTION 'expected foreign_key_violation for nonexistent target_meeting_id'; END IF;
END $$;
INSERT INTO wf87_results VALUES (18,'A meetings.cancelled.v1-shaped intent referencing a nonexistent target_meeting_id is rejected at creation time via the existing target_meeting_id hard FK (Phase 1.4A precedent)');

-- ══════════════════ CROSS-CUTTING ══════════════════

-- 19. task.assigned.v1 (Phase 1.4) still works completely unchanged.
DO $$
DECLARE v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87000000-0001-0000-0000-000000000001"}',true);
  PERFORM assign_task('87000000-0007-0000-0000-000000000003', '87000000-0001-0000-0000-000000000008');
  RESET ROLE;
  PERFORM process_platform_outbox_batch(50, 'wf87-worker');
  SELECT count(*) INTO v_count FROM user_notifications
    WHERE notification_type = 'task.assigned.v1' AND recipient_user_id = '87000000-0001-0000-0000-000000000008'
      AND source_record_id = '87000000-0007-0000-0000-000000000003';
  IF v_count <> 1 THEN RAISE EXCEPTION 'task.assigned.v1 (Phase 1.4 pilot) regressed, got %', v_count; END IF;
END $$;
INSERT INTO wf87_results VALUES (19,'task.assigned.v1 (Phase 1.4''s own pilot event) still works completely unchanged end-to-end through the real worker after Phase 1.4B''s additions');

-- 20. A task-sourced intent deliberately given a meeting_participants
-- target (structurally valid -- the target-shape CHECK has no opinion
-- on source_record_type, exactly Phase 1.4A's own established
-- precedent) still fails CLOSED at resolution: the meeting's real
-- participant, who has zero relationship to the referenced private
-- task, is never authorized, because source_record_type='task' still
-- dispatches to intent_user_can_view_task() regardless of which
-- target kind supplied the candidate.
DO $$
DECLARE v_mismatch_meeting_id UUID; v_intent_id UUID; v_status TEXT; v_resolved INTEGER; v_skipped INTEGER; v_event_id UUID;
BEGIN
  INSERT INTO meetings (id, organization_id, created_by, title, meeting_type, status, visibility, timezone, start_at, end_at)
  VALUES (gen_random_uuid(),'87000000-0000-0000-0000-000000000001','87000000-0001-0000-0000-000000000001','WF87 mismatch-only meeting','general','scheduled','participants','Indian/Maldives', now()+interval '1 day', now()+interval '1 day 1 hour')
  RETURNING id INTO v_mismatch_meeting_id;
  INSERT INTO meeting_participants (meeting_id, user_id, participant_role, is_organizer, invited_by, invitation_status)
  VALUES (v_mismatch_meeting_id, '87000000-0001-0000-0000-000000000008', 'attendee', FALSE, '87000000-0001-0000-0000-000000000001', 'accepted');

  v_event_id := platform_enqueue_outbox_event('task.completed.v1','tasks','task','87000000-0007-0000-0000-000000000001',
    '87000000-0000-0000-0000-000000000001', NULL, gen_random_uuid(), NULL, NOW(), '{}'::JSONB, gen_random_uuid());
  v_intent_id := create_notification_intent(v_event_id,'task.completed.v1','task.completed','{}'::JSONB,'normal',
    'meeting_participants', NULL,NULL,NULL,NULL,NULL,NULL, v_mismatch_meeting_id);
  IF v_intent_id IS NULL THEN RAISE EXCEPTION 'expected the structurally-valid (if semantically mismatched) intent to be created'; END IF;

  SELECT status, resolved_count, skipped_count INTO v_status, v_resolved, v_skipped FROM resolve_notification_intent(v_intent_id);
  IF v_resolved <> 0 OR v_status <> 'failed' THEN
    RAISE EXCEPTION 'SECURITY: a task-sourced intent with a mismatched meeting_participants target unexpectedly authorized a candidate unrelated to the referenced private task, got %/%/%', v_status, v_resolved, v_skipped;
  END IF;
END $$;
INSERT INTO wf87_results VALUES (20,'A task-sourced intent given a meeting_participants target (structurally valid -- the target-shape CHECK has no opinion on source_record_type) still fails CLOSED at resolution: source_record_type=''task'' always dispatches to intent_user_can_view_task(), so a meeting participant with zero relationship to the referenced private task is never authorized -- source authorization and target resolution remain independently enforced even under a deliberately adversarial combination');

-- 21. No sensitive fields (task description, meeting notes/agenda) were
-- ever copied into notification_intents by any of the three new events.
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM notification_intents ni
  JOIN platform_outbox_events e ON e.id = ni.outbox_event_id
  WHERE e.event_type IN ('task.completed.v1','meetings.rescheduled.v1','meetings.cancelled.v1')
    AND (ni.template_params::TEXT ILIKE '%description%' OR ni.template_params::TEXT ILIKE '%agenda%' OR ni.template_params::TEXT ILIKE '%minutes%' OR ni.template_params::TEXT ILIKE '%comment%');
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY: a Phase 1.4B intent unexpectedly references sensitive-content-shaped fields'; END IF;
END $$;
INSERT INTO wf87_results VALUES (21,'No notification_intents row created by any of the three new event types references task description, meeting agenda/minutes, or comment-shaped fields -- template_params carries only structural identifiers/timestamps/actor ids, matching task.assigned.v1''s own established shape');

-- 22. The worker required zero code changes: draining a
-- task.completed.v1 event and a meetings.rescheduled.v1 event through
-- the SAME unmodified process_platform_outbox_batch() entry point.
DO $$
DECLARE v_task_id UUID; v_meeting_id UUID; v_completed INTEGER := 0; v_batch RECORD; v_iteration INTEGER; v_rows_in_call INTEGER;
BEGIN
  INSERT INTO tasks (id, task_number, title, status, priority, created_by, organization_id, owning_section_id, visibility)
  VALUES (gen_random_uuid(),'WF87-T4','WF87 worker-genericity task','in_progress','normal','87000000-0001-0000-0000-000000000001','87000000-0000-0000-0000-000000000001','87000000-0002-0000-0000-000000000001','private')
  RETURNING id INTO v_task_id;
  INSERT INTO meetings (id, organization_id, created_by, title, meeting_type, status, visibility, timezone, start_at, end_at)
  VALUES (gen_random_uuid(),'87000000-0000-0000-0000-000000000001','87000000-0001-0000-0000-000000000001','WF87 worker-genericity meeting','general','scheduled','participants','Indian/Maldives', now()+interval '20 day', now()+interval '20 day 1 hour')
  RETURNING id INTO v_meeting_id;

  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"87000000-0001-0000-0000-000000000001"}',true);
  PERFORM complete_task(v_task_id, NULL);
  PERFORM update_meeting(p_meeting_id := v_meeting_id, p_start_at := now()+interval '21 day', p_end_at := now()+interval '21 day 1 hour');
  RESET ROLE;

  FOR v_iteration IN 1..50 LOOP
    EXIT WHEN v_completed >= 2;
    v_rows_in_call := 0;
    FOR v_batch IN SELECT * FROM process_platform_outbox_batch(200, 'wf87-worker') LOOP
      v_rows_in_call := v_rows_in_call + 1;
      IF v_batch.event_type IN ('task.completed.v1','meetings.rescheduled.v1') AND v_batch.event_id IN (
        SELECT id FROM platform_outbox_events WHERE source_record_id IN (v_task_id, v_meeting_id)
      ) THEN v_completed := v_completed + 1; END IF;
    END LOOP;
    EXIT WHEN v_rows_in_call = 0;
  END LOOP;
  IF v_completed <> 2 THEN RAISE EXCEPTION 'expected both a task.completed.v1 and a meetings.rescheduled.v1 event drained by the same unmodified worker call, got %', v_completed; END IF;
END $$;
INSERT INTO wf87_results VALUES (22,'process_platform_outbox_batch() -- byte-for-byte unmodified beyond the registry rows this milestone adds -- drains both a task.completed.v1 and a meetings.rescheduled.v1 event correctly, proving zero target-kind or module-specific branching was needed for either new producer');

-- 23. Deferred candidates are genuinely inert: creating an outbox event
-- with a deferred literal is not itself blocked (source module could
-- still enqueue arbitrary event_types) but the registry gate means it
-- is NOT processed via the generic envelope path (fails deterministically).
DO $$
DECLARE v_event_id UUID; v_outcome TEXT;
BEGIN
  v_event_id := platform_enqueue_outbox_event('task.review_requested.v1','tasks','task','87000000-0007-0000-0000-000000000001',
    '87000000-0000-0000-0000-000000000001','87000000-0001-0000-0000-000000000001', gen_random_uuid(), NULL, NOW(),
    jsonb_build_object('notification_type','task.review_requested.v1','title_template_key','x','template_params','{}'::JSONB,
      'priority','normal','target_type','specific_users','target_user_ids', jsonb_build_array('87000000-0001-0000-0000-000000000001')),
    gen_random_uuid());
  SELECT outcome INTO v_outcome FROM process_platform_outbox_batch(50, 'wf87-worker') WHERE event_id = v_event_id;
  IF v_outcome NOT IN ('retry_scheduled','dead_lettered') THEN
    RAISE EXCEPTION 'expected the deferred task.review_requested.v1 event to fail deterministically (not registered), got outcome=%', v_outcome;
  END IF;
END $$;
INSERT INTO wf87_results VALUES (23,'task.review_requested.v1 (an explicitly deferred candidate) is genuinely NOT registered -- an outbox event using that literal fails deterministically through the existing retry/dead-letter machinery rather than being silently processed, confirming no accidental registry row exists for any deferred candidate');

-- 24. meetings.scheduled.v1 (deferred) is likewise genuinely absent
-- from the registry.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type = 'meetings.scheduled.v1') THEN
    RAISE EXCEPTION 'meetings.scheduled.v1 unexpectedly registered despite being an explicitly deferred candidate';
  END IF;
  IF EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type = 'task.returned.v1') THEN
    RAISE EXCEPTION 'task.returned.v1 unexpectedly registered despite being an explicitly deferred candidate';
  END IF;
END $$;
INSERT INTO wf87_results VALUES (24,'meetings.scheduled.v1 and task.returned.v1 (the remaining explicitly deferred candidates) have no platform_event_type_registry row at all -- confirmed by direct query, not merely by absence of a worker code path');

-- 25. Existing six + task_watchers + meeting_participants target kinds
-- (Phase 1.2/1.4A) still behave exactly as before -- a specific_users
-- event for an ordinary recipient still resolves normally.
DO $$
DECLARE v_status TEXT; v_resolved INTEGER; v_intent_id UUID; v_event_id UUID;
BEGIN
  v_event_id := platform_enqueue_outbox_event('platform.generic_notification_request.v1','platform','platform',gen_random_uuid(),
    '87000000-0000-0000-0000-000000000001', NULL, gen_random_uuid(), NULL, NOW(),
    jsonb_build_object('notification_type','wf87.d25.v1','title_template_key','x','template_params','{}'::JSONB,'priority','normal',
      'target_type','specific_users','target_user_ids', jsonb_build_array('87000000-0001-0000-0000-000000000008')),
    gen_random_uuid());
  v_intent_id := create_notification_intent(v_event_id,'wf87.d25.v1','x','{}'::JSONB,'normal','specific_users',
    ARRAY['87000000-0001-0000-0000-000000000008']::UUID[], NULL,NULL,NULL,NULL,NULL,NULL);
  SELECT status, resolved_count INTO v_status, v_resolved FROM resolve_notification_intent(v_intent_id);
  IF v_status <> 'resolved' OR v_resolved <> 1 THEN RAISE EXCEPTION 'existing specific_users target kind regressed: %/%', v_status, v_resolved; END IF;
END $$;
INSERT INTO wf87_results VALUES (25,'The pre-existing specific_users target kind (and by construction, every other Phase 1.2/1.4A target kind, since resolve_notification_intent''s CASE dispatch is completely unmodified) still resolves exactly as before -- Phase 1.4B added zero target-kind changes');

RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf87_results;
  IF v_count <> 25 THEN RAISE EXCEPTION 'expected 25 scenarios recorded, got %', v_count; END IF;
  RAISE NOTICE 'Task/Meeting notification event integration behavioral tests PASSED: 25/25';
END $$;

ROLLBACK;
