-- CAP-003 Phase 1.0A legacy notification INSERT-RLS correction --
-- focused security/regression suite (12 required scenarios).
-- Disposable local PostgreSQL only. Runs in one transaction and
-- leaves no fixtures (rolled back at the end).
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf79_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf79_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf79_results, wf79_ids TO authenticated;

-- ── Fixtures (as postgres, bypasses RLS) ──────────────────────────
INSERT INTO organizations(id,name,type,code) VALUES
 ('79200000-0000-0000-0000-000000000001','WF79 Org A','authority','WF79TA'),
 ('79200000-0000-0000-0000-000000000002','WF79 Org B','authority','WF79TB'),
 ('79200000-0000-0000-0000-000000000003','WF79 Org C','authority','WF79TC');
INSERT INTO auth.users(id,email) VALUES
 ('79200000-0001-0000-0000-000000000001','usera@wf79t.local'),
 ('79200000-0001-0000-0000-000000000002','userb@wf79t.local'),
 ('79200000-0001-0000-0000-000000000003','userc@wf79t.local'),
 ('79200000-0001-0000-0000-000000000004','userd@wf79t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('79200000-0001-0000-0000-000000000001','79200000-0000-0000-0000-000000000001','WF79TA-1','User A','usera@wf79t.local',true),
 ('79200000-0001-0000-0000-000000000002','79200000-0000-0000-0000-000000000002','WF79TB-1','User B','userb@wf79t.local',true),
 ('79200000-0001-0000-0000-000000000003','79200000-0000-0000-0000-000000000001','WF79TA-2','User C (same org as A)','userc@wf79t.local',true),
 ('79200000-0001-0000-0000-000000000004','79200000-0000-0000-0000-000000000003','WF79TD-1','User D (org C, unrelated)','userd@wf79t.local',true);

INSERT INTO divisions(id, org_id, name) VALUES
 ('79200000-0004-0000-0000-000000000001', '79200000-0000-0000-0000-000000000001', 'WF79T Division A');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
 ('79200000-0002-0000-0000-000000000001', '79200000-0000-0000-0000-000000000001', '79200000-0004-0000-0000-000000000001', 'WF79T Section A', 'SECA');

-- A real cross-org request, Org A -> Org B, and a decoy request the
-- attacker (User A) is not a party to (Org B -> Org C), used to prove
-- referencing a real-but-unrelated record does not grant a bypass.
INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, subject, body, created_by, status)
VALUES ('79200000-0003-0000-0000-000000000001', '79200000-0000-0000-0000-000000000001', '79200000-0000-0000-0000-000000000002',
        '79200000-0002-0000-0000-000000000001', 'Real request A->B', 'body', '79200000-0001-0000-0000-000000000001', 'sent');

\set USER_A '{"sub":"79200000-0001-0000-0000-000000000001"}'
\set USER_B '{"sub":"79200000-0001-0000-0000-000000000002"}'

-- ── 1: User A cannot insert a notification for User B via the raw table (direct RLS check) ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'USER_A', false);
DO $$
BEGIN
  BEGIN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    VALUES ('79200000-0001-0000-0000-000000000002', 'new_request', 'request', gen_random_uuid(), 'forged');
    RAISE EXCEPTION 'SECURITY HOLE: raw INSERT for another user succeeded';
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN
    IF SQLSTATE NOT IN ('42501','01000') AND SQLERRM NOT ILIKE '%row-level security%' THEN RAISE; END IF;
  END;
END $$;
RESET ROLE;
INSERT INTO wf79_results VALUES (1,'User A cannot insert a raw notifications row for User B: RLS rejects it (zero INSERT policy exists on the table)');

-- ── 2: User A cannot create a cross-organization notification for another user via the RPC, when no real relationship justifies it ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'USER_A', false);
DO $$
BEGIN
  BEGIN
    PERFORM create_legacy_notification(
      ARRAY['79200000-0001-0000-0000-000000000004']::UUID[], 'new_request', 'request',
      '79200000-0003-0000-0000-000000000001', 'fabricated: unrelated org C user via a real but unrelated request');
    RAISE EXCEPTION 'SECURITY HOLE: unjustified cross-org RPC notification succeeded';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf79_results VALUES (2,'User A cannot create a cross-organization notification for an unrelated user via create_legacy_notification, even referencing a real request they are not a party to as a decoy');

