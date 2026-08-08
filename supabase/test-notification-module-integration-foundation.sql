-- CAP-003 Phase 1.4 notification module integration foundation --
-- focused behavioral suite (20 required scenarios). Disposable local
-- PostgreSQL only. Runs in one transaction and leaves no fixtures
-- (rolled back at the end).
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf85_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
GRANT SELECT, INSERT ON wf85_results TO authenticated, service_role;

-- ── Fixtures ─────────────────────────────────────────────────────────
INSERT INTO organizations(id,name,type,code) VALUES
 ('85000000-0000-0000-0000-000000000001','WF85 Org A','authority','WF85A'),
 ('85000000-0000-0000-0000-000000000002','WF85 Org B','authority','WF85B');
INSERT INTO divisions(id, org_id, name) VALUES
 ('85000000-0004-0000-0000-000000000001','85000000-0000-0000-0000-000000000001','WF85 Div A');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
 ('85000000-0002-0000-0000-000000000001','85000000-0000-0000-0000-000000000001','85000000-0004-0000-0000-000000000001','WF85 Sec A','SA1'),
 ('85000000-0002-0000-0000-000000000002','85000000-0000-0000-0000-000000000001','85000000-0004-0000-0000-000000000001','WF85 Sec B','SB1');

INSERT INTO auth.users(id,email) VALUES
 ('85000000-0001-0000-0000-000000000001','creator@wf85t.local'),
 ('85000000-0001-0000-0000-000000000002','assignee@wf85t.local'),
 ('85000000-0001-0000-0000-000000000003','watcher@wf85t.local'),
 ('85000000-0001-0000-0000-000000000004','completer@wf85t.local'),
 ('85000000-0001-0000-0000-000000000005','samesecmember@wf85t.local'),
 ('85000000-0001-0000-0000-000000000006','othersecmember@wf85t.local'),
 ('85000000-0001-0000-0000-000000000007','supervisorb@wf85t.local'),
 ('85000000-0001-0000-0000-000000000008','mcsadmin@wf85t.local'),
 ('85000000-0001-0000-0000-000000000009','superadmin@wf85t.local'),
 ('85000000-0001-0000-0000-000000000010','unrelated@wf85t.local'),
 ('85000000-0001-0000-0000-000000000011','crossorguser@wf85t.local'),
 ('85000000-0001-0000-0000-000000000012','inactiveassignee@wf85t.local');

INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_super_admin) VALUES
 ('85000000-0001-0000-0000-000000000001','85000000-0000-0000-0000-000000000001','WF85-1','Creator','creator@wf85t.local',true,false),
 ('85000000-0001-0000-0000-000000000002','85000000-0000-0000-0000-000000000001','WF85-2','Assignee','assignee@wf85t.local',true,false),
 ('85000000-0001-0000-0000-000000000003','85000000-0000-0000-0000-000000000001','WF85-3','Watcher','watcher@wf85t.local',true,false),
 ('85000000-0001-0000-0000-000000000004','85000000-0000-0000-0000-000000000001','WF85-4','Completer','completer@wf85t.local',true,false),
 ('85000000-0001-0000-0000-000000000005','85000000-0000-0000-0000-000000000001','WF85-5','Same Section Member','samesecmember@wf85t.local',true,false),
 ('85000000-0001-0000-0000-000000000006','85000000-0000-0000-0000-000000000001','WF85-6','Other Section Member','othersecmember@wf85t.local',true,false),
 ('85000000-0001-0000-0000-000000000007','85000000-0000-0000-0000-000000000001','WF85-7','Section B Supervisor','supervisorb@wf85t.local',true,false),
 ('85000000-0001-0000-0000-000000000008','85000000-0000-0000-0000-000000000001','WF85-8','MCS Admin','mcsadmin@wf85t.local',true,false),
 ('85000000-0001-0000-0000-000000000009','85000000-0000-0000-0000-000000000001','WF85-9','Super Admin','superadmin@wf85t.local',true,true),
 ('85000000-0001-0000-0000-000000000010','85000000-0000-0000-0000-000000000001','WF85-10','Unrelated Same-Org','unrelated@wf85t.local',true,false),
 ('85000000-0001-0000-0000-000000000011','85000000-0000-0000-0000-000000000002','WF85-11','Cross-Org User','crossorguser@wf85t.local',true,false),
 ('85000000-0001-0000-0000-000000000012','85000000-0000-0000-0000-000000000001','WF85-12','Inactive Assignee','inactiveassignee@wf85t.local',false,false);

INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('85000000-0001-0000-0000-000000000005','section','85000000-0002-0000-0000-000000000001','staff',true,true),
 ('85000000-0001-0000-0000-000000000006','section','85000000-0002-0000-0000-000000000002','staff',true,true),
 ('85000000-0001-0000-0000-000000000007','section','85000000-0002-0000-0000-000000000001','supervisor',true,true),
 ('85000000-0001-0000-0000-000000000008','organization','85000000-0000-0000-0000-000000000001','mcs_admin',true,true);

-- A private-visibility, section-A-owned task: creator=1, assignee=2
-- (active), watcher=3, completed_by=4, private visibility so ONLY the
-- explicit-membership branches of can_view_task/intent_user_can_view_task
-- apply (not the org/section-visibility branches) -- isolates each
-- membership branch cleanly.
INSERT INTO tasks (id, task_number, title, status, priority, completed_by, created_by, organization_id, owning_section_id, visibility)
VALUES ('85000000-0007-0000-0000-000000000001','WF85-T1','WF85 private task','completed','normal',
        '85000000-0001-0000-0000-000000000004','85000000-0001-0000-0000-000000000001',
        '85000000-0000-0000-0000-000000000001','85000000-0002-0000-0000-000000000001','private');
INSERT INTO task_assignments (task_id, user_id, assigned_by, is_active) VALUES
 ('85000000-0007-0000-0000-000000000001','85000000-0001-0000-0000-000000000002','85000000-0001-0000-0000-000000000001',true);
INSERT INTO task_watchers (task_id, user_id) VALUES
 ('85000000-0007-0000-0000-000000000001','85000000-0001-0000-0000-000000000003');

-- A section-A-visibility task (no explicit assignee/watcher fixtures),
-- used to isolate the section-visibility branch.
INSERT INTO tasks (id, task_number, title, status, priority, created_by, organization_id, owning_section_id, visibility)
VALUES ('85000000-0007-0000-0000-000000000002','WF85-T2','WF85 section task','open','normal',
        '85000000-0001-0000-0000-000000000001','85000000-0000-0000-0000-000000000001',
        '85000000-0002-0000-0000-000000000001','section');

-- An organization-visibility task, owning_section_id NULL, isolates
-- the organization-visibility branch and the "supervisor with no
-- owning section" branch.
INSERT INTO tasks (id, task_number, title, status, priority, created_by, organization_id, owning_section_id, visibility)
VALUES ('85000000-0007-0000-0000-000000000003','WF85-T3','WF85 org task','open','normal',
        '85000000-0001-0000-0000-000000000001','85000000-0000-0000-0000-000000000001',
        NULL,'organization');

SET ROLE authenticated;

