-- CAP-003 Phase 1.3A legacy notification SECURITY DEFINER search-path
-- hardening -- focused regression suite. Disposable local PostgreSQL
-- only. Runs in one transaction and leaves no fixtures (rolled back
-- at the end).
--
-- Part 1 (scenarios 1-9): re-verifies the same record-authorization
-- outcomes docs/80's own 20-scenario suite already established,
-- against the SAME seven functions now that they pin search_path --
-- proving the hardening changed zero business-authorization behavior.
-- Part 2 (scenarios 10-11): proves the actual security property the
-- hardening exists for -- a caller-controlled search_path can no
-- longer redirect these SECURITY DEFINER functions' unqualified table
-- references to an attacker-created shadow object.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf84_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
GRANT SELECT, INSERT ON wf84_results TO authenticated;

-- ── Fixtures ─────────────────────────────────────────────────────────
INSERT INTO organizations(id,name,type,code) VALUES
 ('84000000-0000-0000-0000-000000000001','WF84 Org From','authority','WF84F'),
 ('84000000-0000-0000-0000-000000000002','WF84 Org To','authority','WF84T'),
 ('84000000-0000-0000-0000-000000000003','WF84 Org Other','authority','WF84O');
INSERT INTO divisions(id, org_id, name) VALUES
 ('84000000-0004-0000-0000-000000000001','84000000-0000-0000-0000-000000000001','WF84 Div From'),
 ('84000000-0004-0000-0000-000000000002','84000000-0000-0000-0000-000000000002','WF84 Div To');
INSERT INTO sections(id, org_id, division_id, name, code) VALUES
 ('84000000-0002-0000-0000-000000000001','84000000-0000-0000-0000-000000000001','84000000-0004-0000-0000-000000000001','WF84 Sec From','SF1'),
 ('84000000-0002-0000-0000-000000000002','84000000-0000-0000-0000-000000000002','84000000-0004-0000-0000-000000000002','WF84 Sec To','ST1');
INSERT INTO entry_sections(org_id, section_id) VALUES ('84000000-0000-0000-0000-000000000001','84000000-0002-0000-0000-000000000001');

