-- CAP-003 Phase 1.1 notification outbox persistence foundation --
-- focused behavioral suite (20 required scenarios). Disposable local
-- PostgreSQL only. Runs in one transaction and leaves no fixtures
-- (rolled back at the end).
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf81_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf81_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf81_results, wf81_ids TO authenticated, service_role;

-- ── Fixtures (as postgres, bypasses RLS) ────────────────────────────
INSERT INTO organizations(id,name,type,code) VALUES
 ('81100000-0000-0000-0000-000000000001','WF81 Org A','authority','WF81A'),
 ('81100000-0000-0000-0000-000000000002','WF81 Org B','authority','WF81B');
INSERT INTO auth.users(id,email) VALUES
 ('81100000-0001-0000-0000-000000000001','u1@wf81t.local'),
 ('81100000-0001-0000-0000-000000000002','u2@wf81t.local'),
 ('81100000-0001-0000-0000-000000000003','u3@wf81t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('81100000-0001-0000-0000-000000000001','81100000-0000-0000-0000-000000000001','WF81-1','User One (Org A)','u1@wf81t.local',true),
 ('81100000-0001-0000-0000-000000000002','81100000-0000-0000-0000-000000000001','WF81-2','User Two (Org A, unrelated)','u2@wf81t.local',true),
 ('81100000-0001-0000-0000-000000000003','81100000-0000-0000-0000-000000000002','WF81-3','User Three (Org B, cross-org)','u3@wf81t.local',true);

-- A real requests row User One has zero legitimate 1.0B relationship
-- to, used by scenario 17 to prove a notification's source reference
-- grants no underlying-record access.
INSERT INTO divisions(id, org_id, name) VALUES ('81100000-0004-0000-0000-000000000001','81100000-0000-0000-0000-000000000002','WF81 Div B');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES ('81100000-0002-0000-0000-000000000001','81100000-0000-0000-0000-000000000002','81100000-0004-0000-0000-000000000001','WF81 Sec B','SB1');
INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, subject, body, created_by, status)
VALUES ('81100000-0005-0000-0000-000000000001','81100000-0000-0000-0000-000000000002','81100000-0000-0000-0000-000000000002',
        '81100000-0002-0000-0000-000000000001','WF81 unrelated request','body','81100000-0001-0000-0000-000000000003','draft');

\set U1 '{"sub":"81100000-0001-0000-0000-000000000001"}'
\set U2 '{"sub":"81100000-0001-0000-0000-000000000002"}'
\set U3 '{"sub":"81100000-0001-0000-0000-000000000003"}'

-- ── 1: Internal/service outbox enqueue succeeds ──
SET ROLE service_role;
DO $$
DECLARE v_id UUID;
BEGIN
  v_id := platform_enqueue_outbox_event(
    'platform.wf81_test.v1','platform','wf81_record',gen_random_uuid(),
    '81100000-0000-0000-0000-000000000001'::UUID, '81100000-0001-0000-0000-000000000001'::UUID,
    gen_random_uuid(), NULL, now(), '{"k":"v"}'::JSONB, gen_random_uuid());
  IF v_id IS NULL THEN RAISE EXCEPTION 'expected a real outbox event id'; END IF;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (1,'Internal/service outbox enqueue (called as service_role) succeeds and returns a real event id');

-- ── 2: Duplicate semantic enqueue is deduplicated ──
SET ROLE service_role;
DO $$
DECLARE v_record_id UUID := gen_random_uuid(); v_idem UUID := gen_random_uuid();
        v_corr UUID := gen_random_uuid(); v_id1 UUID; v_id2 UUID; v_count INTEGER;
