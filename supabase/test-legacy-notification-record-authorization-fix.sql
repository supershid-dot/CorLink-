-- CAP-003 Phase 1.0B legacy notification RECORD-authorization
-- correction -- focused security/regression suite (20 required
-- scenarios). Disposable local PostgreSQL only. Runs in one
-- transaction and leaves no fixtures (rolled back at the end).
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf80_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf80_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf80_results, wf80_ids TO authenticated;

-- ── Fixtures (as postgres, bypasses RLS) ────────────────────────────
INSERT INTO organizations(id,name,type,code) VALUES
 ('80300000-0000-0000-0000-000000000001','WF80 Org From','authority','WF80OF'),
 ('80300000-0000-0000-0000-000000000002','WF80 Org To','authority','WF80OT'),
 ('80300000-0000-0000-0000-000000000003','WF80 Org Other','authority','WF80OO'),
 ('80300000-0000-0000-0000-000000000004','WF80 Org MCS','mcs','WF80MC');

INSERT INTO divisions(id, org_id, name) VALUES
 ('80300000-0004-0000-0000-000000000001', '80300000-0000-0000-0000-000000000001', 'WF80 Div From'),
 ('80300000-0004-0000-0000-000000000002', '80300000-0000-0000-0000-000000000002', 'WF80 Div To'),
 ('80300000-0004-0000-0000-000000000003', '80300000-0000-0000-0000-000000000004', 'WF80 Div MCS');

