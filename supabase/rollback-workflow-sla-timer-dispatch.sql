-- CAP-002 Phase 5.4 -- SLA timer dispatch & worker foundation
-- rollback. Reverses patch-workflow-sla-timer-dispatch.sql exactly.
--
-- Refusal precedent: this phase is purely additive -- it creates five
-- new functions and touches zero existing tables, functions, grants,
-- or comments (see the patch's own header). It stores no data of its
-- own: every row the dispatcher ever writes lands in Phase 5.3's own
-- workflow_sla_clock_events / workflow_escalation_events tables,
-- using exactly the same evidence shape a manual RPC call would have
-- produced. There is therefore nothing this rollback could destroy
-- that Phase 5.3's own rollback does not already own -- dropping
-- these five functions removes only the automatic-dispatch code path;
-- every clock and every piece of evidence already recorded (whether
-- fired manually or automatically) is completely unaffected, exactly
-- as Phase 5.3A's own correction rollback established for the same
-- reason ("a function body only affects future calls, never already-
-- stored rows"). No refusal path is needed or implemented.
\set ON_ERROR_STOP on
BEGIN;

DROP FUNCTION IF EXISTS process_workflow_sla_due_batch(INTEGER);
DROP FUNCTION IF EXISTS workflow_sla_process_due_escalations(INTEGER);
DROP FUNCTION IF EXISTS workflow_sla_process_due_breaches(INTEGER);
DROP FUNCTION IF EXISTS workflow_sla_process_due_warnings(INTEGER);
DROP FUNCTION IF EXISTS workflow_sla_automatic_idempotency_key(UUID,TEXT);

COMMIT;