INSERT INTO auth.users(id,email) VALUES
 ('84000000-0001-0000-0000-000000000001','creator@wf84t.local'),
 ('84000000-0001-0000-0000-000000000002','attacker@wf84t.local'),
 ('84000000-0001-0000-0000-000000000003','entrycreator@wf84t.local'),
 ('84000000-0001-0000-0000-000000000004','lettersubmitter@wf84t.local'),
 ('84000000-0001-0000-0000-000000000005','crossorgsupervisor@wf84t.local'),
 ('84000000-0001-0000-0000-000000000006','thirdorguser@wf84t.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('84000000-0001-0000-0000-000000000001','84000000-0000-0000-0000-000000000001','WF84-1','Creator','creator@wf84t.local',true),
 ('84000000-0001-0000-0000-000000000002','84000000-0000-0000-0000-000000000001','WF84-2','Attacker (same org, unrelated)','attacker@wf84t.local',true),
 ('84000000-0001-0000-0000-000000000003','84000000-0000-0000-0000-000000000001','WF84-3','Entry Creator','entrycreator@wf84t.local',true),
 ('84000000-0001-0000-0000-000000000004','84000000-0000-0000-0000-000000000001','WF84-4','Letter Submitter','lettersubmitter@wf84t.local',true),
 ('84000000-0001-0000-0000-000000000005','84000000-0000-0000-0000-000000000002','WF84-5','Cross-Org Supervisor','crossorgsupervisor@wf84t.local',true),
 ('84000000-0001-0000-0000-000000000006','84000000-0000-0000-0000-000000000003','WF84-6','Third-Org Unrelated','thirdorguser@wf84t.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('84000000-0001-0000-0000-000000000001','section','84000000-0002-0000-0000-000000000001','staff',true,true),
 ('84000000-0001-0000-0000-000000000005','section','84000000-0002-0000-0000-000000000002','supervisor',true,true);

INSERT INTO requests (id, from_org_id, to_org_id, from_section_id, to_section_id, created_by, subject, body, reference_number)
VALUES ('84000000-0003-0000-0000-000000000001','84000000-0000-0000-0000-000000000001','84000000-0000-0000-0000-000000000002','84000000-0002-0000-0000-000000000001','84000000-0002-0000-0000-000000000002','84000000-0001-0000-0000-000000000001','WF84 test request','WF84 test request body','WF84-REQ-1');
INSERT INTO external_correspondence (id, org_id, source_channel, sender_category, sender_name, to_section_id, entered_by, reference_number, subject, body)
VALUES ('84000000-0005-0000-0000-000000000001','84000000-0000-0000-0000-000000000001','email','public','WF84 Sender','84000000-0002-0000-0000-000000000001','84000000-0001-0000-0000-000000000003','WF84-ENT-1','WF84 test entry','WF84 test entry body');
INSERT INTO prisoner_letters (id, prisoner_id, prisoner_name, from_prison_id, to_org_id, submitted_by, reference_number, body)
VALUES ('84000000-0006-0000-0000-000000000001','WF84-P1','WF84 Prisoner','84000000-0000-0000-0000-000000000001','84000000-0000-0000-0000-000000000002','84000000-0001-0000-0000-000000000004','WF84-PL-1','WF84 test letter body');

-- ── 1: legitimate request recipient ──
DO $$ BEGIN
  IF NOT notif_request_legitimate_recipient('84000000-0003-0000-0000-000000000001','84000000-0001-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'scenario 1 failed: the request creator must be a legitimate recipient';
  END IF;
END $$;
INSERT INTO wf84_results VALUES (1,'Legitimate request recipient (the request''s own creator) is accepted -- identical to pre-1.3A behavior');

-- ── 2: invalid request recipient (same-org unrelated) ──
DO $$ BEGIN
  IF notif_request_legitimate_recipient('84000000-0003-0000-0000-000000000001','84000000-0001-0000-0000-000000000002') THEN
    RAISE EXCEPTION 'SECURITY HOLE: a same-org unrelated user was accepted as a request recipient';
  END IF;
END $$;
INSERT INTO wf84_results VALUES (2,'Invalid request recipient (same-org, unrelated to the record) is rejected -- identical to pre-1.3A behavior');

-- ── 3: legitimate entry recipient ──
DO $$ BEGIN
  IF NOT notif_entry_legitimate_recipient('84000000-0005-0000-0000-000000000001','84000000-0001-0000-0000-000000000003') THEN
    RAISE EXCEPTION 'scenario 3 failed: the entry''s own entered_by user must be a legitimate recipient';
  END IF;
END $$;
INSERT INTO wf84_results VALUES (3,'Legitimate entry recipient (the entry''s own entered_by user) is accepted -- identical to pre-1.3A behavior');

-- ── 4: invalid entry recipient ──
DO $$ BEGIN
  IF notif_entry_legitimate_recipient('84000000-0005-0000-0000-000000000001','84000000-0001-0000-0000-000000000002') THEN
    RAISE EXCEPTION 'SECURITY HOLE: a same-org unrelated user was accepted as an entry recipient';
  END IF;
END $$;
INSERT INTO wf84_results VALUES (4,'Invalid entry recipient (same-org, unrelated to the record) is rejected -- identical to pre-1.3A behavior');

-- ── 5: legitimate prisoner-letter recipient ──
DO $$ BEGIN
  IF NOT notif_prisoner_letter_legitimate_recipient('84000000-0006-0000-0000-000000000001','84000000-0001-0000-0000-000000000004') THEN
    RAISE EXCEPTION 'scenario 5 failed: the letter''s own submitted_by user must be a legitimate recipient';
  END IF;
END $$;
INSERT INTO wf84_results VALUES (5,'Legitimate prisoner-letter recipient (the letter''s own submitted_by user) is accepted -- identical to pre-1.3A behavior');

-- ── 6: invalid prisoner-letter recipient ──
DO $$ BEGIN
  IF notif_prisoner_letter_legitimate_recipient('84000000-0006-0000-0000-000000000001','84000000-0001-0000-0000-000000000002') THEN
    RAISE EXCEPTION 'SECURITY HOLE: a same-org unrelated user was accepted as a prisoner-letter recipient';
  END IF;
END $$;
INSERT INTO wf84_results VALUES (6,'Invalid prisoner-letter recipient (same-org, unrelated to the record) is rejected -- identical to pre-1.3A behavior');

-- ── 7: same-org unrelated recipient rejected (explicit, cross-record-type) ──
DO $$
DECLARE v_req BOOLEAN; v_ent BOOLEAN; v_pl BOOLEAN;
BEGIN
  SELECT notif_request_legitimate_recipient('84000000-0003-0000-0000-000000000001','84000000-0001-0000-0000-000000000002') INTO v_req;
  SELECT notif_entry_legitimate_recipient('84000000-0005-0000-0000-000000000001','84000000-0001-0000-0000-000000000002') INTO v_ent;
  SELECT notif_prisoner_letter_legitimate_recipient('84000000-0006-0000-0000-000000000001','84000000-0001-0000-0000-000000000002') INTO v_pl;
  IF v_req OR v_ent OR v_pl THEN
    RAISE EXCEPTION 'SECURITY HOLE: same-org unrelated Attacker was accepted by at least one record-type predicate (req=%,ent=%,pl=%)', v_req, v_ent, v_pl;
  END IF;
END $$;
INSERT INTO wf84_results VALUES (7,'The same same-org unrelated user is rejected consistently across all three record-type predicates (request/entry/prisoner_letter) -- identical to pre-1.3A behavior');

-- ── 8: cross-org legitimate recipient accepted where approved ──
DO $$ BEGIN
  IF NOT notif_request_legitimate_recipient('84000000-0003-0000-0000-000000000001','84000000-0001-0000-0000-000000000005') THEN
    RAISE EXCEPTION 'scenario 8 failed: the to-org supervisor (a genuine party-org supervisor) must be accepted';
  END IF;
END $$;
INSERT INTO wf84_results VALUES (8,'Cross-org legitimate recipient (the request''s own to-org supervisor) is accepted -- identical to pre-1.3A behavior');

-- ── 9: unrelated third org rejected ──
DO $$
DECLARE v_req BOOLEAN; v_ent BOOLEAN; v_pl BOOLEAN;
BEGIN
  SELECT notif_request_legitimate_recipient('84000000-0003-0000-0000-000000000001','84000000-0001-0000-0000-000000000006') INTO v_req;
  SELECT notif_entry_legitimate_recipient('84000000-0005-0000-0000-000000000001','84000000-0001-0000-0000-000000000006') INTO v_ent;
  SELECT notif_prisoner_letter_legitimate_recipient('84000000-0006-0000-0000-000000000001','84000000-0001-0000-0000-000000000006') INTO v_pl;
  IF v_req OR v_ent OR v_pl THEN
    RAISE EXCEPTION 'SECURITY HOLE: a user from an entirely unrelated third organization was accepted (req=%,ent=%,pl=%)', v_req, v_ent, v_pl;
  END IF;
END $$;
INSERT INTO wf84_results VALUES (9,'A user from an entirely unrelated third organization (no party-org tie to any record) is rejected across all three record-type predicates -- identical to pre-1.3A behavior');

-- ── 10 & 11: search-path adversarial regression -- a caller-controlled
-- search_path can no longer redirect these functions' unqualified
-- table references to an attacker-created shadow object ──
CREATE SCHEMA wf84_evil;
CREATE TABLE wf84_evil.users (id UUID PRIMARY KEY, org_id UUID);
-- Poisoned row: claims Creator belongs to Org Other (a party to
-- nothing in these fixtures) instead of their real Org From.
INSERT INTO wf84_evil.users VALUES ('84000000-0001-0000-0000-000000000001','84000000-0000-0000-0000-000000000003');
CREATE TABLE wf84_evil.requests (id UUID PRIMARY KEY, from_org_id UUID, to_org_id UUID, created_by UUID, received_by UUID, assigned_to UUID, from_section_id UUID, to_section_id UUID, previous_section_id UUID);
-- Poisoned row: claims REQ1 is a request between Org Other and Org
-- Other only, with Attacker as its creator -- if search_path
-- resolution were hijackable, this would make Attacker "legitimate."
INSERT INTO wf84_evil.requests VALUES ('84000000-0003-0000-0000-000000000001','84000000-0000-0000-0000-000000000003','84000000-0000-0000-0000-000000000003','84000000-0001-0000-0000-000000000002',NULL,NULL,NULL,NULL,NULL);

DO $$
DECLARE v_result UUID;
BEGIN
  SET search_path = wf84_evil, public, pg_temp;
  SELECT notif_user_org_id('84000000-0001-0000-0000-000000000001') INTO v_result;
  RESET search_path;
  IF v_result IS DISTINCT FROM '84000000-0000-0000-0000-000000000001'::UUID THEN
    RAISE EXCEPTION 'SECURITY HOLE: notif_user_org_id resolved the caller-poisoned wf84_evil.users row (got org %) instead of the real public.users row (expected Org From)', v_result;
  END IF;
END $$;
INSERT INTO wf84_results VALUES (10,'notif_user_org_id resolves its unqualified "users" reference to the real public.users table regardless of a caller-controlled search_path placing an attacker-created shadow wf84_evil.users ahead of it -- the pinned search_path=public,pg_temp cannot be overridden by the calling session');

DO $$
DECLARE v_result BOOLEAN;
BEGIN
  SET search_path = wf84_evil, public, pg_temp;
  SELECT notif_request_legitimate_recipient('84000000-0003-0000-0000-000000000001','84000000-0001-0000-0000-000000000002') INTO v_result;
  RESET search_path;
  IF v_result THEN
    RAISE EXCEPTION 'SECURITY HOLE: notif_request_legitimate_recipient resolved the caller-poisoned wf84_evil.requests row and accepted Attacker as legitimate';
  END IF;
END $$;
INSERT INTO wf84_results VALUES (11,'notif_request_legitimate_recipient (a more complex helper with multiple unqualified table references and nested SECURITY DEFINER calls) also resolves to the real public.requests table regardless of a caller-controlled search_path -- Attacker remains correctly rejected even with an attacker-created shadow requests row claiming otherwise');

DROP TABLE wf84_evil.requests;
DROP TABLE wf84_evil.users;
DROP SCHEMA wf84_evil;

DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf84_results;
  IF v_count <> 11 THEN RAISE EXCEPTION 'Expected 11 scenarios to record a result, found %', v_count; END IF;
  RAISE NOTICE 'Legacy notification search-path hardening regression tests PASSED: %/11', v_count;
END $$;

ROLLBACK;
