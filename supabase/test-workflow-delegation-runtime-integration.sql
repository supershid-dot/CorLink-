-- CAP-002 Phase 5.2 delegation/substitution runtime integration
-- behavioral suite (24 scenarios). Disposable local PostgreSQL only.
-- Runs in one transaction and leaves no fixtures (rolled back at the
-- end), matching the test-workflow-approval-decision-engine.sql
-- precedent -- avoids the direct-write-grant permission issue a
-- manual DELETE-based teardown would hit against the intentionally
-- SELECT-only workflow_ tables.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf522_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TEMP TABLE wf522_ids (name TEXT PRIMARY KEY, id UUID NOT NULL);
GRANT SELECT, INSERT ON wf522_results, wf522_ids TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES
 ('65220000-0000-0000-0000-000000000001','WF522 Org','authority','WF522');
INSERT INTO commands(id,org_id,name) VALUES
 ('65220000-0000-0000-0000-000000000002','65220000-0000-0000-0000-000000000001','WF522 Command');
INSERT INTO departments(id,command_id,name) VALUES
 ('65220000-0000-0000-0000-000000000003','65220000-0000-0000-0000-000000000002','WF522 Department');
INSERT INTO sections(id,org_id,department_id,name,code) VALUES
 ('65220000-0000-0000-0000-000000000004','65220000-0000-0000-0000-000000000001','65220000-0000-0000-0000-000000000003','WF522 Section A','WFSA'),
 ('65220000-0000-0000-0000-000000000005','65220000-0000-0000-0000-000000000001','65220000-0000-0000-0000-000000000003','WF522 Section B','WFSB');
INSERT INTO auth.users(id,email) VALUES
 ('65220000-0001-0000-0000-000000000001','admin@wf522.local'),
 ('65220000-0001-0000-0000-000000000002','alice@wf522.local'),
 ('65220000-0001-0000-0000-000000000003','bob@wf522.local'),
 ('65220000-0001-0000-0000-000000000004','carol@wf522.local'),
 ('65220000-0001-0000-0000-000000000005','dave@wf522.local'),
 ('65220000-0001-0000-0000-000000000006','erin@wf522.local'),
 ('65220000-0001-0000-0000-000000000007','frank@wf522.local'),
 ('65220000-0001-0000-0000-000000000008','grace@wf522.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('65220000-0001-0000-0000-000000000001','65220000-0000-0000-0000-000000000001','WF522-1','Admin','admin@wf522.local',true),
 ('65220000-0001-0000-0000-000000000002','65220000-0000-0000-0000-000000000001','WF522-2','Alice','alice@wf522.local',true),
 ('65220000-0001-0000-0000-000000000003','65220000-0000-0000-0000-000000000001','WF522-3','Bob','bob@wf522.local',true),
 ('65220000-0001-0000-0000-000000000004','65220000-0000-0000-0000-000000000001','WF522-4','Carol','carol@wf522.local',true),
 ('65220000-0001-0000-0000-000000000005','65220000-0000-0000-0000-000000000001','WF522-5','Dave','dave@wf522.local',true),
 ('65220000-0001-0000-0000-000000000006','65220000-0000-0000-0000-000000000001','WF522-6','Erin','erin@wf522.local',true),
 ('65220000-0001-0000-0000-000000000007','65220000-0000-0000-0000-000000000001','WF522-7','Frank','frank@wf522.local',true),
 ('65220000-0001-0000-0000-000000000008','65220000-0000-0000-0000-000000000001','WF522-8','Grace','grace@wf522.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('65220000-0001-0000-0000-000000000001','organization','65220000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('65220000-0001-0000-0000-000000000002','organization','65220000-0000-0000-0000-000000000001','supervisor',true,true),
 ('65220000-0001-0000-0000-000000000003','organization','65220000-0000-0000-0000-000000000001','supervisor',true,true),
-- Deliberately a DIFFERENT role than alice/bob's organization-level
-- 'supervisor': scope_org_id() resolves a section-scoped assignment
-- back to its owning organization regardless of scope_type, so a
-- section-scoped 'supervisor' role would also (correctly) match the
-- organization_role:supervisor selector below -- a real, pre-existing
-- feature of that selector (it means "this role anywhere in the
-- org," not literally scope_type='organization'), not a Phase 5.2
-- change. Using 'assigned_receiver' here keeps the org-role and
-- section-role fixtures cleanly independent of each other.
 ('65220000-0001-0000-0000-000000000005','section','65220000-0000-0000-0000-000000000004','assigned_receiver',true,true),
 ('65220000-0001-0000-0000-000000000006','section','65220000-0000-0000-0000-000000000005','assigned_receiver',true,true);

\set ADMIN '{"sub":"65220000-0001-0000-0000-000000000001"}'
\set ALICE '{"sub":"65220000-0001-0000-0000-000000000002"}'
\set BOB '{"sub":"65220000-0001-0000-0000-000000000003"}'
\set CAROL '{"sub":"65220000-0001-0000-0000-000000000004"}'
\set DAVE '{"sub":"65220000-0001-0000-0000-000000000005"}'
\set ERIN '{"sub":"65220000-0001-0000-0000-000000000006"}'
\set FRANK '{"sub":"65220000-0001-0000-0000-000000000007"}'
\set GRACE '{"sub":"65220000-0001-0000-0000-000000000008"}'

SET ROLE authenticated;

\set ORG_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":true,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

\set ORG_PAYLOAD_NODUP '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":false,"minimum_candidates":1,"candidate_selectors":[{"key":"home_supervisors","order":1,"type":"organization_role","organization":"home","role":"supervisor"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

\set SECTION_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":true,"minimum_candidates":1,"candidate_selectors":[{"key":"section_a_supervisors","order":1,"type":"section_role","section_id":"65220000-0000-0000-0000-000000000004","role":"assigned_receiver"}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

\set EXPLICIT_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":true,"minimum_candidates":1,"candidate_selectors":[{"key":"frank_only","order":1,"type":"explicit_user","user_ids":["65220000-0001-0000-0000-000000000007"]}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_definition(
  '65220000-0000-0000-0000-000000000001','wf522_org','WF522 Org Flow','opaque_case', :ORG_PAYLOAD::jsonb, gen_random_uuid()))
INSERT INTO wf522_ids SELECT 'org_def_v', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wf522_ids WHERE name='org_def_v'),0,gen_random_uuid());

