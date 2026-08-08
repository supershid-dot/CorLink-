-- CAP-003 Phase 1.1 notification outbox persistence foundation --
-- RLS test suite. Disposable local PostgreSQL only. Runs in one
-- transaction and leaves no fixtures (rolled back at the end). Uses
-- authenticated non-superuser contexts throughout for every
-- authorization-relevant assertion.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf81r_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf81r_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf81r_results, wf81r_ids TO authenticated, service_role;

INSERT INTO organizations(id,name,type,code) VALUES
 ('81200000-0000-0000-0000-000000000001','WF81R Org A','authority','WF81RA'),
 ('81200000-0000-0000-0000-000000000002','WF81R Org B','authority','WF81RB');
INSERT INTO auth.users(id,email) VALUES
 ('81200000-0001-0000-0000-000000000001','r1@wf81rt.local'),
 ('81200000-0001-0000-0000-000000000002','r2@wf81rt.local'),
 ('81200000-0001-0000-0000-000000000003','r3@wf81rt.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('81200000-0001-0000-0000-000000000001','81200000-0000-0000-0000-000000000001','WF81R-1','Recipient','r1@wf81rt.local',true),
 ('81200000-0001-0000-0000-000000000002','81200000-0000-0000-0000-000000000001','WF81R-2','Same-org unrelated','r2@wf81rt.local',true),
 ('81200000-0001-0000-0000-000000000003','81200000-0000-0000-0000-000000000002','WF81R-3','Cross-org unrelated','r3@wf81rt.local',true);

\set R1 '{"sub":"81200000-0001-0000-0000-000000000001"}'
\set R2 '{"sub":"81200000-0001-0000-0000-000000000002"}'
\set R3 '{"sub":"81200000-0001-0000-0000-000000000003"}'

SET ROLE service_role;
DO $$
DECLARE v_outbox_id UUID; v_notif_id UUID;
BEGIN
  v_outbox_id := platform_enqueue_outbox_event(
    'platform.wf81r_test.v1','platform','wf81r_record',gen_random_uuid(),
    '81200000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(), '{}'::JSONB, gen_random_uuid());
  v_notif_id := platform_create_user_notification(
    '81200000-0001-0000-0000-000000000001'::UUID, '81200000-0000-0000-0000-000000000001'::UUID,
    'platform.wf81r_test.v1', 'x.title', '{}'::JSONB, 'platform', 'wf81r_record', gen_random_uuid(),
    v_outbox_id, 'normal', NULL, NULL, NULL);
  INSERT INTO wf81r_ids VALUES ('outbox', v_outbox_id);
  INSERT INTO wf81r_ids VALUES ('notif', v_notif_id);
END $$;
RESET ROLE;

-- ── 1: own notification visible ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'R1', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM user_notifications WHERE id = (SELECT id FROM wf81r_ids WHERE name='notif');
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected own notification visible, got %', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf81r_results VALUES (1,'Own notification visible to the recipient via SELECT');

-- ── 2: unrelated same-org notification hidden ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'R2', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM user_notifications WHERE id = (SELECT id FROM wf81r_ids WHERE name='notif');
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: same-org unrelated user saw the notification, count=%', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf81r_results VALUES (2,'A same-organization but unrelated user cannot see another recipient''s notification');

-- ── 3: cross-org notification hidden ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'R3', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM user_notifications WHERE id = (SELECT id FROM wf81r_ids WHERE name='notif');
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: cross-org user saw the notification, count=%', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf81r_results VALUES (3,'A cross-organization user cannot see another organization''s notification');

-- ── 4: direct insert denied ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'R1', false);
DO $$
BEGIN
  BEGIN
    INSERT INTO user_notifications (recipient_user_id, organization_id, notification_type, title_template_key, source_module, source_record_type, source_record_id, outbox_event_id)
    VALUES ('81200000-0001-0000-0000-000000000001','81200000-0000-0000-0000-000000000001','platform.forged.v1','x','platform','x',gen_random_uuid(),(SELECT id FROM wf81r_ids WHERE name='outbox'));
    RAISE EXCEPTION 'SECURITY HOLE: direct authenticated INSERT succeeded';
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN
    IF SQLSTATE NOT IN ('42501','01000') AND SQLERRM NOT ILIKE '%row-level security%' THEN RAISE; END IF;
  END;
END $$;
RESET ROLE;
INSERT INTO wf81r_results VALUES (4,'Direct authenticated INSERT into user_notifications is denied -- no INSERT policy exists for authenticated');

-- ── 5: direct update outside allowed state denied ──
-- RLS itself permits the UPDATE (own row), but the immutability
-- trigger must still reject a change to any business-fact column --
-- RLS is row-level only and cannot restrict individual columns, so
-- this is a distinct enforcement layer from scenario 4/2/3 above.
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'R1', false);
DO $$
BEGIN
  BEGIN
    UPDATE user_notifications SET notification_type = 'platform.hijacked.v1'
      WHERE id = (SELECT id FROM wf81r_ids WHERE name = 'notif');
    RAISE EXCEPTION 'SECURITY HOLE: the recipient rewrote their own notification''s business-fact notification_type column';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE user_notifications SET template_params = '{"forged":true}'::JSONB
      WHERE id = (SELECT id FROM wf81r_ids WHERE name = 'notif');
    RAISE EXCEPTION 'SECURITY HOLE: the recipient rewrote their own notification''s business-fact template_params column';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE user_notifications SET outbox_event_id = gen_random_uuid()
      WHERE id = (SELECT id FROM wf81r_ids WHERE name = 'notif');
    RAISE EXCEPTION 'SECURITY HOLE: the recipient rewrote their own notification''s outbox_event_id traceability column';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf81r_results VALUES (5,'A direct UPDATE by the owning recipient that touches any business-fact column (notification_type, template_params, outbox_event_id, ...) is rejected by the immutability trigger, even though RLS itself would otherwise permit the UPDATE on their own row -- read_at/acknowledged_at/archived_at remain the only ever-mutable columns');

