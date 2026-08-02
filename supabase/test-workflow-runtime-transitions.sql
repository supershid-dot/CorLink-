-- CAP-002 Phase 2 complete public-command/state matrix (40 scenarios)
-- Every public runtime command is tested from every architecture state.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE wf_transition_cases (
  scenario INTEGER PRIMARY KEY,
  command TEXT NOT NULL,
  from_state TEXT NOT NULL,
  expected_state TEXT,
  should_succeed BOOLEAN NOT NULL,
  instance_id UUID NOT NULL,
  idempotency_key UUID NOT NULL
);
CREATE TEMP TABLE wf_transition_results (scenario INTEGER PRIMARY KEY, name TEXT NOT NULL);
GRANT SELECT ON wf_transition_cases TO authenticated;
GRANT SELECT,INSERT ON wf_transition_results TO authenticated;

INSERT INTO organizations(id,name,type,code) VALUES ('62500000-0000-0000-0000-000000000001','Workflow Transition Org','authority','WTR');
INSERT INTO auth.users(id,email) VALUES ('62500000-0001-0000-0000-000000000001','admin@wtr.local');
INSERT INTO users(id,org_id,service_number,full_name,email,is_active) VALUES
 ('62500000-0001-0000-0000-000000000001','62500000-0000-0000-0000-000000000001','WTR-1','Transition Admin','admin@wtr.local',true);
INSERT INTO user_assignments(user_id,scope_type,scope_id,role,is_primary,is_active) VALUES
 ('62500000-0001-0000-0000-000000000001','organization','62500000-0000-0000-0000-000000000001','authority_admin',true,true);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"62500000-0001-0000-0000-000000000001"}',true);
CREATE TEMP TABLE wf_transition_definition AS
SELECT * FROM create_workflow_definition(
 '62500000-0000-0000-0000-000000000001','transition_flow','Transition Flow','opaque_record',
 '{"nodes":[],"edges":[]}','62500000-1000-0000-0000-000000000001');
SELECT publish_workflow_definition_version((SELECT version_id FROM wf_transition_definition),0,'62500000-1000-0000-0000-000000000002');
RESET ROLE;

WITH states(state_name) AS (
  VALUES ('pending'),('active'),('suspended'),('completed'),
         ('rejected'),('cancelled'),('withdrawn'),('failed')
), commands(command_name) AS (
  VALUES ('start'),('suspend'),('resume'),('cancel'),('complete')
), numbered AS (
  SELECT row_number() OVER(ORDER BY command_name,state_name)::INTEGER scenario,
         command_name,state_name
  FROM commands CROSS JOIN states
)
INSERT INTO wf_transition_cases
SELECT scenario,command_name,state_name,
 CASE
   WHEN command_name IN ('start','resume') THEN 'active'
   WHEN command_name='suspend' THEN 'suspended'
   WHEN command_name='cancel' THEN 'cancelled'
   WHEN command_name='complete' THEN 'completed'
 END,
 (command_name='start' AND state_name='pending')
 OR (command_name='suspend' AND state_name='active')
 OR (command_name='resume' AND state_name='suspended')
 OR (command_name='cancel' AND state_name IN ('pending','active','suspended'))
 OR (command_name='complete' AND state_name='active'),
 ('62500000-2000-0000-0000-'||lpad(to_hex(scenario),12,'0'))::UUID,
 ('62500000-3000-0000-0000-'||lpad(to_hex(scenario),12,'0'))::UUID
FROM numbered;