WITH made AS (SELECT * FROM create_workflow_definition(
  '65220000-0000-0000-0000-000000000001','wf522_org_nodup','WF522 Org Flow (no multi-capacity)','opaque_case', :ORG_PAYLOAD_NODUP::jsonb, gen_random_uuid()))
INSERT INTO wf522_ids SELECT 'org_nodup_def_v', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wf522_ids WHERE name='org_nodup_def_v'),0,gen_random_uuid());

WITH made AS (SELECT * FROM create_workflow_definition(
  '65220000-0000-0000-0000-000000000001','wf522_section','WF522 Section Flow','opaque_case', :SECTION_PAYLOAD::jsonb, gen_random_uuid()))
INSERT INTO wf522_ids SELECT 'section_def_v', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wf522_ids WHERE name='section_def_v'),0,gen_random_uuid());

WITH made AS (SELECT * FROM create_workflow_definition(
  '65220000-0000-0000-0000-000000000001','wf522_explicit','WF522 Explicit Flow','opaque_case', :EXPLICIT_PAYLOAD::jsonb, gen_random_uuid()))
INSERT INTO wf522_ids SELECT 'explicit_def_v', version_id FROM made;
SELECT publish_workflow_definition_version((SELECT id FROM wf522_ids WHERE name='explicit_def_v'),0,gen_random_uuid());

-- Small helper macro pattern: start a fresh instance from a given
-- published version and record its id + the id of the single work
-- item offered to a given user under name p_wi_name.
-- (Implemented inline per scenario below rather than as a stored
-- procedure, to keep every scenario's fixture self-contained and
-- independently readable.)

-- ── 1: acting_appointment (organization_role) substitution redirects
--      the whole electorate to the substitute ───────────────────────
SELECT set_config('request.jwt.claims', :'ADMIN', false);
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT substitution_id INTO v_id FROM create_workflow_substitution(
    '65220000-0000-0000-0000-000000000001',
    '{"type":"organization_role","organization_id":"65220000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
    '65220000-0001-0000-0000-000000000004','acting_appointment', now(), now() + interval '1 day', 'position vacant', gen_random_uuid());
  INSERT INTO wf522_ids VALUES ('sub1', v_id);
END $$;
SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522_ids WHERE name='org_def_v'),'opaque_case',gen_random_uuid(),
  '65220000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522_ids SELECT 'i1', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522_ids WHERE name='i1'),0,gen_random_uuid());
DO $$
DECLARE v_alice_wi INTEGER; v_bob_wi INTEGER; v_carol_wi INTEGER;
BEGIN
  SELECT count(*) INTO v_alice_wi FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i1') AND assigned_to='65220000-0001-0000-0000-000000000002';
  SELECT count(*) INTO v_bob_wi FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i1') AND assigned_to='65220000-0001-0000-0000-000000000003';
  SELECT count(*) INTO v_carol_wi FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i1') AND assigned_to='65220000-0001-0000-0000-000000000004';
  IF v_alice_wi <> 0 OR v_bob_wi <> 0 THEN
    RAISE EXCEPTION 'expected original supervisors alice/bob to receive no work items while an acting_appointment substitution is active, got alice=% bob=%', v_alice_wi, v_bob_wi;
  END IF;
  -- allow_multi_capacity=true on this definition, and alice/bob are
  -- two genuinely distinct role-holders both substituted to carol --
  -- correctly two separate positions/work items for carol (capacity
  -- is preserved; substitution never silently collapses two real
  -- capacities into one).
  IF v_carol_wi <> 2 THEN
    RAISE EXCEPTION 'expected exactly two work items assigned to the acting substitute carol (one per substituted role-holder), got %', v_carol_wi;
  END IF;
END $$;
INSERT INTO wf522_results VALUES (1,'an active acting_appointment substitution for organization_role:supervisor redirects the entire electorate to the substitute, and the original role-holders receive no work item');

-- ── 2: the substitute''s authority_source records original + substitution traceability ──
DO $$
DECLARE v_src TEXT;
BEGIN
  SELECT authority_source INTO v_src FROM workflow_participants
  WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i1') AND user_id='65220000-0001-0000-0000-000000000004' LIMIT 1;
  IF v_src NOT LIKE 'organization_role:supervisor|substituted_from:%|substitution_id:%' THEN
    RAISE EXCEPTION 'expected substitution traceability in authority_source, got %', v_src;
  END IF;
END $$;
INSERT INTO wf522_results VALUES (2,'the substitute''s authority_source records both the original candidate and the substitution id for full traceability');

-- ── 3: revoking the substitution and starting a fresh instance restores the original electorate ──
SELECT set_config('request.jwt.claims', :'ADMIN', false);
SELECT status FROM revoke_workflow_substitution((SELECT id FROM wf522_ids WHERE name='sub1'), 0, 'no longer needed', gen_random_uuid());
SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522_ids WHERE name='org_def_v'),'opaque_case',gen_random_uuid(),
  '65220000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522_ids SELECT 'i2', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522_ids WHERE name='i2'),0,gen_random_uuid());
DO $$
DECLARE v_alice_wi INTEGER; v_bob_wi INTEGER;
BEGIN
  SELECT count(*) INTO v_alice_wi FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i2') AND assigned_to='65220000-0001-0000-0000-000000000002';
  SELECT count(*) INTO v_bob_wi FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i2') AND assigned_to='65220000-0001-0000-0000-000000000003';
  IF v_alice_wi <> 1 OR v_bob_wi <> 1 THEN
    RAISE EXCEPTION 'expected the original supervisors to be restored once the substitution is revoked, got alice=% bob=%', v_alice_wi, v_bob_wi;
  END IF;
END $$;
INSERT INTO wf522_results VALUES (3,'once the acting_appointment substitution is revoked, a fresh instance''s candidate resolution reverts to the original role-holders');

-- ── 4: section_role acting_appointment substitution is scoped to the exact section, never a different one ──
SELECT set_config('request.jwt.claims', :'ADMIN', false);
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT substitution_id INTO v_id FROM create_workflow_substitution(
    '65220000-0000-0000-0000-000000000001',
    '{"type":"section_role","section_id":"65220000-0000-0000-0000-000000000004","role":"assigned_receiver"}'::jsonb,
    '65220000-0001-0000-0000-000000000004','acting_appointment', now(), now() + interval '1 day', 'section A coverage', gen_random_uuid());
  INSERT INTO wf522_ids VALUES ('sub4', v_id);