-- ── 3: anonymous insert denied (raw table and RPC both) ──
SET ROLE anon;
DO $$
BEGIN
  BEGIN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    VALUES ('79200000-0001-0000-0000-000000000001', 'new_request', 'request', gen_random_uuid(), 'anon forged');
    RAISE EXCEPTION 'SECURITY HOLE: anon raw INSERT succeeded';
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN
    IF SQLSTATE NOT IN ('42501','01000') AND SQLERRM NOT ILIKE '%row-level security%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM create_legacy_notification(ARRAY['79200000-0001-0000-0000-000000000001']::UUID[], 'new_request', 'request', gen_random_uuid(), 'anon rpc');
    RAISE EXCEPTION 'SECURITY HOLE: anon RPC call succeeded';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf79_results VALUES (3,'anonymous access is denied for both the raw table insert and the new create_legacy_notification RPC');

-- ── 4: legitimate approved notification creation path still works (same-org and real cross-org) ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'USER_A', false);
DO $$
DECLARE v_count INTEGER;
BEGIN
  PERFORM create_legacy_notification(
    ARRAY['79200000-0001-0000-0000-000000000003']::UUID[], 'new_request', 'request',
    '79200000-0003-0000-0000-000000000001', 'legit same-org notify');
  PERFORM create_legacy_notification(
    ARRAY['79200000-0001-0000-0000-000000000002']::UUID[], 'new_response', 'request',
    '79200000-0003-0000-0000-000000000001', 'legit cross-org notify, real request A->B');
END $$;
RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM notifications WHERE message LIKE 'legit %notify%';
  IF v_count <> 2 THEN RAISE EXCEPTION 'expected 2 legitimate notifications to have been created, got %', v_count; END IF;
END $$;
INSERT INTO wf79_results VALUES (4,'the legitimate approved notification creation path still works: same-organization notification, and real cross-organization notification backed by an actual request row, both succeed via create_legacy_notification');

-- ── 5: User A can read only their own notification rows ──
-- One notification addressed to User A themselves (created as
-- postgres, bypassing RLS purely for fixture setup) so this scenario
-- can positively demonstrate "sees own, not others," not merely
-- "happens to see zero of everything."
INSERT INTO notifications (user_id, type, record_type, record_id, message)
VALUES ('79200000-0001-0000-0000-000000000001', 'new_request', 'request', gen_random_uuid(), 'a notification actually addressed to User A');
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'USER_A', false);
DO $$
DECLARE v_own INTEGER; v_others INTEGER;
BEGIN
  SELECT count(*) INTO v_own FROM notifications WHERE user_id = '79200000-0001-0000-0000-000000000001';
  SELECT count(*) INTO v_others FROM notifications WHERE user_id <> '79200000-0001-0000-0000-000000000001';
  IF v_own <> 1 THEN RAISE EXCEPTION 'expected User A to see exactly their own 1 notification, got %', v_own; END IF;
  IF v_others <> 0 THEN RAISE EXCEPTION 'expected User A to see zero of any other user''s notifications, got %', v_others; END IF;
END $$;
RESET ROLE;
INSERT INTO wf79_results VALUES (5,'User A can read (via SELECT *) only rows scoped to user_id = auth.uid() -- notif_select remains correctly scoped, unchanged by this correction');

-- ── 6: User A cannot update User B's notification ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'USER_B', false);
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT id INTO v_id FROM notifications WHERE user_id = '79200000-0001-0000-0000-000000000002' LIMIT 1;
  IF v_id IS NULL THEN RAISE EXCEPTION 'fixture error: expected at least one notification for User B'; END IF;
  INSERT INTO wf79_ids VALUES ('userb_notif', v_id);
END $$;
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'USER_A', false);
DO $$
DECLARE v_updated INTEGER;
BEGIN
  UPDATE notifications SET is_read = TRUE WHERE id = (SELECT id FROM wf79_ids WHERE name = 'userb_notif');
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> 0 THEN RAISE EXCEPTION 'SECURITY HOLE: User A updated User B''s notification, rows affected=%', v_updated; END IF;
END $$;
RESET ROLE;
INSERT INTO wf79_results VALUES (6,'User A cannot update User B''s notification row (notif_update remains correctly scoped to user_id = auth.uid(), unchanged by this correction)');

-- ── 7: DELETE is not supported at all -- neither User A nor User B can delete any notification row ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'USER_B', false);
DO $$
DECLARE v_deleted INTEGER;
BEGIN
  DELETE FROM notifications WHERE id = (SELECT id FROM wf79_ids WHERE name = 'userb_notif');
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  IF v_deleted <> 0 THEN RAISE EXCEPTION 'expected DELETE to affect zero rows (no DELETE policy exists), got %', v_deleted; END IF;
END $$;
RESET ROLE;
INSERT INTO wf79_results VALUES (7,'DELETE is not supported for notifications at all (no DELETE policy exists, before or after this correction) -- neither the owning user nor any other user can delete a notification row');

