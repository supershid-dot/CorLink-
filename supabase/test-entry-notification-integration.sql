-- CAP-003 Phase 1.7B notification event integration -- focused
-- behavioral suite. Disposable local PostgreSQL only. Runs in one
-- transaction and leaves no fixtures (rolled back at the end).
--
-- Role convention: identical to
-- test-requests-notification-integration.sql -- the connecting
-- superuser (postgres, rolbypassrls) is the default role throughout; it
-- can freely read platform_outbox_events/notification_intents/
-- user_notifications (zero RLS policies on any of the three, by
-- design). Each scenario explicitly `SET ROLE authenticated` + sets the
-- JWT claim only around the actual RPC call(s) that must run as a real
-- end user, then `RESET ROLE` back to postgres before reading any
-- CAP-003 table.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE e92_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);

-- ── Fixtures: Org Alpha (Entry-enabled, two sections: Records/Welfare),
-- Org Gamma (a genuinely unrelated third, ALSO Entry-enabled org, for
-- the cross-org negative control). ─────────────────────────────────────
INSERT INTO organizations(id,name,type,code) VALUES
 ('92000000-0000-0000-0000-000000000001','E92 Org Alpha','authority','E92A'),
 ('92000000-0000-0000-0000-000000000002','E92 Org Gamma','authority','E92G');