BEGIN
  v_id1 := platform_enqueue_outbox_event(
    'platform.wf81_dedup.v1','platform','wf81_record',v_record_id,
    '81100000-0000-0000-0000-000000000001'::UUID, NULL, v_corr, NULL, now(), '{"a":1}'::JSONB, v_idem);
  v_id2 := platform_enqueue_outbox_event(
    'platform.wf81_dedup.v1','platform','wf81_record',v_record_id,
    '81100000-0000-0000-0000-000000000001'::UUID, NULL, v_corr, NULL, now(), '{"a":1}'::JSONB, v_idem);
  IF v_id1 <> v_id2 THEN RAISE EXCEPTION 'expected the same event id back from a semantically identical replay, got % and %', v_id1, v_id2; END IF;
  SELECT count(*) INTO v_count FROM platform_outbox_events WHERE idempotency_key = v_idem;
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 row for this idempotency key, got %', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (2,'A duplicate enqueue with the same source/type/idempotency_key AND the same payload/correlation_id is deduplicated -- a safe no-op replay returning the original event id, exactly one row on disk');

-- ── 3: Conflicting reuse of idempotency key rejects deterministically ──
SET ROLE service_role;
DO $$
DECLARE v_record_id UUID := gen_random_uuid(); v_idem UUID := gen_random_uuid();
BEGIN
  PERFORM platform_enqueue_outbox_event(
    'platform.wf81_conflict.v1','platform','wf81_record',v_record_id,
    '81100000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(), '{"a":1}'::JSONB, v_idem);
  BEGIN
    PERFORM platform_enqueue_outbox_event(
      'platform.wf81_conflict.v1','platform','wf81_record',v_record_id,
      '81100000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(), '{"a":2}'::JSONB, v_idem);
    RAISE EXCEPTION 'SECURITY HOLE: reusing an idempotency key with a different payload silently succeeded';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (3,'Reusing the same source/type/idempotency_key with a DIFFERENT payload/correlation_id (a caller bug, not a legitimate replay) is rejected deterministically, not silently discarded or merged');

-- ── 4: Ordinary authenticated user cannot enqueue arbitrary outbox event ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U1', false);
DO $$
BEGIN
  BEGIN
    PERFORM platform_enqueue_outbox_event(
      'platform.wf81_forbidden.v1','platform','wf81_record',gen_random_uuid(),
      '81100000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(), '{}'::JSONB, gen_random_uuid());
    RAISE EXCEPTION 'SECURITY HOLE: an ordinary authenticated user enqueued an outbox event directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (4,'An ordinary authenticated user cannot call platform_enqueue_outbox_event directly (EXECUTE granted to service_role only)');

-- ── 5: Anonymous cannot enqueue ──
SET ROLE anon;
DO $$
BEGIN
  BEGIN
    PERFORM platform_enqueue_outbox_event(
      'platform.wf81_anon.v1','platform','wf81_record',gen_random_uuid(),
      '81100000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(), '{}'::JSONB, gen_random_uuid());
    RAISE EXCEPTION 'SECURITY HOLE: anon enqueued an outbox event';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (5,'Anonymous execution of platform_enqueue_outbox_event is denied');

-- ── 6: Internal durable notification creation succeeds ──
SET ROLE service_role;
DO $$
DECLARE v_outbox_id UUID; v_notif_id UUID;
BEGIN
  v_outbox_id := platform_enqueue_outbox_event(
    'platform.wf81_notify.v1','platform','wf81_record',gen_random_uuid(),
    '81100000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(), '{}'::JSONB, gen_random_uuid());
  v_notif_id := platform_create_user_notification(
    '81100000-0001-0000-0000-000000000001'::UUID, '81100000-0000-0000-0000-000000000001'::UUID,
    'platform.wf81_notify.v1', 'wf81.title', '{"n":1}'::JSONB, 'platform', 'wf81_record', gen_random_uuid(),
    v_outbox_id, 'normal', NULL, NULL, NULL);
  IF v_notif_id IS NULL THEN RAISE EXCEPTION 'expected a real notification id'; END IF;
  INSERT INTO wf81_ids VALUES ('scenario6_outbox', v_outbox_id);
  INSERT INTO wf81_ids VALUES ('scenario6_notif', v_notif_id);
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (6,'Internal/service durable user_notification creation (called as service_role) succeeds and returns a real notification id');

-- ── 7: Duplicate event+recipient notification does not duplicate ──
SET ROLE service_role;
DO $$
DECLARE v_id1 UUID; v_id2 UUID; v_count INTEGER; v_outbox_id UUID;
BEGIN
  SELECT id INTO v_outbox_id FROM wf81_ids WHERE name = 'scenario6_outbox';
  v_id1 := platform_create_user_notification(
    '81100000-0001-0000-0000-000000000001'::UUID, '81100000-0000-0000-0000-000000000001'::UUID,
    'platform.wf81_notify.v1', 'wf81.title', '{"n":1}'::JSONB, 'platform', 'wf81_record', gen_random_uuid(),
    v_outbox_id, 'normal', NULL, NULL, NULL);
  v_id2 := platform_create_user_notification(
    '81100000-0001-0000-0000-000000000001'::UUID, '81100000-0000-0000-0000-000000000001'::UUID,
    'platform.wf81_notify.v1', 'wf81.title', '{"n":1}'::JSONB, 'platform', 'wf81_record', gen_random_uuid(),
    v_outbox_id, 'normal', NULL, NULL, NULL);
  IF v_id1 <> v_id2 THEN RAISE EXCEPTION 'expected the same notification id back for the same (outbox_event_id, recipient) pair, got % and %', v_id1, v_id2; END IF;
  SELECT count(*) INTO v_count FROM user_notifications WHERE outbox_event_id = v_outbox_id AND recipient_user_id = '81100000-0001-0000-0000-000000000001';
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected exactly 1 notification row for this (outbox_event_id, recipient) pair, got %', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (7,'A duplicate (outbox_event_id, recipient_user_id) notification creation is deduplicated -- a worker claiming/replaying the same event never creates a second notification for the same recipient');

-- ── 8: User can read own notification ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U1', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM user_notifications WHERE id = (SELECT id FROM wf81_ids WHERE name = 'scenario6_notif');
  IF v_count <> 1 THEN RAISE EXCEPTION 'expected User One to see their own notification, got %', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (8,'User One can SELECT their own notification row');

-- ── 9: User cannot read another user's notification ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U2', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM user_notifications WHERE id = (SELECT id FROM wf81_ids WHERE name = 'scenario6_notif');
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: same-org User Two saw User One''s notification, count=%', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (9,'A same-organization but unrelated user (User Two) cannot read User One''s notification row');

-- ── 10: Cross-org notification row cannot be read ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U3', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM user_notifications WHERE id = (SELECT id FROM wf81_ids WHERE name = 'scenario6_notif');
  IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: cross-org User Three saw User One''s notification, count=%', v_count; END IF;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (10,'A cross-organization user (User Three, Org B) cannot read User One''s (Org A) notification row');

-- ── 11: User can mark own notification read ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U1', false);
DO $$
DECLARE v_updated INTEGER; v_read_at TIMESTAMPTZ;
BEGIN
  UPDATE user_notifications SET read_at = now() WHERE id = (SELECT id FROM wf81_ids WHERE name = 'scenario6_notif');
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> 1 THEN RAISE EXCEPTION 'expected User One to mark their own notification read, rows affected=%', v_updated; END IF;
  SELECT read_at INTO v_read_at FROM user_notifications WHERE id = (SELECT id FROM wf81_ids WHERE name = 'scenario6_notif');
  IF v_read_at IS NULL THEN RAISE EXCEPTION 'expected read_at to be set'; END IF;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (11,'User One can mark their own notification read via a direct UPDATE (RLS-scoped to recipient_user_id = auth.uid())');

-- ── 12: User cannot mark another user's notification read ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U2', false);
DO $$
DECLARE v_updated INTEGER;
BEGIN
  UPDATE user_notifications SET read_at = now() WHERE id = (SELECT id FROM wf81_ids WHERE name = 'scenario6_notif');
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: User Two updated User One''s notification, rows affected=%', v_updated; END IF;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (12,'User Two cannot mark User One''s notification read -- zero rows affected, RLS scopes UPDATE to the owning recipient only');

-- ── 13: Anonymous cannot read ──
SET ROLE anon;
DO $$
DECLARE v_count INTEGER;
BEGIN
  -- Anonymous is denied either way: a hard permission-denied error if
  -- anon carries no table-level grant at all (this patch's own,
  -- explicit REVOKE ALL ... FROM ... anon ... with no SELECT re-grant,
  -- exactly mirroring workflow_events' own REVOKE/GRANT convention),
  -- or a silently empty result if some broader platform-default grant
  -- exists and RLS (zero policy for anon) is the actual gate instead.
  -- Both are valid denial outcomes; only an actual non-empty read
  -- would be a security hole.
  BEGIN
    SELECT count(*) INTO v_count FROM user_notifications;
    IF v_count <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: anon read % notification rows', v_count; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (13,'Anonymous access to user_notifications is denied -- either by table-level permission (no grant to anon) or by RLS filtering to zero rows, depending on which grant layer is in effect; anon never reads a real row either way');

-- ── 14: Direct authenticated INSERT denied ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U1', false);
DO $$
BEGIN
  BEGIN
    INSERT INTO user_notifications (recipient_user_id, organization_id, notification_type, title_template_key, source_module, source_record_type, source_record_id, outbox_event_id)
    VALUES ('81100000-0001-0000-0000-000000000001','81100000-0000-0000-0000-000000000001','platform.forged.v1','x','platform','x',gen_random_uuid(),(SELECT id FROM wf81_ids WHERE name='scenario6_outbox'));
    RAISE EXCEPTION 'SECURITY HOLE: direct authenticated INSERT into user_notifications succeeded';
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN
    IF SQLSTATE NOT IN ('42501','01000') AND SQLERRM NOT ILIKE '%row-level security%' THEN RAISE; END IF;
  END;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (14,'A direct authenticated client INSERT into user_notifications is denied -- no INSERT policy exists, creation is exclusively via platform_create_user_notification()');

-- ── 15: Direct authenticated DELETE denied ──
-- Denied either way: a hard permission-denied error since this patch
-- never grants DELETE to authenticated at all, or (if some broader
-- platform-default grant existed) zero rows affected since no DELETE
-- policy exists either.
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U1', false);
DO $$
DECLARE v_deleted INTEGER;
BEGIN
  BEGIN
    DELETE FROM user_notifications WHERE id = (SELECT id FROM wf81_ids WHERE name = 'scenario6_notif');
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    IF v_deleted <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: User One deleted their own notification row, rows affected=%', v_deleted; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (15,'Direct DELETE on user_notifications is denied for the owning recipient (permission-denied, since DELETE is never granted to authenticated -- or zero rows affected if it were, since no DELETE policy exists either) -- notifications are never deleted, only archived (a future column, not a row removal)');

-- ── 16: Safe metadata constraints enforced ──
SET ROLE service_role;
DO $$
BEGIN
  BEGIN
    PERFORM platform_enqueue_outbox_event(
      'platform.wf81_oversized.v1','platform','wf81_record',gen_random_uuid(),
      '81100000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(),
      jsonb_build_object('blob', repeat('x', 9000)), gen_random_uuid());
    RAISE EXCEPTION 'SECURITY HOLE: an oversized (>8KB) payload was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    PERFORM platform_enqueue_outbox_event(
      'platform.wf81_array.v1','platform','wf81_record',gen_random_uuid(),
      '81100000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(),
      '[1,2,3]'::JSONB, gen_random_uuid());
    RAISE EXCEPTION 'SECURITY HOLE: a non-object JSON payload was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (16,'Safe-metadata constraints are enforced: an oversized (>8KB) payload and a non-object JSON payload are both rejected by CHECK constraints, not merely convention');

-- ── 17: Source reference does not grant underlying-record access ──
SET ROLE service_role;
DO $$
DECLARE v_outbox_id UUID; v_notif_id UUID;
BEGIN
  v_outbox_id := platform_enqueue_outbox_event(
    'request.status_changed.v1','requests','request','81100000-0005-0000-0000-000000000001'::UUID,
    '81100000-0000-0000-0000-000000000002'::UUID, NULL, gen_random_uuid(), NULL, now(), '{}'::JSONB, gen_random_uuid());
  v_notif_id := platform_create_user_notification(
    '81100000-0001-0000-0000-000000000001'::UUID, '81100000-0000-0000-0000-000000000002'::UUID,
    'request.status_changed.v1', 'x.title', '{}'::JSONB, 'requests', 'request', '81100000-0005-0000-0000-000000000001'::UUID,
    v_outbox_id, 'normal', 'requests', jsonb_build_object('id','81100000-0005-0000-0000-000000000001'), NULL);
  INSERT INTO wf81_ids VALUES ('scenario17_notif', v_notif_id);
END $$;
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U1', false);
DO $$
DECLARE v_notif_count INTEGER; v_request_count INTEGER;
BEGIN
  SELECT count(*) INTO v_notif_count FROM user_notifications WHERE id = (SELECT id FROM wf81_ids WHERE name = 'scenario17_notif');
  IF v_notif_count <> 1 THEN RAISE EXCEPTION 'expected User One to see their own notification about the request'; END IF;
  SELECT count(*) INTO v_request_count FROM requests WHERE id = '81100000-0005-0000-0000-000000000001';
  IF v_request_count <> 0 THEN
    RAISE EXCEPTION 'SECURITY HOLE: a user_notifications row referencing a request granted the recipient visibility into the underlying requests row they have no independent 1.0B relationship to, count=%', v_request_count;
  END IF;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (17,'User One can see the notification row itself (source_module=requests, source_record_id set), but the referenced requests row remains completely invisible to them via the requests table''s own RLS -- a notification''s source reference is never itself an authorization source, exactly as docs/78 §7.3/§17 require');

-- ── 18: Keyset pagination stable across inserts ──
SET ROLE service_role;
DO $$
DECLARE i INTEGER; v_outbox_id UUID;
BEGIN
  FOR i IN 1..5 LOOP
    v_outbox_id := platform_enqueue_outbox_event(
      'platform.wf81_page.v1','platform','wf81_record',gen_random_uuid(),
      '81100000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(), '{}'::JSONB, gen_random_uuid());
    PERFORM platform_create_user_notification(
      '81100000-0001-0000-0000-000000000002'::UUID, '81100000-0000-0000-0000-000000000001'::UUID,
      'platform.wf81_page.v1', 'x', '{}'::JSONB, 'platform', 'wf81_record', gen_random_uuid(),
      v_outbox_id, 'normal', NULL, NULL, NULL);
    PERFORM pg_sleep(0.01);
  END LOOP;
END $$;
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U2', false);
DO $$
DECLARE v_page1_ids UUID[]; v_last_created TIMESTAMPTZ; v_last_id UUID;
BEGIN
  SELECT array_agg(id ORDER BY created_at DESC, id DESC) INTO v_page1_ids
  FROM (SELECT * FROM list_my_notifications(3, NULL, NULL, FALSE)) x;
  IF array_length(v_page1_ids,1) <> 3 THEN RAISE EXCEPTION 'expected page 1 to have exactly 3 rows, got %', array_length(v_page1_ids,1); END IF;

  SELECT created_at, id INTO v_last_created, v_last_id FROM user_notifications WHERE id = v_page1_ids[3];
  PERFORM set_config('wf81.page1_ids', array_to_string(v_page1_ids, ','), false);
  PERFORM set_config('wf81.last_created', v_last_created::TEXT, false);
  PERFORM set_config('wf81.last_id', v_last_id::TEXT, false);
END $$;
RESET ROLE;

-- New notifications arrive AFTER page 1 was fetched -- a keyset cursor
-- must not let them leak into "older" continuation pages, unlike
-- OFFSET pagination which would shift under concurrent inserts.
SET ROLE service_role;
DO $$
DECLARE v_outbox_id UUID;
BEGIN
  v_outbox_id := platform_enqueue_outbox_event(
    'platform.wf81_page.v1','platform','wf81_record',gen_random_uuid(),
    '81100000-0000-0000-0000-000000000001'::UUID, NULL, gen_random_uuid(), NULL, now(), '{}'::JSONB, gen_random_uuid());
  PERFORM platform_create_user_notification(
    '81100000-0001-0000-0000-000000000002'::UUID, '81100000-0000-0000-0000-000000000001'::UUID,
    'platform.wf81_page.v1', 'x', '{}'::JSONB, 'platform', 'wf81_record', gen_random_uuid(),
    v_outbox_id, 'normal', NULL, NULL, NULL);
END $$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U2', false);
DO $$
DECLARE v_page1_ids UUID[]; v_page2_ids UUID[]; v_overlap INTEGER;
BEGIN
  SELECT string_to_array(current_setting('wf81.page1_ids'), ',')::UUID[] INTO v_page1_ids;
  SELECT array_agg(id ORDER BY created_at DESC, id DESC) INTO v_page2_ids
  FROM (SELECT * FROM list_my_notifications(3, current_setting('wf81.last_created')::TIMESTAMPTZ, current_setting('wf81.last_id')::UUID, FALSE)) x;

  SELECT count(*) INTO v_overlap FROM unnest(v_page1_ids) p1 WHERE p1 = ANY(v_page2_ids);
  IF v_overlap <> 0 THEN RAISE EXCEPTION 'expected zero overlap between page 1 and page 2, got %', v_overlap; END IF;
  IF v_page1_ids[1] = ANY(v_page2_ids) THEN RAISE EXCEPTION 'the row inserted after page 1 was fetched must not appear in page 2 (the older continuation)'; END IF;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (18,'Keyset (created_at, id) pagination is stable across concurrent inserts: page 2, fetched via the cursor from the end of page 1, has zero overlap with page 1 and does not include a row that arrived after page 1 was fetched -- OFFSET-based pagination would not have this guarantee');

-- ── 19: Unread count accurate ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U2', false);
DO $$
DECLARE v_unread INTEGER; v_total INTEGER; v_read_count INTEGER;
BEGIN
  SELECT count(*) INTO v_total FROM user_notifications WHERE recipient_user_id = '81100000-0001-0000-0000-000000000002';
  UPDATE user_notifications SET read_at = now()
    WHERE recipient_user_id = '81100000-0001-0000-0000-000000000002' AND id IN (
      SELECT id FROM user_notifications WHERE recipient_user_id = '81100000-0001-0000-0000-000000000002' ORDER BY created_at LIMIT 2
    );
  GET DIAGNOSTICS v_read_count = ROW_COUNT;
  v_unread := count_my_unread_notifications();
  IF v_unread <> (v_total - v_read_count) THEN
    RAISE EXCEPTION 'expected unread count % (total % - read %), got %', v_total - v_read_count, v_total, v_read_count, v_unread;
  END IF;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (19,'count_my_unread_notifications() accurately reflects total-minus-read for the calling user after marking a known subset read');

-- ── 20: Legacy notification behavior remains unchanged ──
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
  IF to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)') IS NULL THEN
    v_missing := v_missing || 'create_legacy_notification-missing ';
  END IF;
  IF v_missing <> '' THEN RAISE EXCEPTION 'legacy notification behavior drifted: %', v_missing; END IF;
END $$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U1', false);
DO $$
DECLARE v_result INTEGER;
BEGIN
  -- A same-org legacy call using User One as both caller and their own
  -- section-mate target would require full 1.0B fixtures to exercise
  -- positively; here we confirm the RPC itself is still callable and
  -- still enforces 1.0B's record-authoritative rule (rejects a
  -- fabricated same-org recipient with no record tie), proving CAP-003
  -- Phase 1.1's additive tables introduced no regression in the
  -- already-shipped 1.0A/1.0B behavior.
  BEGIN
    PERFORM create_legacy_notification(
      ARRAY['81100000-0001-0000-0000-000000000002']::UUID[], 'new_request', 'request',
      '81100000-0005-0000-0000-000000000001'::UUID, 'legacy behavior probe');
    RAISE EXCEPTION 'expected 1.0B''s record-authorization rule to still reject this fabricated same-org notification';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf81_results VALUES (20,'The legacy notifications table''s RLS policies and create_legacy_notification() (including its 1.0B record-authorization behavior) are completely unaffected by the new, purely additive CAP-003 Phase 1.1 persistence tables');

RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf81_results;
  IF v_count <> 20 THEN
    RAISE EXCEPTION 'Expected 20 scenarios to record a result, found %', v_count;
  END IF;
  RAISE NOTICE 'Notification outbox persistence foundation behavioral tests PASSED: %/20', v_count;
END $$;

ROLLBACK;
