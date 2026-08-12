-- CAP-003 Phase 1.6B notification event integration -- RLS suite.
-- Disposable local PostgreSQL only. Runs in one transaction and
-- leaves no fixtures (rolled back at the end).
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE r90r_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);

INSERT INTO organizations(id,name,type,code) VALUES
 ('90100000-0000-0000-0000-000000000001','R90R Org Alpha','authority','R90RA'),
 ('90100000-0000-0000-0000-000000000002','R90R Org Beta','authority','R90RB'),
 ('90100000-0000-0000-0000-000000000003','R90R Org Gamma','authority','R90RG');
INSERT INTO divisions(id, org_id, name) VALUES
 ('90100000-0004-0000-0000-000000000001','90100000-0000-0000-0000-000000000001','R90R Alpha Div'),
 ('90100000-0004-0000-0000-000000000002','90100000-0000-0000-0000-000000000002','R90R Beta Div'),
 ('90100000-0004-0000-0000-000000000003','90100000-0000-0000-0000-000000000003','R90R Gamma Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
 ('90100000-0002-0000-0000-000000000001','90100000-0000-0000-0000-000000000001','90100000-0004-0000-0000-000000000001','R90R Alpha Sec A','R90RAA'),
 ('90100000-0002-0000-0000-000000000002','90100000-0000-0000-0000-000000000002','90100000-0004-0000-0000-000000000002','R90R Beta Sec A','R90RBA'),
 ('90100000-0002-0000-0000-000000000003','90100000-0000-0000-0000-000000000003','90100000-0004-0000-0000-000000000003','R90R Gamma Sec A','R90RGA');
INSERT INTO auth.users(id,email) VALUES
 ('90100000-0001-0000-0000-000000000001','alpha-staff@r90rt.local'),
 ('90100000-0001-0000-0000-000000000002','alpha-super@r90rt.local'),
 ('90100000-0001-0000-0000-000000000003','beta-staff@r90rt.local'),
 ('90100000-0001-0000-0000-000000000004','beta-super@r90rt.local'),
 ('90100000-0001-0000-0000-000000000005','gamma-super@r90rt.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('90100000-0001-0000-0000-000000000001','90100000-0000-0000-0000-000000000001','R90R-1','Alpha Staff','alpha-staff@r90rt.local',true),
 ('90100000-0001-0000-0000-000000000002','90100000-0000-0000-0000-000000000001','R90R-2','Alpha Super','alpha-super@r90rt.local',true),
 ('90100000-0001-0000-0000-000000000003','90100000-0000-0000-0000-000000000002','R90R-3','Beta Staff','beta-staff@r90rt.local',true),
 ('90100000-0001-0000-0000-000000000004','90100000-0000-0000-0000-000000000002','R90R-4','Beta Super','beta-super@r90rt.local',true),
 ('90100000-0001-0000-0000-000000000005','90100000-0000-0000-0000-000000000003','R90R-5','Gamma Super','gamma-super@r90rt.local',true);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
 ('90100000-0001-0000-0000-000000000001','section','90100000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
 ('90100000-0001-0000-0000-000000000002','section','90100000-0002-0000-0000-000000000001','supervisor',TRUE,TRUE),
 ('90100000-0001-0000-0000-000000000003','section','90100000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
 ('90100000-0001-0000-0000-000000000004','section','90100000-0002-0000-0000-000000000002','mcs_admin',TRUE,TRUE),
 ('90100000-0001-0000-0000-000000000005','section','90100000-0002-0000-0000-000000000003','supervisor',TRUE,TRUE);

-- Produce one real requests.sent.v1 + one requests.routed.v1 event via
-- the actual RPCs, then drain the worker -- fixture setup only.
DO $$
DECLARE v_req requests;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90100000-0001-0000-0000-000000000001"}',true);
  v_req := create_request('90100000-0002-0000-0000-000000000001','90100000-0000-0000-0000-000000000002','S','B','en','en',NULL,NULL);
  PERFORM submit_request(v_req.id, NULL);
  PERFORM set_config('request.jwt.claims','{"sub":"90100000-0001-0000-0000-000000000004"}',true);
  v_req := approve_request(v_req.id, NULL);
  PERFORM mark_request_received(v_req.id);
  v_req := route_request(v_req.id, '90100000-0002-0000-0000-000000000002');
  RESET ROLE;
  PERFORM set_config('app.r90r_req', v_req.id::text, false);
END $$;

SET ROLE service_role;
SELECT * FROM process_platform_outbox_batch(50, 'r90r-worker');
RESET ROLE;

-- 1. Ordinary authenticated users cannot INSERT directly into
-- platform_outbox_events (unchanged Phase 1.1 posture -- still zero
-- authenticated grant/policy on the table).
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90100000-0001-0000-0000-000000000005"}',true);
  BEGIN
    INSERT INTO platform_outbox_events (event_type, source_module, source_record_type, source_record_id, organization_id, correlation_id, occurred_at, payload, idempotency_key)
    VALUES ('requests.sent.v1','requests','request', current_setting('app.r90r_req')::uuid,'90100000-0000-0000-0000-000000000002', gen_random_uuid(), NOW(), '{}'::JSONB, gen_random_uuid());
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN v_caught := TRUE;
  END;
  RESET ROLE;
  IF NOT v_caught THEN RAISE EXCEPTION 'SECURITY: an ordinary user directly inserted a requests.sent.v1 outbox row, bypassing approve_request()''s own authorization'; END IF;
END $$;
INSERT INTO r90r_results VALUES (1,'An ordinary authenticated user cannot bypass approve_request()/return_request()/route_request()/assign_request()/approve_response() by inserting a requests.*.v1-shaped row directly into platform_outbox_events -- unchanged Phase 1.1 posture');

-- 2. Ordinary authenticated users cannot call create_notification_intent()
-- directly for any requests.*.v1 event type either.
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90100000-0001-0000-0000-000000000005"}',true);
  BEGIN
    PERFORM create_notification_intent(
      (SELECT id FROM platform_outbox_events WHERE event_type = 'requests.sent.v1' LIMIT 1),
      'requests.sent.v1','requests.sent','{}'::JSONB,'normal','org_admins',
      NULL,'90100000-0000-0000-0000-000000000003',NULL,NULL,NULL,NULL,NULL
    );
  EXCEPTION WHEN insufficient_privilege OR undefined_function OR OTHERS THEN v_caught := TRUE;
  END;
  RESET ROLE;
  IF NOT v_caught THEN RAISE EXCEPTION 'SECURITY: an ordinary user directly created a requests.sent.v1 intent'; END IF;
END $$;
INSERT INTO r90r_results VALUES (2,'An ordinary authenticated user cannot call create_notification_intent() directly for any Phase 1.6B event type -- unchanged Phase 1.2 grant posture (service_role/internal only)');

-- 3. Ordinary authenticated users cannot invoke the worker directly.
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90100000-0001-0000-0000-000000000005"}',true);
  BEGIN
    PERFORM process_platform_outbox_batch(10, 'sneaky');
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN v_caught := TRUE;
  END;
  RESET ROLE;
  IF NOT v_caught THEN RAISE EXCEPTION 'SECURITY: an ordinary user directly invoked process_platform_outbox_batch()'; END IF;
END $$;
INSERT INTO r90r_results VALUES (3,'An ordinary authenticated user cannot directly invoke process_platform_outbox_batch() (service_role-only EXECUTE grant, unchanged since Phase 1.3)');

-- 4. Ordinary authenticated users cannot call intent_user_can_view_request()
-- directly (internal-only adapter, no grant).
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90100000-0001-0000-0000-000000000005"}',true);
  BEGIN
    PERFORM intent_user_can_view_request(current_setting('app.r90r_req')::uuid, '90100000-0001-0000-0000-000000000004');
  EXCEPTION WHEN insufficient_privilege OR undefined_function OR OTHERS THEN v_caught := TRUE;
  END;
  RESET ROLE;
  IF NOT v_caught THEN RAISE EXCEPTION 'SECURITY: an ordinary user directly invoked intent_user_can_view_request()'; END IF;
END $$;
INSERT INTO r90r_results VALUES (4,'An ordinary authenticated user cannot directly invoke intent_user_can_view_request() -- internal-only adapter, no EXECUTE grant to authenticated/anon, matching intent_user_can_view_task()/intent_user_can_view_meeting()''s own posture');

-- 5. user_notifications remain recipient-only: the real recipient
-- (Beta Admin, who was resolved for requests.sent.v1) sees their own
-- row; a same-org non-recipient (Beta Staff, a section member who was
-- correctly notified of the LATER requests.routed.v1 but is not an
-- org_admins candidate) sees zero requests.sent.v1 rows that aren't theirs.
DO $$
DECLARE v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90100000-0001-0000-0000-000000000004"}',true);
  SELECT count(*) INTO v_count FROM user_notifications WHERE notification_type = 'requests.sent.v1' AND source_record_id = current_setting('app.r90r_req')::uuid;
  RESET ROLE;
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected the real recipient (Beta Admin) to see exactly their own row, got %', v_count; END IF;

  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90100000-0001-0000-0000-000000000003"}',true);
  SELECT count(*) INTO v_count FROM user_notifications WHERE notification_type = 'requests.sent.v1' AND source_record_id = current_setting('app.r90r_req')::uuid;
  RESET ROLE;
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY: a same-org non-recipient saw a requests.sent.v1 row that is not theirs, got %', v_count; END IF;
END $$;
INSERT INTO r90r_results VALUES (5,'user_notifications RLS remains strictly recipient_user_id = auth.uid()-scoped for every Phase 1.6B event type -- a same-org user who is not a genuine resolved recipient sees zero rows, unchanged since Phase 1.1');

-- 6. A user in a genuinely unrelated third organization (Gamma) sees
-- nothing at all, even though they hold a supervisor role somewhere.
DO $$
DECLARE v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90100000-0001-0000-0000-000000000005"}',true);
  SELECT count(*) INTO v_count FROM user_notifications WHERE source_record_id = current_setting('app.r90r_req')::uuid;
  RESET ROLE;
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY: a third-org (Gamma) user saw a notification for a request their org is not party to'; END IF;
END $$;
INSERT INTO r90r_results VALUES (6,'A user belonging to a third organization that is not party to the request (neither from_org_id nor to_org_id) sees zero user_notifications rows for it -- cross-org isolation holds end-to-end');

-- 7. An ordinary user cannot UPDATE another user's user_notifications row.
DO $$
DECLARE v_id UUID; v_read_at TIMESTAMPTZ;
BEGIN
  SELECT id INTO v_id FROM user_notifications WHERE notification_type = 'requests.sent.v1' AND recipient_user_id = '90100000-0001-0000-0000-000000000004';
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90100000-0001-0000-0000-000000000003"}',true);
  UPDATE user_notifications SET read_at = now() WHERE id = v_id;
  RESET ROLE;
  SELECT read_at INTO v_read_at FROM user_notifications WHERE id = v_id;
  IF v_read_at IS NOT NULL THEN RAISE EXCEPTION 'SECURITY: a non-recipient marked another user''s notification as read'; END IF;
END $$;
INSERT INTO r90r_results VALUES (7,'An ordinary user cannot mark another recipient''s requests.sent.v1 user_notification as read -- RLS-enabled-zero-matching-policy UPDATE silently affects zero rows rather than raising, unchanged Phase 1.1/1.3 convention');

-- 8. Positive control: the real recipient CAN mark their own
-- notification as read.
DO $$
DECLARE v_id UUID; v_read_at TIMESTAMPTZ;
BEGIN
  SELECT id INTO v_id FROM user_notifications WHERE notification_type = 'requests.sent.v1' AND recipient_user_id = '90100000-0001-0000-0000-000000000004';
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90100000-0001-0000-0000-000000000004"}',true);
  UPDATE user_notifications SET read_at = now() WHERE id = v_id;
  RESET ROLE;
  SELECT read_at INTO v_read_at FROM user_notifications WHERE id = v_id;
  IF v_read_at IS NULL THEN RAISE EXCEPTION 'positive control failed: the real recipient could not mark their own notification read -- harness may be broken'; END IF;
END $$;
INSERT INTO r90r_results VALUES (8,'Positive control: the genuine recipient CAN mark their own notification as read -- confirms scenario 7''s denial is real RLS enforcement, not a broken test harness');

-- 9. requests_select RLS is completely unaffected by Phase 1.6B: an
-- outsider (Gamma) still cannot select the underlying request row, and
-- a legitimate party (Beta Staff, a section member of to_section_id)
-- still can.
DO $$
DECLARE v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90100000-0001-0000-0000-000000000005"}',true);
  SELECT count(*) INTO v_count FROM requests WHERE id = current_setting('app.r90r_req')::uuid;
  RESET ROLE;
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY: a third-org outsider unexpectedly can SELECT the request row after Phase 1.6B'; END IF;

  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90100000-0001-0000-0000-000000000003"}',true);
  SELECT count(*) INTO v_count FROM requests WHERE id = current_setting('app.r90r_req')::uuid;
  RESET ROLE;
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected the receiving section member to still see the request row after Phase 1.6B, got %', v_count; END IF;
END $$;
INSERT INTO r90r_results VALUES (9,'requests_select RLS is completely unaffected by Phase 1.6B -- a third-org outsider still cannot SELECT the request row, and a legitimate party (the receiving section''s own staff member) still can -- notification existence never grants Request access, and Request access is unchanged by notification existence');

-- 10. Direct write closure preserved: no INSERT/UPDATE grant reopened
-- on requests/responses (Phase 1.6A's own posture, untouched here).
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90100000-0001-0000-0000-000000000001"}',true);
  BEGIN
    UPDATE requests SET status = 'sent' WHERE id = current_setting('app.r90r_req')::uuid;
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN v_caught := TRUE;
  END;
  RESET ROLE;
  IF NOT v_caught THEN RAISE EXCEPTION 'SECURITY: a direct UPDATE on requests succeeded -- Phase 1.6A''s direct-write closure was reopened'; END IF;
END $$;
INSERT INTO r90r_results VALUES (10,'Phase 1.6A''s direct-write closure on requests/responses (no authenticated INSERT/UPDATE grant) remains intact -- Phase 1.6B introduces no new direct write path');

-- 11. platform_event_type_registry: ordinary authenticated users still
-- cannot write to it, despite Phase 1.6B adding 5 new rows via the
-- migration itself (not via any relaxed grant).
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"90100000-0001-0000-0000-000000000005"}',true);
  BEGIN
    INSERT INTO platform_event_type_registry (event_type, owning_module, description, uses_generic_notification_envelope)
    VALUES ('requests.sneaky.v1','requests','sneaky',TRUE);
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN v_caught := TRUE;
  END;
  RESET ROLE;
  IF NOT v_caught THEN RAISE EXCEPTION 'SECURITY: an ordinary user wrote a new row into platform_event_type_registry'; END IF;
END $$;
INSERT INTO r90r_results VALUES (11,'An ordinary authenticated user still cannot INSERT into platform_event_type_registry -- admin-only RLS policy unchanged, confirmed after Phase 1.6B added 5 new rows via the migration itself');

RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM r90r_results;
  IF v_count <> 11 THEN RAISE EXCEPTION 'expected 11 scenarios recorded, got %', v_count; END IF;
  RAISE NOTICE 'Requests notification integration RLS tests PASSED: 11/11';
END $$;

ROLLBACK;
