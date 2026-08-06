-- CAP-002 Phase 5.1 delegation/substitution foundation rollback.
--
-- Refuses to discard any delegation/substitution/evidence data; no
-- CASCADE is used. This mirrors the Phase 1
-- (rollback-workflow-backend-foundation.sql) "refuse if any row
-- exists" precedent exactly, not the "protect real activated work"
-- precedent used elsewhere in this engine — because this milestone
-- creates wholly new tables with no prior data ever possible, any
-- row that exists at rollback time is necessarily real, created
-- work that would be silently destroyed by a permissive rollback.
--
-- Drops every object this patch created: the two new tables, their
-- two immutable evidence tables, every RPC, and every private
-- helper/trigger function. Restores nothing (no pre-5.1 body to
-- restore — every one of these objects is wholly new). The
-- btree_gist extension is NOT dropped, since a sibling CAP
-- (patch-rooms-booking-foundation.sql) also depends on it and this
-- patch does not own it exclusively.
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE v_table TEXT; v_count BIGINT;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'workflow_delegation_events','workflow_delegations',
    'workflow_substitution_events','workflow_substitutions'
  ] LOOP
    IF to_regclass('public.'||v_table) IS NOT NULL THEN
      EXECUTE format('SELECT count(*) FROM public.%I',v_table) INTO v_count;
      IF v_count<>0 THEN
        RAISE EXCEPTION 'Workflow delegation/substitution foundation rollback refused: % contains % row(s)',v_table,v_count;
      END IF;
    END IF;
  END LOOP;
END $$;

DROP FUNCTION IF EXISTS list_workflow_substitutions(UUID,TEXT,INTEGER,TIMESTAMPTZ,UUID);
DROP FUNCTION IF EXISTS get_workflow_substitution(UUID);
DROP FUNCTION IF EXISTS revoke_workflow_substitution(UUID,BIGINT,TEXT,UUID);
DROP FUNCTION IF EXISTS create_workflow_substitution(UUID,JSONB,UUID,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,TEXT,UUID);
DROP FUNCTION IF EXISTS list_workflow_delegations(UUID,TEXT,INTEGER,TIMESTAMPTZ,UUID);
DROP FUNCTION IF EXISTS get_workflow_delegation(UUID);
DROP FUNCTION IF EXISTS revoke_workflow_delegation(UUID,BIGINT,TEXT,UUID);
DROP FUNCTION IF EXISTS reject_workflow_delegation(UUID,BIGINT,TEXT,UUID);
DROP FUNCTION IF EXISTS accept_workflow_delegation(UUID,BIGINT,UUID);
DROP FUNCTION IF EXISTS create_workflow_delegation(UUID,UUID,UUID,JSONB,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,TEXT,UUID);

DROP TABLE IF EXISTS workflow_substitution_events;
DROP TABLE IF EXISTS workflow_substitutions;
DROP TABLE IF EXISTS workflow_delegation_events;
DROP TABLE IF EXISTS workflow_delegations;

DROP FUNCTION IF EXISTS workflow_reject_terminal_substitution_mutation();
DROP FUNCTION IF EXISTS workflow_reject_delegation_event_mutation();
DROP FUNCTION IF EXISTS workflow_reject_terminal_delegation_mutation();
DROP FUNCTION IF EXISTS can_manage_workflow_delegation_scope(UUID);
DROP FUNCTION IF EXISTS workflow_substitution_visible_to_caller(TEXT,UUID,UUID,UUID);
DROP FUNCTION IF EXISTS workflow_delegation_visible_to_caller(UUID,UUID,UUID);

COMMIT;
