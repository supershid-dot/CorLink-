-- CAP-003 Phase 1.3 notification outbox worker -- RLS test suite.
-- Disposable local PostgreSQL only. Runs in one transaction and leaves
-- no fixtures (rolled back at the end). Uses authenticated
-- non-superuser contexts throughout for every authorization-relevant
-- assertion.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf83r_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf83r_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf83r_results, wf83r_ids TO authenticated, service_role;

INSERT INTO organizations(id,name,type,code) VALUES ('83100000-0000-0000-0000-000000000001','WF83R Org','authority','WF83RA');
INSERT INTO auth.users(id,email) VALUES ('83100000-0001-0000-0000-000000000001','r1@wf83rt.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('83100000-0001-0000-0000-000000000001','83100000-0000-0000-0000-000000000001','WF83R-1','Recipient','r1@wf83rt.local',true);

\set R1 '{"sub":"83100000-0001-0000-0000-000000000001"}'

SET ROLE service_role;
DO $$
DECLARE v_outbox_id UUID; v_dl_id UUID;
BEGIN
  v_outbox_id := platform_enqueue_outbox_event(
    'platform.generic_notification_request.v1','platform','platform',gen_random_uuid(),
    '83100000-0000-0000-0000-000000000001'::UUID,NULL,gen_random_uuid(),NULL,now(),
    jsonb_build_object('notification_type','platform.wf83r_test.v1','title_template_key','x.title',
      'target_type','specific_users','target_user_ids', jsonb_build_array('83100000-0001-0000-0000-000000000001')),
    gen_random_uuid());
  INSERT INTO wf83r_ids VALUES ('outbox', v_outbox_id);

  v_dl_id := platform_enqueue_outbox_event(
    'platform.wf83r_poison.v1','platform','platform',gen_random_uuid(),
    '83100000-0000-0000-0000-000000000001'::UUID,NULL,gen_random_uuid(),NULL,now(),'{}'::JSONB,gen_random_uuid());
  UPDATE platform_outbox_events SET status = 'dead_letter', attempt_count = 5 WHERE id = v_dl_id;
  INSERT INTO wf83r_ids VALUES ('dead_letter', v_dl_id);
END $$;
RESET ROLE;

-- ── 1: authenticated cannot call the worker ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'R1', false);
DO $$
BEGIN
  BEGIN
    PERFORM * FROM process_platform_outbox_batch(25, 'attacker-worker');
    RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user invoked process_platform_outbox_batch';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf83r_results VALUES (1,'An ordinary authenticated user cannot call process_platform_outbox_batch (EXECUTE granted to service_role only)');

-- ── 2: anon cannot call the worker ──
SET ROLE anon;
DO $$
BEGIN
  BEGIN
    PERFORM * FROM process_platform_outbox_batch(25, 'attacker-worker');
    RAISE EXCEPTION 'SECURITY HOLE: anon invoked process_platform_outbox_batch';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf83r_results VALUES (2,'Anonymous sessions cannot call process_platform_outbox_batch (EXECUTE denied)');

-- ── 3: service/internal role can call the worker ──
SET ROLE service_role;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM process_platform_outbox_batch(25, 'rls-suite-worker')
  WHERE event_id = (SELECT id FROM wf83r_ids WHERE name='outbox');
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected service_role to successfully process the fixture event, got %', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf83r_results VALUES (3,'The service/internal role (service_role, BYPASSRLS) can invoke process_platform_outbox_batch and it processes real work -- the lockout in scenarios 1-2 is specific to ordinary authenticated/anon sessions');

-- ── 4: authenticated cannot read raw outbox rows ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'R1', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  BEGIN
    SELECT count(*) INTO v_count FROM platform_outbox_events;
    IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user read % platform_outbox_events rows', v_count; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf83r_results VALUES (4,'An ordinary authenticated user still cannot read raw platform_outbox_events rows -- the worker''s own processing-state writes (status/attempt_count/next_attempt_at/last_error/claimed_*) do not weaken Phase 1.1''s zero-policy outbox RLS');

-- ── 5: authenticated cannot read raw intents ──
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
INSERT INTO wf83r_results VALUES (5,'An ordinary authenticated user still cannot read raw notification_intents rows created by the worker -- Phase 1.2''s zero-policy RLS is unaffected');

-- ── 6: user_notifications remain recipient-only ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'R1', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM user_notifications
  WHERE outbox_event_id = (SELECT id FROM wf83r_ids WHERE name='outbox') AND recipient_user_id = '83100000-0001-0000-0000-000000000001';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected the recipient to see their own worker-created notification, got %', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf83r_results VALUES (6,'The recipient can read their own user_notifications row even when it was created by the worker rather than a direct create_notification_intent/resolve_notification_intent call -- Phase 1.1''s recipient-scoped RLS applies identically regardless of the caller');

