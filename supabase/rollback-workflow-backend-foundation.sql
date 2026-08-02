-- CAP-002 Phase 1 transactional rollback.
-- Refuses to discard workflow data; no CASCADE is used.
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE v_table TEXT; v_count BIGINT;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'workflow_events','workflow_decisions','workflow_variables','workflow_participants',
    'workflow_work_items','workflow_tokens','workflow_instance_steps','workflow_instances',
    'workflow_definition_versions','workflow_definitions'
  ] LOOP
    IF to_regclass('public.'||v_table) IS NOT NULL THEN
      EXECUTE format('SELECT count(*) FROM public.%I',v_table) INTO v_count;
      IF v_count<>0 THEN
        RAISE EXCEPTION 'Workflow rollback refused: % contains % row(s)',v_table,v_count;
      END IF;
    END IF;
  END LOOP;
END $$;

DROP FUNCTION IF EXISTS list_workflow_work_items(INTEGER,TIMESTAMPTZ,UUID);
DROP FUNCTION IF EXISTS get_workflow_instance(UUID);
DROP FUNCTION IF EXISTS create_workflow_instance(UUID,TEXT,UUID,UUID,UUID,UUID);
DROP FUNCTION IF EXISTS publish_workflow_definition_version(UUID,BIGINT,UUID);
DROP FUNCTION IF EXISTS create_workflow_definition_version(UUID,JSONB,UUID);
DROP FUNCTION IF EXISTS create_workflow_definition(UUID,TEXT,TEXT,TEXT,JSONB,UUID);
DO $$ BEGIN
  IF to_regclass('public.workflow_definitions') IS NOT NULL THEN
    ALTER TABLE workflow_definitions DROP CONSTRAINT IF EXISTS workflow_definitions_active_version_fkey;
  END IF;
END $$;

DROP TABLE IF EXISTS workflow_events;
DROP TABLE IF EXISTS workflow_decisions;
DROP TABLE IF EXISTS workflow_variables;
DROP TABLE IF EXISTS workflow_participants;
DROP TABLE IF EXISTS workflow_work_items;
DROP TABLE IF EXISTS workflow_tokens;
DROP TABLE IF EXISTS workflow_instance_steps;
DROP TABLE IF EXISTS workflow_instances;
DROP TABLE IF EXISTS workflow_definition_versions;
DROP TABLE IF EXISTS workflow_definitions;

DROP FUNCTION IF EXISTS can_manage_workflow_instance(UUID);
DROP FUNCTION IF EXISTS can_view_workflow_instance(UUID);
DROP FUNCTION IF EXISTS can_manage_workflow_definition(UUID);
DROP FUNCTION IF EXISTS workflow_actor_is_active();
DROP FUNCTION IF EXISTS workflow_guard_definition_version_mutation();
DROP FUNCTION IF EXISTS workflow_reject_immutable_mutation();

COMMIT;
