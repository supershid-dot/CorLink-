-- CAP-002 Phase 3.1 rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
BEGIN
  IF to_regprocedure('public.decide_workflow_work_item(uuid,text,bigint,bigint,uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'Workflow approval decision engine rollback FAILED; decide_workflow_work_item still exists';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='workflow_decisions' AND column_name IN ('round_id','position_id')
  ) THEN RAISE EXCEPTION 'Workflow approval decision engine rollback FAILED; workflow_decisions still carries round_id/position_id'; END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid
    WHERE t.relname='workflow_decisions' AND c.conname IN (
      'workflow_decisions_round_instance_fkey','workflow_decisions_position_instance_fkey',
      'workflow_decisions_workitem_instance_fkey','workflow_decisions_step_instance_fkey')
  ) THEN RAISE EXCEPTION 'Workflow approval decision engine rollback FAILED; a composite instance foreign key on workflow_decisions still exists'; END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname IN (
      'workflow_instance_steps_id_instance_unique','workflow_approval_rounds_id_instance_unique',
      'workflow_approval_positions_id_instance_unique','workflow_work_items_id_instance_unique')
  ) THEN RAISE EXCEPTION 'Workflow approval decision engine rollback FAILED; a purely-additive (id, instance_id) unique constraint still exists'; END IF;

  -- Prior-phase baseline (Phase 1/2/2B.1/2B.2/2B.2A/2C.1) untouched.
  IF to_regprocedure('public.workflow_enter_downstream_node(uuid,uuid,uuid,uuid,uuid,integer,uuid,bigint,bigint,uuid,text,text,jsonb)') IS NULL
     OR to_regprocedure('public.workflow_advance_graph_step(uuid,bigint,uuid)') IS NULL
     OR to_regprocedure('public.canonicalize_workflow_definition_payload(jsonb,uuid)') IS NULL
     OR to_regclass('workflow_approval_rounds') IS NULL
     OR to_regclass('workflow_approval_positions') IS NULL
     OR to_regclass('workflow_decisions') IS NULL
  THEN RAISE EXCEPTION 'Workflow approval decision engine rollback FAILED; Phase 1/2/2B.1/2B.2/2C.1 baseline drift'; END IF;

  IF (SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'workflow\_%' ESCAPE '\') <> 12
  THEN RAISE EXCEPTION 'Workflow approval decision engine rollback FAILED; unexpected workflow table count'; END IF;

  RAISE NOTICE 'Workflow approval decision engine rollback validation PASSED (decide_workflow_work_item absent, workflow_decisions restored to its pre-Phase-3.1 shape, purely-additive unique constraints removed, Phase 1/2/2B.1/2B.2/2C.1 baseline intact).';
END $$;
