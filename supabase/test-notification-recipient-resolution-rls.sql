-- CAP-003 Phase 1.2 notification recipient resolution -- RLS test
-- suite. Disposable local PostgreSQL only. Runs in one transaction
-- and leaves no fixtures (rolled back at the end). Uses authenticated
-- non-superuser contexts throughout for every authorization-relevant
-- assertion.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf82r_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf82r_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf82r_results, wf82r_ids TO authenticated, service_role;

INSERT INTO organizations(id,name,type,code) VALUES ('82100000-0000-0000-0000-000000000001','WF82R Org','authority','WF82RA');
INSERT INTO auth.users(id,email) VALUES
 ('82100000-0001-0000-0000-000000000001','r1@wf82rt.local'),
 ('82100000-0001-0000-0000-000000000002','r2@wf82rt.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('82100000-0001-0000-0000-000000000001','82100000-0000-0000-0000-000000000001','WF82R-1','Recipient','r1@wf82rt.local',true),
 ('82100000-0001-0000-0000-000000000002','82100000-0000-0000-0000-000000000001','WF82R-2','Unrelated','r2@wf82rt.local',true);

\set R1 '{"sub":"82100000-0001-0000-0000-000000000001"}'
\set R2 '{"sub":"82100000-0001-0000-0000-000000000002"}'

SET ROLE service_role;
DO $$
DECLARE v_outbox_id UUID; v_intent_id UUID; v_result RECORD;
BEGIN
  v_outbox_id := platform_enqueue_outbox_event(
    'platform.wf82r_test.v1','platform','platform',gen_random_uuid(),
    '82100000-0000-0000-0000-000000000001'::UUID,NULL,gen_random_uuid(),NULL,now(),'{}'::JSONB,gen_random_uuid());
  v_intent_id := create_notification_intent(
    v_outbox_id, 'platform.wf82r_test.v1','x.title','{}'::JSONB,'normal',
    'specific_users', ARRAY['82100000-0001-0000-0000-000000000001']::UUID[], NULL, NULL, NULL, NULL,NULL,NULL);
  SELECT * INTO v_result FROM resolve_notification_intent(v_intent_id);
  INSERT INTO wf82r_ids VALUES ('outbox', v_outbox_id);
  INSERT INTO wf82r_ids VALUES ('intent', v_intent_id);
  SELECT id INTO STRICT v_intent_id FROM user_notifications WHERE outbox_event_id = v_outbox_id AND recipient_user_id = '82100000-0001-0000-0000-000000000001';
  INSERT INTO wf82r_ids VALUES ('notif', v_intent_id);
END $$;
RESET ROLE;

-- ── 1: ordinary user cannot read raw intents ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'R1', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  BEGIN
    SELECT count(*) INTO v_count FROM notification_intents;
    IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user read % notification_intents rows', v_count; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf82r_results VALUES (1,'An ordinary authenticated user cannot read raw notification_intents rows (permission-denied or RLS-empty, either is a valid denial)');

-- ── 2: ordinary user cannot read raw target descriptors ──
-- (Target descriptors are columns on notification_intents itself, not
-- a separate table -- the same denial as scenario 1 covers them; this
-- scenario additionally confirms even a targeted column-selecting
-- query gains nothing.)
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'R1', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  BEGIN
    SELECT count(*) INTO v_count FROM notification_intents WHERE target_type = 'specific_users';
    IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user read % target-descriptor rows', v_count; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf82r_results VALUES (2,'An ordinary authenticated user cannot read raw target-descriptor fields either -- they live on notification_intents, which carries the same zero-visibility RLS posture');

-- ── 3: ordinary user cannot create intents ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'R1', false);
DO $$
BEGIN
  BEGIN
    PERFORM create_notification_intent(
      (SELECT id FROM wf82r_ids WHERE name='outbox'), 'platform.wf82r_test.v1','x.title','{}'::JSONB,'normal',
      'specific_users', ARRAY['82100000-0001-0000-0000-000000000001']::UUID[], NULL, NULL, NULL, NULL,NULL,NULL);
    RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user created a notification intent';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf82r_results VALUES (3,'An ordinary authenticated user cannot call create_notification_intent (EXECUTE granted to service_role only)');