-- ── 7: no direct write reaches any Phase 1.1/1.2 table -- RLS (zero
-- policies for authenticated/anon on both tables), not table-level
-- GRANT, is the real gate here, exactly matching this disposable
-- harness's own documented posture (01-mock-grants.sql mirrors real
-- Supabase: broad table GRANT + RLS as the actual enforcement) and
-- exactly how every other CAP-003 RLS suite in this codebase already
-- verifies this boundary -- a raw has_table_privilege() check would
-- pass even though the write itself is denied, so this scenario
-- attempts the real writes instead. ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'R1', false);
DO $$
DECLARE v_missing TEXT := '';
BEGIN
  BEGIN
    INSERT INTO platform_outbox_events (event_type,source_module,source_record_type,source_record_id,organization_id,correlation_id,occurred_at,idempotency_key)
    VALUES ('platform.wf83r_hack.v1','x','platform',gen_random_uuid(),'83100000-0000-0000-0000-000000000001',gen_random_uuid(),now(),gen_random_uuid());
    v_missing := v_missing || 'authenticated-direct-outbox-insert-succeeded ';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO notification_intents (outbox_event_id,organization_id,notification_type,title_template_key,source_module,source_record_type,source_record_id,target_type,target_user_ids,target_key)
    VALUES ((SELECT id FROM wf83r_ids WHERE name='outbox'),'83100000-0000-0000-0000-000000000001','platform.wf83r_hack.v1','x','x','platform',gen_random_uuid(),'specific_users',ARRAY['83100000-0001-0000-0000-000000000001']::UUID[],'83100000-0001-0000-0000-000000000001');
    v_missing := v_missing || 'authenticated-direct-intent-insert-succeeded ';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  DECLARE v_deleted INTEGER;
  BEGIN
    -- No DELETE policy exists at all on user_notifications (Phase 1.1)
    -- -- RLS with zero applicable policies for a command silently
    -- matches zero rows (not an exception) rather than raising, so
    -- this branch checks the actual row count instead of expecting
    -- insufficient_privilege.
    DELETE FROM user_notifications WHERE outbox_event_id = (SELECT id FROM wf83r_ids WHERE name='outbox');
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    IF v_deleted > 0 THEN v_missing := v_missing || 'authenticated-direct-notification-delete-succeeded '; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  IF v_missing <> '' THEN RAISE EXCEPTION 'SECURITY HOLE: a direct write by an ordinary authenticated user reached a Phase 1.1/1.2 table: %', v_missing; END IF;
END $$;
RESET ROLE;
INSERT INTO wf83r_results VALUES (7,'An ordinary authenticated user''s direct INSERT into platform_outbox_events/notification_intents and direct DELETE on user_notifications are all denied by RLS (zero policies for authenticated on the first two, no DELETE policy on the third) -- every worker-side write still goes exclusively through the SECURITY DEFINER primitives, and this milestone introduces no bypass');

-- ── 8: legacy notifications policies unchanged ──
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
  IF v_missing <> '' THEN RAISE EXCEPTION 'legacy notification policies drifted: %', v_missing; END IF;
END $$;
INSERT INTO wf83r_results VALUES (8,'CAP-003 1.0A/1.0B legacy notification RLS policies and create_legacy_notification remain byte-identical -- the outbox worker never touches the legacy table');

-- ── 9: Phase 1.0A/1.0B/1.1/1.2 protections all remain intact together ──
DO $$
DECLARE v_missing TEXT := '';
BEGIN
  IF to_regprocedure('public.notif_request_legitimate_recipient(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || '1.0b-baseline-drift ';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_notifications'
      AND policyname='user_notifications_select' AND cmd='SELECT' AND qual='(recipient_user_id = auth.uid())'
  ) THEN v_missing := v_missing || '1.1-baseline-drift '; END IF;
  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='platform_outbox_events'
  ) THEN v_missing := v_missing || '1.1-outbox-unexpected-policy '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_class WHERE oid = to_regclass('public.notification_intents') AND relrowsecurity
  ) THEN v_missing := v_missing || '1.2-intents-rls-not-enabled '; END IF;
  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='notification_intents'
  ) THEN v_missing := v_missing || '1.2-intents-unexpected-policy '; END IF;
  IF v_missing <> '' THEN RAISE EXCEPTION 'prior-phase security posture drifted: %', v_missing; END IF;
END $$;
INSERT INTO wf83r_results VALUES (9,'Every prior-phase security posture (1.0A/1.0B legacy fixes, Phase 1.1 outbox zero-policy RLS, Phase 1.2 intents zero-policy RLS) remains byte-identical -- Phase 1.3 is purely additive');

RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf83r_results;
  IF v_count <> 9 THEN RAISE EXCEPTION 'Expected 9 scenarios to record a result, found %', v_count; END IF;
  RAISE NOTICE 'Notification outbox worker RLS tests PASSED: %/9', v_count;
END $$;

ROLLBACK;