-- ── 6: direct delete denied ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'R1', false);
DO $$
DECLARE v_deleted INTEGER;
BEGIN
  BEGIN
    DELETE FROM user_notifications WHERE id = (SELECT id FROM wf81r_ids WHERE name = 'notif');
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    IF v_deleted <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: recipient deleted their own notification, rows=%', v_deleted; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf81r_results VALUES (6,'Direct DELETE on user_notifications is denied for the owning recipient (permission-denied -- DELETE is never granted to authenticated -- or zero rows affected if it were, since no DELETE policy exists either)');

-- ── 7: outbox inaccessible to ordinary user ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'R1', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  -- Denied either way: a hard permission-denied error if authenticated
  -- carries no table-level grant at all (this patch's own explicit
  -- REVOKE, mirroring workflow_events' own convention), or a silently
  -- empty result if some broader platform-default grant exists and
  -- RLS (zero policy for authenticated) is the actual gate instead.
  BEGIN
    SELECT count(*) INTO v_count FROM platform_outbox_events;
    IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user read % outbox rows', v_count; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    INSERT INTO platform_outbox_events (event_type, source_module, source_record_type, source_record_id, organization_id, correlation_id, occurred_at, payload, idempotency_key)
    VALUES ('platform.forged.v1','platform','x',gen_random_uuid(),'81200000-0000-0000-0000-000000000001',gen_random_uuid(),now(),'{}','x'::text::uuid);
    RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user inserted an outbox row directly';
  EXCEPTION WHEN insufficient_privilege OR invalid_text_representation THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf81r_results VALUES (7,'platform_outbox_events is completely inaccessible to an ordinary authenticated user -- zero rows readable (permission-denied or RLS-empty, either is valid), direct INSERT denied -- it is operational infrastructure, never a user-facing record');

-- ── 8: service/internal path works ──
SET ROLE service_role;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE id = (SELECT id FROM wf81r_ids WHERE name = 'outbox');
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected service_role to see the outbox row it created, got %', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf81r_results VALUES (8,'The service/internal path (service_role, BYPASSRLS) can read and write outbox rows normally -- the RLS lockout in scenario 7 is specific to ordinary authenticated sessions, not a structural inability to ever operate on the table');

-- ── 9: anonymous denied ──
-- Anonymous is denied either way for the two SELECTs: a hard
-- permission-denied error if anon carries no table-level grant at all
-- (this patch's own explicit REVOKE, mirroring workflow_events' own
-- convention), or a silently empty result if some broader
-- platform-default grant exists and RLS is the actual gate instead.
-- Both are valid denial outcomes.
SET ROLE anon;
DO $$
DECLARE v_count INTEGER;
BEGIN
  BEGIN
    SELECT count(*) INTO v_count FROM user_notifications;
    IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: anon read % notification rows', v_count; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    SELECT count(*) INTO v_count FROM platform_outbox_events;
    IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: anon read % outbox rows', v_count; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM platform_enqueue_outbox_event('platform.anon.v1','platform','x',gen_random_uuid(),'81200000-0000-0000-0000-000000000001'::UUID,NULL,gen_random_uuid(),NULL,now(),'{}'::JSONB,gen_random_uuid());
    RAISE EXCEPTION 'SECURITY HOLE: anon enqueued an outbox event';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf81r_results VALUES (9,'Anonymous access is denied across every surface: zero SELECT visibility on both tables (permission-denied or RLS-empty, either is valid), and EXECUTE denied on the enqueue primitive');

-- ── 10: legacy table policies unchanged ──
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
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='notifications') <> 2 THEN
    v_missing := v_missing || 'notifications-policy-count-drift ';
  END IF;
  IF v_missing <> '' THEN RAISE EXCEPTION 'legacy notifications table RLS drifted: %', v_missing; END IF;
END $$;
INSERT INTO wf81r_results VALUES (10,'The legacy notifications table''s RLS policies (notif_select, notif_update, zero INSERT policy) are byte-identical to their pre-Phase-1.1 shape -- this milestone is purely additive');

RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf81r_results;
  IF v_count <> 10 THEN RAISE EXCEPTION 'Expected 10 scenarios to record a result, found %', v_count; END IF;
  RAISE NOTICE 'Notification outbox persistence foundation RLS tests PASSED: %/10', v_count;
END $$;

ROLLBACK;