-- Sections. ORG_FROM: SEC_FROM1 (request from-side), SEC_FROM_OTHER
-- (unrelated -- attacker/victim live here), SEC_ENTRY (designated
-- Entry intake section), SEC_ENTRY_TO (Entry's responding section),
-- SEC_LOOP (looped-in via internal collaboration, shared by both the
-- request- and entry-anchored internal_requests fixtures).
-- ORG_TO: SEC_TO1 (request/letter to-side), SEC_TO_OTHER (unrelated,
-- isolates the org-level supervisor branch from any section tie).
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
 ('80300000-0002-0000-0000-000000000001', '80300000-0000-0000-0000-000000000001', '80300000-0004-0000-0000-000000000001', 'WF80 Sec From1', 'SF1'),
 ('80300000-0002-0000-0000-000000000002', '80300000-0000-0000-0000-000000000001', '80300000-0004-0000-0000-000000000001', 'WF80 Sec From Other', 'SFO'),
 ('80300000-0002-0000-0000-000000000003', '80300000-0000-0000-0000-000000000001', '80300000-0004-0000-0000-000000000001', 'WF80 Sec Entry', 'SEN'),
 ('80300000-0002-0000-0000-000000000004', '80300000-0000-0000-0000-000000000001', '80300000-0004-0000-0000-000000000001', 'WF80 Sec Entry To', 'SET'),
 ('80300000-0002-0000-0000-000000000005', '80300000-0000-0000-0000-000000000001', '80300000-0004-0000-0000-000000000001', 'WF80 Sec Loop', 'SLP'),
 ('80300000-0002-0000-0000-000000000006', '80300000-0000-0000-0000-000000000002', '80300000-0004-0000-0000-000000000002', 'WF80 Sec To1', 'ST1'),
 ('80300000-0002-0000-0000-000000000007', '80300000-0000-0000-0000-000000000002', '80300000-0004-0000-0000-000000000002', 'WF80 Sec To Other', 'STO');

INSERT INTO entry_sections(org_id, section_id) VALUES
 ('80300000-0000-0000-0000-000000000001', '80300000-0002-0000-0000-000000000003');

INSERT INTO auth.users(id,email) VALUES
 ('80300000-0001-0000-0000-000000000001','creator@wf80t.local'),
 ('80300000-0001-0000-0000-000000000002','attacker@wf80t.local'),
 ('80300000-0001-0000-0000-000000000003','victim@wf80t.local'),
 ('80300000-0001-0000-0000-000000000004','enteredby@wf80t.local'),
 ('80300000-0001-0000-0000-000000000005','entrytomember@wf80t.local'),
 ('80300000-0001-0000-0000-000000000006','loopmember@wf80t.local'),
 ('80300000-0001-0000-0000-000000000007','tosectionmember@wf80t.local'),
 ('80300000-0001-0000-0000-000000000008','toorgsupervisor@wf80t.local'),
 ('80300000-0001-0000-0000-000000000009','tounrelated@wf80t.local'),
 ('80300000-0001-0000-0000-000000000010','otherorg@wf80t.local'),
 ('80300000-0001-0000-0000-000000000011','plsubmitter@wf80t.local');

INSERT INTO users(id,org_id,service_number,full_name,email,is_active,is_prisoner_letters_staff) VALUES
 ('80300000-0001-0000-0000-000000000001','80300000-0000-0000-0000-000000000001','WF80-1','Creator', 'creator@wf80t.local',true,false),
 ('80300000-0001-0000-0000-000000000002','80300000-0000-0000-0000-000000000001','WF80-2','Attacker (same org as Victim, no ties to any record)', 'attacker@wf80t.local',true,false),
 ('80300000-0001-0000-0000-000000000003','80300000-0000-0000-0000-000000000001','WF80-3','Victim (same org as Attacker, no ties to any record)', 'victim@wf80t.local',true,false),
 ('80300000-0001-0000-0000-000000000004','80300000-0000-0000-0000-000000000001','WF80-4','Entered By', 'enteredby@wf80t.local',true,false),
 ('80300000-0001-0000-0000-000000000005','80300000-0000-0000-0000-000000000001','WF80-5','Entry To-Section Member', 'entrytomember@wf80t.local',true,false),
 ('80300000-0001-0000-0000-000000000006','80300000-0000-0000-0000-000000000001','WF80-6','Looped-In Section Member', 'loopmember@wf80t.local',true,false),
 ('80300000-0001-0000-0000-000000000007','80300000-0000-0000-0000-000000000002','WF80-7','To-Section Member', 'tosectionmember@wf80t.local',true,false),
 ('80300000-0001-0000-0000-000000000008','80300000-0000-0000-0000-000000000002','WF80-8','To-Org Supervisor (no direct section tie)', 'toorgsupervisor@wf80t.local',true,false),
 ('80300000-0001-0000-0000-000000000009','80300000-0000-0000-0000-000000000002','WF80-9','To-Org Unrelated (no notify-role, no section tie)', 'tounrelated@wf80t.local',true,false),
 ('80300000-0001-0000-0000-000000000010','80300000-0000-0000-0000-000000000003','WF80-10','Other-Org User (not a party to anything)', 'otherorg@wf80t.local',true,false),
 ('80300000-0001-0000-0000-000000000011','80300000-0000-0000-0000-000000000004','WF80-11','Prisoner Letters Submitter', 'plsubmitter@wf80t.local',true,true);

INSERT INTO user_assignments(user_id, scope_type, scope_id, role, is_active) VALUES
 ('80300000-0001-0000-0000-000000000001','section','80300000-0002-0000-0000-000000000001','staff',true),
 ('80300000-0001-0000-0000-000000000002','section','80300000-0002-0000-0000-000000000002','staff',true),
 ('80300000-0001-0000-0000-000000000003','section','80300000-0002-0000-0000-000000000002','staff',true),
 ('80300000-0001-0000-0000-000000000004','section','80300000-0002-0000-0000-000000000003','staff',true),
 ('80300000-0001-0000-0000-000000000005','section','80300000-0002-0000-0000-000000000004','staff',true),
 ('80300000-0001-0000-0000-000000000006','section','80300000-0002-0000-0000-000000000005','staff',true),
 ('80300000-0001-0000-0000-000000000007','section','80300000-0002-0000-0000-000000000006','staff',true),
 ('80300000-0001-0000-0000-000000000008','section','80300000-0002-0000-0000-000000000007','supervisor',true),
 ('80300000-0001-0000-0000-000000000009','section','80300000-0002-0000-0000-000000000007','staff',true);

-- Real request REQ1: WF80 Org From -> WF80 Org To, routed to SEC_TO1,
-- assigned to the to-section member.
INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, to_section_id, assigned_to, subject, body, created_by, status)
VALUES ('80300000-0003-0000-0000-000000000001',
        '80300000-0000-0000-0000-000000000001', '80300000-0000-0000-0000-000000000002',
        '80300000-0002-0000-0000-000000000001', '80300000-0002-0000-0000-000000000006',
        '80300000-0001-0000-0000-000000000007',
        'WF80 real request', 'body', '80300000-0001-0000-0000-000000000001', 'in_progress');

