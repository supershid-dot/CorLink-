-- CAP-003 Phase 1.7B notification event integration -- RLS suite.
-- Disposable local PostgreSQL only. Runs in one transaction and leaves
-- no fixtures (rolled back at the end).
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE e92r_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);

INSERT INTO organizations(id,name,type,code) VALUES
 ('92100000-0000-0000-0000-000000000001','E92R Org Alpha','authority','E92RA'),
 ('92100000-0000-0000-0000-000000000002','E92R Org Gamma','authority','E92RG');
INSERT INTO divisions(id, org_id, name) VALUES
 ('92100000-0004-0000-0000-000000000001','92100000-0000-0000-0000-000000000001','E92R Alpha Div'),
 ('92100000-0004-0000-0000-000000000002','92100000-0000-0000-0000-000000000002','E92R Gamma Div');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
 ('92100000-0002-0000-0000-000000000001','92100000-0000-0000-0000-000000000001','92100000-0004-0000-0000-000000000001','E92R Records','E92RREC'),
 ('92100000-0002-0000-0000-000000000002','92100000-0000-0000-0000-000000000001','92100000-0004-0000-0000-000000000001','E92R Welfare','E92RWEL'),
 ('92100000-0002-0000-0000-000000000003','92100000-0000-0000-0000-000000000002','92100000-0004-0000-0000-000000000002','E92R Gamma Sec','E92RGS'),
 -- A THIRD Alpha section deliberately NOT registered in entry_sections
 -- -- e.g. a general administrative section with no Entry involvement
 -- at all -- used by scenario 12 below.
 ('92100000-0002-0000-0000-000000000004','92100000-0000-0000-0000-000000000001','92100000-0004-0000-0000-000000000001','E92R General Admin','E92RGA');
INSERT INTO entry_sections(org_id, section_id) VALUES
 ('92100000-0000-0000-0000-000000000001','92100000-0002-0000-0000-000000000001'),
 ('92100000-0000-0000-0000-000000000001','92100000-0002-0000-0000-000000000002'),
 ('92100000-0000-0000-0000-000000000002','92100000-0002-0000-0000-000000000003');