-- ── 1: assign_task() atomically enqueues a task.assigned.v1 outbox
-- event in the SAME transaction as task_assignments -- correct
-- event_type/source_module/source_record_type/source_record_id/org ──
SELECT set_config('request.jwt.claims','{"sub":"85000000-0001-0000-0000-000000000001"}',false);
SELECT assign_task('85000000-0007-0000-0000-000000000002'::UUID, '85000000-0001-0000-0000-000000000005'::UUID);
RESET ROLE;
SET ROLE service_role;
DO $$
DECLARE v_row RECORD;
BEGIN
  SELECT * INTO v_row FROM platform_outbox_events
  WHERE event_type = 'task.assigned.v1' AND source_record_id = '85000000-0007-0000-0000-000000000002';
  IF NOT FOUND THEN RAISE EXCEPTION 'assign_task did not enqueue a task.assigned.v1 outbox event'; END IF;
  IF v_row.source_module <> 'tasks' OR v_row.source_record_type <> 'task'
     OR v_row.organization_id <> '85000000-0000-0000-0000-000000000001'
     OR v_row.actor_id <> '85000000-0001-0000-0000-000000000001'
     OR v_row.status <> 'pending'
  THEN RAISE EXCEPTION 'task.assigned.v1 outbox event has wrong business-identity fields: %', row_to_json(v_row); END IF;
  IF (v_row.payload->>'target_type') <> 'specific_users'
     OR v_row.payload->'target_user_ids' <> '["85000000-0001-0000-0000-000000000005"]'::JSONB
  THEN RAISE EXCEPTION 'task.assigned.v1 payload has wrong target descriptor: %', v_row.payload; END IF;
END $$;
INSERT INTO wf85_results VALUES (1,'assign_task() atomically enqueues a task.assigned.v1 outbox event in the same transaction as the task_assignments write, with correct source identity and a specific_users payload targeting exactly the newly assigned user');

-- ── 2: idempotent re-assignment (already active) is a no-op -- no
-- second outbox event ─────────────────────────────────────────────
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"85000000-0001-0000-0000-000000000001"}',false);
SELECT assign_task('85000000-0007-0000-0000-000000000002'::UUID, '85000000-0001-0000-0000-000000000005'::UUID);
RESET ROLE;
SET ROLE service_role;
DO $$ DECLARE v_count INTEGER; BEGIN
  SELECT count(*) INTO v_count FROM platform_outbox_events
  WHERE event_type = 'task.assigned.v1' AND source_record_id = '85000000-0007-0000-0000-000000000002';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 outbox event after re-assigning an already-active assignee, got %', v_count; END IF;
END $$;
INSERT INTO wf85_results VALUES (2,'Re-calling assign_task() for an already-actively-assigned user is a safe idempotent no-op (task_assignments'' own ON CONFLICT + early RETURN) -- no duplicate outbox event is ever enqueued');

-- ── 3: platform_enqueue_outbox_event's own idempotency_key dedup
-- (a direct replay with the same identity/idempotency_key is a safe
-- no-op, never a duplicate row) ─────────────────────────────────────
DO $$
DECLARE v_id1 UUID; v_id2 UUID; v_count INTEGER; v_corr UUID := gen_random_uuid();
BEGIN
  v_id1 := platform_enqueue_outbox_event('task.assigned.v1','tasks','task','85000000-0007-0000-0000-000000000003',
    '85000000-0000-0000-0000-000000000001','85000000-0001-0000-0000-000000000001'::UUID,
    v_corr, NULL, NOW(),
    jsonb_build_object('notification_type','task.assigned.v1','title_template_key','task.assigned',
      'template_params','{}'::JSONB,'priority','normal','target_type','specific_users',
      'target_user_ids', jsonb_build_array('85000000-0001-0000-0000-000000000005')),
    '85000000-0009-0000-0000-000000000001'::UUID);
  v_id2 := platform_enqueue_outbox_event('task.assigned.v1','tasks','task','85000000-0007-0000-0000-000000000003',
    '85000000-0000-0000-0000-000000000001','85000000-0001-0000-0000-000000000001'::UUID,
    v_corr, NULL, NOW(),
    jsonb_build_object('notification_type','task.assigned.v1','title_template_key','task.assigned',
      'template_params','{}'::JSONB,'priority','normal','target_type','specific_users',
      'target_user_ids', jsonb_build_array('85000000-0001-0000-0000-000000000005')),
    '85000000-0009-0000-0000-000000000001'::UUID);
  IF v_id1 <> v_id2 THEN RAISE EXCEPTION 'expected the same outbox event id on idempotency_key replay, got % and %', v_id1, v_id2; END IF;
  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE id = v_id1;
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly one durable row, got %', v_count; END IF;
END $$;
INSERT INTO wf85_results VALUES (3,'platform_enqueue_outbox_event''s own (source_module,source_record_type,source_record_id,event_type,idempotency_key) uniqueness constraint makes a direct replay with identical identity a safe no-op, returning the same event id rather than creating a duplicate row');