-- Decoy unrelated request (Org To -> Org Other) -- attacker/victim
-- have zero relationship to it, same "real-but-unrelated decoy" shape
-- 1.0A's own suite uses.
INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, subject, body, created_by, status)
VALUES ('80300000-0003-0000-0000-000000000002',
        '80300000-0000-0000-0000-000000000002', '80300000-0000-0000-0000-000000000003',
        '80300000-0002-0000-0000-000000000007',
        'WF80 decoy request', 'body', '80300000-0001-0000-0000-000000000009', 'sent');

-- internal_requests looped-in on REQ1: SEC_TO1 loops in SEC_LOOP.
INSERT INTO internal_requests (id, parent_request_id, from_section_id, to_section_id, created_by, subject, body, status)
VALUES ('80300000-0005-0000-0000-000000000001', '80300000-0003-0000-0000-000000000001',
        '80300000-0002-0000-0000-000000000006', '80300000-0002-0000-0000-000000000005',
        '80300000-0001-0000-0000-000000000007', 'WF80 loop-in', 'body', 'sent');

-- Real external_correspondence ENTRY1: logged by Entry, routed to
-- SEC_ENTRY_TO.
INSERT INTO external_correspondence (id, org_id, source_channel, sender_category, sender_name, subject, body, entered_by, to_section_id, assigned_to, status)
VALUES ('80300000-0006-0000-0000-000000000001', '80300000-0000-0000-0000-000000000001',
        'email', 'public', 'A member of the public', 'WF80 real entry', 'body',
        '80300000-0001-0000-0000-000000000004', '80300000-0002-0000-0000-000000000004',
        '80300000-0001-0000-0000-000000000005', 'routed');

-- internal_requests looped-in on ENTRY1: SEC_ENTRY_TO loops in SEC_LOOP.
INSERT INTO internal_requests (id, parent_entry_id, from_section_id, to_section_id, created_by, subject, body, status)
VALUES ('80300000-0005-0000-0000-000000000002', '80300000-0006-0000-0000-000000000001',
        '80300000-0002-0000-0000-000000000004', '80300000-0002-0000-0000-000000000005',
        '80300000-0001-0000-0000-000000000005', 'WF80 entry loop-in', 'body', 'sent');

-- Real prisoner_letter LETTER1: WF80 Org MCS -> WF80 Org To.
INSERT INTO prisoner_letters (id, prisoner_id, prisoner_name, from_prison_id, to_org_id, to_section_id, body, submitted_by, assigned_to, status)
VALUES ('80300000-0007-0000-0000-000000000001', 'P-1', 'Prisoner One',
        '80300000-0000-0000-0000-000000000004', '80300000-0000-0000-0000-000000000002',
        '80300000-0002-0000-0000-000000000006', 'body',
        '80300000-0001-0000-0000-000000000011', '80300000-0001-0000-0000-000000000007', 'received');

