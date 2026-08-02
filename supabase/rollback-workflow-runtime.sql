-- CAP-002 Phase 2 transactional rollback.
-- Removes only runtime commands; preserves all Phase 1 tables and data.
\set ON_ERROR_STOP on
BEGIN;

DROP FUNCTION IF EXISTS complete_workflow_instance(UUID,BIGINT,UUID,TEXT);
DROP FUNCTION IF EXISTS cancel_workflow_instance(UUID,BIGINT,UUID,TEXT);
DROP FUNCTION IF EXISTS resume_workflow_instance(UUID,BIGINT,UUID,TEXT);
DROP FUNCTION IF EXISTS suspend_workflow_instance(UUID,BIGINT,UUID,TEXT);
DROP FUNCTION IF EXISTS start_workflow_instance(UUID,BIGINT,UUID);
DROP FUNCTION IF EXISTS workflow_transition_instance(UUID,TEXT,BIGINT,UUID,TEXT,TEXT);

COMMIT;