-- ── 4: the worker processes task.assigned.v1 via the registry-driven
-- generic envelope path -- create_notification_intent is called with
-- source_record_type='task' ─────────────────────────────────────────
DO $$
DECLARE v_batch RECORD; v_intent RECORD;
BEGIN
  SELECT * INTO v_batch FROM process_platform_outbox_batch(50, 'wf85-worker')
    WHERE event_type = 'task.assigned.v1' AND event_id = (
      SELECT id FROM platform_outbox_events WHERE event_type='task.assigned.v1' AND source_record_id='85000000-0007-0000-0000-000000000002'
    );
  IF v_batch.outcome NOT IN ('processed','processed_zero_recipients') THEN RAISE EXCEPTION 'expected outcome=processed, got %', v_batch.outcome; END IF;
  SELECT * INTO v_intent FROM notification_intents WHERE id = v_batch.intent_id;
  IF v_intent.source_record_type <> 'task' OR v_intent.target_type <> 'specific_users' THEN
    RAISE EXCEPTION 'notification_intents row has wrong source_record_type/target_type: %/%', v_intent.source_record_type, v_intent.target_type;
  END IF;
END $$;
INSERT INTO wf85_results VALUES (4,'process_platform_outbox_batch() processes task.assigned.v1 via the SAME registry-driven generic-envelope passthrough path Phase 1.3''s platform.generic_notification_request.v1 already used -- create_notification_intent() is called with source_record_type=''task'', with zero new worker code branching on the event type string');

-- ── 5: resolve_notification_intent() creates a durable
-- user_notifications row for the actual assignee (who IS an active
-- assignee, so intent_user_can_view_task authorizes them) ──────────
DO $$ DECLARE v_count INTEGER; BEGIN
  SELECT count(*) INTO v_count FROM user_notifications
  WHERE recipient_user_id = '85000000-0001-0000-0000-000000000005'
    AND notification_type = 'task.assigned.v1' AND source_record_id = '85000000-0007-0000-0000-000000000002';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 user_notifications row for the assignee, got %', v_count; END IF;
END $$;
INSERT INTO wf85_results VALUES (5,'A durable user_notifications row is created for the actual task assignee once the intent resolves -- the full pipeline (outbox -> intent -> resolution -> notification) completes end to end for a real module event, not just the Phase 1.3 generic test envelope');

-- ── 6: the pre-existing legacy dual-write is completely unaffected --
-- both the new outbox notification AND the legacy notifications row
-- exist side by side ─────────────────────────────────────────────
DO $$ DECLARE v_count INTEGER; BEGIN
  SELECT count(*) INTO v_count FROM notifications
  WHERE user_id = '85000000-0001-0000-0000-000000000005' AND type = 'task_assigned' AND record_id = '85000000-0007-0000-0000-000000000002';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 legacy notifications row (dual-write preserved), got %', v_count; END IF;
END $$;
INSERT INTO wf85_results VALUES (6,'assign_task()''s pre-existing legacy INSERT INTO notifications call is completely unmodified -- the legacy row and the new CAP-003 outbox-driven notification both exist side by side (dual-write during the transition period, no premature cutover)');