\set U_CREATOR '{"sub":"80300000-0001-0000-0000-000000000001"}'
\set U_ATTACKER '{"sub":"80300000-0001-0000-0000-000000000002"}'
\set U_VICTIM '{"sub":"80300000-0001-0000-0000-000000000003"}'
\set U_ENTERED_BY '{"sub":"80300000-0001-0000-0000-000000000004"}'
\set U_ENTRY_TO_MEMBER '{"sub":"80300000-0001-0000-0000-000000000005"}'
\set U_LOOP_MEMBER '{"sub":"80300000-0001-0000-0000-000000000006"}'
\set U_TO_SECTION_MEMBER '{"sub":"80300000-0001-0000-0000-000000000007"}'
\set U_TO_ORG_SUPERVISOR '{"sub":"80300000-0001-0000-0000-000000000008"}'
\set U_TO_UNRELATED '{"sub":"80300000-0001-0000-0000-000000000009"}'
\set U_OTHER_ORG '{"sub":"80300000-0001-0000-0000-000000000010"}'
\set U_PL_SUBMITTER '{"sub":"80300000-0001-0000-0000-000000000011"}'

-- ── 1: Same-org Attacker cannot notify unrelated Victim with a fake Task reference ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_ATTACKER', false);
DO $$
BEGIN
  BEGIN
    PERFORM create_legacy_notification(
      ARRAY['80300000-0001-0000-0000-000000000003']::UUID[], 'new_request', 'task',
      gen_random_uuid(), 'FAKE: task-shaped fabrication');
    RAISE EXCEPTION 'SECURITY HOLE: record_type=task was accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf80_results VALUES (1,'Same-organization Attacker cannot notify unrelated Victim with a fake Task reference -- record_type=task is unsupported and rejected outright');

-- ── 2: ... fake Meeting reference ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_ATTACKER', false);
DO $$
BEGIN
  BEGIN
    PERFORM create_legacy_notification(
      ARRAY['80300000-0001-0000-0000-000000000003']::UUID[], 'new_request', 'meeting',
      gen_random_uuid(), 'FAKE: meeting-shaped fabrication');
    RAISE EXCEPTION 'SECURITY HOLE: record_type=meeting was accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf80_results VALUES (2,'Same-organization Attacker cannot notify unrelated Victim with a fake Meeting reference -- record_type=meeting is unsupported and rejected outright');

-- ── 3: ... fake Entry reference (nonexistent external_correspondence id) ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_ATTACKER', false);
DO $$
BEGIN
  BEGIN
    PERFORM create_legacy_notification(
      ARRAY['80300000-0001-0000-0000-000000000003']::UUID[], 'new_external_correspondence', 'external_correspondence',
      gen_random_uuid(), 'FAKE: entry-shaped fabrication, nonexistent record');
    RAISE EXCEPTION 'SECURITY HOLE: a nonexistent external_correspondence id was accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf80_results VALUES (3,'Same-organization Attacker cannot notify unrelated Victim with a fake Entry reference -- external_correspondence is a supported record_type but the nonexistent record_id is rejected');

-- ── 4: ... fake Internal Collaboration reference ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_ATTACKER', false);
DO $$
BEGIN
  BEGIN
    PERFORM create_legacy_notification(
      ARRAY['80300000-0001-0000-0000-000000000003']::UUID[], 'new_request', 'internal_request',
      gen_random_uuid(), 'FAKE: internal-collab-shaped fabrication');
    RAISE EXCEPTION 'SECURITY HOLE: record_type=internal_request was accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf80_results VALUES (4,'Same-organization Attacker cannot notify unrelated Victim with a fake Internal Collaboration reference -- record_type=internal_request is unsupported (real client code only ever notifies about the resolved PARENT request/entry) and rejected outright');

-- ── 5: nonexistent record_id rejected (supported record_type, real caller/recipient shape) ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_CREATOR', false);
DO $$
BEGIN
  BEGIN
    PERFORM create_legacy_notification(
      ARRAY['80300000-0001-0000-0000-000000000007']::UUID[], 'new_request', 'request',
      gen_random_uuid(), 'nonexistent request id');
    RAISE EXCEPTION 'SECURITY HOLE: a nonexistent request id was accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf80_results VALUES (5,'A nonexistent record_id is rejected for a supported record_type, even with an otherwise-plausible caller/recipient shape');

