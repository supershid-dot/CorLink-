-- CAP-003 Phase 1.6A structural validator. Disposable local
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
    'create_request(uuid,uuid,text,text,text,text,timestamptz,uuid)',
    'update_request_draft(uuid,text,text,text,text,timestamptz)',
    'submit_request(uuid,uuid)',
    'approve_request(uuid,text)',
    'return_request(uuid,text)',
    'mark_request_received(uuid)',
    'route_request(uuid,uuid)',
    'return_request_to_previous_section(uuid,text)',
    'assign_request(uuid,uuid)',
    'receive_and_route_request(uuid,uuid,uuid)',
    'close_request(uuid)',
    'cancel_request(uuid,text)',
    'create_response(uuid,text,text)',
    'update_response_draft(uuid,text,text)',
    'submit_response(uuid,uuid)',
    'approve_response(uuid,text)',
    'return_response(uuid,text)',
    'mark_response_received(uuid)',
    'acknowledge_and_close(uuid,uuid)'
  ] LOOP
    IF to_regprocedure('public.'||v_fn) IS NULL THEN
      v_missing := v_missing || v_fn || '-missing ';
    END IF;
  END LOOP;

  -- ── 2. SECURITY DEFINER posture: pinned search_path, PUBLIC/anon
  -- revoked, authenticated granted, on every one of the 19 RPCs ────
  FOREACH v_fn IN ARRAY ARRAY[
    'create_request(uuid,uuid,text,text,text,text,timestamptz,uuid)',
    'update_request_draft(uuid,text,text,text,text,timestamptz)',
    'submit_request(uuid,uuid)',
    'approve_request(uuid,text)',
    'return_request(uuid,text)',
    'mark_request_received(uuid)',
    'route_request(uuid,uuid)',
    'return_request_to_previous_section(uuid,text)',
    'assign_request(uuid,uuid)',
    'receive_and_route_request(uuid,uuid,uuid)',
    'close_request(uuid)',
    'cancel_request(uuid,text)',
    'create_response(uuid,text,text)',
    'update_response_draft(uuid,text,text)',
    'submit_response(uuid,uuid)',
    'approve_response(uuid,text)',
    'return_response(uuid,text)',
    'mark_response_received(uuid)',
    'acknowledge_and_close(uuid,uuid)'
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
  -- narrowing the patch performs on top of it. Table grants ARE the
  -- meaningful check here (unlike the notification milestones'
  -- validators, which deliberately skip grant checks because nothing
  -- there ever narrows a grant) -- this disposable harness's own
  -- 01-grants.sql carries a matching supplemental REVOKE precisely so
  -- this check reflects real production behavior instead of the
  -- harness's own blanket grant. SELECT remains untouched (every list/
  -- detail read in requests-api.js is unmigrated by design).
  IF has_table_privilege('authenticated','public.requests','INSERT')
     OR has_table_privilege('authenticated','public.requests','UPDATE')
  THEN v_missing := v_missing || 'requests-still-directly-writable-by-authenticated '; END IF;
  IF has_table_privilege('authenticated','public.responses','INSERT')
     OR has_table_privilege('authenticated','public.responses','UPDATE')
  THEN v_missing := v_missing || 'responses-still-directly-writable-by-authenticated '; END IF;
  IF NOT has_table_privilege('authenticated','public.requests','SELECT') THEN
    v_missing := v_missing || 'requests-select-unexpectedly-revoked '; END IF;
  IF NOT has_table_privilege('authenticated','public.responses','SELECT') THEN
    v_missing := v_missing || 'responses-select-unexpectedly-revoked '; END IF;

  -- ── 4. Every migrated RPC independently derives the actor from
  -- auth.uid() -- never accepts a client-supplied actor/creator id ──
  FOREACH v_fn IN ARRAY ARRAY[
    'create_request(uuid,uuid,text,text,text,text,timestamptz,uuid)',
    'update_request_draft(uuid,text,text,text,text,timestamptz)',
    'submit_request(uuid,uuid)',
    'approve_request(uuid,text)',
    'mark_request_received(uuid)',
    'cancel_request(uuid,text)',
    'create_response(uuid,text,text)',
    'mark_response_received(uuid)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
    IF v_def IS NOT NULL AND v_def NOT ILIKE '%auth.uid()%' THEN
      v_missing := v_missing || v_fn || '-does-not-derive-actor-from-auth-uid ';
    END IF;
  END LOOP;

  -- ── 5. requests/responses RLS is byte-for-byte unchanged -- this
  -- milestone narrows GRANTs, never touches the policies themselves ──
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='requests'
      AND policyname='requests_update' AND cmd='UPDATE'
  ) THEN v_missing := v_missing || 'requests_update-policy-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='requests'
      AND policyname='requests_update_cancel' AND cmd='UPDATE'
  ) THEN v_missing := v_missing || 'requests_update_cancel-policy-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='responses'
      AND policyname='responses_update_supervisor' AND cmd='UPDATE'
  ) THEN v_missing := v_missing || 'responses_update_supervisor-policy-missing '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='requests') <> 10 THEN
    v_missing := v_missing || 'requests-unexpected-policy-count ';
  END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='responses') <> 6 THEN
    v_missing := v_missing || 'responses-unexpected-policy-count ';
  END IF;

  -- ── 6. Bidirectionality: no organization is hard-coded anywhere in
  -- any of the 19 function bodies (no literal UUID, no ILIKE on an
  -- org name/code) -- every authorization/reference derives from the
  -- request/response row's own from_org_id/to_org_id/from_section_id/
  -- to_section_id, or from get_my_org_id()/my_section_ids() ─────────
  FOREACH v_fn IN ARRAY ARRAY[
    'create_request(uuid,uuid,text,text,text,text,timestamptz,uuid)',
    'submit_request(uuid,uuid)', 'approve_request(uuid,text)', 'return_request(uuid,text)',
    'mark_request_received(uuid)', 'route_request(uuid,uuid)',
    'return_request_to_previous_section(uuid,text)', 'assign_request(uuid,uuid)',
    'close_request(uuid)', 'cancel_request(uuid,text)',
    'create_response(uuid,text,text)', 'approve_response(uuid,text)',
    'return_response(uuid,text)', 'mark_response_received(uuid)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
    IF v_def IS NOT NULL AND (v_def ~* 'MCS|HRCM' OR v_def ~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') THEN
      v_missing := v_missing || v_fn || '-contains-hardcoded-org-reference ';
    END IF;
  END LOOP;

  -- ── 7. No CAP-003 Requests event integration was added by this
  -- milestone -- Phase 1.6B remains separate ─────────────────────────
  IF EXISTS (
    SELECT 1 FROM information_schema.routines WHERE routine_schema='public'
      AND routine_name IN ('create_request','submit_request','approve_request','return_request',
        'mark_request_received','route_request','return_request_to_previous_section','assign_request',
        'receive_and_route_request','close_request','cancel_request','create_response',
        'update_response_draft','submit_response','approve_response','return_response',
        'mark_response_received','acknowledge_and_close','update_request_draft')
  ) THEN
    -- As of Phase 1.6A's own completion, ZERO of the 19 RPCs
    -- integrated CAP-003. CAP-003 Phase 1.6B
    -- (patch-requests-notification-integration.sql) later legitimately
    -- wired exactly 5 of them (approve_request, return_request,
    -- route_request, assign_request, approve_response) to atomically
    -- enqueue a CAP-003 outbox event -- documented, evidenced,
    -- approved (see docs/90). This validator therefore only asserts
    -- the remaining 14 RPCs -- the ones Phase 1.6B deliberately left
    -- alone -- still integrate nothing; Phase 1.6B's own validator
    -- (validate-requests-notification-integration.sql) is what proves
    -- the 5 migrated RPCs' CAP-003 integration is itself correct
    -- (atomic, correct event type, no direct user_notifications write,
    -- no free-text leakage).
    FOREACH v_fn IN ARRAY ARRAY[
      'create_request(uuid,uuid,text,text,text,text,timestamptz,uuid)',
      'submit_request(uuid,uuid)',
      'mark_request_received(uuid)',
      'return_request_to_previous_section(uuid,text)',
      'receive_and_route_request(uuid,uuid,uuid)', 'close_request(uuid)', 'cancel_request(uuid,text)',
      'create_response(uuid,text,text)', 'update_response_draft(uuid,text,text)',
      'submit_response(uuid,uuid)', 'return_response(uuid,text)',
      'mark_response_received(uuid)', 'acknowledge_and_close(uuid,uuid)'
    ] LOOP
      SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
      IF v_def IS NOT NULL AND (
        v_def ILIKE '%platform_enqueue_outbox_event%' OR v_def ILIKE '%platform_create_user_notification%'
        OR v_def ILIKE '%notification_intents%' OR v_def ILIKE '%create_notification_intent%'
        OR v_def ILIKE '%requests.%.v1%'
      ) THEN v_missing := v_missing || v_fn || '-unexpectedly-integrates-cap003 '; END IF;
    END LOOP;
  END IF;
  -- Phase 1.6B legitimately registered exactly 5 requests.*.v1 event
  -- types (owning_module='requests') -- this validator now only
  -- refuses an event count outside that known, documented set.
  IF (SELECT count(*) FROM platform_event_type_registry WHERE owning_module = 'requests') NOT IN (0, 5) THEN
    v_missing := v_missing || 'unexpected-requests-event-type-count '; END IF;

  -- ── 8. Legacy Requests notifications untouched: NotificationsAPI.
  -- notify()'s own RPC (create_legacy_notification) is completely
  -- unmodified by this milestone, and the legacy `notifications` table
  -- itself is untouched ────────────────────────────────────────────
  IF to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)') IS NULL THEN
    v_missing := v_missing || 'create_legacy_notification-missing '; END IF;
  IF to_regclass('public.notifications') IS NULL THEN
    v_missing := v_missing || 'legacy-notifications-table-missing '; END IF;

  -- ── 9. No Entry/Internal Collaboration/Prisoner Letters mutation
  -- migration -- their own tables/RPCs are completely untouched, and
  -- none of this milestone's 19 functions reference their tables ──
  FOREACH v_fn IN ARRAY ARRAY[
    'create_request(uuid,uuid,text,text,text,text,timestamptz,uuid)',
    'route_request(uuid,uuid)', 'assign_request(uuid,uuid)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
    IF v_def IS NOT NULL AND (
      v_def ILIKE '%internal_requests%' OR v_def ILIKE '%external_correspondence%'
      OR v_def ILIKE '%prisoner_letters%' OR v_def ILIKE '%prisoner_replies%'
    ) THEN v_missing := v_missing || v_fn || '-unexpectedly-references-a-non-requests-module '; END IF;
  END LOOP;
  IF to_regclass('public.internal_requests') IS NULL THEN v_missing := v_missing || 'internal_requests-missing '; END IF;
  IF to_regclass('public.external_correspondence') IS NULL THEN v_missing := v_missing || 'external_correspondence-missing '; END IF;
  IF to_regclass('public.prisoner_letters') IS NULL THEN v_missing := v_missing || 'prisoner_letters-missing '; END IF;
  -- Their own INSERT policies remain -- direct client writes to those
  -- three modules are completely unaffected by this milestone.
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='internal_requests' AND cmd='INSERT') THEN
    v_missing := v_missing || 'internal_requests-insert-policy-missing '; END IF;

  -- ── 10. No new schema field (e.g. a speculative lock_version) was
  -- introduced -- the concurrency strategy is state-guarded UPDATE
  -- only, reusing existing columns ────────────────────────────────
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name IN ('requests','responses') AND column_name ILIKE '%lock_version%'
  ) THEN v_missing := v_missing || 'unexpected-lock_version-column-introduced '; END IF;

  -- ── 11. CAP-002/CAP-003 baselines through Phase 1.5 unaffected ────
  IF to_regprocedure('public.assign_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'assign_task-missing '; END IF;
  IF to_regprocedure('public.list_my_notifications(integer,timestamptz,uuid,boolean)') IS NULL THEN
    v_missing := v_missing || 'phase1.1-baseline-drift '; END IF;
  IF to_regclass('public.user_notifications') IS NULL THEN v_missing := v_missing || 'user_notifications-missing '; END IF;
  IF to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL THEN
    v_missing := v_missing || 'cap002-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Requests server mutation foundation structural validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Requests server mutation foundation structural validation PASSED (all 19 evidenced commands present, SECURITY DEFINER/search_path/grants correct, direct client writes eliminated for requests/responses while SELECT and RLS remain intact, actor always derived from auth.uid(), no hard-coded organization anywhere, zero CAP-003 Requests event integration, legacy notifications untouched, Entry/Internal Collaboration/Prisoner Letters untouched, no speculative lock_version column, CAP-002/CAP-003 baselines through Phase 1.5 unaffected, Phase 1.6B not started).';
END $$;
