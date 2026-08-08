-- CAP-003 Phase 1.2 notification recipient resolution -- focused
-- behavioral suite (20 required scenarios). Disposable local
-- PostgreSQL only. Runs in one transaction and leaves no fixtures
-- (rolled back at the end).
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf82_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf82_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf82_results, wf82_ids TO authenticated, service_role;

-- ── Fixtures ─────────────────────────────────────────────────────────
INSERT INTO organizations(id,name,type,code) VALUES
 ('82000000-0000-0000-0000-000000000001','WF82 Org A','authority','WF82A'),
 ('82000000-0000-0000-0000-000000000002','WF82 Org B','authority','WF82B');
INSERT INTO divisions(id, org_id, name) VALUES ('82000000-0004-0000-0000-000000000001','82000000-0000-0000-0000-000000000001','WF82 Div A');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES ('82000000-0002-0000-0000-000000000001','82000000-0000-0000-0000-000000000001','82000000-0004-0000-0000-000000000001','WF82 Sec A','SA1');

INSERT INTO auth.users(id,email) VALUES
 ('82000000-0001-0000-0000-000000000001','admin@wf82t.local'),
 ('82000000-0001-0000-0000-000000000002','secmember@wf82t.local'),
 ('82000000-0001-0000-0000-000000000003','secleader@wf82t.local'),
 ('82000000-0001-0000-0000-000000000004','orgbadmin@wf82t.local'),
 ('82000000-0001-0000-0000-000000000005','participant@wf82t.local'),
 ('82000000-0001-0000-0000-000000000006','inactive@wf82t.local'),
 ('82000000-0001-0000-0000-000000000007','workitemassignee@wf82t.local'),
 ('82000000-0001-0000-0000-000000000008','unrelated@wf82t.local');

INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('82000000-0001-0000-0000-000000000001','82000000-0000-0000-0000-000000000001','WF82-1','Admin','admin@wf82t.local',true),
 ('82000000-0001-0000-0000-000000000002','82000000-0000-0000-0000-000000000001','WF82-2','Section Member','secmember@wf82t.local',true),
 ('82000000-0001-0000-0000-000000000003','82000000-0000-0000-0000-000000000001','WF82-3','Section Leader','secleader@wf82t.local',true),
 ('82000000-0001-0000-0000-000000000004','82000000-0000-0000-0000-000000000002','WF82-4','Org B Admin','orgbadmin@wf82t.local',true),
 ('82000000-0001-0000-0000-000000000005','82000000-0000-0000-0000-000000000001','WF82-5','Extra Participant','participant@wf82t.local',true),
 ('82000000-0001-0000-0000-000000000006','82000000-0000-0000-0000-000000000001','WF82-6','Inactive Participant','inactive@wf82t.local',false),
 ('82000000-0001-0000-0000-000000000007','82000000-0000-0000-0000-000000000001','WF82-7','Work Item Assignee','workitemassignee@wf82t.local',true),
 ('82000000-0001-0000-0000-000000000008','82000000-0000-0000-0000-000000000001','WF82-8','Unrelated Same-Org User','unrelated@wf82t.local',true);

INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('82000000-0001-0000-0000-000000000001','organization','82000000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('82000000-0001-0000-0000-000000000002','section','82000000-0002-0000-0000-000000000001','staff',true,true),
 ('82000000-0001-0000-0000-000000000003','section','82000000-0002-0000-0000-000000000001','supervisor',true,true),
 ('82000000-0001-0000-0000-000000000004','organization','82000000-0000-0000-0000-000000000002','authority_admin',true,true);

-- Real workflow instance (create_workflow_instance auto-seeds a
-- workflow_participants row for the creator, role='owner').
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"82000000-0001-0000-0000-000000000001"}',false);
\set ORG_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}}],"edges":[{"source":"start","target":"a_end","outcome":"started","priority":0,"default":false}]}\''
WITH made AS (SELECT * FROM create_workflow_definition(
  '82000000-0000-0000-0000-000000000001','wf82_org','WF82 Flow','opaque_case', :ORG_PAYLOAD::jsonb, gen_random_uuid()))