INSERT INTO auth.users(id,email) VALUES
 ('92100000-0001-0000-0000-000000000001','e92r-clerk@t.local'),
 ('92100000-0001-0000-0000-000000000002','e92r-welfare-staff@t.local'),
 ('92100000-0001-0000-0000-000000000003','e92r-records-staff@t.local'),
 ('92100000-0001-0000-0000-000000000004','e92r-org-admin@t.local'),
 ('92100000-0001-0000-0000-000000000005','e92r-gamma-super@t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('92100000-0001-0000-0000-000000000001','92100000-0000-0000-0000-000000000001','E92R-1','Clerk','e92r-clerk@t.local',true),
 ('92100000-0001-0000-0000-000000000002','92100000-0000-0000-0000-000000000001','E92R-2','Welfare Staff','e92r-welfare-staff@t.local',true),
 ('92100000-0001-0000-0000-000000000003','92100000-0000-0000-0000-000000000001','E92R-3','Records Staff','e92r-records-staff@t.local',true),
 ('92100000-0001-0000-0000-000000000004','92100000-0000-0000-0000-000000000001','E92R-4','Org Admin','e92r-org-admin@t.local',true),
 ('92100000-0001-0000-0000-000000000005','92100000-0000-0000-0000-000000000002','E92R-5','Gamma Super','e92r-gamma-super@t.local',true);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
 ('92100000-0001-0000-0000-000000000001','section','92100000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
 ('92100000-0001-0000-0000-000000000002','section','92100000-0002-0000-0000-000000000002','staff',TRUE,TRUE),
 ('92100000-0001-0000-0000-000000000003','section','92100000-0002-0000-0000-000000000001','staff',TRUE,TRUE),
 -- Org Admin: an authority_admin role, but assigned ONLY to General
 -- Admin -- a section deliberately NOT registered in entry_sections at
 -- all (not Records, not Welfare). Used to prove
 -- intent_user_can_view_entry() has no admin-role-alone bypass -- the
 -- same class of bug is_entry_staff()'s own schema comment documents
 -- was reported and removed (a blanket is_supervisor_or_above() bypass
 -- regardless of genuine entry-section membership).
 ('92100000-0001-0000-0000-000000000004','section','92100000-0002-0000-0000-000000000004','authority_admin',TRUE,TRUE),
 ('92100000-0001-0000-0000-000000000005','section','92100000-0002-0000-0000-000000000003','supervisor',TRUE,TRUE);

-- Produce one real entry.routed.v1 + one entry.assigned.v1 event via
-- the actual RPCs, then drain the worker -- fixture setup only.
DO $$
DECLARE v_ent external_correspondence;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92100000-0001-0000-0000-000000000001"}',true);
  v_ent := create_entry('letter','public','RLS Sender','RLS Subject','RLS Body');
  v_ent := route_entry(v_ent.id, '92100000-0002-0000-0000-000000000002', '92100000-0001-0000-0000-000000000002');
  RESET ROLE;
  PERFORM set_config('app.e92r_ent', v_ent.id::text, false);
END $$;

SET ROLE service_role;
SELECT * FROM process_platform_outbox_batch(50, 'e92r-worker');
RESET ROLE;

-- 1. Ordinary authenticated users cannot INSERT directly into
-- platform_outbox_events with an entry.*.v1 shape.
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92100000-0001-0000-0000-000000000005"}',true);
  BEGIN
    INSERT INTO platform_outbox_events (event_type, source_module, source_record_type, source_record_id, organization_id, correlation_id, occurred_at, payload, idempotency_key)
    VALUES ('entry.assigned.v1','entry','external_correspondence', current_setting('app.e92r_ent')::uuid,'92100000-0000-0000-0000-000000000001', gen_random_uuid(), NOW(), '{}'::JSONB, gen_random_uuid());
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN v_caught := TRUE;
  END;
  RESET ROLE;
  IF NOT v_caught THEN RAISE EXCEPTION 'SECURITY: an ordinary user directly inserted an entry.assigned.v1 outbox row, bypassing assign_entry()/route_entry()''s own authorization'; END IF;
END $$;
INSERT INTO e92r_results VALUES (1,'An ordinary authenticated user cannot bypass route_entry()/assign_entry()/approve_entry_reply()/return_entry_reply() by inserting an entry.*.v1-shaped row directly into platform_outbox_events');

-- 2. Ordinary authenticated users cannot call create_notification_intent()
-- directly for any entry.*.v1 event type either.
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92100000-0001-0000-0000-000000000005"}',true);
  BEGIN
    PERFORM create_notification_intent(
      (SELECT id FROM platform_outbox_events WHERE event_type = 'entry.assigned.v1' LIMIT 1),
      'entry.assigned.v1','entry.assigned','{}'::JSONB,'normal','specific_users',
      ARRAY['92100000-0001-0000-0000-000000000005'::UUID],NULL,NULL,NULL,NULL,NULL,NULL
    );
  EXCEPTION WHEN insufficient_privilege OR undefined_function OR OTHERS THEN v_caught := TRUE;
  END;
  RESET ROLE;
  IF NOT v_caught THEN RAISE EXCEPTION 'SECURITY: an ordinary user directly created an entry.assigned.v1 intent'; END IF;
END $$;
INSERT INTO e92r_results VALUES (2,'An ordinary authenticated user cannot call create_notification_intent() directly for any Phase 1.7B event type -- unchanged Phase 1.2 grant posture (service_role/internal only)');

-- 3. Ordinary authenticated users cannot invoke the worker directly.
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92100000-0001-0000-0000-000000000005"}',true);
  BEGIN
    PERFORM process_platform_outbox_batch(10, 'sneaky');
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN v_caught := TRUE;
  END;
  RESET ROLE;
  IF NOT v_caught THEN RAISE EXCEPTION 'SECURITY: an ordinary user directly invoked process_platform_outbox_batch()'; END IF;
END $$;
INSERT INTO e92r_results VALUES (3,'An ordinary authenticated user cannot directly invoke process_platform_outbox_batch() (service_role-only EXECUTE grant, unchanged since Phase 1.3)');

-- 4. Ordinary authenticated users cannot call intent_user_can_view_entry()
-- directly (internal-only adapter, no grant).
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92100000-0001-0000-0000-000000000005"}',true);
  BEGIN
    PERFORM intent_user_can_view_entry(current_setting('app.e92r_ent')::uuid, '92100000-0001-0000-0000-000000000002');
  EXCEPTION WHEN insufficient_privilege OR undefined_function OR OTHERS THEN v_caught := TRUE;
  END;
  RESET ROLE;
  IF NOT v_caught THEN RAISE EXCEPTION 'SECURITY: an ordinary user directly invoked intent_user_can_view_entry()'; END IF;
END $$;
INSERT INTO e92r_results VALUES (4,'An ordinary authenticated user cannot directly invoke intent_user_can_view_entry() -- internal-only adapter, no EXECUTE grant to authenticated/anon, matching every other intent_user_can_view_*() adapter''s own posture');

-- 5. user_notifications remain recipient-only: the real recipient
-- (Welfare Staff, assigned via route_entry) sees their own row; a
-- same-org non-recipient (Records Staff, who has no relationship to
-- this entry) sees zero rows that aren't theirs.
DO $$
DECLARE v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92100000-0001-0000-0000-000000000002"}',true);
  SELECT count(*) INTO v_count FROM user_notifications WHERE notification_type = 'entry.assigned.v1' AND source_record_id = current_setting('app.e92r_ent')::uuid;
  RESET ROLE;
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected the real recipient (Welfare Staff, the assignee) to see exactly their own row, got %', v_count; END IF;

  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92100000-0001-0000-0000-000000000003"}',true);
  SELECT count(*) INTO v_count FROM user_notifications WHERE notification_type = 'entry.assigned.v1' AND source_record_id = current_setting('app.e92r_ent')::uuid;
  RESET ROLE;
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY: a same-org non-recipient (Records Staff, unrelated to this entry) saw an entry.assigned.v1 row that is not theirs, got %', v_count; END IF;
END $$;
INSERT INTO e92r_results VALUES (5,'user_notifications RLS remains strictly recipient_user_id = auth.uid()-scoped for every Phase 1.7B event type -- a same-org user who is not a genuine resolved recipient sees zero rows, unchanged since Phase 1.1');

-- 6. A user in a genuinely unrelated third organization (Gamma) sees
-- nothing at all, even though they hold a supervisor role somewhere and
-- their own org is also Entry-enabled.
DO $$
DECLARE v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92100000-0001-0000-0000-000000000005"}',true);
  SELECT count(*) INTO v_count FROM user_notifications WHERE source_record_id = current_setting('app.e92r_ent')::uuid;
  RESET ROLE;
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY: a third-org (Gamma) user saw a notification for an entry their org is not party to'; END IF;
END $$;
INSERT INTO e92r_results VALUES (6,'A user belonging to a third organization not party to the entry sees zero user_notifications rows for it -- cross-org isolation holds end-to-end, even though Gamma is itself an Entry-enabled org with its own staff');

-- 7. An ordinary user cannot UPDATE another user's user_notifications row.
DO $$
DECLARE v_id UUID; v_read_at TIMESTAMPTZ;
BEGIN
  SELECT id INTO v_id FROM user_notifications WHERE notification_type = 'entry.assigned.v1' AND recipient_user_id = '92100000-0001-0000-0000-000000000002';
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92100000-0001-0000-0000-000000000003"}',true);
  UPDATE user_notifications SET read_at = now() WHERE id = v_id;
  RESET ROLE;
  SELECT read_at INTO v_read_at FROM user_notifications WHERE id = v_id;
  IF v_read_at IS NOT NULL THEN RAISE EXCEPTION 'SECURITY: a non-recipient marked another user''s notification as read'; END IF;
END $$;
INSERT INTO e92r_results VALUES (7,'An ordinary user cannot mark another recipient''s entry.assigned.v1 user_notification as read -- RLS-enabled-zero-matching-policy UPDATE silently affects zero rows rather than raising, unchanged Phase 1.1/1.3 convention');

-- 8. Positive control: the real recipient CAN mark their own
-- notification as read.
DO $$
DECLARE v_id UUID; v_read_at TIMESTAMPTZ;
BEGIN
  SELECT id INTO v_id FROM user_notifications WHERE notification_type = 'entry.assigned.v1' AND recipient_user_id = '92100000-0001-0000-0000-000000000002';
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92100000-0001-0000-0000-000000000002"}',true);
  UPDATE user_notifications SET read_at = now() WHERE id = v_id;
  RESET ROLE;
  SELECT read_at INTO v_read_at FROM user_notifications WHERE id = v_id;
  IF v_read_at IS NULL THEN RAISE EXCEPTION 'positive control failed: the real recipient could not mark their own notification read -- harness may be broken'; END IF;
END $$;
INSERT INTO e92r_results VALUES (8,'Positive control: the genuine recipient CAN mark their own notification as read -- confirms scenario 7''s denial is real RLS enforcement, not a broken test harness');

-- 9. external_correspondence_select RLS is completely unaffected by
-- Phase 1.7B: an outsider (Gamma) still cannot select the entry row,
-- and a legitimate party (the assignee) still can.
DO $$
DECLARE v_count INTEGER;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92100000-0001-0000-0000-000000000005"}',true);
  SELECT count(*) INTO v_count FROM external_correspondence WHERE id = current_setting('app.e92r_ent')::uuid;
  RESET ROLE;
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY: a third-org outsider unexpectedly can SELECT the entry row after Phase 1.7B'; END IF;

  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92100000-0001-0000-0000-000000000002"}',true);
  SELECT count(*) INTO v_count FROM external_correspondence WHERE id = current_setting('app.e92r_ent')::uuid;
  RESET ROLE;
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected the assignee to still see the entry row after Phase 1.7B, got %', v_count; END IF;
END $$;
INSERT INTO e92r_results VALUES (9,'external_correspondence_select RLS is completely unaffected by Phase 1.7B -- a third-org outsider still cannot SELECT the entry row, and a legitimate party (the assignee) still can -- notification existence never grants Entry access, and Entry access is unchanged by notification existence');

-- 10. Direct write closure preserved: no INSERT/UPDATE grant reopened
-- on external_correspondence/external_correspondence_replies (Phase
-- 1.7A's own posture, untouched here).
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92100000-0001-0000-0000-000000000001"}',true);
  BEGIN
    UPDATE external_correspondence SET status = 'closed' WHERE id = current_setting('app.e92r_ent')::uuid;
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN v_caught := TRUE;
  END;
  RESET ROLE;
  IF NOT v_caught THEN RAISE EXCEPTION 'SECURITY: a direct UPDATE on external_correspondence succeeded -- Phase 1.7A''s direct-write closure was reopened'; END IF;
END $$;
INSERT INTO e92r_results VALUES (10,'Phase 1.7A''s direct-write closure on external_correspondence/external_correspondence_replies (no authenticated INSERT/UPDATE grant) remains intact -- Phase 1.7B introduces no new direct write path');

-- 11. platform_event_type_registry: ordinary authenticated users still
-- cannot write to it, despite Phase 1.7B adding 4 new rows via the
-- migration itself (not via any relaxed grant).
DO $$
DECLARE v_caught BOOLEAN := FALSE;
BEGIN
  SET ROLE authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"92100000-0001-0000-0000-000000000005"}',true);
  BEGIN
    INSERT INTO platform_event_type_registry (event_type, owning_module, description, uses_generic_notification_envelope)
    VALUES ('entry.sneaky.v1','entry','sneaky',TRUE);
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN v_caught := TRUE;
  END;
  RESET ROLE;
  IF NOT v_caught THEN RAISE EXCEPTION 'SECURITY: an ordinary user wrote a new row into platform_event_type_registry'; END IF;
END $$;
INSERT INTO e92r_results VALUES (11,'An ordinary authenticated user still cannot INSERT into platform_event_type_registry -- admin-only RLS policy unchanged, confirmed after Phase 1.7B added 4 new rows via the migration itself');

-- 12. NO ADMIN-ROLE-ALONE BYPASS proof: intent_user_can_view_entry()
-- called directly as superuser (bypassing the grant check itself, to
-- isolate and test its own BUSINESS LOGIC) returns FALSE for an org
-- authority_admin whose only section assignment (General Admin) is
-- deliberately NOT registered in entry_sections at all -- not Records,
-- not Welfare (this entry's own to_section_id) -- and who is neither
-- its entered_by nor its assigned_to. A genuine, evidenced divergence
-- from intent_user_can_view_request()'s own admin-bypass branch (see
-- docs/92/patch header): Entry RLS's own is_entry_staff() deliberately
-- has no admin-role-alone bypass (a documented, reported, fixed bug --
-- schema.sql's own comment on is_entry_staff() describes exactly this
-- class of prior defect).
DO $$
DECLARE v_authorized BOOLEAN;
BEGIN
  SELECT intent_user_can_view_entry(current_setting('app.e92r_ent')::uuid, '92100000-0001-0000-0000-000000000004') INTO v_authorized;
  IF v_authorized THEN
    RAISE EXCEPTION 'SECURITY: intent_user_can_view_entry() unexpectedly authorized an org admin (authority_admin) with no genuine entry-section membership and no assignment/entered_by relationship to this entry -- an admin-role-alone bypass was reintroduced despite is_entry_staff()''s own documented bug fix removing it';
  END IF;
END $$;
INSERT INTO e92r_results VALUES (12,'intent_user_can_view_entry() correctly returns FALSE for an org authority_admin whose only section assignment (General Admin) is not registered in entry_sections at all, is not this entry''s own to_section_id (Welfare), and who is neither entered_by nor assigned_to -- proves NO admin-role-alone bypass exists, a deliberate, evidenced divergence from intent_user_can_view_request()''s own admin-bypass branch, matching is_entry_staff()''s own real, bug-fixed RLS behavior exactly (an admin role alone grants nothing; genuine entry-section membership is required)');

-- 13. Positive control for scenario 12: the SAME admin user, once
-- actually assigned to Welfare (this entry's to_section_id), IS
-- authorized -- proves scenario 12's FALSE result was the admin-bypass
-- check specifically, not a broken adapter.
DO $$
DECLARE v_authorized BOOLEAN;
BEGIN
  INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active)
  VALUES ('92100000-0001-0000-0000-000000000004','section','92100000-0002-0000-0000-000000000002','staff',FALSE,TRUE);
  SELECT intent_user_can_view_entry(current_setting('app.e92r_ent')::uuid, '92100000-0001-0000-0000-000000000004') INTO v_authorized;
  IF NOT v_authorized THEN
    RAISE EXCEPTION 'positive control failed: the same user, once genuinely assigned to the entry''s own to_section_id (Welfare), should be authorized -- adapter may be broken, not just admin-bypass-free';
  END IF;
  DELETE FROM user_assignments WHERE user_id = '92100000-0001-0000-0000-000000000004' AND scope_id = '92100000-0002-0000-0000-000000000002';
END $$;
INSERT INTO e92r_results VALUES (13,'Positive control: the same org-admin user, once given a genuine section assignment to the entry''s own to_section_id (Welfare), IS correctly authorized by intent_user_can_view_entry() -- confirms scenario 12''s FALSE result reflects the deliberate absence of an admin-wide bypass, not a broken or overly-restrictive adapter');

RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM e92r_results;
  IF v_count <> 13 THEN RAISE EXCEPTION 'expected 13 scenarios recorded, got %', v_count; END IF;
  RAISE NOTICE 'Entry notification integration RLS tests PASSED: 13/13';
END $$;

ROLLBACK;
