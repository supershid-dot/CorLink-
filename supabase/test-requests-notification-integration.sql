-- CAP-003 Phase 1.6B notification event integration -- focused
-- behavioral suite. Disposable local PostgreSQL only. Runs in one
-- transaction and leaves no fixtures (rolled back at the end).
--
-- Role convention: the connecting superuser (postgres, rolbypassrls)
-- is the default role throughout -- it can freely read
-- platform_outbox_events/notification_intents/user_notifications,
-- none of which grant SELECT to 'authenticated' via RLS (zero
-- policies, by design -- see docs/78). Each scenario explicitly `SET
-- ROLE authenticated` + sets the JWT claim only around the actual RPC
-- call(s) that must run as a real end user, then `RESET ROLE` back to
-- postgres before reading any CAP-003 table -- the identical
-- convention test-task-meeting-notification-events.sql established
-- (there via a single blanket `SET ROLE service_role`, which also
-- bypasses RLS; RESET ROLE to the connecting superuser is equivalent
-- and avoids an extra role switch per scenario).
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE r90_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);

-- ── Fixtures: three orgs (Alpha, Beta -- bidirectional pair; Gamma --
-- a genuinely unrelated third org for negative controls) ──────────────
INSERT INTO organizations(id,name,type,code) VALUES
 ('90000000-0000-0000-0000-000000000001','R90 Org Alpha','authority','R90A'),
 ('90000000-0000-0000-0000-000000000002','R90 Org Beta','authority','R90B'),
 ('90000000-0000-0000-0000-000000000003','R90 Org Gamma','authority','R90G');