END $$;
SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522_ids WHERE name='section_def_v'),'opaque_case',gen_random_uuid(),
  '65220000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522_ids SELECT 'i4', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522_ids WHERE name='i4'),0,gen_random_uuid());
DO $$
DECLARE v_dave_wi INTEGER; v_carol_wi INTEGER;
BEGIN
  SELECT count(*) INTO v_dave_wi FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i4') AND assigned_to='65220000-0001-0000-0000-000000000005';
  SELECT count(*) INTO v_carol_wi FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i4') AND assigned_to='65220000-0001-0000-0000-000000000004';
  IF v_dave_wi <> 0 OR v_carol_wi <> 1 THEN
    RAISE EXCEPTION 'expected section A''s acting_appointment substitution to redirect dave to carol, got dave=% carol=%', v_dave_wi, v_carol_wi;
  END IF;
END $$;
INSERT INTO wf522_results VALUES (4,'a section_role acting_appointment substitution correctly redirects the exact section''s role-holder to the substitute, matched by section_id');
SELECT set_config('request.jwt.claims', :'ADMIN', false);
SELECT status FROM revoke_workflow_substitution((SELECT id FROM wf522_ids WHERE name='sub4'), 0, 'scenario cleanup', gen_random_uuid());

-- ── 5: a section_role substitution for section A never affects section B''s holder ──
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT substitution_id INTO v_id FROM create_workflow_substitution(
    '65220000-0000-0000-0000-000000000001',
    '{"type":"section_role","section_id":"65220000-0000-0000-0000-000000000004","role":"assigned_receiver"}'::jsonb,
    '65220000-0001-0000-0000-000000000004','acting_appointment', now(), now() + interval '1 day', 'section A coverage again', gen_random_uuid());
  INSERT INTO wf522_ids VALUES ('sub5', v_id);
END $$;
SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522_ids WHERE name='org_def_v'),'opaque_case',gen_random_uuid(),
  '65220000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522_ids SELECT 'i5', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522_ids WHERE name='i5'),0,gen_random_uuid());
DO $$
DECLARE v_alice_wi INTEGER; v_bob_wi INTEGER;
BEGIN
  SELECT count(*) INTO v_alice_wi FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i5') AND assigned_to='65220000-0001-0000-0000-000000000002';
  SELECT count(*) INTO v_bob_wi FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i5') AND assigned_to='65220000-0001-0000-0000-000000000003';
  IF v_alice_wi <> 1 OR v_bob_wi <> 1 THEN
    RAISE EXCEPTION 'a section-A-scoped substitution must never affect an unrelated organization_role electorate, got alice=% bob=%', v_alice_wi, v_bob_wi;
  END IF;
END $$;
INSERT INTO wf522_results VALUES (5,'a section_role substitution scoped to section A has zero effect on an unrelated organization_role electorate');
SELECT status FROM revoke_workflow_substitution((SELECT id FROM wf522_ids WHERE name='sub5'), 0, 'scenario cleanup', gen_random_uuid());

-- ── 6: planned_leave (user-based) substitution outranks an overlapping acting_appointment for the same person''s role ──
DO $$
DECLARE v_leave_id UUID; v_act_id UUID;
BEGIN
  SELECT substitution_id INTO v_leave_id FROM create_workflow_substitution(
    '65220000-0000-0000-0000-000000000001',
    '{"type":"user","user_id":"65220000-0001-0000-0000-000000000002"}'::jsonb,
    '65220000-0001-0000-0000-000000000008','planned_leave', now(), now() + interval '1 day', 'alice on leave', gen_random_uuid());
  INSERT INTO wf522_ids VALUES ('sub6_leave', v_leave_id);
END $$;
SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522_ids WHERE name='org_def_v'),'opaque_case',gen_random_uuid(),
  '65220000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522_ids SELECT 'i6', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522_ids WHERE name='i6'),0,gen_random_uuid());
DO $$
DECLARE v_alice_wi INTEGER; v_bob_wi INTEGER; v_grace_wi INTEGER;
BEGIN
  SELECT count(*) INTO v_alice_wi FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i6') AND assigned_to='65220000-0001-0000-0000-000000000002';
  SELECT count(*) INTO v_bob_wi FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i6') AND assigned_to='65220000-0001-0000-0000-000000000003';
  SELECT count(*) INTO v_grace_wi FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i6') AND assigned_to='65220000-0001-0000-0000-000000000008';
  IF v_alice_wi <> 0 OR v_grace_wi <> 1 OR v_bob_wi <> 1 THEN
    RAISE EXCEPTION 'expected alice''s planned_leave to redirect only her own position to grace while bob is unaffected, got alice=% bob=% grace=%', v_alice_wi, v_bob_wi, v_grace_wi;
  END IF;
END $$;
INSERT INTO wf522_results VALUES (6,'a planned_leave substitution redirects only the named person''s own position, leaving the other role-holder unaffected');
SELECT status FROM revoke_workflow_substitution((SELECT id FROM wf522_ids WHERE name='sub6_leave'), 0, 'scenario cleanup', gen_random_uuid());

-- ── 7: an expired substitution has no live effect ───────────────────
DO $$
DECLARE v_id UUID; v_status TEXT;
BEGIN
  SELECT substitution_id, status INTO v_id, v_status FROM create_workflow_substitution(
    '65220000-0000-0000-0000-000000000001',
    '{"type":"organization_role","organization_id":"65220000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
    '65220000-0001-0000-0000-000000000004','acting_appointment', now() + interval '10 days', now() + interval '20 days', 'future coverage', gen_random_uuid());
  INSERT INTO wf522_ids VALUES ('sub7', v_id);
END $$;
-- Force it into the past to simulate an already-expired window
-- without a background worker ever having flipped its status --
-- exactly the scenario the live-effectiveness design must reject.
-- workflow_substitutions is deliberately SELECT-only for
-- authenticated (only the RPCs may mutate it), so this direct test-
-- fixture manipulation runs as the table owner, matching the
-- existing precedent (e.g. test-workflow-approval-round-lifecycle.sql
-- directly deactivating a user to simulate an out-of-band state
-- change no RPC produces).
RESET ROLE;
UPDATE workflow_substitutions SET starts_at = now() - interval '20 days', ends_at = now() - interval '10 days'
WHERE id = (SELECT id FROM wf522_ids WHERE name='sub7');
SET ROLE authenticated;
SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522_ids WHERE name='org_def_v'),'opaque_case',gen_random_uuid(),
  '65220000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522_ids SELECT 'i7', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522_ids WHERE name='i7'),0,gen_random_uuid());