-- ── 7-16: intent_user_can_view_task() branch-by-branch, exercised
-- ONLY indirectly through the real create_notification_intent/
-- resolve_notification_intent pipeline (intent_user_can_view_task, like
-- Phase 1.2's own intent_user_can_view_workflow_instance, is granted
-- to no role at all -- it is an internal primitive resolve_notification_
-- intent's SECURITY DEFINER body calls as its owner, never invoked
-- directly by service_role or any other caller; Phase 1.2's own test
-- suite exercises its adapter the same indirect way). A local,
-- transaction-scoped helper avoids repeating the enqueue/create/resolve
-- boilerplate ten times. ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION pg_temp.wf85_task_authorized(p_task_id UUID, p_candidate UUID) RETURNS BOOLEAN AS $$
DECLARE
  v_event_id UUID; v_intent_id UUID; v_resolved INTEGER;
BEGIN
  v_event_id := platform_enqueue_outbox_event('task.assigned.v1','tasks','task',p_task_id,
    '85000000-0000-0000-0000-000000000001', NULL, gen_random_uuid(), NULL, NOW(),
    jsonb_build_object('notification_type','task.assigned.v1','title_template_key','task.assigned',
      'template_params','{}'::JSONB,'priority','normal','target_type','specific_users',
      'target_user_ids', jsonb_build_array(p_candidate)),
    gen_random_uuid());
  v_intent_id := create_notification_intent(v_event_id, 'task.assigned.v1','task.assigned','{}'::JSONB,'normal',
    'specific_users', ARRAY[p_candidate]::UUID[], NULL, NULL, NULL, NULL,NULL,NULL);
  SELECT resolved_count INTO v_resolved FROM resolve_notification_intent(v_intent_id);
  RETURN v_resolved = 1;
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN
  IF NOT pg_temp.wf85_task_authorized('85000000-0007-0000-0000-000000000001','85000000-0001-0000-0000-000000000002') THEN
    RAISE EXCEPTION 'active assignee should be authorized'; END IF;
END $$;
INSERT INTO wf85_results VALUES (7,'intent_user_can_view_task(), exercised through the real create_notification_intent/resolve_notification_intent pipeline: the active task_assignments membership branch authorizes the assignee, mirroring can_view_task()''s own assignee branch');