-- ── 4: ordinary user cannot invoke resolver ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'R1', false);
DO $$
BEGIN
  BEGIN
    PERFORM resolve_notification_intent((SELECT id FROM wf82r_ids WHERE name='intent'));
    RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user invoked resolve_notification_intent';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf82r_results VALUES (4,'An ordinary authenticated user cannot call resolve_notification_intent (EXECUTE granted to service_role only)');

-- ── 5: service/internal role can ──
SET ROLE service_role;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM notification_intents WHERE id = (SELECT id FROM wf82r_ids WHERE name='intent');
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected service_role to see the intent it created, got %', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf82r_results VALUES (5,'The service/internal role (service_role, BYPASSRLS) can read and operate on notification_intents normally -- the lockout in scenarios 1-4 is specific to ordinary authenticated sessions');

-- ── 6: user_notifications remain recipient-only ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'R1', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM user_notifications WHERE id = (SELECT id FROM wf82r_ids WHERE name='notif');
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected the recipient to see their own notification, got %', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf82r_results VALUES (6,'The recipient can still read their own user_notifications row, created via intent resolution, exactly as Phase 1.1 established');

-- ── 7: cross-user notification visibility impossible ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'R2', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM user_notifications WHERE id = (SELECT id FROM wf82r_ids WHERE name='notif');
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: an unrelated user saw another recipient''s notification, count=%', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf82r_results VALUES (7,'A different, unrelated user cannot see another recipient''s notification, even one created via intent resolution rather than the old direct primitive');

-- ── 8: anonymous denied ──
SET ROLE anon;
DO $$
DECLARE v_count INTEGER;
BEGIN
  BEGIN
    SELECT count(*) INTO v_count FROM notification_intents;
    IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: anon read % notification_intents rows', v_count; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    SELECT count(*) INTO v_count FROM user_notifications;
    IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: anon read % user_notifications rows', v_count; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM create_notification_intent(
      (SELECT id FROM wf82r_ids WHERE name='outbox'), 'platform.wf82r_test.v1','x.title','{}'::JSONB,'normal',
      'specific_users', ARRAY['82100000-0001-0000-0000-000000000001']::UUID[], NULL, NULL, NULL, NULL,NULL,NULL);
    RAISE EXCEPTION 'SECURITY HOLE: anon created a notification intent';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM resolve_notification_intent((SELECT id FROM wf82r_ids WHERE name='intent'));
    RAISE EXCEPTION 'SECURITY HOLE: anon invoked resolve_notification_intent';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf82r_results VALUES (8,'Anonymous access is denied across every Phase 1.2 surface: zero SELECT visibility on notification_intents/user_notifications, and EXECUTE denied on both create_notification_intent and resolve_notification_intent');

-- ── 9: legacy security fixes remain intact ──
DO $$
DECLARE v_missing TEXT := '';
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='notifications'
      AND policyname='notif_select' AND cmd='SELECT' AND qual='(user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'notif_select-drift '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='notifications'
      AND policyname='notif_update' AND cmd='UPDATE' AND qual='(user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'notif_update-drift '; END IF;
  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='notifications' AND cmd='INSERT'
  ) THEN v_missing := v_missing || 'unexpected-notif-insert-policy '; END IF;
  IF to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)') IS NULL THEN
    v_missing := v_missing || 'create_legacy_notification-missing ';
  END IF;
  IF to_regprocedure('public.notif_request_legitimate_recipient(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || '1.0b-baseline-drift ';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_notifications'
      AND policyname='user_notifications_select' AND cmd='SELECT' AND qual='(recipient_user_id = auth.uid())'
  ) THEN v_missing := v_missing || '1.1-baseline-drift '; END IF;
  IF v_missing <> '' THEN RAISE EXCEPTION 'legacy/prior-phase security fixes drifted: %', v_missing; END IF;
END $$;
INSERT INTO wf82r_results VALUES (9,'Every prior-phase security fix (1.0A/1.0B legacy notification RLS, Phase 1.1 user_notifications RLS) remains byte-identical to its own established shape -- Phase 1.2 is purely additive');

RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf82r_results;
  IF v_count <> 9 THEN RAISE EXCEPTION 'Expected 9 scenarios to record a result, found %', v_count; END IF;
  RAISE NOTICE 'Notification recipient resolution RLS tests PASSED: %/9', v_count;
END $$;

ROLLBACK;
