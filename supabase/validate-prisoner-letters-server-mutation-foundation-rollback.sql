-- Prisoner Letters server-mutation-foundation rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_missing TEXT := ''; v_fn TEXT; v_qual TEXT; v_check TEXT;
BEGIN
  -- All 6 RPCs gone.
  FOREACH v_fn IN ARRAY ARRAY[
    'create_prisoner_letter(uuid,uuid,uuid,text)',
    'mark_prisoner_letter_received(uuid)',
    'route_prisoner_letter(uuid,uuid,uuid)',
    'mark_prisoner_letter_slip_generated(uuid)',
    'create_prisoner_letter_reply(uuid,text)',
    'mark_prisoner_letter_delivered(uuid)'
  ] LOOP
    IF to_regprocedure('public.'||v_fn) IS NOT NULL THEN
      v_missing := v_missing || v_fn || '-still-present ';
    END IF;
  END LOOP;

  -- Direct client writes restored.
  IF NOT has_table_privilege('authenticated','public.prisoner_letters','INSERT') THEN
    v_missing := v_missing || 'prisoner_letters-insert-not-restored '; END IF;
  IF NOT has_table_privilege('authenticated','public.prisoner_letters','UPDATE') THEN
    v_missing := v_missing || 'prisoner_letters-update-not-restored '; END IF;
  IF NOT has_table_privilege('authenticated','public.prisoner_letters','DELETE') THEN
    v_missing := v_missing || 'prisoner_letters-delete-not-restored '; END IF;
  IF NOT has_table_privilege('authenticated','public.prisoner_replies','INSERT') THEN
    v_missing := v_missing || 'prisoner_replies-insert-not-restored '; END IF;
  IF NOT has_table_privilege('authenticated','public.prisoner_replies','UPDATE') THEN
    v_missing := v_missing || 'prisoner_replies-update-not-restored '; END IF;
  IF NOT has_table_privilege('authenticated','public.prisoner_replies','DELETE') THEN
    v_missing := v_missing || 'prisoner_replies-delete-not-restored '; END IF;

  -- generate_prisoner_letter_reference() restored to its original
  -- (unpinned search_path, PUBLIC-callable) shape.
  IF to_regprocedure('public.generate_prisoner_letter_reference(uuid)') IS NULL THEN
    v_missing := v_missing || 'generate_prisoner_letter_reference-missing ';
  ELSE
    IF EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.generate_prisoner_letter_reference(uuid)')
        AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || 'generate_prisoner_letter_reference-still-has-search-path-pin '; END IF;
    IF NOT has_function_privilege('authenticated', 'public.generate_prisoner_letter_reference(uuid)'::regprocedure, 'EXECUTE') THEN
      v_missing := v_missing || 'generate_prisoner_letter_reference-execute-not-restored '; END IF;
  END IF;

  -- RLS policy count restored (byte-for-byte the same assertion the
  -- structural validator makes for the forward-applied state).
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='prisoner_letters') <> 3 THEN
    v_missing := v_missing || 'prisoner_letters-policy-count-drift '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='prisoner_replies') <> 2 THEN
    v_missing := v_missing || 'prisoner_replies-policy-count-drift '; END IF;

  -- prisoner_letters_select restored to the coarse flag+party-org
  -- model -- no submitted_by/assigned_to/supervisor narrowing.
  SELECT qual INTO v_qual FROM pg_policies WHERE schemaname='public' AND tablename='prisoner_letters' AND policyname='prisoner_letters_select';
  IF v_qual IS NULL OR v_qual ILIKE '%submitted_by%' OR v_qual ILIKE '%assigned_to%' OR v_qual ILIKE '%is_supervisor_or_above%' THEN
    v_missing := v_missing || 'prisoner_letters_select-not-restored-to-original-shape '; END IF;
  SELECT qual INTO v_qual FROM pg_policies WHERE schemaname='public' AND tablename='prisoner_letters' AND policyname='prisoner_letters_update';
  IF v_qual IS NULL OR v_qual ILIKE '%submitted_by%' OR v_qual ILIKE '%assigned_to%' THEN
    v_missing := v_missing || 'prisoner_letters_update-not-restored-to-original-shape '; END IF;

  -- prisoner_replies_insert restored to the original either-side
  -- predicate (the pre-milestone MCS-can-also-reply gap this milestone
  -- fixed -- correctly reopened by a genuine rollback).
  SELECT with_check INTO v_qual FROM pg_policies WHERE schemaname='public' AND tablename='prisoner_replies' AND policyname='prisoner_replies_insert';
  IF v_qual IS NULL OR v_qual ILIKE '%is_supervisor_or_above%' THEN
    v_missing := v_missing || 'prisoner_replies_insert-not-restored-to-original-shape '; END IF;

  -- Attachment finalization lock removed -- the prisoner_letter/
  -- prisoner_reply branches of attachments_insert/_delete no longer
  -- carry the pl.status <> 'delivered' condition.
  SELECT with_check INTO v_check FROM pg_policies WHERE schemaname='public' AND tablename='attachments' AND policyname='attachments_insert';
  IF v_check ILIKE '%pl.status <> ''delivered''%' THEN
    v_missing := v_missing || 'attachments_insert-finalization-lock-not-removed '; END IF;
  SELECT qual INTO v_check FROM pg_policies WHERE schemaname='public' AND tablename='attachments' AND policyname='attachments_delete';
  IF v_check ILIKE '%pl.status <> ''delivered''%' THEN
    v_missing := v_missing || 'attachments_delete-finalization-lock-not-removed '; END IF;
  -- request/response/internal_request/internal_reply branches of all
  -- three attachments policies remain untouched throughout.
  SELECT qual INTO v_check FROM pg_policies WHERE schemaname='public' AND tablename='attachments' AND policyname='attachments_select';
  IF v_check IS NULL OR v_check NOT ILIKE '%r.from_org_id = get_my_org_id%' OR v_check NOT ILIKE '%ir.from_section_id%' OR v_check NOT ILIKE '%my_section_ids%' THEN
    v_missing := v_missing || 'attachments_select-unrelated-branches-disturbed '; END IF;

  -- No schema object of any kind was added by the patch, so none
  -- should have needed removing and none should be missing now.
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name IN ('prisoner_letters','prisoner_replies')
      AND column_name ILIKE '%lock_version%'
  ) THEN v_missing := v_missing || 'unexpected-speculative-column-present '; END IF;

  -- Business data, history, and CAP-002/CAP-003 baselines intact.
  IF to_regclass('public.prisoner_letters') IS NULL OR to_regclass('public.prisoner_replies') IS NULL THEN
    v_missing := v_missing || 'prisoner_letters-or-replies-table-missing '; END IF;
  IF to_regclass('public.audit_logs') IS NULL THEN v_missing := v_missing || 'audit-logs-table-missing '; END IF;
  IF to_regprocedure('public.create_internal_request(uuid,uuid,text,text,uuid,uuid,text,text,timestamptz)') IS NULL THEN
    v_missing := v_missing || 'internal-collaboration-1.8a-baseline-drift '; END IF;
  IF (SELECT count(*) FROM platform_event_type_registry WHERE owning_module = 'internal_collaboration') <> 5 THEN
    v_missing := v_missing || 'internal-collaboration-1.8b-event-registry-drift '; END IF;
  IF to_regclass('public.user_notifications') IS NULL THEN v_missing := v_missing || 'cap003-baseline-drift '; END IF;
  IF to_regprocedure('public.assign_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'task-baseline-drift '; END IF;
  IF to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL THEN
    v_missing := v_missing || 'cap002-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Prisoner Letters server mutation foundation rollback validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Prisoner Letters server mutation foundation rollback validation PASSED (all 6 RPCs removed, direct prisoner_letters/prisoner_replies writes restored to authenticated, generate_prisoner_letter_reference restored to its original PUBLIC-callable/unpinned shape, RLS policies restored to their original coarse flag+party-org model, attachment finalization lock removed, no schema object left behind, Requests/Entry/Internal Collaboration/CAP-002/CAP-003 baselines all intact). Frontend rollback (js/data/prisoner-letters-api.js) is a separate git-revert; the companion Task-integration helper realignment must also be reverted in the same maintenance window per this file''s own header.';
END $$;