INSERT INTO workflow_instances(
 id,definition_id,definition_version_id,subject_type,subject_id,
 home_organization_id,participant_organization_ids,status,terminal_outcome,
 correlation_id,created_by,create_idempotency_key,started_at,ended_at
)
SELECT c.instance_id,(SELECT definition_id FROM wf_transition_definition),(SELECT version_id FROM wf_transition_definition),
 'opaque_record',('62500000-4000-0000-0000-'||lpad(to_hex(c.scenario),12,'0'))::UUID,
 '62500000-0000-0000-0000-000000000001',ARRAY['62500000-0000-0000-0000-000000000001'::UUID],
 c.from_state,
 CASE WHEN c.from_state IN ('completed','rejected','cancelled','withdrawn') THEN c.from_state ELSE NULL END,
 ('62500000-5000-0000-0000-'||lpad(to_hex(c.scenario),12,'0'))::UUID,
 '62500000-0001-0000-0000-000000000001',
 ('62500000-6000-0000-0000-'||lpad(to_hex(c.scenario),12,'0'))::UUID,
 CASE WHEN c.from_state='pending' THEN NULL ELSE now()-interval '1 hour' END,
 CASE WHEN c.from_state IN ('completed','rejected','cancelled','withdrawn') THEN now() ELSE NULL END
FROM wf_transition_cases c;

INSERT INTO workflow_participants(instance_id,user_id,participant_role,authority_source,created_by)
SELECT instance_id,'62500000-0001-0000-0000-000000000001','owner','transition_fixture','62500000-0001-0000-0000-000000000001'
FROM wf_transition_cases;
INSERT INTO workflow_events(instance_id,event_sequence,event_type,actor_id,correlation_id,idempotency_key)
SELECT c.instance_id,1,'instance_created','62500000-0001-0000-0000-000000000001',i.correlation_id,i.create_idempotency_key
FROM wf_transition_cases c JOIN workflow_instances i ON i.id=c.instance_id;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims','{"sub":"62500000-0001-0000-0000-000000000001"}',true);
DO $$
DECLARE c RECORD; v_actual TEXT;
BEGIN
  FOR c IN SELECT * FROM wf_transition_cases ORDER BY scenario LOOP
    BEGIN
      CASE c.command
        WHEN 'start' THEN
          SELECT status INTO v_actual FROM start_workflow_instance(c.instance_id,0,c.idempotency_key);
        WHEN 'suspend' THEN
          SELECT status INTO v_actual FROM suspend_workflow_instance(c.instance_id,0,c.idempotency_key,'matrix_test');
        WHEN 'resume' THEN
          SELECT status INTO v_actual FROM resume_workflow_instance(c.instance_id,0,c.idempotency_key,'matrix_test');
        WHEN 'cancel' THEN
          SELECT status INTO v_actual FROM cancel_workflow_instance(c.instance_id,0,c.idempotency_key,'matrix_test');
        WHEN 'complete' THEN
          SELECT status INTO v_actual FROM complete_workflow_instance(c.instance_id,0,c.idempotency_key,'success');
      END CASE;
      IF NOT c.should_succeed THEN
        RAISE EXCEPTION 'Illegal matrix transition accepted: % from %',c.command,c.from_state;
      END IF;
      IF v_actual<>c.expected_state THEN
        RAISE EXCEPTION 'Matrix result mismatch: % from % returned %',c.command,c.from_state,v_actual;
      END IF;
      INSERT INTO wf_transition_results VALUES(c.scenario,c.command||' from '||c.from_state||' succeeds');
    EXCEPTION WHEN SQLSTATE '55000' THEN
      IF c.should_succeed THEN
        RAISE EXCEPTION 'Legal matrix transition rejected: % from %',c.command,c.from_state;
      END IF;
      INSERT INTO wf_transition_results VALUES(c.scenario,c.command||' from '||c.from_state||' rejected');
    END;
  END LOOP;
END $$;
RESET ROLE;

DO $$ BEGIN
 IF (SELECT count(*) FROM wf_transition_results)<>40 THEN RAISE EXCEPTION 'Expected 40 transition scenarios'; END IF;
 IF (SELECT count(*) FROM workflow_events WHERE event_sequence=2)<>7 THEN RAISE EXCEPTION 'Expected seven accepted transition events'; END IF;
 IF (SELECT count(*) FROM workflow_instances WHERE lock_version=1)<>7 THEN RAISE EXCEPTION 'Expected seven transitioned aggregates'; END IF;
END $$;
SELECT 'Workflow runtime transition tests PASSED: 40/40' AS result;
ROLLBACK;