-- ── 6: unsupported record_type rejected (generic case, distinct string) ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_ATTACKER', false);
DO $$
BEGIN
  BEGIN
    PERFORM create_legacy_notification(
      ARRAY['80300000-0001-0000-0000-000000000003']::UUID[], 'new_request', 'room_booking',
      gen_random_uuid(), 'unsupported record_type');
    RAISE EXCEPTION 'SECURITY HOLE: record_type=room_booking was accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf80_results VALUES (6,'An arbitrary unsupported record_type string is rejected outright, before any record lookup');

-- ── 7: unsupported type/record_type combination rejected ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_CREATOR', false);
DO $$
BEGIN
  BEGIN
    PERFORM create_legacy_notification(
      ARRAY['80300000-0001-0000-0000-000000000007']::UUID[], 'new_external_correspondence', 'request',
      '80300000-0003-0000-0000-000000000001', 'valid type, wrong record_type pairing');
    RAISE EXCEPTION 'SECURITY HOLE: an Entry-only type was accepted paired with record_type=request';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf80_results VALUES (7,'A notification type that is valid overall (passes the table''s own type CHECK) but was never legitimately paired with the given record_type by any real call site is rejected by the closed (record_type, type) allowlist');

-- ── 8: caller lacking record authorization rejected (recipient would otherwise be legitimate) ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_ATTACKER', false);
DO $$
BEGIN
  BEGIN
    PERFORM create_legacy_notification(
      ARRAY['80300000-0001-0000-0000-000000000007']::UUID[], 'new_request', 'request',
      '80300000-0003-0000-0000-000000000001', 'FAKE: unauthorized caller, otherwise-legitimate recipient');
    RAISE EXCEPTION 'SECURITY HOLE: an unauthorized caller (no tie to REQ1) was allowed to notify a legitimate REQ1 recipient';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf80_results VALUES (8,'A caller with zero legitimate connection to the real referenced request is rejected, even though the requested recipient (the request''s own assigned to-section member) would otherwise be a legitimate recipient of a notification about it');

-- ── 9: recipient not legitimately tied to the record rejected -- THE core same-org gap this milestone closes ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_CREATOR', false);
DO $$
BEGIN
  BEGIN
    PERFORM create_legacy_notification(
      ARRAY['80300000-0001-0000-0000-000000000003']::UUID[], 'new_request', 'request',
      '80300000-0003-0000-0000-000000000001', 'FAKE: same-org recipient, zero relationship to REQ1');
    RAISE EXCEPTION 'SECURITY HOLE: a same-organization recipient with zero relationship to the real request was accepted (the exact 1.0A-era gap)';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf80_results VALUES (9,'A recipient sharing the caller''s organization but with zero section/role/individual-reference tie to the real referenced request is rejected -- same-organization membership is no longer, by itself, ever sufficient (the core defect this milestone closes)');

-- ── 10: legitimate same-org Entry notification succeeds ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_ENTERED_BY', false);
DO $$
DECLARE v_result INTEGER;
BEGIN
  SELECT create_legacy_notification(
    ARRAY['80300000-0001-0000-0000-000000000005']::UUID[], 'new_external_correspondence', 'external_correspondence',
    '80300000-0006-0000-0000-000000000001', 'legit entry notify'
  ) INTO v_result;
  IF v_result <> 1 THEN RAISE EXCEPTION 'expected 1 row inserted, got %', v_result; END IF;
END $$;
RESET ROLE;
INSERT INTO wf80_results VALUES (10,'A legitimate same-organization Entry notification (Entry staff who logged the case notifying the routed-to section''s member) succeeds');

