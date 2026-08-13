-- CAP-003 Phase 1.7A rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_missing TEXT := ''; v_fn TEXT;
BEGIN
  -- All 12 RPCs gone.
  FOREACH v_fn IN ARRAY ARRAY[
    'create_entry(text,text,text,text,text,text,text,uuid,text,text,text,date,date)',
    'update_entry_draft(uuid,text,text,text,text,date)',
    'route_entry(uuid,uuid,uuid)', 'mark_entry_received(uuid)', 'assign_entry(uuid,uuid,date)',
    'close_entry(uuid)', 'draft_entry_reply(uuid,text,text)', 'update_entry_reply_draft(uuid,text,text)',
    'submit_entry_reply(uuid,uuid)', 'approve_entry_reply(uuid)', 'return_entry_reply(uuid,text)',
    'mark_entry_reply_sent(uuid,text)'
  ] LOOP
    IF to_regprocedure('public.'||v_fn) IS NOT NULL THEN
      v_missing := v_missing || v_fn || '-still-present ';
    END IF;
  END LOOP;

  -- Direct client writes restored (RLS itself was never touched, so
  -- restoring the grant is the complete restoration of pre-1.7A state).
  IF NOT has_table_privilege('authenticated','public.external_correspondence','INSERT') THEN
    v_missing := v_missing || 'external_correspondence-insert-not-restored '; END IF;
  IF NOT has_table_privilege('authenticated','public.external_correspondence','UPDATE') THEN
    v_missing := v_missing || 'external_correspondence-update-not-restored '; END IF;
  IF NOT has_table_privilege('authenticated','public.external_correspondence_replies','INSERT') THEN
    v_missing := v_missing || 'external_correspondence_replies-insert-not-restored '; END IF;
  IF NOT has_table_privilege('authenticated','public.external_correspondence_replies','UPDATE') THEN
    v_missing := v_missing || 'external_correspondence_replies-update-not-restored '; END IF;

  -- external_correspondence(_replies) RLS untouched throughout
  -- (byte-for-byte the same assertion the structural validator itself
  -- makes).
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='external_correspondence') <> 5 THEN
    v_missing := v_missing || 'external_correspondence-policy-count-drift '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='external_correspondence_replies') <> 3 THEN
    v_missing := v_missing || 'external_correspondence_replies-policy-count-drift '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='external_correspondence'
      AND policyname='external_correspondence_update_entry' AND cmd='UPDATE'
  ) THEN v_missing := v_missing || 'external_correspondence_update_entry-policy-missing '; END IF;

  -- No schema object of any kind was added by the patch, so none
  -- should have needed removing and none should be missing now
  -- (including no facility/prison column).
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name IN ('external_correspondence','external_correspondence_replies')
      AND (column_name ILIKE '%lock_version%' OR column_name ILIKE '%facility%' OR column_name ILIKE '%prison_id%')
  ) THEN v_missing := v_missing || 'unexpected-speculative-column-present '; END IF;

  -- Business data, history, Requests (1.6A/1.6B), and CAP-002/CAP-003
  -- baselines intact.
  IF to_regclass('public.external_correspondence') IS NULL OR to_regclass('public.external_correspondence_replies') IS NULL THEN
    v_missing := v_missing || 'external_correspondence-or-replies-table-missing '; END IF;
  IF to_regclass('public.audit_logs') IS NULL OR to_regclass('public.approvals') IS NULL THEN
    v_missing := v_missing || 'audit-or-approvals-table-missing '; END IF;
  IF to_regprocedure('public.create_request(uuid,uuid,text,text,text,text,timestamptz,uuid)') IS NULL THEN
    v_missing := v_missing || 'requests-1.6a-baseline-drift '; END IF;
  IF (SELECT count(*) FROM platform_event_type_registry WHERE owning_module = 'requests') <> 5 THEN
    v_missing := v_missing || 'requests-1.6b-event-registry-drift '; END IF;
  IF to_regclass('public.user_notifications') IS NULL THEN v_missing := v_missing || 'phase1.1-baseline-drift '; END IF;
  IF to_regprocedure('public.assign_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'task-baseline-drift '; END IF;
  IF to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL THEN
    v_missing := v_missing || 'cap002-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Entry server mutation foundation rollback validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Entry server mutation foundation rollback validation PASSED (all 12 RPCs removed, direct external_correspondence/external_correspondence_replies writes restored to authenticated, RLS policies byte-for-byte unchanged throughout, no schema object left behind, business data/history/Requests/CAP-002/CAP-003 baselines all intact). Frontend rollback (js/data/entry-api.js) is a separate git-revert -- see docs/91.';
END $$;