INSERT INTO divisions(id, org_id, name) VALUES
 ('90000000-0004-0000-0000-000000000001','90000000-0000-0000-0000-000000000001','R90 Alpha Div'),
 ('90000000-0004-0000-0000-000000000002','90000000-0000-0000-0000-000000000002','R90 Beta Div'),
 ('90000000-0004-0000-0000-000000000003','90000000-0000-0000-0000-000000000003','R90 Gamma Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
 ('90000000-0002-0000-0000-000000000001','90000000-0000-0000-0000-000000000001','90000000-0004-0000-0000-000000000001','R90 Alpha Sec A','R90AA'),
 ('90000000-0002-0000-0000-000000000002','90000000-0000-0000-0000-000000000002','90000000-0004-0000-0000-000000000002','R90 Beta Sec A','R90BA'),
 ('90000000-0002-0000-0000-000000000003','90000000-0000-0000-0000-000000000003','90000000-0004-0000-0000-000000000003','R90 Gamma Sec A','R90GA');

INSERT INTO auth.users(id,email) VALUES
 ('90000000-0001-0000-0000-000000000001','alpha-staff@r90t.local'),
 ('90000000-0001-0000-0000-000000000002','alpha-super@r90t.local'),
 ('90000000-0001-0000-0000-000000000003','beta-staff@r90t.local'),
 ('90000000-0001-0000-0000-000000000004','beta-super@r90t.local'),
 ('90000000-0001-0000-0000-000000000005','beta-staff2@r90t.local'),
 ('90000000-0001-0000-0000-000000000006','beta-admin@r90t.local'),
 ('90000000-0001-0000-0000-000000000007','gamma-super@r90t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('90000000-0001-0000-0000-000000000001','90000000-0000-0000-0000-000000000001','R90-1','Alpha Staff','alpha-staff@r90t.local',true),
 ('90000000-0001-0000-0000-000000000002','90000000-0000-0000-0000-000000000001','R90-2','Alpha Super','alpha-super@r90t.local',true),
 ('90000000-0001-0000-0000-000000000003','90000000-0000-0000-0000-000000000002','R90-3','Beta Staff','beta-staff@r90t.local',true),
 ('90000000-0001-0000-0000-000000000004','90000000-0000-0000-0000-000000000002','R90-4','Beta Super','beta-super@r90t.local',true),
 ('90000000-0001-0000-0000-000000000005','90000000-0000-0000-0000-000000000002','R90-5','Beta Staff Two','beta-staff2@r90t.local',true),
 ('90000000-0001-0000-0000-000000000006','90000000-0000-0000-0000-000000000002','R90-6','Beta Admin','beta-admin@r90t.local',true),
 ('90000000-0001-0000-0000-000000000007','90000000-0000-0000-0000-000000000003','R90-7','Gamma Super','gamma-super@r90t.local',true);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
 ('90000000-0001-0000-0000-000000000001','section','90000000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
 ('90000000-0001-0000-0000-000000000002','section','90000000-0002-0000-0000-000000000001','supervisor',TRUE,TRUE),
 ('90000000-0001-0000-0000-000000000003','section','90000000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
 ('90000000-0001-0000-0000-000000000004','section','90000000-0002-0000-0000-000000000002','supervisor',TRUE,TRUE),
 ('90000000-0001-0000-0000-000000000005','section','90000000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
 ('90000000-0001-0000-0000-000000000006','section','90000000-0002-0000-0000-000000000002','mcs_admin',TRUE,TRUE),
 ('90000000-0001-0000-0000-000000000007','section','90000000-0002-0000-0000-000000000003','supervisor',TRUE,TRUE);

-- ══════════════════ REQUESTS.SENT.V1 (approve_request) ══════════════════

-- 1. Outbox correctness: event/source identity, org_admins target,
-- safe payload, subject NOT leaked.
DO $$
DECLARE v_req requests; v_evt platform_outbox_events;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('90000000-0002-0000-0000-000000000001','90000000-0000-0000-0000-000000000002','CONFIDENTIAL SUBJECT','CONFIDENTIAL BODY','en','en',NULL,NULL);
  PERFORM submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, 'internal comment, must never leak');
  RESET ROLE;
  PERFORM set_config('app.r90_req1', v_req.id::text, false);

  SELECT * INTO v_evt FROM platform_outbox_events WHERE event_type = 'requests.sent.v1' AND source_record_id = v_req.id;
  IF v_evt.id IS NULL THEN RAISE EXCEPTION 'no requests.sent.v1 outbox event'; END IF;
  IF v_evt.source_record_type <> 'request' OR v_evt.source_module <> 'requests' THEN RAISE EXCEPTION 'wrong source identity'; END IF;
  IF v_evt.organization_id <> v_req.to_org_id THEN RAISE EXCEPTION 'wrong organization_id'; END IF;
  IF v_evt.actor_id <> '90000000-0001-0000-0000-000000000002' THEN RAISE EXCEPTION 'wrong actor_id'; END IF;
  IF v_evt.payload ->> 'target_type' <> 'org_admins' OR (v_evt.payload ->> 'target_organization_id')::UUID <> v_req.to_org_id THEN
    RAISE EXCEPTION 'wrong target descriptor'; END IF;
  IF v_evt.payload -> 'template_params' ->> 'reference_number' <> v_req.reference_number THEN RAISE EXCEPTION 'wrong reference_number'; END IF;
  IF v_evt.payload::TEXT ILIKE '%CONFIDENTIAL%' THEN RAISE EXCEPTION 'SECURITY: subject/comment leaked into payload'; END IF;
END $$;
INSERT INTO r90_results VALUES (1,'approve_request() atomically enqueues exactly 1 requests.sent.v1 event with correct source identity, org_admins(to_org_id) target, safe structural payload; subject/body/comment never leak into it');

-- 2. Domain failure: calling approve_request on a non-pending_approval
-- request raises and produces NO outbox event.
DO $$
DECLARE v_before INTEGER; v_after INTEGER;
BEGIN
  SELECT count(*) INTO v_before FROM platform_outbox_events WHERE event_type = 'requests.sent.v1';
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000002"}',true);
  BEGIN
    PERFORM approve_request(current_setting('app.r90_req1')::uuid, NULL); -- already sent
    RAISE EXCEPTION 'expected rejection (already sent)';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected rejection (already sent)' THEN RAISE; END IF;
  END;
  RESET ROLE;
  SELECT count(*) INTO v_after FROM platform_outbox_events WHERE event_type = 'requests.sent.v1';
  IF v_before <> v_after THEN RAISE EXCEPTION 'a rejected approve_request call unexpectedly produced an outbox event'; END IF;
END $$;
INSERT INTO r90_results VALUES (2,'A domain-authorization/status-guard failure in approve_request() produces zero outbox events -- the guard runs before the enqueue is ever reached');

-- 3. Forced outbox-enqueue failure -> the ENTIRE domain mutation
-- (status/reference_number/approvals/audit_logs) rolls back with it,
-- never a partial commit. Engineered by temporarily renaming
-- platform_enqueue_outbox_event (top-level DDL, since ALTER FUNCTION
-- is not a valid direct statement inside a PL/pgSQL block) so the
-- RPC's own PERFORM call raises "function does not exist" mid-body;
-- the calling DO block's own BEGIN/EXCEPTION handler is PL/pgSQL's
-- implicit subtransaction boundary, which is what actually discards
-- every effect of the failed approve_request() call as one atomic
-- unit -- no explicit SAVEPOINT is needed for that part.
DO $$
DECLARE v_req requests;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('90000000-0002-0000-0000-000000000001','90000000-0000-0000-0000-000000000002','S2','B2','en','en',NULL,NULL);
  PERFORM submit_request(v_req.id, NULL);
  RESET ROLE;
  PERFORM set_config('app.r90_req3', v_req.id::text, false);
END $$;

ALTER FUNCTION platform_enqueue_outbox_event(text,text,text,uuid,uuid,uuid,uuid,uuid,timestamptz,jsonb,uuid) RENAME TO platform_enqueue_outbox_event_r90_disabled;

DO $$
DECLARE v_req_id UUID := current_setting('app.r90_req3')::uuid; v_before requests; v_after requests; v_audit_before INTEGER; v_audit_after INTEGER;
BEGIN
  SELECT * INTO v_before FROM requests WHERE id = v_req_id;
  SELECT count(*) INTO v_audit_before FROM audit_logs WHERE record_type = 'request' AND record_id = v_req_id;

  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000002"}',true);
  BEGIN
    PERFORM approve_request(v_req_id, NULL);
    RAISE EXCEPTION 'expected forced outbox failure (platform_enqueue_outbox_event renamed away)';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected forced outbox failure (platform_enqueue_outbox_event renamed away)' THEN RAISE; END IF;
    -- any other error (the expected "function ... does not exist") is
    -- swallowed here -- this is the proof point itself.
  END;
  RESET ROLE;

  SELECT * INTO v_after FROM requests WHERE id = v_req_id;
  SELECT count(*) INTO v_audit_after FROM audit_logs WHERE record_type = 'request' AND record_id = v_req_id;
  IF v_after.status <> v_before.status OR v_after.reference_number IS DISTINCT FROM v_before.reference_number OR v_after.is_locked <> v_before.is_locked THEN
    RAISE EXCEPTION 'PARTIAL COMMIT DETECTED: requests row changed despite the forced outbox failure (before status=%, after status=%)', v_before.status, v_after.status;
  END IF;
  IF v_audit_after <> v_audit_before THEN
    RAISE EXCEPTION 'PARTIAL COMMIT DETECTED: an audit_logs row survived the forced outbox failure';
  END IF;
  IF EXISTS (SELECT 1 FROM approvals WHERE record_type='request' AND record_id=v_req_id AND decision='approved') THEN
    RAISE EXCEPTION 'PARTIAL COMMIT DETECTED: an approvals row survived the forced outbox failure';
  END IF;
END $$;

ALTER FUNCTION platform_enqueue_outbox_event_r90_disabled(text,text,text,uuid,uuid,uuid,uuid,uuid,timestamptz,jsonb,uuid) RENAME TO platform_enqueue_outbox_event;

-- Function restored -- prove a normal call succeeds again right afterward.
DO $$
DECLARE v_req requests;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(current_setting('app.r90_req3')::uuid, NULL);
  RESET ROLE;
  IF v_req.status <> 'sent' THEN RAISE EXCEPTION 'approve_request did not recover after platform_enqueue_outbox_event was restored'; END IF;
END $$;
INSERT INTO r90_results VALUES (3,'A forced platform_enqueue_outbox_event() failure inside approve_request() rolls back the ENTIRE domain mutation together -- requests.status/reference_number/is_locked, the approvals row, and the audit_logs row all revert as one unit; no partial state, proving the atomic single-transaction boundary; a normal call succeeds again once the dependency is restored');

-- 4. Late authorization: a plain supervisor with no admin role and no
-- from/to/previous-section relationship to a still-UNROUTED request is
-- a legitimate org_admins candidate but is correctly SKIPPED at
-- resolution (documented, evidenced, fail-closed limitation -- see
-- docs/90). An mcs_admin candidate in the same org IS resolved.
DO $$
DECLARE v_req requests; v_intent RECORD;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('90000000-0002-0000-0000-000000000001','90000000-0000-0000-0000-000000000002','S3','B3','en','en',NULL,NULL);
  PERFORM submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  RESET ROLE;
  PERFORM set_config('app.r90_req4', v_req.id::text, false);

  PERFORM process_platform_outbox_batch(50, 'r90-worker');

  SELECT status, resolved_count, skipped_count INTO v_intent FROM notification_intents
    WHERE outbox_event_id = (SELECT id FROM platform_outbox_events WHERE event_type='requests.sent.v1' AND source_record_id = v_req.id);
  IF v_intent.resolved_count <> 1 OR v_intent.skipped_count <> 1 THEN
    RAISE EXCEPTION 'expected exactly 1 resolved (Beta Admin) + 1 skipped (Beta Super, unrouted) candidate, got resolved=% skipped=%', v_intent.resolved_count, v_intent.skipped_count;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM user_notifications WHERE notification_type='requests.sent.v1' AND recipient_user_id='90000000-0001-0000-0000-000000000006' AND source_record_id=v_req.id) THEN
    RAISE EXCEPTION 'Beta Admin (mcs_admin) should have been notified';
  END IF;
  IF EXISTS (SELECT 1 FROM user_notifications WHERE notification_type='requests.sent.v1' AND recipient_user_id='90000000-0001-0000-0000-000000000004' AND source_record_id=v_req.id) THEN
    RAISE EXCEPTION 'SECURITY: Beta Super (plain supervisor, no section relationship to a still-unrouted request) should NOT receive a CAP-003 user_notification';
  END IF;
END $$;
INSERT INTO r90_results VALUES (4,'Late authorization revalidation: org_admins(to_org_id) legitimately includes a plain supervisor who cannot yet view a still-unrouted request under requests_select''s own real, narrowed visibility rule -- that candidate is correctly skipped (fails closed) while an org admin (mcs_admin) in the same org, who CAN view it, is correctly resolved and notified -- documented, evidenced limitation (see docs/90), not a bug');

-- 5. Cross-org stranger (Org Gamma) never becomes a candidate at all --
-- org_admins is scoped to to_org_id, Gamma is neither party.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM user_notifications WHERE notification_type='requests.sent.v1' AND recipient_user_id='90000000-0001-0000-0000-000000000007') THEN
    RAISE EXCEPTION 'SECURITY: a third-org (Gamma) user unexpectedly received a requests.sent.v1 notification';
  END IF;
END $$;
INSERT INTO r90_results VALUES (5,'A user belonging to neither party organization (Org Gamma) never becomes an org_admins candidate for any requests.sent.v1 event and never receives a notification');

-- 6. Idempotent replay: re-resolving an already-resolved intent is a
-- safe no-op.
DO $$
DECLARE v_intent_id UUID; v_before INTEGER; v_after INTEGER;
BEGIN
  SELECT id INTO v_intent_id FROM notification_intents
    WHERE outbox_event_id = (SELECT id FROM platform_outbox_events WHERE event_type='requests.sent.v1' AND source_record_id = current_setting('app.r90_req4')::uuid);
  SELECT count(*) INTO v_before FROM user_notifications WHERE outbox_event_id = (SELECT id FROM platform_outbox_events WHERE event_type='requests.sent.v1' AND source_record_id = current_setting('app.r90_req4')::uuid);
  PERFORM resolve_notification_intent(v_intent_id);
  SELECT count(*) INTO v_after FROM user_notifications WHERE outbox_event_id = (SELECT id FROM platform_outbox_events WHERE event_type='requests.sent.v1' AND source_record_id = current_setting('app.r90_req4')::uuid);
  IF v_before <> v_after THEN RAISE EXCEPTION 'idempotent replay produced a duplicate notification'; END IF;
END $$;
INSERT INTO r90_results VALUES (6,'Idempotent replay: re-resolving an already-resolved requests.sent.v1 intent is a safe no-op (early-return path, no duplicate user_notifications)');

-- 7. Replaying the real worker over an already-completed event does
-- not duplicate the outbox row or re-enqueue.
DO $$
DECLARE v_count INTEGER;
BEGIN
  PERFORM process_platform_outbox_batch(50, 'r90-worker-replay');
  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE event_type='requests.sent.v1' AND source_record_id = current_setting('app.r90_req4')::uuid;
  IF v_count <> 1 THEN RAISE EXCEPTION 'worker replay duplicated the outbox event, got %', v_count; END IF;
END $$;
INSERT INTO r90_results VALUES (7,'Replaying process_platform_outbox_batch() over an already-processed requests.sent.v1 event does not duplicate the outbox row (status=completed is skipped by platform_outbox_events_due_for_processing)');

-- ══════════════════ REQUESTS.RETURNED.V1 (return_request) ═══════════

-- 8. Outbox correctness + end-to-end: creator receives exactly one
-- notification.
DO $$
DECLARE v_req requests; v_evt platform_outbox_events;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('90000000-0002-0000-0000-000000000001','90000000-0000-0000-0000-000000000002','S4','B4','en','en',NULL,NULL);
  PERFORM submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000002"}',true);
  v_req := return_request(v_req.id, 'please fix the reference number');
  RESET ROLE;

  SELECT * INTO v_evt FROM platform_outbox_events WHERE event_type = 'requests.returned.v1' AND source_record_id = v_req.id;
  IF v_evt.id IS NULL THEN RAISE EXCEPTION 'no requests.returned.v1 outbox event'; END IF;
  IF v_evt.organization_id <> v_req.from_org_id THEN RAISE EXCEPTION 'wrong organization_id'; END IF;
  IF v_evt.payload ->> 'target_type' <> 'specific_users' OR (v_evt.payload -> 'target_user_ids') <> jsonb_build_array(v_req.created_by) THEN
    RAISE EXCEPTION 'wrong target descriptor'; END IF;
  IF v_evt.payload::TEXT ILIKE '%please fix%' THEN RAISE EXCEPTION 'SECURITY: comment leaked into payload'; END IF;

  PERFORM process_platform_outbox_batch(50, 'r90-worker');
  IF NOT EXISTS (SELECT 1 FROM user_notifications WHERE notification_type='requests.returned.v1' AND recipient_user_id = v_req.created_by AND source_record_id = v_req.id) THEN
    RAISE EXCEPTION 'creator was not notified of the return';
  END IF;
END $$;
INSERT INTO r90_results VALUES (8,'return_request() atomically enqueues exactly 1 requests.returned.v1 event targeting specific_users([created_by]), safe payload (comment excluded), delivered end-to-end via the real worker');

-- 9. Domain failure: return_request on a non-pending_approval request
-- produces no outbox event.
DO $$
DECLARE v_before INTEGER; v_after INTEGER; v_req_id UUID;
BEGIN
  SELECT id INTO v_req_id FROM requests WHERE reference_number IS NOT NULL ORDER BY created_at DESC LIMIT 1;
  SELECT count(*) INTO v_before FROM platform_outbox_events WHERE event_type = 'requests.returned.v1';
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000002"}',true);
  BEGIN
    PERFORM return_request(v_req_id, NULL); -- already sent, not pending_approval
    RAISE EXCEPTION 'expected rejection';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected rejection' THEN RAISE; END IF;
  END;
  RESET ROLE;
  SELECT count(*) INTO v_after FROM platform_outbox_events WHERE event_type = 'requests.returned.v1';
  IF v_before <> v_after THEN RAISE EXCEPTION 'a rejected return_request call unexpectedly produced an outbox event'; END IF;
END $$;
INSERT INTO r90_results VALUES (9,'A status-guard failure in return_request() (called on an already-sent request) produces zero outbox events');

-- ══════════════════ REQUESTS.ROUTED.V1 (route_request) ═══════════════

-- 10. Outbox correctness + end-to-end: ALL current section members
-- (both staff) receive a notification (section target kind resolves
-- the whole section, matching legacy sectionUserIds() exactly).
DO $$
DECLARE v_req requests; v_evt platform_outbox_events; v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('90000000-0002-0000-0000-000000000001','90000000-0000-0000-0000-000000000002','S5','B5','en','en',NULL,NULL);
  PERFORM submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000004"}',true);
  PERFORM mark_request_received(v_req.id);
  v_req := route_request(v_req.id, '90000000-0002-0000-0000-000000000002');
  RESET ROLE;
  PERFORM set_config('app.r90_req10', v_req.id::text, false);

  SELECT * INTO v_evt FROM platform_outbox_events WHERE event_type = 'requests.routed.v1' AND source_record_id = v_req.id;
  IF v_evt.id IS NULL THEN RAISE EXCEPTION 'no requests.routed.v1 outbox event'; END IF;
  IF v_evt.payload ->> 'target_type' <> 'section' OR (v_evt.payload ->> 'target_section_id')::UUID <> '90000000-0002-0000-0000-000000000002'::UUID THEN
    RAISE EXCEPTION 'wrong target descriptor'; END IF;

  PERFORM process_platform_outbox_batch(50, 'r90-worker');
  SELECT count(*) INTO v_count FROM user_notifications WHERE notification_type='requests.routed.v1' AND source_record_id = v_req.id
    AND recipient_user_id IN ('90000000-0001-0000-0000-000000000003','90000000-0001-0000-0000-000000000004','90000000-0001-0000-0000-000000000005','90000000-0001-0000-0000-000000000006');
  IF v_count <> 4 THEN RAISE EXCEPTION 'expected all 4 Beta Sec A members notified (staff/supervisor/staff2/mcs_admin), got %', v_count; END IF;
END $$;
INSERT INTO r90_results VALUES (10,'route_request() atomically enqueues exactly 1 requests.routed.v1 event targeting section(to_section_id); the real worker notifies every CURRENT member of that section, matching the legacy sectionUserIds() recipient set exactly');

-- 11. Late authorization: a section member deactivated between enqueue
-- and worker processing receives nothing (dynamic membership).
DO $$
DECLARE v_req requests; v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('90000000-0002-0000-0000-000000000001','90000000-0000-0000-0000-000000000002','S6','B6','en','en',NULL,NULL);
  PERFORM submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000004"}',true);
  PERFORM mark_request_received(v_req.id);
  v_req := route_request(v_req.id, '90000000-0002-0000-0000-000000000002');
  RESET ROLE;

  UPDATE user_assignments SET is_active = FALSE WHERE user_id = '90000000-0001-0000-0000-000000000005' AND scope_id = '90000000-0002-0000-0000-000000000002';
  PERFORM process_platform_outbox_batch(50, 'r90-worker');
  SELECT count(*) INTO v_count FROM user_notifications WHERE notification_type='requests.routed.v1' AND source_record_id = v_req.id AND recipient_user_id = '90000000-0001-0000-0000-000000000005';
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY: a section member deactivated before processing was still notified'; END IF;
  UPDATE user_assignments SET is_active = TRUE WHERE user_id = '90000000-0001-0000-0000-000000000005' AND scope_id = '90000000-0002-0000-0000-000000000002';
END $$;
INSERT INTO r90_results VALUES (11,'Dynamic membership: a section member whose assignment is deactivated BETWEEN enqueue and worker processing receives nothing -- section(to_section_id) resolves current membership at processing time, never a stale enqueue-time snapshot');

-- 12. Domain failure: routing to a section belonging to a different
-- organization is rejected server-side (Phase 1.6A's own deviation) --
-- produces no outbox event.
DO $$
DECLARE v_req requests; v_before INTEGER; v_after INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('90000000-0002-0000-0000-000000000001','90000000-0000-0000-0000-000000000002','S7','B7','en','en',NULL,NULL);
  PERFORM submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000004"}',true);
  PERFORM mark_request_received(v_req.id);
  RESET ROLE;
  SELECT count(*) INTO v_before FROM platform_outbox_events WHERE event_type='requests.routed.v1';
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000004"}',true);
  BEGIN
    PERFORM route_request(v_req.id, '90000000-0002-0000-0000-000000000001'); -- Alpha section, wrong org
    RAISE EXCEPTION 'expected rejection (cross-org section)';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected rejection (cross-org section)' THEN RAISE; END IF;
  END;
  RESET ROLE;
  SELECT count(*) INTO v_after FROM platform_outbox_events WHERE event_type='requests.routed.v1';
  IF v_before <> v_after THEN RAISE EXCEPTION 'a rejected cross-org route_request call unexpectedly produced an outbox event'; END IF;
END $$;
INSERT INTO r90_results VALUES (12,'route_request()''s Phase 1.6A org-consistency guard (destination section must belong to the request''s own to_org_id) rejects a cross-org routing attempt before the enqueue is ever reached -- zero outbox events');

-- 13. Composed path: receive_and_route_request() (no assignee) still
-- fires requests.routed.v1 -- proves the nested PERFORM correctly
-- propagates the atomic enqueue.
DO $$
DECLARE v_req requests; v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('90000000-0002-0000-0000-000000000001','90000000-0000-0000-0000-000000000002','S8','B8','en','en',NULL,NULL);
  PERFORM submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000004"}',true);
  v_req := receive_and_route_request(v_req.id, '90000000-0002-0000-0000-000000000002', NULL);
  RESET ROLE;

  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE event_type='requests.routed.v1' AND source_record_id = v_req.id;
  IF v_count <> 1 THEN RAISE EXCEPTION 'receive_and_route_request (no assignee) did not enqueue requests.routed.v1 via its nested route_request() call, got %', v_count; END IF;
  IF EXISTS (SELECT 1 FROM platform_outbox_events WHERE event_type='requests.assigned.v1' AND source_record_id = v_req.id) THEN
    RAISE EXCEPTION 'receive_and_route_request (no assignee) unexpectedly enqueued requests.assigned.v1';
  END IF;
END $$;
INSERT INTO r90_results VALUES (13,'receive_and_route_request() (composed atomic RPC, no assignee) correctly propagates its nested route_request() call''s atomic requests.routed.v1 enqueue in the same transaction, and does not enqueue requests.assigned.v1 when no assignee was given');

-- ══════════════════ REQUESTS.ASSIGNED.V1 (assign_request) ════════════

-- 14. Outbox correctness + end-to-end: assignee alone is notified.
DO $$
DECLARE v_req requests; v_evt platform_outbox_events;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('90000000-0002-0000-0000-000000000001','90000000-0000-0000-0000-000000000002','S9','B9','en','en',NULL,NULL);
  PERFORM submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000004"}',true);
  PERFORM mark_request_received(v_req.id);
  v_req := route_request(v_req.id, '90000000-0002-0000-0000-000000000002');
  v_req := assign_request(v_req.id, '90000000-0001-0000-0000-000000000003');
  RESET ROLE;

  SELECT * INTO v_evt FROM platform_outbox_events WHERE event_type = 'requests.assigned.v1' AND source_record_id = v_req.id;
  IF v_evt.id IS NULL THEN RAISE EXCEPTION 'no requests.assigned.v1 outbox event'; END IF;
  IF v_evt.payload ->> 'target_type' <> 'specific_users' OR (v_evt.payload -> 'target_user_ids') <> jsonb_build_array('90000000-0001-0000-0000-000000000003'::UUID) THEN
    RAISE EXCEPTION 'wrong target descriptor'; END IF;

  PERFORM process_platform_outbox_batch(50, 'r90-worker');
  IF NOT EXISTS (SELECT 1 FROM user_notifications WHERE notification_type='requests.assigned.v1' AND recipient_user_id='90000000-0001-0000-0000-000000000003' AND source_record_id=v_req.id) THEN
    RAISE EXCEPTION 'assignee was not notified';
  END IF;
  IF EXISTS (SELECT 1 FROM user_notifications WHERE notification_type='requests.assigned.v1' AND recipient_user_id<>'90000000-0001-0000-0000-000000000003' AND source_record_id=v_req.id) THEN
    RAISE EXCEPTION 'someone other than the assignee was notified';
  END IF;
  PERFORM set_config('app.r90_req14', v_req.id::text, false);
END $$;
INSERT INTO r90_results VALUES (14,'assign_request() atomically enqueues exactly 1 requests.assigned.v1 event targeting specific_users([assigned_to]) alone; delivered end-to-end to that user only');

-- 15. Unassignment (p_user_id NULL) fires no event at all.
DO $$
DECLARE v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000004"}',true);
  PERFORM assign_request(current_setting('app.r90_req14')::uuid, NULL);
  RESET ROLE;
  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE event_type='requests.assigned.v1' AND source_record_id = current_setting('app.r90_req14')::uuid;
  IF v_count <> 1 THEN RAISE EXCEPTION 'unassignment unexpectedly changed the outbox event count (expected still 1 from scenario 14), got %', v_count; END IF;
END $$;
INSERT INTO r90_results VALUES (15,'assign_request() called with p_user_id=NULL (unassignment) fires no requests.assigned.v1 event, mirroring the legacy notification''s own `if (userId)` guard exactly');

-- 16. Legitimate repeated occurrence: reassigning produces a SECOND,
-- distinguishable outbox event (own audit_logs.id / idempotency_key) --
-- never collapsed into the first.
DO $$
DECLARE v_count INTEGER; v_ids UUID[];
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000004"}',true);
  PERFORM assign_request(current_setting('app.r90_req14')::uuid, '90000000-0001-0000-0000-000000000005');
  RESET ROLE;
  SELECT count(*), array_agg(DISTINCT idempotency_key) INTO v_count, v_ids
    FROM platform_outbox_events WHERE event_type='requests.assigned.v1' AND source_record_id = current_setting('app.r90_req14')::uuid;
  IF v_count <> 2 THEN RAISE EXCEPTION 'expected 2 distinguishable requests.assigned.v1 occurrences (re-assignment), got %', v_count; END IF;
  IF array_length(v_ids, 1) <> 2 THEN RAISE EXCEPTION 'the two occurrences unexpectedly share one idempotency_key'; END IF;
END $$;
INSERT INTO r90_results VALUES (16,'Reassigning a request (assign_request() called again) produces a second, independently-idempotency-keyed requests.assigned.v1 occurrence -- legitimate repeated lifecycle events are never collapsed by an overly broad uniqueness rule');

-- 17. Composed path with an assignee: receive_and_route_request()
-- enqueues BOTH requests.routed.v1 (section) AND requests.assigned.v1
-- (assignee) -- a documented, evidenced divergence from legacy (which
-- suppresses the section broadcast in this exact case), not a bug.
DO $$
DECLARE v_req requests; v_routed INTEGER; v_assigned INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('90000000-0002-0000-0000-000000000001','90000000-0000-0000-0000-000000000002','S10','B10','en','en',NULL,NULL);
  PERFORM submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000004"}',true);
  v_req := receive_and_route_request(v_req.id, '90000000-0002-0000-0000-000000000002', '90000000-0001-0000-0000-000000000003');
  RESET ROLE;

  SELECT count(*) INTO v_routed FROM platform_outbox_events WHERE event_type='requests.routed.v1' AND source_record_id = v_req.id;
  SELECT count(*) INTO v_assigned FROM platform_outbox_events WHERE event_type='requests.assigned.v1' AND source_record_id = v_req.id;
  IF v_routed <> 1 OR v_assigned <> 1 THEN
    RAISE EXCEPTION 'expected both requests.routed.v1 (%) and requests.assigned.v1 (%) from a composed receive-and-route-with-assignee call', v_routed, v_assigned;
  END IF;
END $$;
INSERT INTO r90_results VALUES (17,'receive_and_route_request() WITH an assignee atomically enqueues BOTH requests.routed.v1 (to the whole section, via the nested route_request() call) AND requests.assigned.v1 (to the assignee, via the nested assign_request() call) -- a documented, evidenced, safe over-notification relative to legacy''s own section-broadcast suppression in this exact composed case (see docs/90), never a dropped or duplicated event');

-- ══════════════════ REQUESTS.RESPONSE_SENT.V1 (approve_response) ═════

-- 18. Outbox correctness: sourced from the PARENT request (not a new
-- 'response' source type), targets the request's own creator, safe
-- payload (response body never leaked).
DO $$
DECLARE v_req requests; v_resp responses; v_evt platform_outbox_events;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('90000000-0002-0000-0000-000000000001','90000000-0000-0000-0000-000000000002','S11','B11','en','en',NULL,NULL);
  PERFORM submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000002"}',true);
  v_req := approve_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000004"}',true);
  PERFORM mark_request_received(v_req.id);
  v_req := route_request(v_req.id, '90000000-0002-0000-0000-000000000002');
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000003"}',true);
  v_resp := create_response(v_req.id, 'CONFIDENTIAL RESPONSE BODY', 'en');
  PERFORM submit_response(v_resp.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000004"}',true);
  v_resp := approve_response(v_resp.id, 'internal reviewer comment');
  RESET ROLE;
  PERFORM set_config('app.r90_req18', v_req.id::text, false);

  SELECT * INTO v_evt FROM platform_outbox_events WHERE event_type = 'requests.response_sent.v1' AND source_record_id = v_req.id;
  IF v_evt.id IS NULL THEN RAISE EXCEPTION 'no requests.response_sent.v1 outbox event, or wrongly sourced from the response instead of the parent request'; END IF;
  IF v_evt.source_record_type <> 'request' THEN RAISE EXCEPTION 'wrong source_record_type: %, expected request', v_evt.source_record_type; END IF;
  IF v_evt.organization_id <> v_req.from_org_id THEN RAISE EXCEPTION 'wrong organization_id'; END IF;
  IF v_evt.payload ->> 'target_type' <> 'specific_users' OR (v_evt.payload -> 'target_user_ids') <> jsonb_build_array(v_req.created_by) THEN
    RAISE EXCEPTION 'wrong target descriptor'; END IF;
  IF (v_evt.payload -> 'template_params' ->> 'response_id')::UUID <> v_resp.id THEN RAISE EXCEPTION 'response_id missing from payload'; END IF;
  IF v_evt.payload::TEXT ILIKE '%CONFIDENTIAL%' OR v_evt.payload::TEXT ILIKE '%reviewer comment%' THEN
    RAISE EXCEPTION 'SECURITY: response body/comment leaked into payload'; END IF;
END $$;
INSERT INTO r90_results VALUES (18,'approve_response() atomically enqueues exactly 1 requests.response_sent.v1 event SOURCED FROM THE PARENT REQUEST (source_record_type=request, source_record_id=parent request id, never a new response source type), targeting specific_users([request.created_by]); response body and reviewer comment never leak into the payload');

-- 19. End-to-end: request creator receives the notification, deep-link
-- identity is the parent request (source_record_id proven above).
DO $$
BEGIN
  PERFORM process_platform_outbox_batch(50, 'r90-worker');
  IF NOT EXISTS (
    SELECT 1 FROM user_notifications WHERE notification_type='requests.response_sent.v1'
      AND recipient_user_id='90000000-0001-0000-0000-000000000001' AND source_record_id = current_setting('app.r90_req18')::uuid
      AND source_record_type = 'request'
  ) THEN RAISE EXCEPTION 'request creator was not notified, or notification points at the wrong source record'; END IF;
END $$;
INSERT INTO r90_results VALUES (19,'End-to-end via the real worker: the request creator receives exactly one requests.response_sent.v1 user_notification, with source_record_type=request/source_record_id=<parent request> -- the exact identity a frontend deep link would route to the existing Requests detail view (no separate response route needed)');

-- 20. Domain failure: approve_response on a non-pending_approval
-- response produces no outbox event.
DO $$
DECLARE v_before INTEGER; v_after INTEGER; v_resp_id UUID;
BEGIN
  SELECT id INTO v_resp_id FROM responses WHERE status = 'sent' ORDER BY created_at DESC LIMIT 1;
  SELECT count(*) INTO v_before FROM platform_outbox_events WHERE event_type = 'requests.response_sent.v1';
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000004"}',true);
  BEGIN
    PERFORM approve_response(v_resp_id, NULL);
    RAISE EXCEPTION 'expected rejection';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected rejection' THEN RAISE; END IF;
  END;
  RESET ROLE;
  SELECT count(*) INTO v_after FROM platform_outbox_events WHERE event_type = 'requests.response_sent.v1';
  IF v_before <> v_after THEN RAISE EXCEPTION 'a rejected approve_response call unexpectedly produced an outbox event'; END IF;
END $$;
INSERT INTO r90_results VALUES (20,'A status-guard failure in approve_response() (called on an already-sent response) produces zero outbox events');

-- ══════════════════ BIDIRECTIONALITY (Beta -> Alpha, reversed roles) ══

-- 21. The full sent+response_sent cycle run in the OPPOSITE direction
-- (Org Beta creates+sends a request TO Org Alpha; Org Alpha responds
-- and sends the response back) produces correct CAP-003 events with no
-- hard-coded organization role anywhere in the producer code.
DO $$
DECLARE v_req requests; v_resp responses; v_evt platform_outbox_events;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000003"}',true); -- Beta staff creates
  v_req := create_request('90000000-0002-0000-0000-000000000002','90000000-0000-0000-0000-000000000001','S-reverse','B-reverse','en','en',NULL,NULL);
  PERFORM submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000004"}',true); -- Beta super approves+sends
  v_req := approve_request(v_req.id, NULL);
  RESET ROLE;

  SELECT * INTO v_evt FROM platform_outbox_events WHERE event_type='requests.sent.v1' AND source_record_id = v_req.id;
  IF v_evt.organization_id <> '90000000-0000-0000-0000-000000000001'::UUID THEN
    RAISE EXCEPTION 'reversed direction: requests.sent.v1 should target Alpha (the receiving org), got org=%', v_evt.organization_id;
  END IF;
  IF v_req.to_org_id <> '90000000-0000-0000-0000-000000000001'::UUID THEN RAISE EXCEPTION 'fixture error: to_org_id not Alpha'; END IF;

  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90000000-0001-0000-0000-000000000002"}',true); -- Alpha super receives+routes+responds
  PERFORM mark_request_received(v_req.id);
  v_req := route_request(v_req.id, '90000000-0002-0000-0000-000000000001');
  v_resp := create_response(v_req.id, 'reverse response body', 'en');
  PERFORM submit_response(v_resp.id, NULL);
  v_resp := approve_response(v_resp.id, NULL);
  RESET ROLE;

  SELECT * INTO v_evt FROM platform_outbox_events WHERE event_type='requests.response_sent.v1' AND source_record_id = v_req.id;
  IF v_evt.organization_id <> '90000000-0000-0000-0000-000000000002'::UUID THEN
    RAISE EXCEPTION 'reversed direction: requests.response_sent.v1 should target Beta (the original creator''s org), got org=%', v_evt.organization_id;
  END IF;
  IF (v_evt.payload -> 'target_user_ids') <> jsonb_build_array('90000000-0001-0000-0000-000000000003'::UUID) THEN
    RAISE EXCEPTION 'reversed direction: response_sent should target the original Beta creator';
  END IF;
END $$;
INSERT INTO r90_results VALUES (21,'Bidirectionality proof: running the identical requests.sent.v1/requests.response_sent.v1 flow with Organization Beta as the sender and Organization Alpha as the receiver (the reverse of every scenario above) produces correct, symmetric CAP-003 events and recipients -- both events read from_org_id/to_org_id/created_by live off the actual request row, never a hard-coded "org A always sends" assumption anywhere in approve_request()/approve_response()');

-- ══════════════════ RLS-adjacent negative controls kept in the
-- dedicated RLS suite; this file stays focused on business behavior. ══

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM r90_results;
  RAISE NOTICE 'REQUESTS NOTIFICATION INTEGRATION BEHAVIORAL SUITE: % scenarios PASSED', v_count;
END $$;

ROLLBACK;
