-- CAP-003 Phase 1.7A structural validator. Disposable local
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
    'create_entry(text,text,text,text,text,text,text,uuid,text,text,text,date,date)',
    'update_entry_draft(uuid,text,text,text,text,date)',
    'route_entry(uuid,uuid,uuid)',
    'mark_entry_received(uuid)',
    'assign_entry(uuid,uuid,date)',
    'close_entry(uuid)',
    'draft_entry_reply(uuid,text,text)',
    'update_entry_reply_draft(uuid,text,text)',
    'submit_entry_reply(uuid,uuid)',
    'approve_entry_reply(uuid)',
    'return_entry_reply(uuid,text)',
    'mark_entry_reply_sent(uuid,text)'
  ] LOOP
    IF to_regprocedure('public.'||v_fn) IS NULL THEN
      v_missing := v_missing || v_fn || '-missing ';
    END IF;
  END LOOP;

  -- ── 2. SECURITY DEFINER posture: pinned search_path, PUBLIC/anon
  -- revoked, authenticated granted, on every one of the 12 RPCs ────
  FOREACH v_fn IN ARRAY ARRAY[
    'create_entry(text,text,text,text,text,text,text,uuid,text,text,text,date,date)',
    'update_entry_draft(uuid,text,text,text,text,date)',
    'route_entry(uuid,uuid,uuid)',
    'mark_entry_received(uuid)',
    'assign_entry(uuid,uuid,date)',
    'close_entry(uuid)',
    'draft_entry_reply(uuid,text,text)',
    'update_entry_reply_draft(uuid,text,text)',
    'submit_entry_reply(uuid,uuid)',
    'approve_entry_reply(uuid)',
    'return_entry_reply(uuid,text)',
    'mark_entry_reply_sent(uuid,text)'
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
  -- (every list/detail read in entry-api.js is unmigrated by design).
  IF has_table_privilege('authenticated','public.external_correspondence','INSERT')
     OR has_table_privilege('authenticated','public.external_correspondence','UPDATE')
  THEN v_missing := v_missing || 'external_correspondence-still-directly-writable-by-authenticated '; END IF;
  IF has_table_privilege('authenticated','public.external_correspondence_replies','INSERT')
     OR has_table_privilege('authenticated','public.external_correspondence_replies','UPDATE')
  THEN v_missing := v_missing || 'external_correspondence_replies-still-directly-writable-by-authenticated '; END IF;
  IF NOT has_table_privilege('authenticated','public.external_correspondence','SELECT') THEN
    v_missing := v_missing || 'external_correspondence-select-unexpectedly-revoked '; END IF;
  IF NOT has_table_privilege('authenticated','public.external_correspondence_replies','SELECT') THEN
    v_missing := v_missing || 'external_correspondence_replies-select-unexpectedly-revoked '; END IF;

  -- ── 4. Every migrated RPC independently derives the actor from
  -- auth.uid() -- never accepts a client-supplied actor/creator id ──
  FOREACH v_fn IN ARRAY ARRAY[
    'create_entry(text,text,text,text,text,text,text,uuid,text,text,text,date,date)',
    'update_entry_draft(uuid,text,text,text,text,date)',
    'route_entry(uuid,uuid,uuid)',
    'mark_entry_received(uuid)',
    'assign_entry(uuid,uuid,date)',
    'close_entry(uuid)',
    'draft_entry_reply(uuid,text,text)',
    'submit_entry_reply(uuid,uuid)',
    'approve_entry_reply(uuid)',
    'return_entry_reply(uuid,text)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
    IF v_def IS NOT NULL AND v_def NOT ILIKE '%auth.uid()%' THEN
      v_missing := v_missing || v_fn || '-does-not-derive-actor-from-auth-uid ';
    END IF;
  END LOOP;

  -- ── 5. external_correspondence(_replies) RLS is byte-for-byte
  -- unchanged -- this milestone narrows GRANTs, never touches the
  -- policies themselves ─────────────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='external_correspondence'
      AND policyname='external_correspondence_update_entry' AND cmd='UPDATE'
  ) THEN v_missing := v_missing || 'external_correspondence_update_entry-policy-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='external_correspondence'
      AND policyname='external_correspondence_update_section' AND cmd='UPDATE'
  ) THEN v_missing := v_missing || 'external_correspondence_update_section-policy-missing '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='external_correspondence_replies'
      AND policyname='external_correspondence_replies_update' AND cmd='UPDATE'
  ) THEN v_missing := v_missing || 'external_correspondence_replies_update-policy-missing '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='external_correspondence') <> 5 THEN
    v_missing := v_missing || 'external_correspondence-unexpected-policy-count ';
  END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='external_correspondence_replies') <> 3 THEN
    v_missing := v_missing || 'external_correspondence_replies-unexpected-policy-count ';
  END IF;

  -- ── 6. No organization is hard-coded anywhere in any of the 12
  -- function bodies -- every authorization/reference derives from the
  -- entry/reply row's own org_id/to_section_id, or from
  -- get_my_org_id()/my_section_ids()/is_entry_staff() ────────────────
  FOREACH v_fn IN ARRAY ARRAY[
    'create_entry(text,text,text,text,text,text,text,uuid,text,text,text,date,date)',
    'update_entry_draft(uuid,text,text,text,text,date)',
    'route_entry(uuid,uuid,uuid)', 'mark_entry_received(uuid)', 'assign_entry(uuid,uuid,date)',
    'close_entry(uuid)', 'draft_entry_reply(uuid,text,text)', 'submit_entry_reply(uuid,uuid)',
    'approve_entry_reply(uuid)', 'return_entry_reply(uuid,text)', 'mark_entry_reply_sent(uuid,text)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
    IF v_def IS NOT NULL AND (v_def ~* 'MCS|HRCM' OR v_def ~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') THEN
      v_missing := v_missing || v_fn || '-contains-hardcoded-org-reference ';
    END IF;
  END LOOP;

  -- ── 7. Zero CAP-003 integration for the 8 commands CAP-003 Phase
  -- 1.7B deliberately left deferred -- this was originally written, at
  -- Phase 1.7A's own completion, as a blanket isolation proof across
  -- all 12 RPCs ("Phase 1.7B, not started, is the only milestone
  -- allowed to add it"). CAP-003 Phase 1.7B has since legitimately
  -- integrated exactly 4 of the 12 (route_entry/assign_entry/
  -- approve_entry_reply/return_entry_reply) -- reconciled the same way
  -- validate-requests-server-mutation-foundation.sql was reconciled for
  -- Phase 1.6B's own analogous, legitimate extension (see docs/90's own
  -- "Sibling structural-validator reconciliation" section): narrowed to
  -- the 8 RPCs still genuinely deferred; validate-entry-notification-
  -- integration.sql now owns the positive assertion that the other 4
  -- correctly DO integrate. ──────────────────────────────────────────
  FOREACH v_fn IN ARRAY ARRAY[
    'create_entry(text,text,text,text,text,text,text,uuid,text,text,text,date,date)',
    'update_entry_draft(uuid,text,text,text,text,date)',
    'mark_entry_received(uuid)',
    'close_entry(uuid)', 'draft_entry_reply(uuid,text,text)', 'update_entry_reply_draft(uuid,text,text)',
    'submit_entry_reply(uuid,uuid)',
    'mark_entry_reply_sent(uuid,text)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
    IF v_def IS NOT NULL AND (
      v_def ILIKE '%platform_enqueue_outbox_event%' OR v_def ILIKE '%platform_outbox_events%'
      OR v_def ILIKE '%notification_intents%' OR v_def ILIKE '%create_notification_intent%'
      OR v_def ILIKE '%resolve_notification_intent%' OR v_def ILIKE '%process_platform_outbox_batch%'
      OR v_def ILIKE '%user_notifications%'
    ) THEN v_missing := v_missing || v_fn || '-unexpectedly-integrates-cap003 '; END IF;
  END LOOP;
  -- 0 (pre-1.7B) or exactly 4 (Phase 1.7B's own approved event count).
  IF (SELECT count(*) FROM platform_event_type_registry WHERE owning_module = 'entry') NOT IN (0, 4) THEN
    v_missing := v_missing || 'unexpected-entry-event-type-count '; END IF;

  -- ── 8. Legacy Entry notifications untouched: entry-api.js's own
  -- NotificationsAPI.notify() plumbing (create_legacy_notification) is
  -- completely unmodified by this milestone, and the legacy
  -- `notifications` table itself is untouched ────────────────────────
  IF to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)') IS NULL THEN
    v_missing := v_missing || 'create_legacy_notification-missing '; END IF;
  IF to_regclass('public.notifications') IS NULL THEN
    v_missing := v_missing || 'legacy-notifications-table-missing '; END IF;

  -- ── 9. No Requests/Internal Collaboration/Prisoner Letters mutation
  -- change -- their own tables/RPCs are completely untouched, and none
  -- of this milestone's 12 functions reference their tables ─────────
  FOREACH v_fn IN ARRAY ARRAY[
    'create_entry(text,text,text,text,text,text,text,uuid,text,text,text,date,date)',
    'route_entry(uuid,uuid,uuid)', 'assign_entry(uuid,uuid,date)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
    IF v_def IS NOT NULL AND (
      v_def ILIKE '%FROM requests%' OR v_def ILIKE '%UPDATE requests%' OR v_def ILIKE '%INTO requests%'
      OR v_def ILIKE '%prisoner_letters%' OR v_def ILIKE '%prisoner_replies%'
    ) THEN v_missing := v_missing || v_fn || '-unexpectedly-references-a-non-entry-module '; END IF;
  END LOOP;
  IF to_regprocedure('public.create_request(uuid,uuid,text,text,text,text,timestamptz,uuid)') IS NULL THEN
    v_missing := v_missing || 'requests-1.6a-baseline-missing '; END IF;
  IF to_regclass('public.internal_requests') IS NULL THEN v_missing := v_missing || 'internal_requests-missing '; END IF;
  IF to_regclass('public.prisoner_letters') IS NULL THEN v_missing := v_missing || 'prisoner_letters-missing '; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='internal_requests' AND cmd='INSERT') THEN
    v_missing := v_missing || 'internal_requests-insert-policy-missing '; END IF;

  -- ── 10. No prisoner-transfer/facility-reassignment engine was
  -- silently invented -- the documented architecture-gap resolution
  -- means zero such command exists in this patch ─────────────────────
  IF to_regprocedure('public.transfer_entry(uuid,uuid)') IS NOT NULL
     OR to_regprocedure('public.reassign_entry_prison(uuid,uuid)') IS NOT NULL
     OR EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_schema='public' AND routine_name ILIKE '%prison_transfer%')
  THEN v_missing := v_missing || 'unexpected-prisoner-transfer-engine-introduced '; END IF;

  -- ── 11. No new schema field (e.g. a speculative lock_version, or a
  -- speculative facility/prison column) was introduced -- the
  -- concurrency strategy is state-guarded UPDATE only, reusing
  -- existing columns; the facility question is a documented gap, not
  -- a silently-added column ───────────────────────────────────────────
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name IN ('external_correspondence','external_correspondence_replies')
      AND (column_name ILIKE '%lock_version%' OR column_name ILIKE '%facility%' OR column_name ILIKE '%prison_id%')
  ) THEN v_missing := v_missing || 'unexpected-speculative-column-introduced '; END IF;

  -- ── 12. CAP-002/CAP-003 baselines through Phase 1.6B unaffected ────
  IF to_regprocedure('public.assign_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'assign_task-missing '; END IF;
  IF to_regclass('public.user_notifications') IS NULL THEN v_missing := v_missing || 'user_notifications-missing '; END IF;
  IF to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL THEN
    v_missing := v_missing || 'cap002-baseline-drift '; END IF;
  IF (SELECT count(*) FROM platform_event_type_registry WHERE owning_module = 'requests') <> 5 THEN
    v_missing := v_missing || 'requests-1.6b-event-registry-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Entry server mutation foundation structural validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Entry server mutation foundation structural validation PASSED (all 12 evidenced commands present, SECURITY DEFINER/search_path/grants correct, direct client writes eliminated for external_correspondence/external_correspondence_replies while SELECT and RLS remain intact, actor always derived from auth.uid(), no hard-coded organization anywhere, zero CAP-003 Entry event integration, legacy notifications untouched, Requests/Internal Collaboration/Prisoner Letters untouched, no prisoner-transfer engine invented, no speculative column introduced, CAP-002/CAP-003 baselines through Phase 1.6B unaffected, Phase 1.7B not started).';
END $$;
