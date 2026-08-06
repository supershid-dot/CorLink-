-- CAP-002 Phase 3.1 rollback.
--
-- Drops decide_workflow_work_item(), the composite (id, instance_id)
-- foreign keys and round_id/position_id linkage this patch added to
-- workflow_decisions, and the four purely-additive UNIQUE(id,
-- instance_id) constraints on workflow_instance_steps,
-- workflow_approval_rounds, workflow_approval_positions, and
-- workflow_work_items.
--
-- Unlike Phase 2C.1's rollback (which changed only function bodies
-- and therefore never refuses), this migration is the FIRST to write
-- real rows into workflow_decisions, and adds the round_id/position_id
-- columns as NOT NULL. Dropping those columns would destroy evidence
-- already recorded in the immutable decision ledger, so this rollback
-- REFUSES outright if any workflow_decisions row exists — there is no
-- partial or safe rollback path once a real decision has been cast.
\set ON_ERROR_STOP on
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM workflow_decisions) THEN
    RAISE EXCEPTION 'Workflow approval decision engine rollback REFUSED: % row(s) already exist in workflow_decisions; dropping round_id/position_id would destroy immutable evidence',
      (SELECT count(*) FROM workflow_decisions);
  END IF;
END $$;

BEGIN;

DROP FUNCTION IF EXISTS decide_workflow_work_item(UUID,TEXT,BIGINT,BIGINT,UUID,TEXT);

DROP INDEX IF EXISTS idx_workflow_decisions_round;
ALTER TABLE workflow_decisions DROP CONSTRAINT IF EXISTS workflow_decisions_round_instance_fkey;
ALTER TABLE workflow_decisions DROP CONSTRAINT IF EXISTS workflow_decisions_position_instance_fkey;
ALTER TABLE workflow_decisions DROP CONSTRAINT IF EXISTS workflow_decisions_workitem_instance_fkey;
ALTER TABLE workflow_decisions DROP CONSTRAINT IF EXISTS workflow_decisions_step_instance_fkey;
ALTER TABLE workflow_decisions DROP COLUMN IF EXISTS round_id;
ALTER TABLE workflow_decisions DROP COLUMN IF EXISTS position_id;

ALTER TABLE workflow_work_items DROP CONSTRAINT IF EXISTS workflow_work_items_id_instance_unique;
ALTER TABLE workflow_approval_positions DROP CONSTRAINT IF EXISTS workflow_approval_positions_id_instance_unique;
ALTER TABLE workflow_approval_rounds DROP CONSTRAINT IF EXISTS workflow_approval_rounds_id_instance_unique;
ALTER TABLE workflow_instance_steps DROP CONSTRAINT IF EXISTS workflow_instance_steps_id_instance_unique;

COMMIT;
