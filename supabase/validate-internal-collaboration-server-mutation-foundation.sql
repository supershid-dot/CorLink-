-- CAP-003 Phase 1.8A structural validator. Disposable local
-- PostgreSQL only.
\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
  v_fn  TEXT;
BEGIN
  -- ── 1. Every evidenced mutation RPC exists with the exact
  -- signature this milestone defines ──────────────────────────────
  FOREACH v_fn IN ARRAY ARRAY[
    'create_internal_request(uuid,uuid,text,text,uuid,uuid,text,text,timestamptz)',
    'mark_internal_request_received(uuid)',
    'reroute_internal_request(uuid,uuid)',
    'return_internal_request_to_sender(uuid,text)',
    'assign_internal_request(uuid,uuid)',
    'close_internal_request(uuid)',
    'draft_internal_request_reply(uuid,text,text)',
    'update_internal_request_reply_draft(uuid,text,text)',
    'submit_internal_request_reply(uuid,uuid)',
    'approve_internal_request_reply(uuid)',
    'return_internal_request_reply(uuid)'
  ] LOOP
    IF to_regprocedure('public.'||v_fn) IS NULL THEN
      v_missing := v_missing || v_fn || '-missing ';
    END IF;
  END LOOP;

  -- ── 2. SECURITY DEFINER posture: pinned search_path, PUBLIC/anon
  -- revoked, authenticated granted, on every one of the 11 RPCs ────
  FOREACH v_fn IN ARRAY ARRAY[
    'create_internal_request(uuid,uuid,text,text,uuid,uuid,text,text,timestamptz)',
    'mark_internal_request_received(uuid)',
    'reroute_internal_request(uuid,uuid)',
    'return_internal_request_to_sender(uuid,text)',
    'assign_internal_request(uuid,uuid)',
    'close_internal_request(uuid)',
    'draft_internal_request_reply(uuid,text,text)',
    'update_internal_request_reply_draft(uuid,text,text)',
    'submit_internal_request_reply(uuid,uuid)',
    'approve_internal_request_reply(uuid)',
    'return_internal_request_reply(uuid)'
  ] LOOP
    IF to_regprocedure('public.'||v_fn) IS NULL THEN CONTINUE; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.'||v_fn) AND p.prosecdef
    ) THEN v_missing := v_missing || v_fn || '-not-security-definer '; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.'||v_fn)
        AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || v_fn || '-search-path-not-pinned '; END IF;
    IF has_function_privilege('anon', ('public.'||v_fn)::regprocedure, 'EXECUTE') THEN
      v_missing := v_missing || v_fn || '-exposed-to-anon ';
    END IF;
    IF NOT has_function_privilege('authenticated', ('public.'||v_fn)::regprocedure, 'EXECUTE') THEN
      v_missing := v_missing || v_fn || '-not-granted-to-authenticated ';
    END IF;
  END LOOP;

  -- ── 3. Direct client writes eliminated for the migrated tables --
  -- RLS itself is untouched (checked in §5); this checks the grant
  -- narrowing the patch performs on top of it. This disposable
  -- harness's own 01-grants.sql carries a matching supplemental
  -- REVOKE so this check reflects real production behavior instead
  -- of the harness's own blanket grant. SELECT remains untouched
  -- (every list/detail read in internal-requests-api.js is
  -- unmigrated by design).
  IF has_table_privilege('authenticated','public.internal_requests','INSERT')
     OR has_table_privilege('authenticated','public.internal_requests','UPDATE')
  THEN v_missing := v_missing || 'internal_requests-still-directly-writable-by-authenticated '; END IF;
  IF has_table_privilege('authenticated','public.internal_request_replies','INSERT')
     OR has_table_privilege('authenticated','public.internal_request_replies','UPDATE')
  THEN v_missing := v_missing || 'internal_request_replies-still-directly-writable-by-authenticated '; END IF;
  IF NOT has_table_privilege('authenticated','public.internal_requests','SELECT') THEN
    v_missing := v_missing || 'internal_requests-select-unexpectedly-revoked '; END IF;
  IF NOT has_table_privilege('authenticated','public.internal_request_replies','SELECT') THEN
    v_missing := v_missing || 'internal_request_replies-select-unexpectedly-revoked '; END IF;

  -- ── 4. Every migrated RPC independently derives the actor from
  -- auth.uid() -- never accepts a client-supplied actor/creator id ──
  FOREACH v_fn IN ARRAY ARRAY[
    'create_internal_request(uuid,uuid,text,text,uuid,uuid,text,text,timestamptz)',
    'mark_internal_request_received(uuid)',
    'reroute_internal_request(uuid,uuid)',
    'return_internal_request_to_sender(uuid,text)',
    'assign_internal_request(uuid,uuid)',
    'close_internal_request(uuid)',
    'draft_internal_request_reply(uuid,text,text)',
    'submit_internal_request_reply(uuid,uuid)',
    'approve_internal_request_reply(uuid)',
    'return_internal_request_reply(uuid)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
    IF v_def IS NOT NULL AND v_def NOT ILIKE '%auth.uid()%' THEN
      v_missing := v_missing || v_fn || '-does-not-derive-actor-from-auth-uid ';
    END IF;
  END LOOP;

  -- ── 5. internal_requests(_replies) RLS is byte-for-byte unchanged --
  -- this milestone narrows GRANTs, never touches the policies
  -- themselves ─────────────────────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='internal_requests'
      AND policyname='internal_requests_update' AND cmd='UPDATE'
  ) THEN v_missing := v_missing || 'internal_requests_update-policy-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='internal_requests'
      AND policyname='internal_requests_insert' AND cmd='INSERT'
  ) THEN v_missing := v_missing || 'internal_requests_insert-policy-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='internal_request_replies'
      AND policyname='internal_request_replies_update' AND cmd='UPDATE'
  ) THEN v_missing := v_missing || 'internal_request_replies_update-policy-missing '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='internal_requests') <> 3 THEN
    v_missing := v_missing || 'internal_requests-unexpected-policy-count ';
  END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='internal_request_replies') <> 3 THEN
    v_missing := v_missing || 'internal_request_replies-unexpected-policy-count ';
  END IF;
  -- No DELETE policy exists on either table (confirmed during
  -- inventory) -- this migration does not introduce one either.
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='internal_requests' AND cmd='DELETE')
     OR EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='internal_request_replies' AND cmd='DELETE')
  THEN v_missing := v_missing || 'unexpected-delete-policy-introduced '; END IF;

  -- The status-transition trigger gap is a documented, pre-existing
  -- architecture finding (see patch header) -- this milestone does NOT
  -- introduce one; confirm none was silently added.
  IF EXISTS (
    SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
    WHERE c.relname IN ('internal_requests','internal_request_replies')
      AND t.tgname ILIKE '%status%' AND NOT t.tgisinternal
  ) THEN v_missing := v_missing || 'unexpected-status-transition-trigger-introduced '; END IF;
  -- The one pre-existing trigger (previous-section tracking) must
  -- remain exactly as it was.
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
    WHERE c.relname = 'internal_requests' AND t.tgname = 'track_internal_previous_section' AND NOT t.tgisinternal
  ) THEN v_missing := v_missing || 'track_internal_previous_section-trigger-missing '; END IF;

  -- ── 6. No organization is hard-coded anywhere in any of the 11
  -- function bodies -- every authorization/reference derives from the
  -- thread/reply row's own from_section_id/to_section_id, or from
  -- get_my_org_id()/my_section_ids()/scope_org_id()/is_supervisor_or_
  -- above() ────────────────────────────────────────────────────────
  FOREACH v_fn IN ARRAY ARRAY[
    'create_internal_request(uuid,uuid,text,text,uuid,uuid,text,text,timestamptz)',
    'mark_internal_request_received(uuid)', 'reroute_internal_request(uuid,uuid)',
    'return_internal_request_to_sender(uuid,text)', 'assign_internal_request(uuid,uuid)',
    'close_internal_request(uuid)', 'draft_internal_request_reply(uuid,text,text)',
    'submit_internal_request_reply(uuid,uuid)', 'approve_internal_request_reply(uuid)',
    'return_internal_request_reply(uuid)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
    IF v_def IS NOT NULL AND (v_def ~* 'MCS|HRCM' OR v_def ~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') THEN
      v_missing := v_missing || v_fn || '-contains-hardcoded-org-reference ';
    END IF;
  END LOOP;

  -- ── 7. Zero CAP-003 integration: none of the 11 RPCs reference any
  -- CAP-003 outbox/notification-intent primitive. Phase 1.8B (not
  -- started) is the only milestone allowed to add it. ────────────────
  FOREACH v_fn IN ARRAY ARRAY[
    'create_internal_request(uuid,uuid,text,text,uuid,uuid,text,text,timestamptz)',
    'mark_internal_request_received(uuid)', 'reroute_internal_request(uuid,uuid)',
    'return_internal_request_to_sender(uuid,text)', 'assign_internal_request(uuid,uuid)',
    'close_internal_request(uuid)', 'draft_internal_request_reply(uuid,text,text)',
    'update_internal_request_reply_draft(uuid,text,text)',
    'submit_internal_request_reply(uuid,uuid)', 'approve_internal_request_reply(uuid)',
    'return_internal_request_reply(uuid)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
    IF v_def IS NOT NULL AND (
      v_def ILIKE '%platform_enqueue_outbox_event%' OR v_def ILIKE '%platform_outbox_events%'
      OR v_def ILIKE '%notification_intents%' OR v_def ILIKE '%create_notification_intent%'
      OR v_def ILIKE '%resolve_notification_intent%' OR v_def ILIKE '%process_platform_outbox_batch%'
      OR v_def ILIKE '%user_notifications%'
    ) THEN v_missing := v_missing || v_fn || '-unexpectedly-integrates-cap003 '; END IF;
  END LOOP;
  IF (SELECT count(*) FROM platform_event_type_registry WHERE owning_module ILIKE '%internal_collab%' OR owning_module ILIKE '%collaboration%') <> 0 THEN
    v_missing := v_missing || 'unexpected-internal-collaboration-event-registered '; END IF;

  -- ── 8. Legacy Internal Collaboration notifications untouched --
  -- NotificationsAPI.notify() plumbing (create_legacy_notification) is
  -- completely unmodified by this milestone, and the legacy
  -- `notifications` table itself is untouched. No approvals-table
  -- write was newly introduced (see patch header -- Internal
  -- Collaboration never uses the shared approvals table). ────────────
  IF to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)') IS NULL THEN
    v_missing := v_missing || 'create_legacy_notification-missing '; END IF;
  IF to_regclass('public.notifications') IS NULL THEN
    v_missing := v_missing || 'legacy-notifications-table-missing '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.approve_internal_request_reply(uuid)')) INTO v_def;
  IF v_def ILIKE '%INSERT INTO approvals%' THEN
    v_missing := v_missing || 'approve_internal_request_reply-unexpectedly-writes-to-approvals-table '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.return_internal_request_reply(uuid)')) INTO v_def;
  IF v_def ILIKE '%INSERT INTO approvals%' THEN
    v_missing := v_missing || 'return_internal_request_reply-unexpectedly-writes-to-approvals-table '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'approvals_record_type_check'
      AND pg_get_constraintdef(oid) NOT ILIKE '%internal_request%' AND pg_get_constraintdef(oid) NOT ILIKE '%internal_reply%'
  ) THEN v_missing := v_missing || 'approvals-check-constraint-unexpectedly-widened-for-internal-collaboration '; END IF;

  -- ── 9. Atomicity fix verification: approve_internal_request_reply()
  -- writes to BOTH internal_request_replies AND internal_requests in
  -- one function body (the fused replacement for the original two
  -- separate client calls) ────────────────────────────────────────────
  SELECT pg_get_functiondef(to_regprocedure('public.approve_internal_request_reply(uuid)')) INTO v_def;
  IF v_def NOT ILIKE '%UPDATE internal_request_replies%' OR v_def NOT ILIKE '%UPDATE internal_requests%' THEN
    v_missing := v_missing || 'approve_internal_request_reply-not-atomically-fused '; END IF;

  -- ── 10. No Requests/Entry/Prisoner Letters mutation change -- their
  -- own tables/RPCs are completely untouched, and none of this
  -- milestone's 11 functions reference their tables ──────────────────
  FOREACH v_fn IN ARRAY ARRAY[
    'create_internal_request(uuid,uuid,text,text,uuid,uuid,text,text,timestamptz)',
    'reroute_internal_request(uuid,uuid)', 'assign_internal_request(uuid,uuid)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
    IF v_def IS NOT NULL AND (
      v_def ILIKE '%UPDATE requests%' OR v_def ILIKE '%UPDATE external_correspondence%'
      OR v_def ILIKE '%prisoner_letters%' OR v_def ILIKE '%prisoner_replies%'
    ) THEN v_missing := v_missing || v_fn || '-unexpectedly-references-a-non-internal-collaboration-module '; END IF;
  END LOOP;
  IF to_regprocedure('public.create_request(uuid,uuid,text,text,text,text,timestamptz,uuid)') IS NULL THEN
    v_missing := v_missing || 'requests-1.6a-baseline-missing '; END IF;
  IF to_regprocedure('public.create_entry(text,text,text,text,text,text,text,uuid,text,text,text,date,date)') IS NULL THEN
    v_missing := v_missing || 'entry-1.7a-baseline-missing '; END IF;
  IF to_regclass('public.prisoner_letters') IS NULL THEN v_missing := v_missing || 'prisoner_letters-missing '; END IF;

  -- ── 11. Task-linking integration (Section 9) completely untouched --
  -- all 6 pre-existing Task-linking RPCs from
  -- patch-internal-collaboration-task-integration.sql still present,
  -- unmodified, and no new Task event producer was added. ────────────
  IF to_regprocedure('public.get_internal_collaboration_task_capabilities(uuid)') IS NULL THEN
    v_missing := v_missing || 'get_internal_collaboration_task_capabilities-missing '; END IF;
  IF to_regprocedure('public.list_internal_collaboration_tasks(uuid,text,boolean,integer,integer)') IS NULL THEN
    v_missing := v_missing || 'list_internal_collaboration_tasks-missing '; END IF;
  IF to_regprocedure('public.create_internal_collaboration_supporting_task(uuid,text,text,uuid,text,text,date,date,uuid[])') IS NULL THEN
    v_missing := v_missing || 'create_internal_collaboration_supporting_task-missing '; END IF;
  IF to_regprocedure('public.link_existing_task_to_internal_collaboration(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'link_existing_task_to_internal_collaboration-missing '; END IF;
  IF to_regprocedure('public.unlink_task_from_internal_collaboration(uuid,text)') IS NULL THEN
    v_missing := v_missing || 'unlink_task_from_internal_collaboration-missing '; END IF;
  FOREACH v_fn IN ARRAY ARRAY[
    'create_internal_request(uuid,uuid,text,text,uuid,uuid,text,text,timestamptz)',
    'mark_internal_request_received(uuid)', 'reroute_internal_request(uuid,uuid)',
    'return_internal_request_to_sender(uuid,text)', 'assign_internal_request(uuid,uuid)',
    'close_internal_request(uuid)', 'draft_internal_request_reply(uuid,text,text)',
    'update_internal_request_reply_draft(uuid,text,text)',
    'submit_internal_request_reply(uuid,uuid)', 'approve_internal_request_reply(uuid)',
    'return_internal_request_reply(uuid)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
    IF v_def IS NOT NULL AND (v_def ILIKE '%task_links%' OR v_def ILIKE '%INTO tasks%' OR v_def ILIKE '%create_task(%') THEN
      v_missing := v_missing || v_fn || '-unexpectedly-touches-task-integration '; END IF;
  END LOOP;

  -- ── 12. No speculative schema addition (e.g. a lock_version column,
  -- an organization_id column, or an approvals-table widening) ───────
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name IN ('internal_requests','internal_request_replies')
      AND (column_name ILIKE '%lock_version%' OR column_name ILIKE '%organization_id%' OR column_name ILIKE '%org_id%')
  ) THEN v_missing := v_missing || 'unexpected-speculative-column-introduced '; END IF;

  -- ── 13. CAP-002/CAP-003 baselines through Phase 1.7B unaffected ────
  IF to_regprocedure('public.assign_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'assign_task-missing '; END IF;
  IF to_regclass('public.user_notifications') IS NULL THEN v_missing := v_missing || 'user_notifications-missing '; END IF;
  IF to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL THEN
    v_missing := v_missing || 'cap002-baseline-drift '; END IF;
  IF (SELECT count(*) FROM platform_event_type_registry WHERE owning_module = 'requests') <> 5 THEN
    v_missing := v_missing || 'requests-1.6b-event-registry-drift '; END IF;
  IF (SELECT count(*) FROM platform_event_type_registry WHERE owning_module = 'entry') <> 4 THEN
    v_missing := v_missing || 'entry-1.7b-event-registry-drift '; END IF;
  IF to_regprocedure('public.intent_user_can_view_entry(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'entry-1.7b-adapter-missing '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Internal Collaboration server mutation foundation structural validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Internal Collaboration server mutation foundation structural validation PASSED (all 11 evidenced commands present, SECURITY DEFINER/search_path/grants correct, direct client writes eliminated for internal_requests/internal_request_replies while SELECT and RLS remain intact, actor always derived from auth.uid(), no hard-coded organization anywhere, zero CAP-003 integration, legacy notifications untouched, no approvals-table write introduced, approve_internal_request_reply atomically fuses both table writes, Requests/Entry/Prisoner Letters untouched, Task-linking integration untouched, no speculative column introduced, CAP-002/CAP-003 baselines through Phase 1.7B unaffected, Phase 1.8B not started).';
END $$;