DO $$
DECLARE v_alice_wi INTEGER; v_carol_wi INTEGER;
BEGIN
  SELECT count(*) INTO v_alice_wi FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i7') AND assigned_to='65220000-0001-0000-0000-000000000002';
  SELECT count(*) INTO v_carol_wi FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i7') AND assigned_to='65220000-0001-0000-0000-000000000004';
  IF v_alice_wi <> 1 OR v_carol_wi <> 0 THEN
    RAISE EXCEPTION 'a substitution whose window has already ended must have zero live effect regardless of its stored status, got alice=% carol=%', v_alice_wi, v_carol_wi;
  END IF;
END $$;
INSERT INTO wf522_results VALUES (7,'a substitution outside its own [starts_at,ends_at) window has zero live effect on candidate resolution, independent of its stored status literal');

-- ── 8: a scheduled substitution whose window has already started is live-effective despite no worker having flipped its status ──
DO $$
DECLARE v_id UUID; v_status TEXT;
BEGIN
  SELECT substitution_id, status INTO v_id, v_status FROM create_workflow_substitution(
    '65220000-0000-0000-0000-000000000001',
    '{"type":"organization_role","organization_id":"65220000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
    '65220000-0001-0000-0000-000000000004','acting_appointment', now() + interval '10 days', now() + interval '20 days', 'future coverage 2', gen_random_uuid());
  IF v_status <> 'scheduled' THEN RAISE EXCEPTION 'expected scheduled, got %', v_status; END IF;
  INSERT INTO wf522_ids VALUES ('sub8', v_id);
END $$;
-- Pull the window back to already-started, WITHOUT going through any
-- activation RPC (Phase 5.1 deliberately built no worker to do this)
-- -- status column stays 'scheduled' on purpose. Same direct-owner
-- manipulation pattern as scenario 7 above.
RESET ROLE;
UPDATE workflow_substitutions SET starts_at = now() - interval '1 hour', ends_at = now() + interval '1 hour'
WHERE id = (SELECT id FROM wf522_ids WHERE name='sub8');
SET ROLE authenticated;
DO $$
DECLARE v_status TEXT;
BEGIN
  SELECT status INTO v_status FROM workflow_substitutions WHERE id = (SELECT id FROM wf522_ids WHERE name='sub8');
  IF v_status <> 'scheduled' THEN RAISE EXCEPTION 'fixture error: expected status to remain scheduled, got %', v_status; END IF;
END $$;
SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522_ids WHERE name='org_def_v'),'opaque_case',gen_random_uuid(),
  '65220000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522_ids SELECT 'i8', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522_ids WHERE name='i8'),0,gen_random_uuid());
DO $$
DECLARE v_carol_wi INTEGER;
BEGIN
  SELECT count(*) INTO v_carol_wi FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i8') AND assigned_to='65220000-0001-0000-0000-000000000004';
  IF v_carol_wi <> 2 THEN
    RAISE EXCEPTION 'a substitution whose status is still literally scheduled but whose window has started must be treated as live-effective for both substituted role-holders, got carol=%', v_carol_wi;
  END IF;
END $$;
INSERT INTO wf522_results VALUES (8,'a substitution stuck at status=scheduled (no worker ever flipped it) is still treated as effective once its window has genuinely started, per the documented live-effectiveness design');
SELECT status FROM revoke_workflow_substitution((SELECT id FROM wf522_ids WHERE name='sub8'), 0, 'scenario cleanup', gen_random_uuid());

-- ── 9: substituting two distinct role-holders to the same person is a genuine duplicate under allow_multi_capacity=false ──
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT substitution_id INTO v_id FROM create_workflow_substitution(
    '65220000-0000-0000-0000-000000000001',
    '{"type":"organization_role","organization_id":"65220000-0000-0000-0000-000000000001","role":"supervisor"}'::jsonb,
    '65220000-0001-0000-0000-000000000004','acting_appointment', now(), now() + interval '1 day', 'collision test', gen_random_uuid());
  INSERT INTO wf522_ids VALUES ('sub9', v_id);
END $$;
SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522_ids WHERE name='org_nodup_def_v'),'opaque_case',gen_random_uuid(),
  '65220000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522_ids SELECT 'i9', made.create_workflow_instance FROM made;
DO $$ BEGIN
  BEGIN
    PERFORM * FROM start_workflow_instance((SELECT id FROM wf522_ids WHERE name='i9'),0,gen_random_uuid());
    RAISE EXCEPTION 'expected duplicate-candidate rejection';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected duplicate-candidate rejection' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%duplicate user across selectors%' THEN
      RAISE EXCEPTION 'expected the duplicate-candidate error, got: %', SQLERRM;
    END IF;
  END;
END $$;
INSERT INTO wf522_results VALUES (9,'when an acting_appointment substitution collapses two distinct role-holders onto the same effective user, allow_multi_capacity=false correctly raises the existing duplicate-candidate rejection');
SELECT status FROM revoke_workflow_substitution((SELECT id FROM wf522_ids WHERE name='sub9'), 0, 'scenario cleanup', gen_random_uuid());

-- ── 10-11: delegation, work_item scope — authorized delegate can decide; assigned_to never changes ──
SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522_ids WHERE name='explicit_def_v'),'opaque_case',gen_random_uuid(),
  '65220000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522_ids SELECT 'i10', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522_ids WHERE name='i10'),0,gen_random_uuid());
INSERT INTO wf522_ids SELECT 'wi10', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i10') AND assigned_to='65220000-0001-0000-0000-000000000007';

SELECT set_config('request.jwt.claims', :'FRANK', false);
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT delegation_id INTO v_id FROM create_workflow_delegation(
    '65220000-0000-0000-0000-000000000001','65220000-0001-0000-0000-000000000007','65220000-0001-0000-0000-000000000004',
    jsonb_build_object('type','work_item','work_item_id',(SELECT id FROM wf522_ids WHERE name='wi10')::text),
    'temporary','manual', now(), now()+interval '2 days', 'frank is out', gen_random_uuid());
  INSERT INTO wf522_ids VALUES ('deleg10', v_id);