-- ── 11: legitimate same-org Internal Collaboration notification succeeds ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_TO_SECTION_MEMBER', false);
DO $$
DECLARE v_result INTEGER;
BEGIN
  SELECT create_legacy_notification(
    ARRAY['80300000-0001-0000-0000-000000000006']::UUID[], 'new_request', 'request',
    '80300000-0003-0000-0000-000000000001', 'legit internal-collab notify'
  ) INTO v_result;
  IF v_result <> 1 THEN RAISE EXCEPTION 'expected 1 row inserted, got %', v_result; END IF;
END $$;
RESET ROLE;
INSERT INTO wf80_results VALUES (11,'A legitimate same-organization Internal Collaboration notification (the section that looped in help notifying the looped-in section''s member, record_type/record_id resolved to the PARENT request via parentRef()) succeeds');

-- ── 12: legitimate same-org review/comment notification succeeds ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_TO_SECTION_MEMBER', false);
DO $$
DECLARE v_result INTEGER;
BEGIN
  SELECT create_legacy_notification(
    ARRAY['80300000-0001-0000-0000-000000000001']::UUID[], 'draft_returned', 'request',
    '80300000-0003-0000-0000-000000000001', 'legit review-comment notify (supervisor to drafter)'
  ) INTO v_result;
  IF v_result <> 1 THEN RAISE EXCEPTION 'expected 1 row inserted, got %', v_result; END IF;
END $$;
RESET ROLE;
INSERT INTO wf80_results VALUES (12,'A legitimate same-organization review-comment notification (a to-section reviewer notifying the request''s original creator, the review-comments-api.js -> request-detail.js shape) succeeds');

-- ── 13: legitimate Requests cross-org notification succeeds ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_CREATOR', false);
DO $$
DECLARE v_result INTEGER;
BEGIN
  SELECT create_legacy_notification(
    ARRAY['80300000-0001-0000-0000-000000000008']::UUID[], 'new_request', 'request',
    '80300000-0003-0000-0000-000000000001', 'legit cross-org notify (org supervisor at to_org)'
  ) INTO v_result;
  IF v_result <> 1 THEN RAISE EXCEPTION 'expected 1 row inserted, got %', v_result; END IF;
END $$;
RESET ROLE;
INSERT INTO wf80_results VALUES (13,'The already-correct Requests cross-organization path (notifying a supervisor at the request''s own to_org_id, org_supervisor_user_ids()-style, no direct section tie) still succeeds, preserved exactly and re-tested');

-- ── 14: legitimate Prisoner Letters cross-org notification succeeds ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_PL_SUBMITTER', false);
DO $$
DECLARE v_result INTEGER;
BEGIN
  SELECT create_legacy_notification(
    ARRAY['80300000-0001-0000-0000-000000000008']::UUID[], 'new_prisoner_letter', 'prisoner_letter',
    '80300000-0007-0000-0000-000000000001', 'legit cross-org prisoner letter notify'
  ) INTO v_result;
  IF v_result <> 1 THEN RAISE EXCEPTION 'expected 1 row inserted, got %', v_result; END IF;
END $$;
RESET ROLE;
INSERT INTO wf80_results VALUES (14,'The already-correct Prisoner Letters cross-organization path (MCS submitter notifying an authority-org supervisor at the letter''s own to_org_id) still succeeds, preserved exactly and re-tested');

-- ── 15: cross-org unrelated recipient rejected (re-validates 1.0A's original cross-org protection still holds) ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_CREATOR', false);
DO $$
BEGIN
  BEGIN
    PERFORM create_legacy_notification(
      ARRAY['80300000-0001-0000-0000-000000000010']::UUID[], 'new_request', 'request',
      '80300000-0003-0000-0000-000000000001', 'FAKE: unrelated third-org recipient');
    RAISE EXCEPTION 'SECURITY HOLE: a recipient in a third organization with no relationship to the request was accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf80_results VALUES (15,'A recipient in a third organization with no relationship whatsoever to the request (not from_org_id, not to_org_id) is rejected -- 1.0A''s original cross-organization protection still holds unweakened');