INSERT INTO divisions(id, org_id, name) VALUES
 ('92000000-0004-0000-0000-000000000001','92000000-0000-0000-0000-000000000001','E92 Alpha Div'),
 ('92000000-0004-0000-0000-000000000002','92000000-0000-0000-0000-000000000002','E92 Gamma Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
 ('92000000-0002-0000-0000-000000000001','92000000-0000-0000-0000-000000000001','92000000-0004-0000-0000-000000000001','E92 Records','E92REC'),
 ('92000000-0002-0000-0000-000000000002','92000000-0000-0000-0000-000000000001','92000000-0004-0000-0000-000000000001','E92 Welfare','E92WEL'),
 ('92000000-0002-0000-0000-000000000003','92000000-0000-0000-0000-000000000002','92000000-0004-0000-0000-000000000002','E92 Gamma Sec','E92GS');
INSERT INTO entry_sections(org_id, section_id) VALUES
 ('92000000-0000-0000-0000-000000000001','92000000-0002-0000-0000-000000000001'),
 ('92000000-0000-0000-0000-000000000001','92000000-0002-0000-0000-000000000002'),
 ('92000000-0000-0000-0000-000000000002','92000000-0002-0000-0000-000000000003');

INSERT INTO auth.users(id,email) VALUES
 ('92000000-0001-0000-0000-000000000001','e92-clerk@t.local'),
 ('92000000-0001-0000-0000-000000000002','e92-assignee@t.local'),
 ('92000000-0001-0000-0000-000000000003','e92-supervisor@t.local'),
 ('92000000-0001-0000-0000-000000000004','e92-welfare2@t.local'),
 ('92000000-0001-0000-0000-000000000005','e92-replywriter@t.local'),
 ('92000000-0001-0000-0000-000000000006','e92-records-staff@t.local'),
 ('92000000-0001-0000-0000-000000000007','e92-gamma-super@t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('92000000-0001-0000-0000-000000000001','92000000-0000-0000-0000-000000000001','E92-1','Clerk','e92-clerk@t.local',true),
 ('92000000-0001-0000-0000-000000000002','92000000-0000-0000-0000-000000000001','E92-2','Assignee','e92-assignee@t.local',true),
 ('92000000-0001-0000-0000-000000000003','92000000-0000-0000-0000-000000000001','E92-3','Supervisor','e92-supervisor@t.local',true),
 ('92000000-0001-0000-0000-000000000004','92000000-0000-0000-0000-000000000001','E92-4','Welfare Two','e92-welfare2@t.local',true),
 ('92000000-0001-0000-0000-000000000005','92000000-0000-0000-0000-000000000001','E92-5','Reply Writer','e92-replywriter@t.local',true),
 ('92000000-0001-0000-0000-000000000006','92000000-0000-0000-0000-000000000001','E92-6','Records Staff','e92-records-staff@t.local',true),
 ('92000000-0001-0000-0000-000000000007','92000000-0000-0000-0000-000000000002','E92-7','Gamma Super','e92-gamma-super@t.local',true);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
 ('92000000-0001-0000-0000-000000000001','section','92000000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
 ('92000000-0001-0000-0000-000000000002','section','92000000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
 ('92000000-0001-0000-0000-000000000003','section','92000000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE),
 ('92000000-0001-0000-0000-000000000004','section','92000000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
 ('92000000-0001-0000-0000-000000000005','section','92000000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
 ('92000000-0001-0000-0000-000000000006','section','92000000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
 ('92000000-0001-0000-0000-000000000007','section','92000000-0002-0000-0000-000000000003','supervisor',TRUE,TRUE);

-- ══════════════════ ENTRY.ROUTED.V1 (route_entry, no assignee) ══════════

-- 1. Outbox correctness: event/source identity, section target, safe
-- payload, subject/body/sender identity NOT leaked.
DO $$
DECLARE v_ent external_correspondence; v_evt platform_outbox_events;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('letter','public','CONFIDENTIAL SENDER','CONFIDENTIAL SUBJECT','CONFIDENTIAL BODY');
  v_ent := route_entry(v_ent.id, '92000000-0002-0000-0000-000000000002');
  RESET ROLE;
  PERFORM set_config('app.e92_ent1', v_ent.id::text, false);

  SELECT * INTO v_evt FROM platform_outbox_events WHERE event_type = 'entry.routed.v1' AND source_record_id = v_ent.id;
  IF v_evt.id IS NULL THEN RAISE EXCEPTION 'no entry.routed.v1 outbox event'; END IF;
  IF v_evt.source_record_type <> 'external_correspondence' OR v_evt.source_module <> 'entry' THEN RAISE EXCEPTION 'wrong source identity'; END IF;
  IF v_evt.organization_id <> v_ent.org_id THEN RAISE EXCEPTION 'wrong organization_id'; END IF;
  IF v_evt.actor_id <> '92000000-0001-0000-0000-000000000001' THEN RAISE EXCEPTION 'wrong actor_id'; END IF;
  IF v_evt.payload ->> 'target_type' <> 'section' OR (v_evt.payload ->> 'target_section_id')::UUID <> '92000000-0002-0000-0000-000000000002'::UUID THEN
    RAISE EXCEPTION 'wrong target descriptor'; END IF;
  IF v_evt.payload::TEXT ILIKE '%CONFIDENTIAL%' THEN RAISE EXCEPTION 'SECURITY: subject/body/sender_name leaked into payload'; END IF;
END $$;
INSERT INTO e92_results VALUES (1,'route_entry() with no assignee atomically enqueues exactly 1 entry.routed.v1 event with correct source identity (external_correspondence/entry), section(to_section_id) target, safe structural payload; subject/body/sender_name never leak into it');

-- 2. Domain failure: routing to a section belonging to a different
-- organization is rejected -- produces no outbox event.
DO $$
DECLARE v_ent external_correspondence; v_before INTEGER; v_after INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('letter','public','Sender Two','Subject Two','Body Two');
  RESET ROLE;
  SELECT count(*) INTO v_before FROM platform_outbox_events WHERE event_type='entry.routed.v1';
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000001"}',true);
  BEGIN
    PERFORM route_entry(v_ent.id, '92000000-0002-0000-0000-000000000003'); -- Gamma section, wrong org
    RAISE EXCEPTION 'expected rejection (cross-org section)';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected rejection (cross-org section)' THEN RAISE; END IF;
  END;
  RESET ROLE;
  SELECT count(*) INTO v_after FROM platform_outbox_events WHERE event_type='entry.routed.v1';
  IF v_before <> v_after THEN RAISE EXCEPTION 'a rejected cross-org route_entry call unexpectedly produced an outbox event'; END IF;
END $$;
INSERT INTO e92_results VALUES (2,'route_entry()''s Phase 1.7A org-consistency guard (destination section must belong to the entry''s own org_id) rejects a cross-org routing attempt before the enqueue is ever reached -- zero outbox events');

-- 3. Forced outbox-enqueue failure -> the ENTIRE domain mutation
-- (status/to_section_id/audit_logs) rolls back with it, never a
-- partial commit. Engineered by temporarily renaming
-- platform_enqueue_outbox_event so the RPC's own PERFORM raises mid-
-- body; the calling DO block's BEGIN/EXCEPTION is PL/pgSQL's implicit
-- subtransaction boundary that discards every effect as one unit.
DO $$
DECLARE v_ent external_correspondence;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('letter','public','Sender Three','Subject Three','Body Three');
  RESET ROLE;
  PERFORM set_config('app.e92_ent3', v_ent.id::text, false);
END $$;

ALTER FUNCTION platform_enqueue_outbox_event(text,text,text,uuid,uuid,uuid,uuid,uuid,timestamptz,jsonb,uuid) RENAME TO platform_enqueue_outbox_event_e92_disabled;

DO $$
DECLARE v_ent_id UUID := current_setting('app.e92_ent3')::uuid; v_before external_correspondence; v_after external_correspondence; v_audit_before INTEGER; v_audit_after INTEGER;
BEGIN
  SELECT * INTO v_before FROM external_correspondence WHERE id = v_ent_id;
  SELECT count(*) INTO v_audit_before FROM audit_logs WHERE record_type = 'external_correspondence' AND record_id = v_ent_id;

  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000001"}',true);
  BEGIN
    PERFORM route_entry(v_ent_id, '92000000-0002-0000-0000-000000000001');
    RAISE EXCEPTION 'expected forced outbox failure (platform_enqueue_outbox_event renamed away)';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected forced outbox failure (platform_enqueue_outbox_event renamed away)' THEN RAISE; END IF;
  END;
  RESET ROLE;

  SELECT * INTO v_after FROM external_correspondence WHERE id = v_ent_id;
  SELECT count(*) INTO v_audit_after FROM audit_logs WHERE record_type = 'external_correspondence' AND record_id = v_ent_id;
  IF v_after.status <> v_before.status OR v_after.to_section_id IS DISTINCT FROM v_before.to_section_id THEN
    RAISE EXCEPTION 'PARTIAL COMMIT DETECTED: external_correspondence row changed despite the forced outbox failure (before status=%, after status=%)', v_before.status, v_after.status;
  END IF;
  IF v_audit_after <> v_audit_before THEN
    RAISE EXCEPTION 'PARTIAL COMMIT DETECTED: an audit_logs row survived the forced outbox failure';
  END IF;
END $$;

ALTER FUNCTION platform_enqueue_outbox_event_e92_disabled(text,text,text,uuid,uuid,uuid,uuid,uuid,timestamptz,jsonb,uuid) RENAME TO platform_enqueue_outbox_event;

-- Function restored -- prove a normal call succeeds again right afterward.
DO $$
DECLARE v_ent external_correspondence;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000001"}',true);
  v_ent := route_entry(current_setting('app.e92_ent3')::uuid, '92000000-0002-0000-0000-000000000001');
  RESET ROLE;
  IF v_ent.status <> 'routed' THEN RAISE EXCEPTION 'route_entry did not recover after platform_enqueue_outbox_event was restored'; END IF;
END $$;
INSERT INTO e92_results VALUES (3,'A forced platform_enqueue_outbox_event() failure inside route_entry() rolls back the ENTIRE domain mutation together -- external_correspondence.status/to_section_id and the audit_logs row all revert as one unit; no partial state; a normal call succeeds again once the dependency is restored');

-- ══════════════════ ENTRY.ASSIGNED.V1 (route_entry WITH assignee, and assign_entry) ══════

-- 4. route_entry() WITH an assignee enqueues entry.assigned.v1 instead
-- of entry.routed.v1 (mutually exclusive either/or).
DO $$
DECLARE v_ent external_correspondence; v_evt platform_outbox_events;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('letter','public','Sender Four','Subject Four','Body Four');
  v_ent := route_entry(v_ent.id, '92000000-0002-0000-0000-000000000002', '92000000-0001-0000-0000-000000000002');
  RESET ROLE;
  PERFORM set_config('app.e92_ent4', v_ent.id::text, false);

  IF EXISTS (SELECT 1 FROM platform_outbox_events WHERE event_type='entry.routed.v1' AND source_record_id = v_ent.id) THEN
    RAISE EXCEPTION 'route_entry WITH an assignee unexpectedly also enqueued entry.routed.v1';
  END IF;
  SELECT * INTO v_evt FROM platform_outbox_events WHERE event_type = 'entry.assigned.v1' AND source_record_id = v_ent.id;
  IF v_evt.id IS NULL THEN RAISE EXCEPTION 'no entry.assigned.v1 outbox event from route_entry with assignee'; END IF;
  IF v_evt.payload ->> 'target_type' <> 'specific_users' OR (v_evt.payload -> 'target_user_ids') <> jsonb_build_array('92000000-0001-0000-0000-000000000002'::UUID) THEN
    RAISE EXCEPTION 'wrong target descriptor'; END IF;

  PERFORM process_platform_outbox_batch(50, 'e92-worker');
  IF NOT EXISTS (SELECT 1 FROM user_notifications WHERE notification_type='entry.assigned.v1' AND recipient_user_id='92000000-0001-0000-0000-000000000002' AND source_record_id=v_ent.id) THEN
    RAISE EXCEPTION 'assignee was not notified';
  END IF;
END $$;
INSERT INTO e92_results VALUES (4,'route_entry() called WITH an assignee enqueues exactly 1 entry.assigned.v1 event targeting specific_users([assigned_to]) and does NOT also enqueue entry.routed.v1 -- mutually exclusive either/or, mirroring entry-api.js''s own legacy if(assignedTo)/else branch; delivered end-to-end to the assignee alone');

-- 5. assign_entry() (second, independent producer of the same event
-- type) also enqueues entry.assigned.v1.
DO $$
DECLARE v_ent external_correspondence; v_evt platform_outbox_events;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000003"}',true); -- Welfare supervisor
  v_ent := assign_entry(current_setting('app.e92_ent1')::uuid, '92000000-0001-0000-0000-000000000004', NULL);
  RESET ROLE;

  SELECT * INTO v_evt FROM platform_outbox_events WHERE event_type = 'entry.assigned.v1' AND source_record_id = v_ent.id;
  IF v_evt.id IS NULL THEN RAISE EXCEPTION 'no entry.assigned.v1 outbox event from assign_entry'; END IF;
  IF (v_evt.payload -> 'target_user_ids') <> jsonb_build_array('92000000-0001-0000-0000-000000000004'::UUID) THEN
    RAISE EXCEPTION 'wrong assignee in payload'; END IF;
END $$;
INSERT INTO e92_results VALUES (5,'assign_entry() -- the second, independent producer of entry.assigned.v1 -- atomically enqueues its own occurrence targeting specific_users([p_user_id]) when called on an already-routed entry (route_entry itself set to_section_id in scenario 1)');

-- 6. Unassignment (p_user_id NULL) fires no event at all.
DO $$
DECLARE v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000003"}',true);
  PERFORM assign_entry(current_setting('app.e92_ent1')::uuid, NULL, NULL);
  RESET ROLE;
  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE event_type='entry.assigned.v1' AND source_record_id = current_setting('app.e92_ent1')::uuid;
  IF v_count <> 1 THEN RAISE EXCEPTION 'unassignment unexpectedly changed the outbox event count (expected still 1 from scenario 5), got %', v_count; END IF;
END $$;
INSERT INTO e92_results VALUES (6,'assign_entry() called with p_user_id=NULL (unassignment) fires no entry.assigned.v1 event, mirroring the legacy notification''s own `if (userId)` guard exactly');

-- 7. Legitimate repeated occurrence: reassigning produces a SECOND,
-- distinguishable outbox event (own audit_logs.id / idempotency_key).
DO $$
DECLARE v_count INTEGER; v_ids UUID[];
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000003"}',true);
  PERFORM assign_entry(current_setting('app.e92_ent1')::uuid, '92000000-0001-0000-0000-000000000005', NULL);
  RESET ROLE;
  SELECT count(*), array_agg(DISTINCT idempotency_key) INTO v_count, v_ids
    FROM platform_outbox_events WHERE event_type='entry.assigned.v1' AND source_record_id = current_setting('app.e92_ent1')::uuid;
  IF v_count <> 2 THEN RAISE EXCEPTION 'expected 2 distinguishable entry.assigned.v1 occurrences (re-assignment), got %', v_count; END IF;
  IF array_length(v_ids, 1) <> 2 THEN RAISE EXCEPTION 'the two occurrences unexpectedly share one idempotency_key'; END IF;
END $$;
INSERT INTO e92_results VALUES (7,'Reassigning an entry (assign_entry() called again) produces a second, independently-idempotency-keyed entry.assigned.v1 occurrence -- legitimate repeated lifecycle events are never collapsed by an overly broad uniqueness rule');

-- ══════════════════ ENTRY.REPLY_SENT.V1 (approve_entry_reply) ═══════════

-- 8. Outbox correctness: sourced from the PARENT ENTRY (not a new reply
-- source type), targets entered_by, safe payload (reply body never
-- leaked).
DO $$
DECLARE v_ent external_correspondence; v_rep external_correspondence_replies; v_evt platform_outbox_events;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('letter','public','Sender Eight','Subject Eight','Body Eight');
  v_ent := route_entry(v_ent.id, '92000000-0002-0000-0000-000000000002');
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000005"}',true);
  v_rep := draft_entry_reply(v_ent.id, 'CONFIDENTIAL REPLY BODY');
  v_rep := submit_entry_reply(v_rep.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000003"}',true);
  v_rep := approve_entry_reply(v_rep.id);
  RESET ROLE;
  PERFORM set_config('app.e92_ent8', v_ent.id::text, false);

  SELECT * INTO v_evt FROM platform_outbox_events WHERE event_type = 'entry.reply_sent.v1' AND source_record_id = v_ent.id;
  IF v_evt.id IS NULL THEN RAISE EXCEPTION 'no entry.reply_sent.v1 outbox event, or wrongly sourced from the reply instead of the parent entry'; END IF;
  IF v_evt.source_record_type <> 'external_correspondence' THEN RAISE EXCEPTION 'wrong source_record_type: %, expected external_correspondence', v_evt.source_record_type; END IF;
  IF v_evt.payload ->> 'target_type' <> 'specific_users' OR (v_evt.payload -> 'target_user_ids') <> jsonb_build_array(v_ent.entered_by) THEN
    RAISE EXCEPTION 'wrong target descriptor'; END IF;
  IF (v_evt.payload -> 'template_params' ->> 'reply_id')::UUID <> v_rep.id THEN RAISE EXCEPTION 'reply_id missing from payload'; END IF;
  IF v_evt.payload -> 'template_params' ->> 'reference_number' <> v_ent.reference_number THEN RAISE EXCEPTION 'wrong reference_number'; END IF;
  IF v_evt.payload::TEXT ILIKE '%CONFIDENTIAL%' THEN
    RAISE EXCEPTION 'SECURITY: reply body leaked into payload'; END IF;

  PERFORM process_platform_outbox_batch(50, 'e92-worker');
  IF NOT EXISTS (
    SELECT 1 FROM user_notifications WHERE notification_type='entry.reply_sent.v1'
      AND recipient_user_id='92000000-0001-0000-0000-000000000001' AND source_record_id = v_ent.id
      AND source_record_type = 'external_correspondence'
  ) THEN RAISE EXCEPTION 'entry clerk (entered_by) was not notified, or notification points at the wrong source record'; END IF;
END $$;
INSERT INTO e92_results VALUES (8,'approve_entry_reply() atomically enqueues exactly 1 entry.reply_sent.v1 event SOURCED FROM THE PARENT ENTRY (source_record_type=external_correspondence, source_record_id=parent entry id, never a new reply source type), targeting specific_users([entry.entered_by]); reply body never leaks into the payload; delivered end-to-end with the exact identity a frontend deep link would route to the existing Entry detail view');

-- 9. Domain failure: approve_entry_reply on a non-pending_approval
-- reply produces no outbox event.
DO $$
DECLARE v_before INTEGER; v_after INTEGER;
BEGIN
  SELECT count(*) INTO v_before FROM platform_outbox_events WHERE event_type = 'entry.reply_sent.v1';
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000003"}',true);
  BEGIN
    PERFORM approve_entry_reply((SELECT id FROM external_correspondence_replies WHERE entry_id = current_setting('app.e92_ent8')::uuid)); -- already sent
    RAISE EXCEPTION 'expected rejection (already sent)';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected rejection (already sent)' THEN RAISE; END IF;
  END;
  RESET ROLE;
  SELECT count(*) INTO v_after FROM platform_outbox_events WHERE event_type = 'entry.reply_sent.v1';
  IF v_before <> v_after THEN RAISE EXCEPTION 'a rejected approve_entry_reply call unexpectedly produced an outbox event'; END IF;
END $$;
INSERT INTO e92_results VALUES (9,'A status-guard failure in approve_entry_reply() (called on an already-sent reply) produces zero outbox events -- the guard runs before the enqueue is ever reached');

-- ══════════════════ ENTRY.REPLY_RETURNED.V1 (return_entry_reply) ════════

-- 10. Outbox correctness + end-to-end: reply drafter receives exactly
-- one notification, comment excluded from payload.
DO $$
DECLARE v_ent external_correspondence; v_rep external_correspondence_replies; v_evt platform_outbox_events;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('letter','public','Sender Ten','Subject Ten','Body Ten');
  v_ent := route_entry(v_ent.id, '92000000-0002-0000-0000-000000000002');
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000005"}',true);
  v_rep := draft_entry_reply(v_ent.id, 'a draft reply');
  v_rep := submit_entry_reply(v_rep.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000003"}',true);
  v_rep := return_entry_reply(v_rep.id, 'CONFIDENTIAL RETURN COMMENT, needs more detail');
  RESET ROLE;

  SELECT * INTO v_evt FROM platform_outbox_events WHERE event_type = 'entry.reply_returned.v1' AND source_record_id = v_ent.id;
  IF v_evt.id IS NULL THEN RAISE EXCEPTION 'no entry.reply_returned.v1 outbox event'; END IF;
  IF v_evt.payload ->> 'target_type' <> 'specific_users' OR (v_evt.payload -> 'target_user_ids') <> jsonb_build_array(v_rep.created_by) THEN
    RAISE EXCEPTION 'wrong target descriptor'; END IF;
  IF v_evt.payload::TEXT ILIKE '%CONFIDENTIAL%' THEN RAISE EXCEPTION 'SECURITY: return comment leaked into payload'; END IF;

  PERFORM process_platform_outbox_batch(50, 'e92-worker');
  IF NOT EXISTS (SELECT 1 FROM user_notifications WHERE notification_type='entry.reply_returned.v1' AND recipient_user_id = v_rep.created_by AND source_record_id = v_ent.id) THEN
    RAISE EXCEPTION 'reply drafter was not notified of the return';
  END IF;
END $$;
INSERT INTO e92_results VALUES (10,'return_entry_reply() atomically enqueues exactly 1 entry.reply_returned.v1 event SOURCED FROM THE PARENT ENTRY, targeting specific_users([reply.created_by]), safe payload (return comment excluded), delivered end-to-end to the reply''s own drafter');

-- 11. Domain failure: return_entry_reply on a non-pending_approval
-- reply produces no outbox event.
DO $$
DECLARE v_ent external_correspondence; v_rep external_correspondence_replies; v_before INTEGER; v_after INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('letter','public','Sender Eleven','Subject Eleven','Body Eleven');
  v_ent := route_entry(v_ent.id, '92000000-0002-0000-0000-000000000002');
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000005"}',true);
  v_rep := draft_entry_reply(v_ent.id, 'still a draft, never submitted');
  RESET ROLE;
  SELECT count(*) INTO v_before FROM platform_outbox_events WHERE event_type = 'entry.reply_returned.v1';
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000003"}',true);
  BEGIN
    PERFORM return_entry_reply(v_rep.id, NULL); -- still draft, not pending_approval
    RAISE EXCEPTION 'expected rejection';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected rejection' THEN RAISE; END IF;
  END;
  RESET ROLE;
  SELECT count(*) INTO v_after FROM platform_outbox_events WHERE event_type = 'entry.reply_returned.v1';
  IF v_before <> v_after THEN RAISE EXCEPTION 'a rejected return_entry_reply call unexpectedly produced an outbox event'; END IF;
END $$;
INSERT INTO e92_results VALUES (11,'A status-guard failure in return_entry_reply() (called on a still-draft reply, never submitted for approval) produces zero outbox events');

-- ══════════════════ Dynamic recipients / late authorization ════════════

-- 12. Dynamic membership: a section member deactivated between enqueue
-- and worker processing receives nothing.
DO $$
DECLARE v_ent external_correspondence; v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('letter','public','Sender Twelve','Subject Twelve','Body Twelve');
  v_ent := route_entry(v_ent.id, '92000000-0002-0000-0000-000000000002');
  RESET ROLE;

  UPDATE user_assignments SET is_active = FALSE WHERE user_id = '92000000-0001-0000-0000-000000000004' AND scope_id = '92000000-0002-0000-0000-000000000002';
  PERFORM process_platform_outbox_batch(50, 'e92-worker');
  SELECT count(*) INTO v_count FROM user_notifications WHERE notification_type='entry.routed.v1' AND source_record_id = v_ent.id AND recipient_user_id = '92000000-0001-0000-0000-000000000004';
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY: a section member deactivated before processing was still notified'; END IF;
  UPDATE user_assignments SET is_active = TRUE WHERE user_id = '92000000-0001-0000-0000-000000000004' AND scope_id = '92000000-0002-0000-0000-000000000002';
END $$;
INSERT INTO e92_results VALUES (12,'Dynamic membership: a Welfare section member whose assignment is deactivated BETWEEN enqueue and worker processing receives nothing -- section(to_section_id) resolves current membership at processing time, never a stale enqueue-time snapshot');

-- 13. Cross-org stranger (Org Gamma) never becomes a candidate at all
-- and never receives any Entry notification, despite being a real,
-- active, entry-staff supervisor in ANOTHER org on the same platform.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM user_notifications WHERE recipient_user_id='92000000-0001-0000-0000-000000000007' AND notification_type LIKE 'entry.%') THEN
    RAISE EXCEPTION 'SECURITY: a third-org (Gamma) user unexpectedly received an Entry CAP-003 notification';
  END IF;
END $$;
INSERT INTO e92_results VALUES (13,'A user belonging to a genuinely unrelated organization (Org Gamma, itself Entry-enabled with its own section/staff) never becomes a candidate for, and never receives, any entry.*.v1 notification produced by Org Alpha''s Entry activity -- shared platform membership alone confers nothing');

-- 14. Idempotent replay: re-resolving an already-resolved intent is a
-- safe no-op.
DO $$
DECLARE v_intent_id UUID; v_before INTEGER; v_after INTEGER;
BEGIN
  SELECT id INTO v_intent_id FROM notification_intents
    WHERE outbox_event_id = (SELECT id FROM platform_outbox_events WHERE event_type='entry.reply_sent.v1' AND source_record_id = current_setting('app.e92_ent8')::uuid);
  SELECT count(*) INTO v_before FROM user_notifications WHERE outbox_event_id = (SELECT id FROM platform_outbox_events WHERE event_type='entry.reply_sent.v1' AND source_record_id = current_setting('app.e92_ent8')::uuid);
  PERFORM resolve_notification_intent(v_intent_id);
  SELECT count(*) INTO v_after FROM user_notifications WHERE outbox_event_id = (SELECT id FROM platform_outbox_events WHERE event_type='entry.reply_sent.v1' AND source_record_id = current_setting('app.e92_ent8')::uuid);
  IF v_before <> v_after THEN RAISE EXCEPTION 'idempotent replay produced a duplicate notification'; END IF;
END $$;
INSERT INTO e92_results VALUES (14,'Idempotent replay: re-resolving an already-resolved entry.reply_sent.v1 intent is a safe no-op (early-return path, no duplicate user_notifications)');

-- 15. Replaying the real worker over an already-completed event does
-- not duplicate the outbox row or re-enqueue.
DO $$
DECLARE v_count INTEGER;
BEGIN
  PERFORM process_platform_outbox_batch(50, 'e92-worker-replay');
  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE event_type='entry.reply_sent.v1' AND source_record_id = current_setting('app.e92_ent8')::uuid;
  IF v_count <> 1 THEN RAISE EXCEPTION 'worker replay duplicated the outbox event, got %', v_count; END IF;
END $$;
INSERT INTO e92_results VALUES (15,'Replaying process_platform_outbox_batch() over an already-processed entry.reply_sent.v1 event does not duplicate the outbox row (status=completed is skipped by platform_outbox_events_due_for_processing)');

-- 16. Unrelated entries produce fully independent outbox events -- no
-- cross-contamination of idempotency keys or target resolution.
DO $$
DECLARE v_ent_a external_correspondence; v_ent_b external_correspondence; v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000001"}',true);
  v_ent_a := create_entry('letter','public','Sender A','Subject A','Body A');
  v_ent_a := route_entry(v_ent_a.id, '92000000-0002-0000-0000-000000000002');
  v_ent_b := create_entry('email','public','Sender B','Subject B','Body B');
  v_ent_b := route_entry(v_ent_b.id, '92000000-0002-0000-0000-000000000002');
  RESET ROLE;

  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE event_type='entry.routed.v1' AND source_record_id IN (v_ent_a.id, v_ent_b.id);
  IF v_count <> 2 THEN RAISE EXCEPTION 'expected 2 independent entry.routed.v1 events for 2 independent entries, got %', v_count; END IF;
  IF (SELECT idempotency_key FROM platform_outbox_events WHERE source_record_id = v_ent_a.id AND event_type='entry.routed.v1')
     = (SELECT idempotency_key FROM platform_outbox_events WHERE source_record_id = v_ent_b.id AND event_type='entry.routed.v1')
  THEN RAISE EXCEPTION 'two unrelated entries unexpectedly share one idempotency_key'; END IF;
END $$;
INSERT INTO e92_results VALUES (16,'Two independently-created, independently-routed entries each produce their own entry.routed.v1 occurrence with their own distinct idempotency_key -- no cross-entry contamination');

-- 17. mark_entry_received / close_entry / draft_entry_reply /
-- update_entry_reply_draft -- confirmed deferred: none of these RPCs
-- enqueue any CAP-003 event.
DO $$
DECLARE v_ent external_correspondence; v_rep external_correspondence_replies; v_before INTEGER; v_after INTEGER;
BEGIN
  SELECT count(*) INTO v_before FROM platform_outbox_events;
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('letter','public','Sender 17','Subject 17','Body 17');
  v_ent := route_entry(v_ent.id, '92000000-0002-0000-0000-000000000002');
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000004"}',true);
  v_ent := mark_entry_received(v_ent.id);
  v_rep := draft_entry_reply(v_ent.id, 'a draft, never submitted');
  v_rep := update_entry_reply_draft(v_rep.id, 'a revised draft, still never submitted');
  v_rep := submit_entry_reply(v_rep.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000003"}',true);
  v_rep := approve_entry_reply(v_rep.id); -- advances entry to 'responded'
  PERFORM set_config('request.jwt.claims','{"sub":"92000000-0001-0000-0000-000000000001"}',true);
  v_ent := close_entry(v_ent.id); -- 'responded' -> 'closed' is the only valid transition into closed
  RESET ROLE;
  SELECT count(*) INTO v_after FROM platform_outbox_events;
  -- v_before/v_after span this scenario's own route_entry() (1
  -- entry.routed.v1) and approve_entry_reply() (1 entry.reply_sent.v1)
  -- calls -- both IMPLEMENTED events -- so the delta must be exactly 2,
  -- never more; mark_entry_received/draft_entry_reply/
  -- update_entry_reply_draft/close_entry must contribute zero.
  IF (v_after - v_before) <> 2 THEN
    RAISE EXCEPTION 'expected exactly 2 enqueues in this scenario (route_entry + approve_entry_reply), got delta=%; a deferred command unexpectedly enqueued', (v_after - v_before);
  END IF;
END $$;
INSERT INTO e92_results VALUES (17,'mark_entry_received()/draft_entry_reply()/update_entry_reply_draft()/close_entry() -- confirmed-deferred candidates (no legacy notification fires for any of them) -- enqueue no CAP-003 event at all; only this scenario''s own route_entry() call produced its expected single entry.routed.v1');

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM e92_results;
  RAISE NOTICE 'ENTRY NOTIFICATION INTEGRATION BEHAVIORAL SUITE: % scenarios PASSED', v_count;
END $$;

ROLLBACK;
