-- CAP-003 Phase 1.8A rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_missing TEXT := ''; v_fn TEXT;
BEGIN
  -- All 11 RPCs gone.
  FOREACH v_fn IN ARRAY ARRAY[
    'create_internal_request(uuid,uuid,text,text,uuid,uuid,text,text,timestamptz)',
    'mark_internal_request_received(uuid)', 'reroute_internal_request(uuid,uuid)',
    'return_internal_request_to_sender(uuid,text)', 'assign_internal_request(uuid,uuid)',
    'close_internal_request(uuid)', 'draft_internal_request_reply(uuid,text,text)',
    'update_internal_request_reply_draft(uuid,text,text)', 'submit_internal_request_reply(uuid,uuid)',
    'approve_internal_request_reply(uuid)', 'return_internal_request_reply(uuid)'
  ] LOOP
    IF to_regprocedure('public.'||v_fn) IS NOT NULL THEN
      v_missing := v_missing || v_fn || '-still-present ';
    END IF;
  END LOOP;

  -- Direct client writes restored (RLS itself was never touched, so
  -- restoring the grant is the complete restoration of pre-1.8A state).
  IF NOT has_table_privilege('authenticated','public.internal_requests','INSERT') THEN
    v_missing := v_missing || 'internal_requests-insert-not-restored '; END IF;
  IF NOT has_table_privilege('authenticated','public.internal_requests','UPDATE') THEN
    v_missing := v_missing || 'internal_requests-update-not-restored '; END IF;
  IF NOT has_table_privilege('authenticated','public.internal_request_replies','INSERT') THEN
    v_missing := v_missing || 'internal_request_replies-insert-not-restored '; END IF;
  IF NOT has_table_privilege('authenticated','public.internal_request_replies','UPDATE') THEN
    v_missing := v_missing || 'internal_request_replies-update-not-restored '; END IF;

  -- internal_requests(_replies) RLS untouched throughout (byte-for-byte
  -- the same assertion the structural validator itself makes).
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='internal_requests') <> 3 THEN
    v_missing := v_missing || 'internal_requests-policy-count-drift '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='internal_request_replies') <> 3 THEN
    v_missing := v_missing || 'internal_request_replies-policy-count-drift '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='internal_requests'
      AND policyname='internal_requests_update' AND cmd='UPDATE'
  ) THEN v_missing := v_missing || 'internal_requests_update-policy-missing '; END IF;

  -- No schema object of any kind was added by the patch, so none
  -- should have needed removing and none should be missing now.
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name IN ('internal_requests','internal_request_replies')
      AND (column_name ILIKE '%lock_version%' OR column_name ILIKE '%org_id%')
  ) THEN v_missing := v_missing || 'unexpected-speculative-column-present '; END IF;

  -- Task integration (patch-internal-collaboration-task-integration.sql,
  -- untouched by this milestone/rollback) must remain fully intact.
  IF to_regprocedure('public.get_internal_collaboration_task_capabilities(uuid)') IS NULL THEN
    v_missing := v_missing || 'task-integration-baseline-drift '; END IF;
  IF to_regprocedure('public.create_internal_collaboration_supporting_task(uuid,text,text,uuid,text,text,date,date,uuid[])') IS NULL THEN
    v_missing := v_missing || 'task-integration-create-baseline-drift '; END IF;

  -- Business data, history, Requests (1.6A/1.6B), Entry (1.7A/1.7B),
  -- and CAP-002/CAP-003 baselines intact.
  IF to_regclass('public.internal_requests') IS NULL OR to_regclass('public.internal_request_replies') IS NULL THEN
    v_missing := v_missing || 'internal_requests-or-replies-table-missing '; END IF;
  IF to_regclass('public.audit_logs') IS NULL OR to_regclass('public.approvals') IS NULL THEN
    v_missing := v_missing || 'audit-or-approvals-table-missing '; END IF;
  IF to_regprocedure('public.create_request(uuid,uuid,text,text,text,text,timestamptz,uuid)') IS NULL THEN
    v_missing := v_missing || 'requests-1.6a-baseline-drift '; END IF;
  IF (SELECT count(*) FROM platform_event_type_registry WHERE owning_module = 'requests') <> 5 THEN
    v_missing := v_missing || 'requests-1.6b-event-registry-drift '; END IF;
  IF to_regprocedure('public.create_entry(text,text,text,text,text,text,text,uuid,text,text,text,date,date)') IS NULL THEN
    v_missing := v_missing || 'entry-1.7a-baseline-drift '; END IF;
  IF (SELECT count(*) FROM platform_event_type_registry WHERE owning_module = 'entry') <> 4 THEN
    v_missing := v_missing || 'entry-1.7b-event-registry-drift '; END IF;
  IF to_regclass('public.user_notifications') IS NULL THEN v_missing := v_missing || 'phase1.1-baseline-drift '; END IF;
  IF to_regprocedure('public.assign_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'task-baseline-drift '; END IF;
  IF to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL THEN
    v_missing := v_missing || 'cap002-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Internal Collaboration server mutation foundation rollback validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Internal Collaboration server mutation foundation rollback validation PASSED (all 11 RPCs removed, direct internal_requests/internal_request_replies writes restored to authenticated, RLS policies byte-for-byte unchanged throughout, no schema object left behind, Task integration/business data/history/Requests/Entry/CAP-002/CAP-003 baselines all intact). Frontend rollback (js/data/internal-requests-api.js) is a separate git-revert.';
END $$;