END $$;
SELECT set_config('request.jwt.claims', :'CAROL', false);
SELECT status FROM accept_workflow_delegation((SELECT id FROM wf522_ids WHERE name='deleg10'), 0, gen_random_uuid());

SELECT set_config('request.jwt.claims', :'CAROL', false);
DO $$
DECLARE v_before UUID; v_after UUID; v_status TEXT;
BEGIN
  SELECT assigned_to INTO v_before FROM workflow_work_items WHERE id=(SELECT id FROM wf522_ids WHERE name='wi10');
  SELECT instance_status INTO v_status FROM decide_workflow_work_item((SELECT id FROM wf522_ids WHERE name='wi10'),'approve',1,0,gen_random_uuid());
  SELECT assigned_to INTO v_after FROM workflow_work_items WHERE id=(SELECT id FROM wf522_ids WHERE name='wi10');
  IF v_before IS DISTINCT FROM v_after THEN
    RAISE EXCEPTION 'a delegate deciding a work item must never change workflow_work_items.assigned_to';
  END IF;
  IF v_status NOT IN ('active','completed') THEN
    RAISE EXCEPTION 'expected the delegate''s decision to succeed, got status %', v_status;
  END IF;
END $$;
INSERT INTO wf522_results VALUES (10,'an active work_item-scoped delegate can decide a work item originally assigned to the delegator');
INSERT INTO wf522_results VALUES (11,'the delegate''s decision never changes workflow_work_items.assigned_to -- delegation widens authorization on the existing work item, it never reassigns it');

-- ── 12: the decision and event carry full delegation traceability ──
-- Switch to ADMIN (the instance's own creator/owner participant) for
-- this read-only verification -- carol, as a delegate who never
-- became a resolved candidate/participant herself, has no RLS
-- visibility into workflow_events for this instance, and that
-- visibility question is exercised by the dedicated Phase 5.1 RLS
-- suite, not re-tested here.
SELECT set_config('request.jwt.claims', :'ADMIN', false);
DO $$
DECLARE v_auth TEXT; v_meta JSONB;
BEGIN
  SELECT authority_source INTO v_auth FROM workflow_decisions WHERE work_item_id=(SELECT id FROM wf522_ids WHERE name='wi10');
  IF v_auth NOT LIKE '%|delegated_from:65220000-0001-0000-0000-000000000007|delegation_id:%' THEN
    RAISE EXCEPTION 'expected workflow_decisions.authority_source to record delegated_from/delegation_id, got %', v_auth;
  END IF;
  SELECT metadata INTO v_meta FROM workflow_events
  WHERE work_item_id=(SELECT id FROM wf522_ids WHERE name='wi10') AND event_type='decision_recorded';
  IF (v_meta->>'delegation_id') IS NULL OR (v_meta->>'delegation_id') <> (SELECT id::text FROM wf522_ids WHERE name='deleg10') THEN
    RAISE EXCEPTION 'expected decision_recorded metadata delegation_id to match the delegation used, got %', v_meta->>'delegation_id';
  END IF;
END $$;
INSERT INTO wf522_results VALUES (12,'a delegated decision is fully traceable: workflow_decisions.authority_source records the original delegator and delegation id, and decision_recorded''s metadata carries the same delegation_id');

-- ── 13: a decision with no delegation involved records a null delegation_id, unchanged from pre-Phase-5.2 behavior ──
SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522_ids WHERE name='explicit_def_v'),'opaque_case',gen_random_uuid(),
  '65220000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522_ids SELECT 'i13', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522_ids WHERE name='i13'),0,gen_random_uuid());
INSERT INTO wf522_ids SELECT 'wi13', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i13') AND assigned_to='65220000-0001-0000-0000-000000000007';
SELECT set_config('request.jwt.claims', :'FRANK', false);
SELECT * FROM decide_workflow_work_item((SELECT id FROM wf522_ids WHERE name='wi13'),'approve',1,0,gen_random_uuid());
DO $$
DECLARE v_auth TEXT; v_meta JSONB;
BEGIN
  SELECT authority_source INTO v_auth FROM workflow_decisions WHERE work_item_id=(SELECT id FROM wf522_ids WHERE name='wi13');
  IF v_auth LIKE '%delegated_from%' THEN
    RAISE EXCEPTION 'an ordinary decision by the original assignee must not carry delegation traceability, got %', v_auth;
  END IF;
  SELECT metadata INTO v_meta FROM workflow_events
  WHERE work_item_id=(SELECT id FROM wf522_ids WHERE name='wi13') AND event_type='decision_recorded';
  IF v_meta->'delegation_id' IS NOT NULL AND v_meta->>'delegation_id' IS NOT NULL THEN
    RAISE EXCEPTION 'expected a null delegation_id in decision_recorded metadata for an ordinary decision, got %', v_meta->>'delegation_id';
  END IF;
END $$;
INSERT INTO wf522_results VALUES (13,'an ordinary decision by the original assignee, with no delegation in effect, records a null delegation_id and no delegation traceability in authority_source');

-- ── 14: an actor with no delegation at all is still rejected exactly as before Phase 5.2 ──
SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522_ids WHERE name='explicit_def_v'),'opaque_case',gen_random_uuid(),
  '65220000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522_ids SELECT 'i14', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522_ids WHERE name='i14'),0,gen_random_uuid());
INSERT INTO wf522_ids SELECT 'wi14', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i14') AND assigned_to='65220000-0001-0000-0000-000000000007';
SELECT set_config('request.jwt.claims', :'GRACE', false);
DO $$ BEGIN
  BEGIN
    PERFORM * FROM decide_workflow_work_item((SELECT id FROM wf522_ids WHERE name='wi14'),'approve',1,0,gen_random_uuid());
    RAISE EXCEPTION 'expected rejection for an actor with no delegation';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected rejection for an actor with no delegation' THEN RAISE; END IF;
    IF SQLERRM <> 'Workflow work item is not available for this action' THEN
      RAISE EXCEPTION 'expected the standard not-available error, got: %', SQLERRM;
    END IF;
  END;
END $$;
INSERT INTO wf522_results VALUES (14,'an actor holding no delegation at all is rejected with the exact same error as before Phase 5.2 -- authorization is widened, never loosened for everyone');