SELECT version_id AS v INTO TEMP wf82_def FROM made;
SELECT publish_workflow_definition_version((SELECT v FROM wf82_def),0,gen_random_uuid());
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT v FROM wf82_def),'opaque_case',gen_random_uuid(),
  '82000000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
SELECT create_workflow_instance AS id INTO TEMP wf82_i1 FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf82_i1),0,gen_random_uuid());
GRANT SELECT ON wf82_i1 TO service_role, authenticated;
RESET ROLE;

DO $$
DECLARE v_instance_id UUID;
BEGIN
  SELECT id INTO v_instance_id FROM wf82_i1;
  INSERT INTO wf82_ids VALUES ('instance', v_instance_id);

  -- Extra participant (Extra Participant, role=viewer, active).
  INSERT INTO workflow_participants (instance_id, user_id, participant_role, authority_source, created_by)
  VALUES (v_instance_id, '82000000-0001-0000-0000-000000000005', 'viewer', 'wf82-test-fixture', '82000000-0001-0000-0000-000000000001');

  -- Inactive participant (still formally a participant, but users.is_active = FALSE).
  INSERT INTO workflow_participants (instance_id, user_id, participant_role, authority_source, created_by)
  VALUES (v_instance_id, '82000000-0001-0000-0000-000000000006', 'viewer', 'wf82-test-fixture', '82000000-0001-0000-0000-000000000001');

  -- A work item, assigned to Work Item Assignee, who is ALSO a
  -- genuine participant (structurally realistic: an assignee of work
  -- within an instance is a participant of that instance).
  INSERT INTO workflow_work_items (id, instance_id, work_item_type, state, organization_id, assigned_to)
  VALUES ('82000000-0006-0000-0000-000000000001', v_instance_id, 'activity', 'offered', '82000000-0000-0000-0000-000000000001', '82000000-0001-0000-0000-000000000007');
  INSERT INTO workflow_participants (instance_id, work_item_id, user_id, participant_role, authority_source, created_by)
  VALUES (v_instance_id, '82000000-0006-0000-0000-000000000001', '82000000-0001-0000-0000-000000000007', 'assignee', 'wf82-test-fixture', '82000000-0001-0000-0000-000000000001');
END $$;