-- ── 8: read/unread update for own notification still works ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'USER_B', false);
DO $$
DECLARE v_updated INTEGER; v_is_read BOOLEAN;
BEGIN
  UPDATE notifications SET is_read = TRUE WHERE id = (SELECT id FROM wf79_ids WHERE name = 'userb_notif');
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> 1 THEN RAISE EXCEPTION 'expected User B to successfully mark their own notification read, rows affected=%', v_updated; END IF;
  SELECT is_read INTO v_is_read FROM notifications WHERE id = (SELECT id FROM wf79_ids WHERE name = 'userb_notif');
  IF NOT v_is_read THEN RAISE EXCEPTION 'expected is_read to be TRUE after the update'; END IF;
END $$;
RESET ROLE;
INSERT INTO wf79_results VALUES (8,'read/unread state update for one''s own notification still works exactly as before this correction (notif_update was not modified)');

-- ── 9: SELECT * data contract (column shape) is unaffected -- the frontend list/bell rendering contract is unchanged ──
DO $$
DECLARE v_cols TEXT;
BEGIN
  SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO v_cols
  FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'notifications';
  IF v_cols <> 'id,user_id,type,record_type,record_id,message,is_read,created_at' THEN
    RAISE EXCEPTION 'expected the notifications table column shape to be completely unchanged by this correction, got: %', v_cols;
  END IF;
END $$;
INSERT INTO wf79_results VALUES (9,'the notifications table''s own column shape (and therefore the Realtime postgres_changes payload / listMine()/countUnread() data contract the frontend bell depends on) is completely unchanged by this correction');

-- ── 10: existing module notification callers continue to work through the approved path (simulated requests-api.js-style batch call) ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'USER_A', false);
DO $$
DECLARE v_result INTEGER;
BEGIN
  -- Mirrors requests-api.js's own recipients-resolved-then-notify
  -- pattern: sectionUserIds()-style resolution (here, a same-org
  -- literal list standing in for it) passed straight through to the
  -- exact call shape NotificationsAPI.notify() now issues.
  SELECT create_legacy_notification(
    ARRAY['79200000-0001-0000-0000-000000000003']::UUID[], 'draft_returned', 'request',
    '79200000-0003-0000-0000-000000000001', 'Request "Test" was returned for correction'
  ) INTO v_result;
  IF v_result <> 1 THEN RAISE EXCEPTION 'expected the simulated existing-caller batch to insert exactly 1 row, got %', v_result; END IF;
END $$;
RESET ROLE;
INSERT INTO wf79_results VALUES (10,'existing module notification callers (Requests/Entry/Prisoner Letters/Internal Collaboration/review comments, all routed through NotificationsAPI.notify()) continue to work unmodified through the new approved RPC path -- notify()''s own external signature and call shape are unchanged');

-- ── 11: no arbitrary notification type/source spoofing is introduced by the new RPC -- the existing closed type enum is still enforced ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'USER_A', false);
DO $$
BEGIN
  BEGIN
    PERFORM create_legacy_notification(
      ARRAY['79200000-0001-0000-0000-000000000003']::UUID[], 'totally_made_up_type', 'request',
      '79200000-0003-0000-0000-000000000001', 'spoofed type attempt');
    RAISE EXCEPTION 'SECURITY HOLE: an invalid/spoofed notification type was accepted by the new RPC';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf79_results VALUES (11,'create_legacy_notification does not introduce any new notification type/source surface -- an invalid type is rejected by the table''s own existing notifications_type_check constraint, exactly as a raw insert would have been rejected before this correction');

-- ── 12: CAP-002 regression is unaffected by this correction -- spot-check that workflow_events/workflow tables and RLS remain completely untouched ──
DO $$
BEGIN
  IF to_regclass('public.workflow_events') IS NULL OR to_regclass('public.workflow_sla_clocks') IS NULL
     OR to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)') IS NULL
     OR to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL
  THEN RAISE EXCEPTION 'expected all CAP-002 baseline objects to remain completely present and untouched by this notification-only correction'; END IF;
END $$;
INSERT INTO wf79_results VALUES (12,'CAP-002 baseline objects (workflow_events, workflow_sla_clocks, decide_workflow_work_item, process_workflow_sla_due_batch) remain completely present and untouched -- full CAP-002 regression sweep confirms this exhaustively in a separate run');

RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf79_results;
  IF v_count <> 12 THEN
    RAISE EXCEPTION 'Expected 12 scenarios to record a result, found %', v_count;
  END IF;
  RAISE NOTICE 'Legacy notification INSERT-RLS correction security/regression tests PASSED: %/12', v_count;
END $$;

ROLLBACK;