-- ── 16: anonymous execution denied ──
SET ROLE anon;
DO $$
BEGIN
  BEGIN
    PERFORM create_legacy_notification(
      ARRAY['80300000-0001-0000-0000-000000000001']::UUID[], 'new_request', 'request',
      '80300000-0003-0000-0000-000000000001', 'anon rpc');
    RAISE EXCEPTION 'SECURITY HOLE: anon RPC call succeeded';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;
INSERT INTO wf80_results VALUES (16,'Anonymous execution of create_legacy_notification remains denied (EXECUTE revoked from PUBLIC/anon, unchanged by this correction)');

-- ── 17: direct INSERT remains denied ──
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_CREATOR', false);
DO $$
BEGIN
  BEGIN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    VALUES ('80300000-0001-0000-0000-000000000007', 'new_request', 'request', gen_random_uuid(), 'raw forged');
    RAISE EXCEPTION 'SECURITY HOLE: raw INSERT succeeded';
  EXCEPTION WHEN insufficient_privilege OR OTHERS THEN
    IF SQLSTATE NOT IN ('42501','01000') AND SQLERRM NOT ILIKE '%row-level security%' THEN RAISE; END IF;
  END;
END $$;
RESET ROLE;
INSERT INTO wf80_results VALUES (17,'Direct client INSERT into notifications remains denied (no INSERT policy exists, unchanged by this correction) -- create_legacy_notification is still the sole creation path');

-- ── 18: own SELECT/read-state still works ──
INSERT INTO notifications (user_id, type, record_type, record_id, message)
VALUES ('80300000-0001-0000-0000-000000000001', 'new_request', 'request', gen_random_uuid(), 'a notification actually addressed to Creator');
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_CREATOR', false);
DO $$
DECLARE v_own INTEGER; v_id UUID; v_updated INTEGER; v_is_read BOOLEAN;
BEGIN
  SELECT count(*) INTO v_own FROM notifications WHERE user_id = '80300000-0001-0000-0000-000000000001';
  IF v_own < 1 THEN RAISE EXCEPTION 'expected Creator to see at least their own notification, got %', v_own; END IF;
  SELECT id INTO v_id FROM notifications WHERE user_id = '80300000-0001-0000-0000-000000000001'
    AND message = 'a notification actually addressed to Creator';
  UPDATE notifications SET is_read = TRUE WHERE id = v_id;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> 1 THEN RAISE EXCEPTION 'expected Creator to mark their own notification read, rows affected=%', v_updated; END IF;
  SELECT is_read INTO v_is_read FROM notifications WHERE id = v_id;
  IF NOT v_is_read THEN RAISE EXCEPTION 'expected is_read to be TRUE after the update'; END IF;
END $$;
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_VICTIM', false);
DO $$
DECLARE v_others INTEGER;
BEGIN
  SELECT count(*) INTO v_others FROM notifications WHERE user_id = '80300000-0001-0000-0000-000000000001';
  IF v_others <> 0 THEN RAISE EXCEPTION 'expected Victim to see zero of Creator''s notifications, got %', v_others; END IF;
END $$;
RESET ROLE;
INSERT INTO wf80_results VALUES (18,'notif_select/notif_update remain correctly scoped to user_id = auth.uid(), completely unaffected by this correction -- a user can still read and mark-read only their own notifications');

