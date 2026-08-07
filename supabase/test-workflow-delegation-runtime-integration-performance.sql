-- CAP-002 Phase 5.2 delegation/substitution runtime integration
-- performance probes. Disposable local PostgreSQL only.
\set ON_ERROR_STOP on

INSERT INTO organizations(id,name,type,code) VALUES
 ('65250000-0000-0000-0000-000000000001','WF522P Org','authority','WF522P');
INSERT INTO auth.users(id,email) VALUES
 ('65250000-0001-0000-0000-000000000001','admin@wf522p.local'),
 ('65250000-0001-0000-0000-000000000002','frank@wf522p.local'),
 ('65250000-0001-0000-0000-000000000003','carol@wf522p.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('65250000-0001-0000-0000-000000000001','65250000-0000-0000-0000-000000000001','WF522P-1','Admin','admin@wf522p.local',true),
 ('65250000-0001-0000-0000-000000000002','65250000-0000-0000-0000-000000000001','WF522P-2','Frank','frank@wf522p.local',true),
 ('65250000-0001-0000-0000-000000000003','65250000-0000-0000-0000-000000000001','WF522P-3','Carol','carol@wf522p.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('65250000-0001-0000-0000-000000000001','organization','65250000-0000-0000-0000-000000000001','authority_admin',true,true),
 ('65250000-0001-0000-0000-000000000002','organization','65250000-0000-0000-0000-000000000001','supervisor',true,true);

-- 10,000 synthetic users, mirroring the Phase 5.1 performance
-- fixture's own "bulk fixture at superuser level" pattern.
INSERT INTO auth.users(id, email)
SELECT ('65250000-0002-0000-0000-' || lpad(i::text, 12, '0'))::uuid, 'synth' || i || '@wf522p.local'
FROM generate_series(1, 10000) i;
INSERT INTO users(id, org_id, service_number, full_name, email, is_active)
SELECT ('65250000-0002-0000-0000-' || lpad(i::text, 12, '0'))::uuid, '65250000-0000-0000-0000-000000000001',
  'WF522P-S' || i, 'Synth ' || i, 'synth' || i || '@wf522p.local', true
FROM generate_series(1, 10000) i;

-- 10,000 pre-existing, mostly-irrelevant (expired) substitution rows
-- targeting distinct synthetic users, so a live candidate-resolution
-- query must filter past all of them via the represented_user_id/
-- status/window index rather than a sequential scan.
INSERT INTO workflow_substitutions (
  organization_id, represented_type, represented_user_id, substitute_id,
  kind, starts_at, ends_at, status, configured_by, create_idempotency_key
)
SELECT '65250000-0000-0000-0000-000000000001', 'user',
  ('65250000-0002-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
  '65250000-0001-0000-0000-000000000003',
  'planned_leave', now() - interval '20 days', now() - interval '10 days',
  'expired', '65250000-0001-0000-0000-000000000001', gen_random_uuid()
FROM generate_series(1, 10000) i;

-- 10,000 pre-existing, mostly-irrelevant (expired) delegation rows,
-- same shape, so decide_workflow_work_item's delegation lookup must
-- filter past all of them too.
INSERT INTO workflow_delegations (
  organization_id, delegator_id, delegate_id, scope_type,
  scope_role_organization_id, scope_role, kind, activation_mode,
  starts_at, ends_at, status, created_by, create_idempotency_key
)
SELECT '65250000-0000-0000-0000-000000000001', '65250000-0001-0000-0000-000000000002',
  ('65250000-0002-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
  'organization_role', '65250000-0000-0000-0000-000000000001', 'supervisor',
  'temporary', 'manual', now() - interval '20 days', now() - interval '10 days',
  'expired', '65250000-0001-0000-0000-000000000002', gen_random_uuid()
FROM generate_series(1, 10000) i;

\set EXPLICIT_PAYLOAD '\'{"schema_version":1,"entry_node":"start","nodes":[{"key":"start","type":"start","config":{}},{"key":"review","type":"approval","config":{"delivery_mode":"parallel","decision_rule":"majority","minimum_approvals":null,"requirement":"required","optional_policy":null,"allow_abstain":true,"reject_behavior":"when_approval_impossible","allow_self_approval":true,"allow_multi_capacity":true,"minimum_candidates":1,"candidate_selectors":[{"key":"frank_only","order":1,"type":"explicit_user","user_ids":["65250000-0001-0000-0000-000000000002"]}],"comment_policy":{"approve":"optional","reject":"required","abstain":"optional"}}},{"key":"a_end","type":"end","config":{"outcome_code":"a"}},{"key":"r_end","type":"end","config":{"outcome_code":"r"}}],"edges":[{"source":"start","target":"review","outcome":"started","priority":0,"default":false},{"source":"review","target":"a_end","outcome":"approved","priority":0,"default":false},{"source":"review","target":"r_end","outcome":"rejected","priority":0,"default":false}]}\''

SET ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"65250000-0001-0000-0000-000000000001"}',false);

WITH made AS (SELECT * FROM create_workflow_definition(
  '65250000-0000-0000-0000-000000000001','wf522p_explicit','WF522P Explicit Flow','opaque_case', :EXPLICIT_PAYLOAD::jsonb, gen_random_uuid()))
SELECT version_id AS v INTO TEMP wf522p_def FROM made;
SELECT publish_workflow_definition_version((SELECT v FROM wf522p_def),0,gen_random_uuid());

-- ── Dimension 1: create_workflow_instance + start_workflow_instance
--    (candidate resolution) against 10,000 pre-existing, mostly-
--    irrelevant substitution rows ────────────────────────────────
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_iid UUID;
BEGIN
  v_start := clock_timestamp();
  SELECT create_workflow_instance INTO v_iid FROM create_workflow_instance(
    (SELECT v FROM wf522p_def),'opaque_case',gen_random_uuid(),
    '65250000-0000-0000-0000-000000000001',gen_random_uuid(),NULL);
  PERFORM * FROM start_workflow_instance(v_iid,0,gen_random_uuid());
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 1 (create+start_workflow_instance, candidate resolution against 10,000 pre-existing substitution rows): % ms', round(v_ms, 2);
  CREATE TEMP TABLE wf522p_i1 AS SELECT v_iid AS id;
END $$;

-- ── Dimension 2: decide_workflow_work_item on the delegate path
--    against 10,000 pre-existing, mostly-irrelevant delegation rows ─
SELECT set_config('request.jwt.claims','{"sub":"65250000-0001-0000-0000-000000000002"}',false);
DO $$
DECLARE v_id UUID; v_wi UUID;
BEGIN
  -- work_item scope, since EXPLICIT_PAYLOAD's position is resolved
  -- via an explicit_user selector, not organization_role -- an
  -- organization_role-scoped delegation would correctly not apply
  -- here, per the exact selector-type scope matching this milestone
  -- implements (already covered by the behavioral suite's own
  -- scenario 17).
  SELECT id INTO v_wi FROM workflow_work_items WHERE instance_id=(SELECT id FROM wf522p_i1) AND assigned_to='65250000-0001-0000-0000-000000000002';
  CREATE TEMP TABLE wf522p_wi AS SELECT v_wi AS id;
  SELECT delegation_id INTO v_id FROM create_workflow_delegation(
    '65250000-0000-0000-0000-000000000001','65250000-0001-0000-0000-000000000002','65250000-0001-0000-0000-000000000003',
    jsonb_build_object('type','work_item','work_item_id',v_wi::text),
    'temporary','manual', now(), now()+interval '2 days', 'perf probe', gen_random_uuid());
  CREATE TEMP TABLE wf522p_deleg AS SELECT v_id AS id;
END $$;
SELECT set_config('request.jwt.claims','{"sub":"65250000-0001-0000-0000-000000000003"}',false);
SELECT status FROM accept_workflow_delegation((SELECT id FROM wf522p_deleg), 0, gen_random_uuid());
DO $$
DECLARE v_start TIMESTAMPTZ; v_ms NUMERIC; v_wi UUID := (SELECT id FROM wf522p_wi);
BEGIN
  -- v_wi looked up earlier as frank (the resolved candidate, who has
  -- RLS visibility into his own work item) and carried forward here
  -- via a temp table -- carol, as a delegate who never became a
  -- resolved candidate/participant, has no direct RLS visibility
  -- into workflow_work_items herself (same fact the RLS suite's own
  -- scenario 5 exercises), so a fresh lookup under her own claims
  -- would silently return no rows.
  v_start := clock_timestamp();
  PERFORM decision_id FROM decide_workflow_work_item(v_wi,'approve',1,0,gen_random_uuid());
  v_ms := extract(epoch FROM (clock_timestamp() - v_start)) * 1000;
  RAISE NOTICE 'Dimension 2 (decide_workflow_work_item, delegate path, against 10,000 pre-existing delegation rows): % ms', round(v_ms, 2);
END $$;
RESET ROLE;

-- ── Dimension 3: EXPLAIN confirms index usage (never a sequential
--    scan) on the substitution/delegation lookup queries at this
--    scale, for both indexed dimensions each helper filters on. ────
DO $$
DECLARE v_sub_plan TEXT := ''; v_deleg_plan TEXT := ''; v_line TEXT;
BEGIN
  FOR v_line IN EXECUTE $q$EXPLAIN (FORMAT TEXT)
    SELECT s.id FROM workflow_substitutions s
    WHERE s.represented_user_id = '65250000-0001-0000-0000-000000000002' AND s.status IN ('scheduled','active')$q$
  LOOP
    v_sub_plan := v_sub_plan || v_line || E'\n';
  END LOOP;
  IF v_sub_plan ILIKE '%Seq Scan on workflow_substitutions%' THEN
    RAISE EXCEPTION 'expected index usage on workflow_substitutions.represented_user_id, got a sequential scan: %', v_sub_plan;
  END IF;

  FOR v_line IN EXECUTE $q$EXPLAIN (FORMAT TEXT)
    SELECT d.id FROM workflow_delegations d
    WHERE d.delegate_id = '65250000-0001-0000-0000-000000000003' AND d.status IN ('scheduled','active')$q$
  LOOP
    v_deleg_plan := v_deleg_plan || v_line || E'\n';
  END LOOP;
  IF v_deleg_plan ILIKE '%Seq Scan on workflow_delegations%' THEN
    RAISE EXCEPTION 'expected index usage on workflow_delegations.delegate_id, got a sequential scan: %', v_deleg_plan;
  END IF;

  RAISE NOTICE 'Dimension 3 (index usage): both the substitution represented_user_id lookup and the delegation delegate_id lookup use an index, never a sequential scan, at 10,000-row scale';
END $$;

DO $$ BEGIN RAISE NOTICE 'Workflow delegation/substitution runtime integration performance probe PASSED'; END $$;

-- ── Cleanup ──────────────────────────────────────────────────────
ALTER TABLE workflow_events DISABLE TRIGGER workflow_events_immutable;
DELETE FROM workflow_events WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65250000-%');
ALTER TABLE workflow_events ENABLE TRIGGER workflow_events_immutable;
ALTER TABLE workflow_decisions DISABLE TRIGGER workflow_decisions_immutable;
DELETE FROM workflow_decisions WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65250000-%');
ALTER TABLE workflow_decisions ENABLE TRIGGER workflow_decisions_immutable;
DELETE FROM workflow_participants WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65250000-%');
ALTER TABLE workflow_approval_positions DISABLE TRIGGER workflow_approval_positions_immutable_after_terminal;
DELETE FROM workflow_approval_positions WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65250000-%');
ALTER TABLE workflow_approval_positions ENABLE TRIGGER workflow_approval_positions_immutable_after_terminal;
ALTER TABLE workflow_delegation_events DISABLE TRIGGER workflow_delegation_events_immutable;
DELETE FROM workflow_delegation_events WHERE delegation_id IN (SELECT id FROM workflow_delegations WHERE organization_id='65250000-0000-0000-0000-000000000001');
ALTER TABLE workflow_delegation_events ENABLE TRIGGER workflow_delegation_events_immutable;
ALTER TABLE workflow_delegations DISABLE TRIGGER workflow_delegations_immutable_after_terminal;
DELETE FROM workflow_delegations WHERE organization_id='65250000-0000-0000-0000-000000000001';
ALTER TABLE workflow_delegations ENABLE TRIGGER workflow_delegations_immutable_after_terminal;
ALTER TABLE workflow_substitution_events DISABLE TRIGGER workflow_substitution_events_immutable;
DELETE FROM workflow_substitution_events WHERE substitution_id IN (SELECT id FROM workflow_substitutions WHERE organization_id='65250000-0000-0000-0000-000000000001');
ALTER TABLE workflow_substitution_events ENABLE TRIGGER workflow_substitution_events_immutable;
ALTER TABLE workflow_substitutions DISABLE TRIGGER workflow_substitutions_immutable_after_terminal;
DELETE FROM workflow_substitutions WHERE organization_id='65250000-0000-0000-0000-000000000001';
ALTER TABLE workflow_substitutions ENABLE TRIGGER workflow_substitutions_immutable_after_terminal;
DELETE FROM workflow_work_items WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65250000-%');
ALTER TABLE workflow_approval_rounds DISABLE TRIGGER workflow_approval_rounds_immutable_after_terminal;
DELETE FROM workflow_approval_rounds WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65250000-%');
ALTER TABLE workflow_approval_rounds ENABLE TRIGGER workflow_approval_rounds_immutable_after_terminal;
DELETE FROM workflow_tokens WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65250000-%');
DELETE FROM workflow_instance_steps WHERE instance_id IN (SELECT id FROM workflow_instances WHERE created_by::text LIKE '65250000-%');
DELETE FROM workflow_instances WHERE created_by::text LIKE '65250000-%';
ALTER TABLE workflow_definition_versions DISABLE TRIGGER workflow_definition_versions_immutable;
UPDATE workflow_definitions SET active_version_id=NULL WHERE organization_id='65250000-0000-0000-0000-000000000001';
DELETE FROM workflow_definition_versions WHERE definition_id IN (SELECT id FROM workflow_definitions WHERE organization_id='65250000-0000-0000-0000-000000000001');
ALTER TABLE workflow_definition_versions ENABLE TRIGGER workflow_definition_versions_immutable;
DELETE FROM workflow_definitions WHERE organization_id='65250000-0000-0000-0000-000000000001';
DELETE FROM user_assignments WHERE user_id::text LIKE '65250000-%';
DELETE FROM users WHERE id::text LIKE '65250000-%';
DELETE FROM auth.users WHERE id::text LIKE '65250000-%';
DELETE FROM organizations WHERE id='65250000-0000-0000-0000-000000000001';