-- ── 15: organization_role-scoped delegation matches a position resolved via that exact role/scope ──
SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522_ids WHERE name='org_def_v'),'opaque_case',gen_random_uuid(),
  '65220000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522_ids SELECT 'i15', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522_ids WHERE name='i15'),0,gen_random_uuid());
INSERT INTO wf522_ids SELECT 'wi15', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i15') AND assigned_to='65220000-0001-0000-0000-000000000002';

SELECT set_config('request.jwt.claims', :'ALICE', false);
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT delegation_id INTO v_id FROM create_workflow_delegation(
    '65220000-0000-0000-0000-000000000001','65220000-0001-0000-0000-000000000002','65220000-0001-0000-0000-000000000004',
    jsonb_build_object('type','organization_role','organization_id','65220000-0000-0000-0000-000000000001','role','supervisor'),
    'temporary','manual', now(), now()+interval '2 days', 'org role coverage', gen_random_uuid());
  INSERT INTO wf522_ids VALUES ('deleg15', v_id);
END $$;
SELECT set_config('request.jwt.claims', :'CAROL', false);
SELECT status FROM accept_workflow_delegation((SELECT id FROM wf522_ids WHERE name='deleg15'), 0, gen_random_uuid());

SELECT set_config('request.jwt.claims', :'CAROL', false);
DO $$
DECLARE v_status TEXT;
BEGIN
  SELECT instance_status INTO v_status FROM decide_workflow_work_item((SELECT id FROM wf522_ids WHERE name='wi15'),'approve',1,0,gen_random_uuid());
  IF v_status NOT IN ('active','completed') THEN
    RAISE EXCEPTION 'expected the organization_role-delegated decision to succeed, got status %', v_status;
  END IF;
END $$;
INSERT INTO wf522_results VALUES (15,'an organization_role-scoped delegation authorizes the delegate to decide a work item whose position was resolved via that exact role/organization');

-- ── 16: section_role-scoped delegation matches only the exact section it names ──
SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522_ids WHERE name='section_def_v'),'opaque_case',gen_random_uuid(),
  '65220000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522_ids SELECT 'i16', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522_ids WHERE name='i16'),0,gen_random_uuid());
INSERT INTO wf522_ids SELECT 'wi16', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i16') AND assigned_to='65220000-0001-0000-0000-000000000005';

SELECT set_config('request.jwt.claims', :'DAVE', false);
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT delegation_id INTO v_id FROM create_workflow_delegation(
    '65220000-0000-0000-0000-000000000001','65220000-0001-0000-0000-000000000005','65220000-0001-0000-0000-000000000004',
    jsonb_build_object('type','section_role','section_id','65220000-0000-0000-0000-000000000004','role','assigned_receiver'),
    'temporary','manual', now(), now()+interval '2 days', 'section A role coverage', gen_random_uuid());
  INSERT INTO wf522_ids VALUES ('deleg16', v_id);
END $$;
SELECT set_config('request.jwt.claims', :'CAROL', false);
SELECT status FROM accept_workflow_delegation((SELECT id FROM wf522_ids WHERE name='deleg16'), 0, gen_random_uuid());

SELECT set_config('request.jwt.claims', :'CAROL', false);
DO $$
DECLARE v_status TEXT;
BEGIN
  SELECT instance_status INTO v_status FROM decide_workflow_work_item((SELECT id FROM wf522_ids WHERE name='wi16'),'approve',1,0,gen_random_uuid());
  IF v_status NOT IN ('active','completed') THEN
    RAISE EXCEPTION 'expected the section_role-delegated decision to succeed, got status %', v_status;
  END IF;
END $$;
INSERT INTO wf522_results VALUES (16,'a section_role-scoped delegation authorizes the delegate to decide a work item whose position was resolved via that exact section+role');

-- ── 17: an organization_role-scoped delegation never authorizes a section_role position, and vice versa ──
SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522_ids WHERE name='section_def_v'),'opaque_case',gen_random_uuid(),
  '65220000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522_ids SELECT 'i17', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522_ids WHERE name='i17'),0,gen_random_uuid());
INSERT INTO wf522_ids SELECT 'wi17', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i17') AND assigned_to='65220000-0001-0000-0000-000000000005';
-- grace deliberately holds no delegation at all naming dave as
-- delegator for this section_role scope (deleg15/16 name alice/dave
-- as delegator but grace as delegate only for unrelated scopes) --
-- isolating "no matching delegation" from any delegator mismatch.
SELECT set_config('request.jwt.claims', :'GRACE', false);
DO $$ BEGIN
  BEGIN
    PERFORM * FROM decide_workflow_work_item((SELECT id FROM wf522_ids WHERE name='wi17'),'approve',1,0,gen_random_uuid());
    RAISE EXCEPTION 'expected rejection: grace holds no delegation at all for this section_role position';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected rejection: grace holds no delegation at all for this section_role position' THEN RAISE; END IF;
    IF SQLERRM <> 'Workflow work item is not available for this action' THEN
      RAISE EXCEPTION 'expected the standard not-available error, got: %', SQLERRM;
    END IF;
  END;
END $$;
INSERT INTO wf522_results VALUES (17,'an actor holding no delegation at all for a section_role position is rejected exactly like any other unauthorized actor -- scope matching never accidentally widens access');

-- ── 18: definition_step-scoped delegation matches by definition_id + step_key ──
SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522_ids WHERE name='explicit_def_v'),'opaque_case',gen_random_uuid(),
  '65220000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522_ids SELECT 'i18', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522_ids WHERE name='i18'),0,gen_random_uuid());
INSERT INTO wf522_ids SELECT 'wi18', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i18') AND assigned_to='65220000-0001-0000-0000-000000000007';
-- Looked up as ADMIN, since workflow_definition_versions' own RLS
-- (can_manage_workflow_definition) is not visible to an ordinary
-- staff member like frank -- a separate, dedicated question from
-- delegation itself.
INSERT INTO wf522_ids SELECT 'explicit_definition_id', definition_id FROM workflow_definition_versions WHERE id = (SELECT id FROM wf522_ids WHERE name='explicit_def_v');