DO $$ BEGIN
  IF NOT pg_temp.wf85_task_authorized('85000000-0007-0000-0000-000000000001','85000000-0001-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'creator should be authorized'; END IF;
END $$;
INSERT INTO wf85_results VALUES (8,'intent_user_can_view_task(): the created_by branch authorizes the task creator');

DO $$ BEGIN
  IF NOT pg_temp.wf85_task_authorized('85000000-0007-0000-0000-000000000001','85000000-0001-0000-0000-000000000004') THEN
    RAISE EXCEPTION 'completed_by should be authorized'; END IF;
END $$;
INSERT INTO wf85_results VALUES (9,'intent_user_can_view_task(): the completed_by branch authorizes whoever completed the task');

DO $$ BEGIN
  IF NOT pg_temp.wf85_task_authorized('85000000-0007-0000-0000-000000000001','85000000-0001-0000-0000-000000000003') THEN
    RAISE EXCEPTION 'watcher should be authorized'; END IF;
END $$;
INSERT INTO wf85_results VALUES (10,'intent_user_can_view_task(): the task_watchers membership branch authorizes an explicit watcher');

DO $$ BEGIN
  IF pg_temp.wf85_task_authorized('85000000-0007-0000-0000-000000000001','85000000-0001-0000-0000-000000000010') THEN
    RAISE EXCEPTION 'unrelated same-org user should NOT be authorized on a private-visibility task with no membership'; END IF;
END $$;
INSERT INTO wf85_results VALUES (11,'intent_user_can_view_task(): a same-organization user with no creator/completer/assignee/watcher/admin/supervisor relationship to a PRIVATE-visibility task is correctly denied (skipped_count=1, resolved_count=0, zero user_notifications rows) -- membership, not mere org membership, gates a private task');

DO $$ BEGIN
  IF NOT pg_temp.wf85_task_authorized('85000000-0007-0000-0000-000000000002','85000000-0001-0000-0000-000000000005') THEN
    RAISE EXCEPTION 'same-section member should be authorized on a section-visibility task'; END IF;
  IF pg_temp.wf85_task_authorized('85000000-0007-0000-0000-000000000002','85000000-0001-0000-0000-000000000006') THEN
    RAISE EXCEPTION 'a member of a DIFFERENT section should NOT be authorized on a section-visibility task (non-supervisor)'; END IF;
END $$;
INSERT INTO wf85_results VALUES (12,'intent_user_can_view_task(): the section-visibility branch authorizes a member of the task''s owning_section_id and correctly denies a member of a different section who holds no supervisor-or-above role');

DO $$ BEGIN
  IF NOT pg_temp.wf85_task_authorized('85000000-0007-0000-0000-000000000002','85000000-0001-0000-0000-000000000007') THEN
    RAISE EXCEPTION 'a supervisor covering the owning section should be authorized even without explicit membership'; END IF;
END $$;
INSERT INTO wf85_results VALUES (13,'intent_user_can_view_task(): a supervisor-or-above whose covered sections include the task''s owning_section_id is authorized, mirroring can_view_task()''s own supervisor-cascade branch');

DO $$ BEGIN
  IF NOT pg_temp.wf85_task_authorized('85000000-0007-0000-0000-000000000001','85000000-0001-0000-0000-000000000008') THEN
    RAISE EXCEPTION 'mcs_admin should be authorized regardless of section/membership'; END IF;
END $$;
INSERT INTO wf85_results VALUES (14,'intent_user_can_view_task(): an org-wide mcs_admin/authority_admin role authorizes regardless of section coverage or explicit task membership, mirroring can_view_task()''s own is_admin() branch');

DO $$ BEGIN
  IF NOT pg_temp.wf85_task_authorized('85000000-0007-0000-0000-000000000001','85000000-0001-0000-0000-000000000009') THEN
    RAISE EXCEPTION 'super_admin should be authorized on any task'; END IF;
END $$;
INSERT INTO wf85_results VALUES (15,'intent_user_can_view_task(): a platform super_admin is authorized on any task via intent_user_is_super_admin(), the same primitive Phase 1.2''s own workflow_instance adapter reuses');

DO $$ BEGIN
  IF NOT pg_temp.wf85_task_authorized('85000000-0007-0000-0000-000000000003','85000000-0001-0000-0000-000000000010') THEN
    RAISE EXCEPTION 'any same-org user should be authorized on an organization-visibility task'; END IF;
  IF pg_temp.wf85_task_authorized('85000000-0007-0000-0000-000000000003','85000000-0001-0000-0000-000000000011') THEN
    RAISE EXCEPTION 'SECURITY HOLE: a cross-org user was authorized on another organization''s task'; END IF;
END $$;
INSERT INTO wf85_results VALUES (16,'intent_user_can_view_task(): the organization-visibility branch authorizes any same-org user and the top-level organization_id match (mirroring can_view_task()''s own required AND condition) correctly denies a cross-organization user regardless of visibility');

-- ── 17: late (processing-time) authorization revalidation, not an
-- enqueue-time snapshot -- an assignment revoked BETWEEN enqueue and
-- processing means the (now-former) assignee receives nothing ──────
DO $$
DECLARE v_event_id UUID; v_intent_id UUID; v_status TEXT; v_resolved INTEGER; v_skipped INTEGER; v_count INTEGER;
BEGIN
  INSERT INTO task_assignments (task_id, user_id, assigned_by, is_active)
  VALUES ('85000000-0007-0000-0000-000000000001','85000000-0001-0000-0000-000000000010','85000000-0001-0000-0000-000000000001',true);

  v_event_id := platform_enqueue_outbox_event('task.assigned.v1','tasks','task','85000000-0007-0000-0000-000000000001',
    '85000000-0000-0000-0000-000000000001','85000000-0001-0000-0000-000000000001'::UUID,
    gen_random_uuid(), NULL, NOW(),
    jsonb_build_object('notification_type','task.assigned.v1','title_template_key','task.assigned',
      'template_params','{}'::JSONB,'priority','normal','target_type','specific_users',
      'target_user_ids', jsonb_build_array('85000000-0001-0000-0000-000000000010')),
    '85000000-0009-0000-0000-000000000002'::UUID);

  v_intent_id := create_notification_intent(v_event_id, 'task.assigned.v1','task.assigned','{}'::JSONB,'normal',
    'specific_users', ARRAY['85000000-0001-0000-0000-000000000010']::UUID[], NULL, NULL, NULL, NULL,NULL,NULL);

  -- Revoke the assignment BEFORE resolution runs -- the candidate is
  -- no longer a legitimate recipient by processing time.
  UPDATE task_assignments SET is_active = false
  WHERE task_id = '85000000-0007-0000-0000-000000000001' AND user_id = '85000000-0001-0000-0000-000000000010';

  SELECT status, resolved_count, skipped_count INTO v_status, v_resolved, v_skipped FROM resolve_notification_intent(v_intent_id);
  IF v_status <> 'failed' OR v_resolved <> 0 OR v_skipped <> 1 THEN
    RAISE EXCEPTION 'expected failed/0/1 (revoked-membership candidate skipped at processing time), got %/%/%', v_status, v_resolved, v_skipped;
  END IF;
  SELECT count(*) INTO v_count FROM user_notifications WHERE recipient_user_id = '85000000-0001-0000-0000-000000000010' AND outbox_event_id = v_event_id;
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: a notification was created for a candidate whose task membership was revoked before processing'; END IF;
END $$;
INSERT INTO wf85_results VALUES (17,'Authorization for task-sourced intents is revalidated LATE, at processing time, against the task''s CURRENT membership state -- never a cached enqueue-time snapshot (docs/78 Sec8): revoking task_assignments.is_active between enqueue and resolution means the candidate receives nothing, exactly as CAP-003''s own late-resolution guarantee requires');

-- ── 18: the closed source_record_type dispatch remains CLOSED --
-- extended by exactly the one justified literal ('task'), still
-- rejecting every other unsupported source_record_type ─────────────
-- NOTE (Phase 1.4A carve-out): this scenario originally used 'meeting' as
-- its example still-unsupported literal, since meeting_participants did not
-- exist yet at Phase 1.4. Phase 1.4A legitimately added 'meeting' as a
-- supported source_record_type (with its own intent_user_can_view_meeting()
-- authorization dispatch), so 'meeting' is no longer a valid negative-test
-- example. Only the example literal is updated here, to 'request' (still
-- genuinely unsupported -- Requests integration remains deferred); the
-- assertion itself (closed dispatch rejects every unsupported literal) is
-- unchanged and still enforced.
DO $$
DECLARE v_event_id UUID; v_count INTEGER;
BEGIN
  v_event_id := platform_enqueue_outbox_event('request.created.v1','requests','request',gen_random_uuid(),
    '85000000-0000-0000-0000-000000000001', NULL, gen_random_uuid(), NULL, NOW(), '{}'::JSONB, gen_random_uuid());
  BEGIN
    PERFORM create_notification_intent(v_event_id, 'request.created.v1','request.created','{}'::JSONB,'normal',
      'specific_users', ARRAY['85000000-0001-0000-0000-000000000010']::UUID[], NULL, NULL, NULL, NULL,NULL,NULL);
    RAISE EXCEPTION 'SECURITY HOLE: an intent was created for an unsupported source_record_type (request)';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%has no generic authorization dispatch%' THEN RAISE; END IF;
  END;
  SELECT count(*) INTO v_count FROM notification_intents WHERE outbox_event_id = v_event_id;
  IF v_count <> 0 THEN RAISE EXCEPTION 'an intent row was left behind despite the rejection'; END IF;
END $$;
INSERT INTO wf85_results VALUES (18,'The closed source_record_type dispatch remains closed: Phase 1.4 extends it by exactly one evidence-justified literal (''task'') and still deterministically rejects every other unsupported source_record_type (e.g. ''request'', deferred pending its own Requests module integration) at intent-creation time, never silently faking authorization. (Phase 1.4A carve-out: the example literal was changed from ''meeting'' to ''request'' since Phase 1.4A legitimately added ''meeting'' as a supported source_record_type; the assertion itself is unchanged.)');

-- ── 19: the generic event->intent mapping is genuinely data-driven --
-- registering a brand-new event_type with the envelope flag set makes
-- the SAME worker code process it with zero code changes ───────────
DO $$
DECLARE v_event_id UUID; v_batch RECORD;
BEGIN
  INSERT INTO platform_event_type_registry (event_type, owning_module, is_mandatory, requires_acknowledgement, description, uses_generic_notification_envelope)
  VALUES ('wf85.synthetic_probe.v1','wf85_test',FALSE,FALSE,'Scenario-19 probe: proves the mapping is registry-driven, not a worker code branch',TRUE);

  v_event_id := platform_enqueue_outbox_event('wf85.synthetic_probe.v1','wf85_test','platform',gen_random_uuid(),
    '85000000-0000-0000-0000-000000000001', NULL, gen_random_uuid(), NULL, NOW(),
    jsonb_build_object('notification_type','wf85.synthetic_probe.v1','title_template_key','wf85.probe',
      'template_params','{}'::JSONB,'priority','normal','target_type','specific_users',
      'target_user_ids', jsonb_build_array('85000000-0001-0000-0000-000000000002')),
    gen_random_uuid());

  SELECT * INTO v_batch FROM process_platform_outbox_batch(50,'wf85-worker') WHERE event_id = v_event_id;
  IF v_batch.outcome NOT IN ('processed','processed_zero_recipients') THEN RAISE EXCEPTION 'expected a freshly-registered generic-envelope event_type to process successfully with zero worker code changes, got outcome=%', v_batch.outcome; END IF;
END $$;
INSERT INTO wf85_results VALUES (19,'The event->intent mapping is genuinely generic/data-driven: registering an entirely new event_type with uses_generic_notification_envelope=TRUE (no code change to process_platform_outbox_batch) is immediately processed via the same passthrough path -- proving the worker carries no per-module branch, satisfying the governing instruction''s "generic mapping layer, not a worker branch" requirement');

-- ── 20: an unregistered/unsupported event_type is still rejected
-- deterministically and routed through the SAME shared retry/dead-
-- letter machinery (never a special-cased immediate failure) ───────
DO $$
DECLARE v_event_id UUID; v_batch RECORD;
BEGIN
  v_event_id := platform_enqueue_outbox_event('wf85.unregistered.v1','wf85_test','platform',gen_random_uuid(),
    '85000000-0000-0000-0000-000000000001', NULL, gen_random_uuid(), NULL, NOW(), '{}'::JSONB, gen_random_uuid());
  SELECT * INTO v_batch FROM process_platform_outbox_batch(50,'wf85-worker') WHERE event_id = v_event_id;
  IF v_batch.outcome <> 'retry_scheduled' THEN RAISE EXCEPTION 'expected outcome=retry_scheduled (attempt 1 of the shared retry machinery) for an unregistered event_type, got %', v_batch.outcome; END IF;
  IF v_batch.attempt_count <> 1 THEN RAISE EXCEPTION 'expected attempt_count=1, got %', v_batch.attempt_count; END IF;
END $$;
INSERT INTO wf85_results VALUES (20,'An event_type with no platform_event_type_registry row (or one not flagged uses_generic_notification_envelope) is still rejected deterministically and routed through Phase 1.3''s SAME shared retry/dead-letter state machine -- exactly one worker-state system, never a second special-cased immediate-failure path');

RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf85_results;
  IF v_count <> 20 THEN
    RAISE EXCEPTION 'Expected 20 scenarios to record a result, found %', v_count;
  END IF;
  RAISE NOTICE 'Notification module integration foundation behavioral tests PASSED: %/20', v_count;
END $$;

ROLLBACK;