-- ── 19: existing service-definer/module-generated notifications remain unaffected ──
-- notifications.sql (which defines check_deadlines()) requires the
-- pg_cron extension, unavailable in this disposable container (same as
-- every prior phase's baseline build), so it is not part of this local
-- baseline -- verified directly rather than assumed. The actual
-- invariant this scenario protects -- that a SECURITY DEFINER function
-- (Meetings/Rooms/Tasks/task-dependencies/check_deadlines() in the
-- real deployed schema) still inserts into notifications directly,
-- completely bypassing this table's RLS regardless of notif_insert's
-- removal -- is exercised directly here with a throwaway SECURITY
-- DEFINER function, the same mechanism every one of those real
-- module RPCs uses.
DO $$
BEGIN
  IF to_regprocedure('public.check_deadlines()') IS NOT NULL THEN
    PERFORM check_deadlines();
  END IF;
END $$;
CREATE OR REPLACE FUNCTION wf80_simulate_module_rpc_insert() RETURNS VOID AS $$
BEGIN
  INSERT INTO notifications (user_id, type, record_type, record_id, message)
  VALUES ('80300000-0001-0000-0000-000000000001', 'new_request', 'request', gen_random_uuid(), 'module-RPC-style direct insert');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
-- Counted as postgres (not 'authenticated') deliberately -- notif_select
-- scopes SELECT to user_id = auth.uid(), and the row this inserts
-- belongs to Creator, not the Attacker triggering the insert, so
-- counting as 'authenticated' would be RLS-filtered to zero regardless
-- of whether the INSERT itself succeeded. The property under test is
-- whether the INSERT bypassed RLS, not whether the counting query does.
DO $$
DECLARE v_before INTEGER;
BEGIN
  SELECT count(*) INTO v_before FROM notifications WHERE message = 'module-RPC-style direct insert';
  PERFORM set_config('wf80.before_count', v_before::TEXT, false);
END $$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'U_ATTACKER', false);
DO $$
BEGIN
  PERFORM wf80_simulate_module_rpc_insert();
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'wf80_simulate_module_rpc_insert() raised: % (SQLSTATE %)', SQLERRM, SQLSTATE;
END $$;
RESET ROLE;
DO $$
DECLARE v_before INTEGER; v_after INTEGER;
BEGIN
  v_before := current_setting('wf80.before_count')::INTEGER;
  SELECT count(*) INTO v_after FROM notifications WHERE message = 'module-RPC-style direct insert';
  IF v_after <> v_before + 1 THEN
    RAISE EXCEPTION 'expected a SECURITY DEFINER module-style function (Meetings/Rooms/Tasks/check_deadlines() shape) to still insert into notifications directly regardless of notif_insert''s removal, got before=% after=%', v_before, v_after;
  END IF;
END $$;
DROP FUNCTION wf80_simulate_module_rpc_insert();
INSERT INTO wf80_results VALUES (19,'Existing SECURITY DEFINER module notification generators (Meetings/Rooms/Tasks/task-dependencies/check_deadlines()), which insert directly into notifications and never call create_legacy_notification(), remain structurally unaffected by this correction -- a SECURITY DEFINER function still bypasses the table''s RLS entirely and inserts successfully even when invoked by an otherwise-unauthorized caller');

-- ── 20: fabricated notification text never reaches an unrelated recipient -- every rejection above happened before any INSERT ──
DO $$
DECLARE v_fake INTEGER;
BEGIN
  SELECT count(*) INTO v_fake FROM notifications WHERE message LIKE 'FAKE:%';
  IF v_fake <> 0 THEN RAISE EXCEPTION 'expected zero fabricated notifications to have reached the table, found %', v_fake; END IF;
END $$;
INSERT INTO wf80_results VALUES (20,'Every fabricated-notification attempt above (scenarios 1,2,3,4,8,9,15) was rejected entirely before any row was inserted -- zero ''FAKE:'' rows exist in notifications, confirming the all-or-nothing rejection happens pre-insert, not as a partial/silent skip');

RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf80_results;
  IF v_count <> 20 THEN
    RAISE EXCEPTION 'Expected 20 scenarios to record a result, found %', v_count;
  END IF;
  RAISE NOTICE 'Legacy notification RECORD-authorization correction security/regression tests PASSED: %/20', v_count;
END $$;

ROLLBACK;