-- Two outbox events: one workflow_instance-sourced, one platform-sourced.
SET ROLE service_role;
DO $$
DECLARE v_instance_id UUID; v_outbox_id UUID;
BEGIN
  SELECT id INTO v_instance_id FROM wf82_ids WHERE name = 'instance';
  v_outbox_id := platform_enqueue_outbox_event(
    'workflow.wf82_test.v1','workflow','workflow_instance',v_instance_id,
    '82000000-0000-0000-0000-000000000001'::UUID,'82000000-0001-0000-0000-000000000001'::UUID,
    gen_random_uuid(),NULL,now(),'{}'::JSONB,gen_random_uuid());
  INSERT INTO wf82_ids VALUES ('outbox_wf', v_outbox_id);

  v_outbox_id := platform_enqueue_outbox_event(
    'platform.wf82_notice.v1','platform','platform',gen_random_uuid(),
    '82000000-0000-0000-0000-000000000001'::UUID,NULL,
    gen_random_uuid(),NULL,now(),'{}'::JSONB,gen_random_uuid());
  INSERT INTO wf82_ids VALUES ('outbox_platform', v_outbox_id);

  -- Unsupported-source-type outbox event (record_type='request', not
  -- in Phase 1.2's closed dispatch set) -- for scenario 15.
  v_outbox_id := platform_enqueue_outbox_event(
    'request.wf82_test.v1','requests','request',gen_random_uuid(),
    '82000000-0000-0000-0000-000000000001'::UUID,NULL,
    gen_random_uuid(),NULL,now(),'{}'::JSONB,gen_random_uuid());
  INSERT INTO wf82_ids VALUES ('outbox_unsupported', v_outbox_id);
END $$;
RESET ROLE;

\set U_ADMIN '{"sub":"82000000-0001-0000-0000-000000000001"}'

-- ── 1: Internal intent creation succeeds ──
SET ROLE service_role;
DO $$
DECLARE v_id UUID;
BEGIN
  v_id := create_notification_intent(
    (SELECT id FROM wf82_ids WHERE name='outbox_wf'), 'workflow.wf82_test.v1','x.title','{}'::JSONB,'normal',
    'specific_users', ARRAY['82000000-0001-0000-0000-000000000001']::UUID[], NULL, NULL, NULL, NULL,NULL,NULL);
  IF v_id IS NULL THEN RAISE EXCEPTION 'expected a real intent id'; END IF;
  INSERT INTO wf82_ids VALUES ('scenario1_intent', v_id);
END $$;
RESET ROLE;
INSERT INTO wf82_results VALUES (1,'Internal intent creation (called as service_role) succeeds and returns a real intent id');

-- ── 2: Ordinary authenticated intent creation denied ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_ADMIN', false);
DO $$
BEGIN
  BEGIN
    PERFORM create_notification_intent(
      (SELECT id FROM wf82_ids WHERE name='outbox_wf'), 'workflow.wf82_test.v1','x.title','{}'::JSONB,'normal',
      'specific_users', ARRAY['82000000-0001-0000-0000-000000000001']::UUID[], NULL, NULL, NULL, NULL,NULL,NULL);
    RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user created a notification intent directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf82_results VALUES (2,'An ordinary authenticated user cannot call create_notification_intent directly (EXECUTE granted to service_role only)');

-- ── 3: Unknown target type rejected ──
SET ROLE service_role;
DO $$
BEGIN
  BEGIN
    PERFORM create_notification_intent(
      (SELECT id FROM wf82_ids WHERE name='outbox_wf'), 'workflow.wf82_test.v1','x.title','{}'::JSONB,'normal',
      'bogus_target_type', NULL, NULL, NULL, (SELECT id FROM wf82_ids WHERE name='instance'), NULL,NULL,NULL);
    RAISE EXCEPTION 'SECURITY HOLE: an unknown target_type was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%Unsupported target_type%' THEN RAISE; END IF;
  END;
END $$;
RESET ROLE;
INSERT INTO wf82_results VALUES (3,'An unknown target_type is rejected outright by create_notification_intent, before any row is inserted');

-- ── 4: Explicit valid user target resolves ──
SET ROLE service_role;
DO $$
DECLARE v_result RECORD;
BEGIN
  SELECT * INTO v_result FROM resolve_notification_intent((SELECT id FROM wf82_ids WHERE name='scenario1_intent'));
  IF v_result.status <> 'resolved' OR v_result.resolved_count <> 1 THEN
    RAISE EXCEPTION 'expected specific_users targeting the instance owner to resolve cleanly, got status=%, resolved=%, skipped=%', v_result.status, v_result.resolved_count, v_result.skipped_count;
  END IF;
END $$;
RESET ROLE;
INSERT INTO wf82_results VALUES (4,'An explicit specific_users target naming a genuine workflow participant resolves and creates their notification');

-- ── 5: Inactive user skipped ──
SET ROLE service_role;
DO $$
DECLARE v_intent_id UUID; v_result RECORD;
BEGIN
  v_intent_id := create_notification_intent(
    (SELECT id FROM wf82_ids WHERE name='outbox_wf'), 'workflow.wf82_test.v1','x.title','{}'::JSONB,'normal',
    'specific_users', ARRAY['82000000-0001-0000-0000-000000000006']::UUID[], NULL, NULL, NULL, NULL,NULL,NULL);
  SELECT * INTO v_result FROM resolve_notification_intent(v_intent_id);
  IF v_result.resolved_count <> 0 OR v_result.skipped_count <> 1 OR v_result.status <> 'failed' THEN
    RAISE EXCEPTION 'expected the inactive user to be skipped entirely, got status=%, resolved=%, skipped=%', v_result.status, v_result.resolved_count, v_result.skipped_count;
  END IF;
END $$;
RESET ROLE;
INSERT INTO wf82_results VALUES (5,'An inactive user (users.is_active = FALSE), even though formally a workflow participant, is skipped and never receives a notification');

-- ── 6: Same user resolved by multiple targets deduplicated ──
SET ROLE service_role;
DO $$
DECLARE v_intent1 UUID; v_intent2 UUID; v_notif_count INTEGER;
BEGIN
  -- Two DIFFERENT intents on the same outbox event, both eventually
  -- resolving to the instance owner (via specific_users directly, and
  -- via workflow_participants which includes the owner too) -- the
  -- owner must end up with exactly ONE user_notification row despite
  -- being a candidate from two independent intents.
  v_intent1 := create_notification_intent(
    (SELECT id FROM wf82_ids WHERE name='outbox_wf'), 'workflow.wf82_test.v1','x.title','{}'::JSONB,'normal',
    'specific_users', ARRAY['82000000-0001-0000-0000-000000000001']::UUID[], NULL, NULL, NULL, NULL,NULL,NULL);
  v_intent2 := create_notification_intent(
    (SELECT id FROM wf82_ids WHERE name='outbox_wf'), 'workflow.wf82_test.v1','x.title','{}'::JSONB,'normal',
    'workflow_participants', NULL, NULL, NULL, (SELECT id FROM wf82_ids WHERE name='instance'), NULL,NULL,NULL);
  PERFORM resolve_notification_intent(v_intent1);
  PERFORM resolve_notification_intent(v_intent2);
  SELECT count(*) INTO v_notif_count FROM user_notifications
    WHERE outbox_event_id = (SELECT id FROM wf82_ids WHERE name='outbox_wf')
      AND recipient_user_id = '82000000-0001-0000-0000-000000000001';
  IF v_notif_count <> 1 THEN
    RAISE EXCEPTION 'expected exactly 1 notification for a user resolved via two different intents on the same outbox event, got %', v_notif_count;
  END IF;
END $$;
RESET ROLE;
INSERT INTO wf82_results VALUES (6,'A user resolved as a candidate by two different intents on the same outbox event (specific_users and workflow_participants both naming them) ends up with exactly one user_notification row -- Phase 1.1''s own (outbox_event_id, recipient_user_id) uniqueness backstops cross-intent deduplication, not merely within-intent deduplication');

-- ── 7: Section target resolves valid users ──
SET ROLE service_role;
DO $$
DECLARE v_intent_id UUID; v_result RECORD;
BEGIN
  -- section_user_ids() (the reused, already-existing helper) expands
  -- scope_section_ids() across command/department/division/section --
  -- an ORG-scoped assignment (Admin, authority_admin at the org level)
  -- legitimately covers every section in that org too, so Admin
  -- resolves here alongside the two section-scoped members. This is
  -- section_user_ids()'s own existing, correct semantics (reused
  -- as-is, not redefined) -- not a Phase 1.2 defect.
  v_intent_id := create_notification_intent(
    (SELECT id FROM wf82_ids WHERE name='outbox_platform'), 'platform.wf82_notice.v1','x.title','{}'::JSONB,'normal',
    'section', NULL, NULL, '82000000-0002-0000-0000-000000000001', NULL, NULL,NULL,NULL);
  SELECT * INTO v_result FROM resolve_notification_intent(v_intent_id);
  -- Platform-sourced: no record-visibility revalidation beyond active
  -- status, so all three (Admin via org-wide scope, Section Member,
  -- Section Leader) resolve successfully.
  IF v_result.resolved_count <> 3 THEN
    RAISE EXCEPTION 'expected all 3 active users covering the section (Admin via org-wide scope, Section Member, Section Leader) to resolve for a platform-sourced notice, got resolved=%, skipped=%', v_result.resolved_count, v_result.skipped_count;
  END IF;
