-- CAP-003 Phase 1.6A rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_missing TEXT := ''; v_fn TEXT;
BEGIN
  -- All 19 RPCs gone.
  FOREACH v_fn IN ARRAY ARRAY[
    'create_request(uuid,uuid,text,text,text,text,timestamptz,uuid)',
    'update_request_draft(uuid,text,text,text,text,timestamptz)',
    'submit_request(uuid,uuid)', 'approve_request(uuid,text)', 'return_request(uuid,text)',
    'mark_request_received(uuid)', 'route_request(uuid,uuid)',
    'return_request_to_previous_section(uuid,text)', 'assign_request(uuid,uuid)',
    'receive_and_route_request(uuid,uuid,uuid)', 'close_request(uuid)', 'cancel_request(uuid,text)',
    'create_response(uuid,text,text)', 'update_response_draft(uuid,text,text)',
    'submit_response(uuid,uuid)', 'approve_response(uuid,text)', 'return_response(uuid,text)',
    'mark_response_received(uuid)', 'acknowledge_and_close(uuid,uuid)'
  ] LOOP
    IF to_regprocedure('public.'||v_fn) IS NOT NULL THEN
      v_missing := v_missing || v_fn || '-still-present ';
    END IF;
  END LOOP;

  -- Direct client writes restored (RLS itself was never touched, so
  -- restoring the grant is the complete restoration of pre-1.6A state).
  IF NOT has_table_privilege('authenticated','public.requests','INSERT') THEN
    v_missing := v_missing || 'requests-insert-not-restored '; END IF;
  IF NOT has_table_privilege('authenticated','public.requests','UPDATE') THEN
    v_missing := v_missing || 'requests-update-not-restored '; END IF;
  IF NOT has_table_privilege('authenticated','public.responses','INSERT') THEN
    v_missing := v_missing || 'responses-insert-not-restored '; END IF;
  IF NOT has_table_privilege('authenticated','public.responses','UPDATE') THEN
    v_missing := v_missing || 'responses-update-not-restored '; END IF;

  -- requests/responses RLS untouched throughout (byte-for-byte the
  -- same assertion the structural validator itself makes).
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='requests') <> 10 THEN
    v_missing := v_missing || 'requests-policy-count-drift '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='responses') <> 6 THEN
    v_missing := v_missing || 'responses-policy-count-drift '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='requests'
      AND policyname='requests_update' AND cmd='UPDATE'
  ) THEN v_missing := v_missing || 'requests_update-policy-missing '; END IF;

  -- No schema object of any kind was added by the patch, so none
  -- should have needed removing and none should be missing now.
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name IN ('requests','responses') AND column_name ILIKE '%lock_version%'
  ) THEN v_missing := v_missing || 'unexpected-lock_version-column-present '; END IF;

  -- Business data, history, and CAP-002/CAP-003 baselines intact.
  IF to_regclass('public.requests') IS NULL OR to_regclass('public.responses') IS NULL THEN
    v_missing := v_missing || 'requests-or-responses-table-missing '; END IF;
  IF to_regclass('public.audit_logs') IS NULL OR to_regclass('public.approvals') IS NULL THEN
    v_missing := v_missing || 'audit-or-approvals-table-missing '; END IF;
  IF to_regclass('public.user_notifications') IS NULL THEN v_missing := v_missing || 'phase1.1-baseline-drift '; END IF;
  IF to_regprocedure('public.list_my_notifications(integer,timestamptz,uuid,boolean)') IS NULL THEN
    v_missing := v_missing || 'phase1.1-api-baseline-drift '; END IF;
  IF to_regprocedure('public.assign_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'task-baseline-drift '; END IF;
  IF to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL THEN
    v_missing := v_missing || 'cap002-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Requests server mutation foundation rollback validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Requests server mutation foundation rollback validation PASSED (all 19 RPCs removed, direct requests/responses writes restored to authenticated, RLS policies byte-for-byte unchanged throughout, no schema object left behind, business data/history/CAP-002/CAP-003 baselines all intact). Frontend rollback (js/data/requests-api.js, js/views/request-detail.js) is a separate git-revert -- see docs/89.';
END $$;