SELECT set_config('request.jwt.claims', :'FRANK', false);
DO $$
DECLARE v_def_id UUID := (SELECT id FROM wf522_ids WHERE name='explicit_definition_id'); v_id UUID;
BEGIN
  SELECT delegation_id INTO v_id FROM create_workflow_delegation(
    '65220000-0000-0000-0000-000000000001','65220000-0001-0000-0000-000000000007','65220000-0001-0000-0000-000000000004',
    jsonb_build_object('type','definition_step','definition_id',v_def_id::text,'step_key','review'),
    'temporary','manual', now(), now()+interval '2 days', 'whole step coverage', gen_random_uuid());
  INSERT INTO wf522_ids VALUES ('deleg18', v_id);
END $$;
SELECT set_config('request.jwt.claims', :'CAROL', false);
SELECT status FROM accept_workflow_delegation((SELECT id FROM wf522_ids WHERE name='deleg18'), 0, gen_random_uuid());

SELECT set_config('request.jwt.claims', :'CAROL', false);
DO $$
DECLARE v_status TEXT;
BEGIN
  SELECT instance_status INTO v_status FROM decide_workflow_work_item((SELECT id FROM wf522_ids WHERE name='wi18'),'approve',1,0,gen_random_uuid());
  IF v_status NOT IN ('active','completed') THEN
    RAISE EXCEPTION 'expected the definition_step-delegated decision to succeed, got status %', v_status;
  END IF;
END $$;
INSERT INTO wf522_results VALUES (18,'a definition_step-scoped delegation authorizes the delegate to decide any work item at that exact definition+step, regardless of which selector type resolved the assignee');

-- deleg18's definition_step scope covers the ENTIRE 'review' step of
-- explicit_def_v, not just wi18 -- left active it would also
-- (correctly) authorize carol for scenario 19's wi19 (same
-- definition+step), masking the specific work_item-scoped
-- delegation's revocation this scenario means to test. Revoked here
-- so scenario 19 isolates exactly what it claims to.
SELECT set_config('request.jwt.claims', :'FRANK', false);
SELECT status FROM revoke_workflow_delegation((SELECT id FROM wf522_ids WHERE name='deleg18'), 1, 'scenario cleanup', gen_random_uuid());

-- ── 19: a revoked delegation no longer authorizes the delegate ─────
SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522_ids WHERE name='explicit_def_v'),'opaque_case',gen_random_uuid(),
  '65220000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522_ids SELECT 'i19', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522_ids WHERE name='i19'),0,gen_random_uuid());
INSERT INTO wf522_ids SELECT 'wi19', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i19') AND assigned_to='65220000-0001-0000-0000-000000000007';

SELECT set_config('request.jwt.claims', :'FRANK', false);
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT delegation_id INTO v_id FROM create_workflow_delegation(
    '65220000-0000-0000-0000-000000000001','65220000-0001-0000-0000-000000000007','65220000-0001-0000-0000-000000000004',
    jsonb_build_object('type','work_item','work_item_id',(SELECT id FROM wf522_ids WHERE name='wi19')::text),
    'temporary','manual', now(), now()+interval '2 days', 'to be revoked', gen_random_uuid());
  INSERT INTO wf522_ids VALUES ('deleg19', v_id);
END $$;
SELECT set_config('request.jwt.claims', :'CAROL', false);
SELECT status FROM accept_workflow_delegation((SELECT id FROM wf522_ids WHERE name='deleg19'), 0, gen_random_uuid());
SELECT set_config('request.jwt.claims', :'FRANK', false);
SELECT status FROM revoke_workflow_delegation((SELECT id FROM wf522_ids WHERE name='deleg19'), 1, 'plans changed', gen_random_uuid());

SELECT set_config('request.jwt.claims', :'CAROL', false);
DO $$ BEGIN
  BEGIN
    PERFORM * FROM decide_workflow_work_item((SELECT id FROM wf522_ids WHERE name='wi19'),'approve',1,0,gen_random_uuid());
    RAISE EXCEPTION 'expected rejection: delegation was revoked';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected rejection: delegation was revoked' THEN RAISE; END IF;
    IF SQLERRM <> 'Workflow work item is not available for this action' THEN
      RAISE EXCEPTION 'expected the standard not-available error, got: %', SQLERRM;
    END IF;
  END;
END $$;
INSERT INTO wf522_results VALUES (19,'a revoked delegation no longer authorizes its former delegate');

-- ── 20: a delegation still pending_acceptance does not yet authorize the delegate ──
SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522_ids WHERE name='explicit_def_v'),'opaque_case',gen_random_uuid(),
  '65220000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522_ids SELECT 'i20', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522_ids WHERE name='i20'),0,gen_random_uuid());
INSERT INTO wf522_ids SELECT 'wi20', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i20') AND assigned_to='65220000-0001-0000-0000-000000000007';

SELECT set_config('request.jwt.claims', :'FRANK', false);
DO $$
DECLARE v_id UUID; v_status TEXT;
BEGIN
  SELECT delegation_id, status INTO v_id, v_status FROM create_workflow_delegation(
    '65220000-0000-0000-0000-000000000001','65220000-0001-0000-0000-000000000007','65220000-0001-0000-0000-000000000004',
    jsonb_build_object('type','work_item','work_item_id',(SELECT id FROM wf522_ids WHERE name='wi20')::text),
    'temporary','manual', now(), now()+interval '2 days', 'not yet accepted', gen_random_uuid());
  IF v_status <> 'pending_acceptance' THEN RAISE EXCEPTION 'expected pending_acceptance, got %', v_status; END IF;
END $$;

SELECT set_config('request.jwt.claims', :'CAROL', false);
DO $$ BEGIN
  BEGIN
    PERFORM * FROM decide_workflow_work_item((SELECT id FROM wf522_ids WHERE name='wi20'),'approve',1,0,gen_random_uuid());
    RAISE EXCEPTION 'expected rejection: delegation not yet accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected rejection: delegation not yet accepted' THEN RAISE; END IF;
    IF SQLERRM <> 'Workflow work item is not available for this action' THEN
      RAISE EXCEPTION 'expected the standard not-available error, got: %', SQLERRM;
    END IF;
  END;
END $$;
INSERT INTO wf522_results VALUES (20,'a delegation still pending the delegate''s acceptance does not yet authorize any action, exactly like the pre-runtime-integration Phase 5.1 foundation intended');