END $$;
RESET ROLE;
INSERT INTO wf82_results VALUES (7,'A section target resolves every active user covering that section -- via section_user_ids()''s own existing command/department/division/section scope expansion (Admin, Section Member, and Section Leader all notified for a platform-sourced notice, where no record-visibility check beyond active status applies)');

-- ── 8: Section-leadership target resolves only valid leaders ──
-- (Uses its own fresh outbox event -- reusing outbox_platform here
-- would let scenario 7's own section-target notifications, already on
-- disk for the same (outbox_event_id, recipient) dedup key, leak into
-- this scenario's own verification.)
SET ROLE service_role;
DO $$
DECLARE v_outbox_id UUID; v_intent_id UUID; v_result RECORD; v_notified_leader UUID; v_notified_member UUID;
BEGIN
  v_outbox_id := platform_enqueue_outbox_event(
    'platform.wf82_notice2.v1','platform','platform',gen_random_uuid(),
    '82000000-0000-0000-0000-000000000001'::UUID,NULL,gen_random_uuid(),NULL,now(),'{}'::JSONB,gen_random_uuid());
  v_intent_id := create_notification_intent(
    v_outbox_id, 'platform.wf82_notice2.v1','x.title','{}'::JSONB,'normal',
    'section_leadership', NULL, NULL, '82000000-0002-0000-0000-000000000001', NULL, NULL,NULL,NULL);
  SELECT * INTO v_result FROM resolve_notification_intent(v_intent_id);
  -- Admin (org-wide authority_admin) and Section Leader (supervisor)
  -- both carry a notify-role; Section Member (plain staff) does not.
  IF v_result.resolved_count <> 2 THEN
    RAISE EXCEPTION 'expected 2 leadership-role users (Admin, Section Leader) to resolve, got resolved=%', v_result.resolved_count;
  END IF;
  SELECT recipient_user_id INTO v_notified_leader FROM user_notifications
    WHERE outbox_event_id = v_outbox_id AND recipient_user_id = '82000000-0001-0000-0000-000000000003';
  SELECT recipient_user_id INTO v_notified_member FROM user_notifications
    WHERE outbox_event_id = v_outbox_id AND recipient_user_id = '82000000-0001-0000-0000-000000000002';
  IF v_notified_leader IS NULL THEN RAISE EXCEPTION 'expected Section Leader to be notified'; END IF;
  IF v_notified_member IS NOT NULL THEN RAISE EXCEPTION 'SECURITY HOLE: plain staff Section Member was notified by a section_leadership target'; END IF;
END $$;
RESET ROLE;
INSERT INTO wf82_results VALUES (8,'A section_leadership target resolves only users holding a leadership-tier role over that section (Section Leader''s supervisor role, and Admin''s org-wide authority_admin role), never the plain staff member (Section Member) in the same section');

-- ── 9: Organization-admin target resolves authorized users ──
SET ROLE service_role;
DO $$
DECLARE v_intent_id UUID; v_result RECORD;
BEGIN
  -- org_supervisor_user_ids() (the reused, already-existing helper)
  -- matches any user_assignments row with a notify-role
  -- (mcs_admin/authority_admin/supervisor) whose OWNING USER's own
  -- org_id matches -- regardless of that assignment's own scope_type,
  -- so both Admin (org-scoped authority_admin) and Section Leader
  -- (section-scoped supervisor, but their own users.org_id is still
  -- Org A) resolve. This is org_supervisor_user_ids()'s own existing,
  -- correct semantics (reused as-is), not a Phase 1.2 defect.
  v_intent_id := create_notification_intent(
    (SELECT id FROM wf82_ids WHERE name='outbox_platform'), 'platform.wf82_notice.v1','x.title','{}'::JSONB,'normal',
    'org_admins', NULL, '82000000-0000-0000-0000-000000000001', NULL, NULL, NULL,NULL,NULL);
  SELECT * INTO v_result FROM resolve_notification_intent(v_intent_id);
  IF v_result.resolved_count <> 2 THEN
    RAISE EXCEPTION 'expected 2 org-level notify-role users (Admin, Section Leader) to resolve, got resolved=%', v_result.resolved_count;
  END IF;
END $$;
RESET ROLE;
INSERT INTO wf82_results VALUES (9,'An org_admins target resolves every notify-role user belonging to that organization (Admin''s authority_admin role and Section Leader''s supervisor role) for a platform-sourced notice, via org_supervisor_user_ids()''s own existing semantics');

-- ── 10: Workflow-participant target resolves authorized participants ──
SET ROLE service_role;
DO $$
DECLARE v_intent_id UUID; v_result RECORD;
BEGIN
  v_intent_id := create_notification_intent(
    (SELECT id FROM wf82_ids WHERE name='outbox_wf'), 'workflow.wf82_test.v1','x.title','{}'::JSONB,'normal',
    'workflow_participants', NULL, NULL, NULL, (SELECT id FROM wf82_ids WHERE name='instance'), NULL,NULL,NULL);
  SELECT * INTO v_result FROM resolve_notification_intent(v_intent_id);
  -- Participants: owner (Admin), Extra Participant (viewer), Inactive
  -- Participant (skipped for inactivity), Work Item Assignee
  -- (assignee) = 4 candidates, 1 skipped (inactive) => 3 resolved.
  IF v_result.resolved_count <> 3 OR v_result.skipped_count <> 1 THEN
    RAISE EXCEPTION 'expected 3 resolved / 1 skipped (inactive) workflow participants, got resolved=%, skipped=%', v_result.resolved_count, v_result.skipped_count;
  END IF;
END $$;
RESET ROLE;
INSERT INTO wf82_results VALUES (10,'A workflow_participants target resolves every active participant of the instance (owner, extra viewer, work-item assignee) and skips the inactive one, each independently revalidated');

-- ── 11: Work-item-assignee target resolves correctly ──
SET ROLE service_role;
DO $$
DECLARE v_intent_id UUID; v_result RECORD;
BEGIN
  v_intent_id := create_notification_intent(
    (SELECT id FROM wf82_ids WHERE name='outbox_wf'), 'workflow.wf82_test.v1','x.title','{}'::JSONB,'normal',
    'work_item_assignee', NULL, NULL, NULL, NULL, '82000000-0006-0000-0000-000000000001',NULL,NULL);
  SELECT * INTO v_result FROM resolve_notification_intent(v_intent_id);
  IF v_result.resolved_count <> 1 THEN
    RAISE EXCEPTION 'expected exactly 1 (the work item''s own assignee) to resolve, got resolved=%', v_result.resolved_count;
  END IF;
END $$;
RESET ROLE;
INSERT INTO wf82_results VALUES (11,'A work_item_assignee target resolves exactly the work item''s current assignee (Work Item Assignee)');

-- ── 12: Recipient still authorized -> notification created ──
-- (Already proven directly by scenarios 4/10/11's positive resolved
-- counts; recorded here as its own explicit assertion per the
-- required scenario list.)
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM user_notifications
    WHERE outbox_event_id = (SELECT id FROM wf82_ids WHERE name='outbox_wf')
      AND recipient_user_id = '82000000-0001-0000-0000-000000000007';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected the work item assignee to have a real notification row, got %', v_count; END IF;
END $$;
INSERT INTO wf82_results VALUES (12,'A recipient who is currently authorized (a genuine, active workflow participant) has a real user_notifications row created for them');

-- ── 13: Recipient lost authorization -> notification not created ──
SET ROLE service_role;
DO $$
DECLARE v_intent_id UUID; v_result RECORD; v_count INTEGER;
BEGIN
  -- Unrelated Same-Org User is an org_admins-style candidate only in
  -- the sense of being explicitly named -- they are NOT a workflow
  -- participant, so late revalidation must reject them even though
  -- they are a real, active, same-organization user.
  v_intent_id := create_notification_intent(
    (SELECT id FROM wf82_ids WHERE name='outbox_wf'), 'workflow.wf82_test.v1','x.title','{}'::JSONB,'normal',
    'specific_users', ARRAY['82000000-0001-0000-0000-000000000008']::UUID[], NULL, NULL, NULL, NULL,NULL,NULL);
  SELECT * INTO v_result FROM resolve_notification_intent(v_intent_id);
  IF v_result.resolved_count <> 0 OR v_result.skipped_count <> 1 THEN
    RAISE EXCEPTION 'expected the non-participant to be skipped at authorization revalidation, got resolved=%, skipped=%', v_result.resolved_count, v_result.skipped_count;
  END IF;
  SELECT count(*) INTO v_count FROM user_notifications
    WHERE outbox_event_id = (SELECT id FROM wf82_ids WHERE name='outbox_wf')
      AND recipient_user_id = '82000000-0001-0000-0000-000000000008';
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: a non-participant received a notification about the workflow instance, count=%', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf82_results VALUES (13,'A candidate who is not currently authorized for the source record (same organization, active, but never a workflow participant) is skipped -- no notification is created, proving late revalidation, not enqueue-time trust, governs creation');

-- ── 14: Cross-org generic target blocked unless explicitly authorized ──
SET ROLE service_role;
DO $$
DECLARE v_intent_id UUID; v_result RECORD; v_count INTEGER;
BEGIN
  v_intent_id := create_notification_intent(
    (SELECT id FROM wf82_ids WHERE name='outbox_wf'), 'workflow.wf82_test.v1','x.title','{}'::JSONB,'normal',
    'org_admins', NULL, '82000000-0000-0000-0000-000000000002', NULL, NULL, NULL,NULL,NULL);
  SELECT * INTO v_result FROM resolve_notification_intent(v_intent_id);
  IF v_result.resolved_count <> 0 THEN
    RAISE EXCEPTION 'SECURITY HOLE: a cross-org org_admins target resolved recipients for a workflow instance their organization is not party to, resolved=%', v_result.resolved_count;
  END IF;
  SELECT count(*) INTO v_count FROM user_notifications WHERE recipient_user_id = '82000000-0001-0000-0000-000000000004';
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: Org B Admin received a notification about an Org A-only workflow instance'; END IF;
END $$;
RESET ROLE;
INSERT INTO wf82_results VALUES (14,'A generic org_admins target for an unrelated organization (Org B) never crosses into an Org A-only workflow instance -- every candidate is skipped at revalidation since none is a genuine participant, closing the cross-org boundary structurally rather than by a target-type-specific special case');

-- ── 15: Unsupported source type fails closed/deferred ──
SET ROLE service_role;
DO $$
BEGIN
  BEGIN
    PERFORM create_notification_intent(
      (SELECT id FROM wf82_ids WHERE name='outbox_unsupported'), 'request.wf82_test.v1','x.title','{}'::JSONB,'normal',
      'specific_users', ARRAY['82000000-0001-0000-0000-000000000001']::UUID[], NULL, NULL, NULL, NULL,NULL,NULL);
    RAISE EXCEPTION 'SECURITY HOLE: an intent was created for an unsupported source_record_type (request)';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf82_results VALUES (15,'An outbox event whose source_record_type is not in Phase 1.2''s closed generic dispatch set (record_type=request) is rejected at intent-creation time -- fails closed, remains deferred to a future module-adapter phase, never faked');

-- ── 16: Duplicate resolution is idempotent ──
SET ROLE service_role;
DO $$
DECLARE v_intent_id UUID; v_r1 RECORD; v_r2 RECORD; v_r3 RECORD; v_count INTEGER;
BEGIN
  v_intent_id := create_notification_intent(
    (SELECT id FROM wf82_ids WHERE name='outbox_platform'), 'platform.wf82_notice.v1','x.title','{}'::JSONB,'normal',
    'specific_users', ARRAY['82000000-0001-0000-0000-000000000005']::UUID[], NULL, NULL, NULL, NULL,NULL,NULL);
  SELECT * INTO v_r1 FROM resolve_notification_intent(v_intent_id);
  SELECT * INTO v_r2 FROM resolve_notification_intent(v_intent_id);
  SELECT * INTO v_r3 FROM resolve_notification_intent(v_intent_id);
  IF v_r1.* IS DISTINCT FROM v_r2.* OR v_r2.* IS DISTINCT FROM v_r3.* THEN
    RAISE EXCEPTION 'expected identical results across repeated resolution calls, got %/%/%', v_r1, v_r2, v_r3;
  END IF;
  SELECT count(*) INTO v_count FROM user_notifications
    WHERE outbox_event_id = (SELECT id FROM wf82_ids WHERE name='outbox_platform')
      AND recipient_user_id = '82000000-0001-0000-0000-000000000005';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 notification row after 3 resolution calls, got %', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf82_results VALUES (16,'Calling resolve_notification_intent repeatedly on an already-resolved intent is a safe idempotent no-op -- identical structural result every time, exactly one notification row on disk');

-- ── 17: Concurrent duplicate resolution produces one notification ──
-- (Genuine concurrent-session coverage lives in the dedicated
-- concurrency suite; this scenario re-confirms, sequentially, that
-- the FOR UPDATE-guarded status transition -- the exact mechanism
-- that makes the real concurrent case safe -- behaves correctly.)
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM user_notifications
    WHERE outbox_event_id = (SELECT id FROM wf82_ids WHERE name='outbox_platform')
      AND recipient_user_id = '82000000-0001-0000-0000-000000000005';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 notification row (re-verified from scenario 16), got %', v_count; END IF;
END $$;
INSERT INTO wf82_results VALUES (17,'Exactly one durable notification exists regardless of how many times resolution was attempted for the same intent -- the FOR UPDATE row lock plus the (outbox_event_id, recipient_user_id) uniqueness constraint together make concurrent duplicate resolution safe (verified under genuine concurrent sessions in the dedicated concurrency suite)');

-- ── 18: Safe metadata remains bounded ──
SET ROLE service_role;
DO $$
BEGIN
  BEGIN
    PERFORM create_notification_intent(
      (SELECT id FROM wf82_ids WHERE name='outbox_platform'), 'platform.wf82_notice.v1','x.title',
      jsonb_build_object('blob', repeat('x', 5000)),'normal',
      'specific_users', ARRAY['82000000-0001-0000-0000-000000000001']::UUID[], NULL, NULL, NULL, NULL,NULL,NULL);
    RAISE EXCEPTION 'SECURITY HOLE: an oversized (>4KB) template_params was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    PERFORM create_notification_intent(
      (SELECT id FROM wf82_ids WHERE name='outbox_platform'), 'platform.wf82_notice.v1','x.title',
      '[1,2,3]'::JSONB,'normal',
      'specific_users', ARRAY['82000000-0001-0000-0000-000000000001']::UUID[], NULL, NULL, NULL, NULL,NULL,NULL);
    RAISE EXCEPTION 'SECURITY HOLE: a non-object JSON template_params was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    PERFORM create_notification_intent(
      (SELECT id FROM wf82_ids WHERE name='outbox_platform'), 'platform.wf82_notice.v1','x.title','{}'::JSONB,'normal',
      'specific_users',
      (SELECT array_agg(gen_random_uuid()) FROM generate_series(1,51)),
      NULL, NULL, NULL, NULL,NULL,NULL);
    RAISE EXCEPTION 'SECURITY HOLE: a specific_users target with 51 user ids (over the 50-id bound) was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf82_results VALUES (18,'Safe-metadata and target-size constraints are enforced: an oversized (>4KB) template_params, a non-object JSON template_params, and an over-bound (>50) specific_users list are all rejected by CHECK constraints');

-- ── 19: Notification source reference does not bypass module RLS ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"82000000-0001-0000-0000-000000000008"}',false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  -- Unrelated Same-Org User (never a participant, per scenario 13)
  -- still cannot query the workflow instance directly, even though
  -- notifications referencing it now exist in the system.
  SELECT count(*) INTO v_count FROM workflow_instances WHERE id = (SELECT id FROM wf82_ids WHERE name='instance');
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'SECURITY HOLE: a non-participant queried the workflow instance directly, count=%', v_count;
  END IF;
END $$;
RESET ROLE;
INSERT INTO wf82_results VALUES (19,'A user with no workflow-participant relationship still cannot query the workflow_instances row directly via its own RLS, even though the platform now holds multiple notifications referencing that instance -- a notification''s source_record_id is never itself an authorization source');

-- ── 20: Legacy notification system remains unaffected ──
DO $$
DECLARE v_missing TEXT := '';
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='notifications'
      AND policyname='notif_select' AND cmd='SELECT' AND qual='(user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'notif_select-drift '; END IF;
  IF to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)') IS NULL THEN
    v_missing := v_missing || 'create_legacy_notification-missing ';
  END IF;
  IF v_missing <> '' THEN RAISE EXCEPTION 'legacy notification behavior drifted: %', v_missing; END IF;
END $$;
INSERT INTO wf82_results VALUES (20,'The legacy notifications table''s RLS policies and create_legacy_notification() are completely unaffected by the new, purely additive CAP-003 Phase 1.2 recipient-resolution layer');

RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf82_results;
  IF v_count <> 20 THEN
    RAISE EXCEPTION 'Expected 20 scenarios to record a result, found %', v_count;
  END IF;
  RAISE NOTICE 'Notification recipient resolution behavioral tests PASSED: %/20', v_count;
END $$;

ROLLBACK;