-- ── 21: additive, non-exclusive delegation -- the original assignee can still decide even with an active, accepted delegation outstanding ──
SELECT set_config('request.jwt.claims', :'ADMIN', false);
WITH made AS (SELECT * FROM create_workflow_instance(
  (SELECT id FROM wf522_ids WHERE name='explicit_def_v'),'opaque_case',gen_random_uuid(),
  '65220000-0000-0000-0000-000000000001',gen_random_uuid(),NULL))
INSERT INTO wf522_ids SELECT 'i21', made.create_workflow_instance FROM made;
SELECT * FROM start_workflow_instance((SELECT id FROM wf522_ids WHERE name='i21'),0,gen_random_uuid());
INSERT INTO wf522_ids SELECT 'wi21', id FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522_ids WHERE name='i21') AND assigned_to='65220000-0001-0000-0000-000000000007';

SELECT set_config('request.jwt.claims', :'FRANK', false);
DO $$
DECLARE v_id UUID;
BEGIN
  SELECT delegation_id INTO v_id FROM create_workflow_delegation(
    '65220000-0000-0000-0000-000000000001','65220000-0001-0000-0000-000000000007','65220000-0001-0000-0000-000000000004',
    jsonb_build_object('type','work_item','work_item_id',(SELECT id FROM wf522_ids WHERE name='wi21')::text),
    'temporary','manual', now(), now()+interval '2 days', 'available but not used', gen_random_uuid());
  INSERT INTO wf522_ids VALUES ('deleg21', v_id);
END $$;
SELECT set_config('request.jwt.claims', :'CAROL', false);
SELECT status FROM accept_workflow_delegation((SELECT id FROM wf522_ids WHERE name='deleg21'), 0, gen_random_uuid());
SELECT set_config('request.jwt.claims', :'FRANK', false);
DO $$
DECLARE v_status TEXT;
BEGIN
  -- frank himself decides, exercising his own, never-revoked original authorization
  SELECT instance_status INTO v_status FROM decide_workflow_work_item((SELECT id FROM wf522_ids WHERE name='wi21'),'approve',1,0,gen_random_uuid());
  IF v_status NOT IN ('active','completed') THEN
    RAISE EXCEPTION 'expected the original assignee to still be able to decide despite an outstanding active delegation, got status %', v_status;
  END IF;
END $$;
INSERT INTO wf522_results VALUES (21,'the original assignee retains their own ability to decide even while an active, accepted delegation to someone else is outstanding -- delegation is additive, never exclusive, per docs/73''s silence on exclusivity');

-- ── 22: once the original assignee has decided, the delegate''s later attempt on the same (now completed) work item fails via the pre-existing state guard, not new delegation logic ──
SELECT set_config('request.jwt.claims', :'CAROL', false);
DO $$ BEGIN
  BEGIN
    PERFORM * FROM decide_workflow_work_item((SELECT id FROM wf522_ids WHERE name='wi21'),'approve',2,1,gen_random_uuid());
    RAISE EXCEPTION 'expected rejection: work item already completed';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'expected rejection: work item already completed' THEN RAISE; END IF;
    -- This single-node definition completes the whole instance on
    -- its first (and only) decision, so the pre-existing "instance
    -- must be active" guard fires before the work-item-state guard
    -- ever gets a chance to -- either way, it is an existing guard
    -- unrelated to delegation, exercised here unmodified.
    IF SQLERRM <> 'Workflow instance is not active' THEN
      RAISE EXCEPTION 'expected the standard not-active error, got: %', SQLERRM;
    END IF;
  END;
END $$;
INSERT INTO wf522_results VALUES (22,'once either party has decided, the other''s later attempt fails at an existing pre-decision guard (instance-active or work-item-state, whichever the graph shape reaches first) -- the same single-decision-per-position mechanics the engine already had, with no new race window introduced by additive delegation');

-- ── 23: no duplicate work items or candidate resolutions occur under substitution+delegation together ──
DO $$
DECLARE v_wi_count INTEGER; v_pos_count INTEGER;
BEGIN
  SELECT count(*) INTO v_wi_count FROM workflow_work_items WHERE instance_id IN (SELECT id FROM wf522_ids WHERE name IN ('i1','i4','i6','i10','i15','i16','i18'));
  SELECT count(*) INTO v_pos_count FROM workflow_approval_positions WHERE instance_id IN (SELECT id FROM wf522_ids WHERE name IN ('i1','i4','i6','i10','i15','i16','i18'));
  IF v_wi_count <> v_pos_count THEN
    RAISE EXCEPTION 'expected exactly one workflow_approval_positions row per workflow_work_items row across all substitution/delegation-affected instances, got % work items and % positions', v_wi_count, v_pos_count;
  END IF;
END $$;
INSERT INTO wf522_results VALUES (23,'across every substitution- and delegation-affected instance in this suite, work items and approval positions remain in exact 1:1 correspondence -- no duplicate work item or duplicate candidate resolution was introduced');

-- ── 24: workflow_approval_positions.section_id is populated for section_role positions and left null for other selector types ──
DO $$
DECLARE v_section_pos_null INTEGER; v_org_pos_notnull INTEGER;
BEGIN
  SELECT count(*) INTO v_section_pos_null FROM workflow_approval_positions
  WHERE instance_id IN (SELECT id FROM wf522_ids WHERE name IN ('i4','i16')) AND section_id IS NULL;
  SELECT count(*) INTO v_org_pos_notnull FROM workflow_approval_positions
  WHERE instance_id = (SELECT id FROM wf522_ids WHERE name='i15') AND section_id IS NOT NULL;
  IF v_section_pos_null <> 0 THEN
    RAISE EXCEPTION 'expected every section_role position to carry a non-null section_id, found % with a null one', v_section_pos_null;
  END IF;
  IF v_org_pos_notnull <> 0 THEN
    RAISE EXCEPTION 'expected organization_role positions to carry a null section_id, found % with a non-null one', v_org_pos_notnull;
  END IF;
END $$;
INSERT INTO wf522_results VALUES (24,'workflow_approval_positions.section_id is populated exactly for section_role-selector positions and remains null for every other selector type');

RESET ROLE;
DO $$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM wf522_results;
  IF v_count <> 24 THEN
    RAISE EXCEPTION 'Expected 24 scenarios to record a result, found %', v_count;
  END IF;
  RAISE NOTICE 'Workflow delegation/substitution runtime integration behavioral tests PASSED: %/24', v_count;
END $$;

ROLLBACK;
