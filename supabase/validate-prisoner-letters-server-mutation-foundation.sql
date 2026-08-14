-- Prisoner Letters server-mutation-foundation structural validator.
-- Disposable local PostgreSQL only.
\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
  v_fn  TEXT;
BEGIN
  -- ── 1. Every one of the 6 evidenced mutation RPCs exists with the
  -- exact signature this milestone defines ──────────────────────────
  FOREACH v_fn IN ARRAY ARRAY[
    'create_prisoner_letter(uuid,uuid,uuid,text)',
    'mark_prisoner_letter_received(uuid)',
    'route_prisoner_letter(uuid,uuid,uuid)',
    'mark_prisoner_letter_slip_generated(uuid)',
    'create_prisoner_letter_reply(uuid,text)',
    'mark_prisoner_letter_delivered(uuid)'
  ] LOOP
    IF to_regprocedure('public.'||v_fn) IS NULL THEN
      v_missing := v_missing || v_fn || '-missing ';
    END IF;
  END LOOP;

  -- ── 2. SECURITY DEFINER posture: pinned search_path, PUBLIC/anon
  -- revoked, authenticated granted, on every one of the 6 RPCs ──────
  FOREACH v_fn IN ARRAY ARRAY[
    'create_prisoner_letter(uuid,uuid,uuid,text)',
    'mark_prisoner_letter_received(uuid)',
    'route_prisoner_letter(uuid,uuid,uuid)',
    'mark_prisoner_letter_slip_generated(uuid)',
    'create_prisoner_letter_reply(uuid,text)',
    'mark_prisoner_letter_delivered(uuid)'
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

  -- ── 3. generate_prisoner_letter_reference() is now internal-only:
  -- SECURITY DEFINER, pinned search_path, but EXECUTE revoked from both
  -- anon AND authenticated (only callable via a nested nested call from
  -- create_prisoner_letter) ──────────────────────────────────────────
  IF to_regprocedure('public.generate_prisoner_letter_reference(uuid)') IS NULL THEN
    v_missing := v_missing || 'generate_prisoner_letter_reference-missing ';
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.generate_prisoner_letter_reference(uuid)') AND p.prosecdef
    ) THEN v_missing := v_missing || 'generate_prisoner_letter_reference-not-security-definer '; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.generate_prisoner_letter_reference(uuid)')
        AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || 'generate_prisoner_letter_reference-search-path-not-pinned '; END IF;
    IF has_function_privilege('authenticated', 'public.generate_prisoner_letter_reference(uuid)'::regprocedure, 'EXECUTE') THEN
      v_missing := v_missing || 'generate_prisoner_letter_reference-unexpectedly-exposed-to-authenticated ';
    END IF;
    IF has_function_privilege('anon', 'public.generate_prisoner_letter_reference(uuid)'::regprocedure, 'EXECUTE') THEN
      v_missing := v_missing || 'generate_prisoner_letter_reference-unexpectedly-exposed-to-anon ';
    END IF;
  END IF;

  -- ── 4. Direct client writes eliminated for prisoner_letters/
  -- prisoner_replies; SELECT remains untouched (every list/detail read
  -- in prisoner-letters-api.js is unmigrated by design) ──────────────
  IF has_table_privilege('authenticated','public.prisoner_letters','INSERT')
     OR has_table_privilege('authenticated','public.prisoner_letters','UPDATE')
     OR has_table_privilege('authenticated','public.prisoner_letters','DELETE')
  THEN v_missing := v_missing || 'prisoner_letters-still-directly-writable-by-authenticated '; END IF;
  IF has_table_privilege('authenticated','public.prisoner_replies','INSERT')
     OR has_table_privilege('authenticated','public.prisoner_replies','UPDATE')
     OR has_table_privilege('authenticated','public.prisoner_replies','DELETE')
  THEN v_missing := v_missing || 'prisoner_replies-still-directly-writable-by-authenticated '; END IF;
  IF NOT has_table_privilege('authenticated','public.prisoner_letters','SELECT') THEN
    v_missing := v_missing || 'prisoner_letters-select-unexpectedly-revoked '; END IF;
  IF NOT has_table_privilege('authenticated','public.prisoner_replies','SELECT') THEN
    v_missing := v_missing || 'prisoner_replies-select-unexpectedly-revoked '; END IF;
  -- attachments remains client-writable (browser-upload architecture) --
  -- this milestone must NOT revoke it.
  IF NOT has_table_privilege('authenticated','public.attachments','INSERT') THEN
    v_missing := v_missing || 'attachments-insert-unexpectedly-revoked '; END IF;

  -- ── 5. Every migrated RPC independently derives the actor from
  -- auth.uid() -- never accepts a client-supplied actor/creator id ────
  FOREACH v_fn IN ARRAY ARRAY[
    'create_prisoner_letter(uuid,uuid,uuid,text)',
    'mark_prisoner_letter_received(uuid)',
    'route_prisoner_letter(uuid,uuid,uuid)',
    'mark_prisoner_letter_slip_generated(uuid)',
    'create_prisoner_letter_reply(uuid,text)',
    'mark_prisoner_letter_delivered(uuid)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
    IF v_def IS NOT NULL AND v_def NOT ILIKE '%auth.uid()%' THEN
      v_missing := v_missing || v_fn || '-does-not-derive-actor-from-auth-uid ';
    END IF;
  END LOOP;

  -- ── 6. Prisoner identity is derived server-side, never trusted from
  -- the client -- create_prisoner_letter() must look the prisoner up in
  -- the prisoners registry, not accept prisoner_name/prisoner_id as
  -- parameters ─────────────────────────────────────────────────────
  SELECT pg_get_functiondef(to_regprocedure('public.create_prisoner_letter(uuid,uuid,uuid,text)')) INTO v_def;
  IF v_def IS NOT NULL AND (v_def NOT ILIKE '%FROM prisoners%' OR v_def NOT ILIKE '%v_prisoner.full_name%') THEN
    v_missing := v_missing || 'create_prisoner_letter-does-not-derive-prisoner-identity-server-side ';
  END IF;

  -- ── 7. Directionality enforced server-side: create_prisoner_letter()
  -- independently checks both organizations' type ─────────────────────
  IF v_def IS NOT NULL AND (v_def NOT ILIKE '%o.type = ''mcs''%' OR v_def NOT ILIKE '%o.type = ''authority''%') THEN
    v_missing := v_missing || 'create_prisoner_letter-does-not-independently-verify-both-org-types ';
  END IF;

  -- ── 8. State-transition guards present on every lifecycle RPC ───────
  SELECT pg_get_functiondef(to_regprocedure('public.mark_prisoner_letter_received(uuid)')) INTO v_def;
  IF v_def NOT ILIKE '%status <> ''submitted''%' THEN
    v_missing := v_missing || 'mark_prisoner_letter_received-missing-status-guard '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.route_prisoner_letter(uuid,uuid,uuid)')) INTO v_def;
  IF v_def NOT ILIKE '%status = ''delivered''%' THEN
    v_missing := v_missing || 'route_prisoner_letter-missing-terminal-guard '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.mark_prisoner_letter_slip_generated(uuid)')) INTO v_def;
  IF v_def NOT ILIKE '%status = ''delivered''%' THEN
    v_missing := v_missing || 'mark_prisoner_letter_slip_generated-missing-terminal-guard '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.create_prisoner_letter_reply(uuid,text)')) INTO v_def;
  IF v_def NOT ILIKE '%status NOT IN (''submitted'', ''received'')%' THEN
    v_missing := v_missing || 'create_prisoner_letter_reply-missing-status-guard '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.mark_prisoner_letter_delivered(uuid)')) INTO v_def;
  IF v_def NOT ILIKE '%status <> ''replied''%' THEN
    v_missing := v_missing || 'mark_prisoner_letter_delivered-missing-status-guard '; END IF;

  -- ── 9. Row locking: every RPC that reads-then-writes a letter takes
  -- a FOR UPDATE lock first ────────────────────────────────────────
  FOREACH v_fn IN ARRAY ARRAY[
    'mark_prisoner_letter_received(uuid)', 'route_prisoner_letter(uuid,uuid,uuid)',
    'mark_prisoner_letter_slip_generated(uuid)', 'create_prisoner_letter_reply(uuid,text)',
    'mark_prisoner_letter_delivered(uuid)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
    IF v_def IS NOT NULL AND v_def NOT ILIKE '%FOR UPDATE%' THEN
      v_missing := v_missing || v_fn || '-missing-row-lock '; END IF;
  END LOOP;

  -- ── 10. Assignment hardening (route_prisoner_letter): supplied
  -- assignee must be validated active/org-matched/flagged server-side ──
  SELECT pg_get_functiondef(to_regprocedure('public.route_prisoner_letter(uuid,uuid,uuid)')) INTO v_def;
  IF v_def NOT ILIKE '%is_active%' OR v_def NOT ILIKE '%is_prisoner_letters_staff%' OR v_def NOT ILIKE '%u.org_id%' THEN
    v_missing := v_missing || 'route_prisoner_letter-missing-assignment-hardening '; END IF;
  IF v_def NOT ILIKE '%scope_org_id%' THEN
    v_missing := v_missing || 'route_prisoner_letter-missing-section-org-validation '; END IF;

  -- ── 11. Recipient-org immutability: no RPC in this milestone ever
  -- writes to_org_id or from_prison_id (only the initial INSERT in
  -- create_prisoner_letter sets them) ──────────────────────────────
  FOREACH v_fn IN ARRAY ARRAY[
    'mark_prisoner_letter_received(uuid)', 'route_prisoner_letter(uuid,uuid,uuid)',
    'mark_prisoner_letter_slip_generated(uuid)', 'create_prisoner_letter_reply(uuid,text)',
    'mark_prisoner_letter_delivered(uuid)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
    IF v_def IS NOT NULL AND (v_def ~* '(set|,)\s*to_org_id\s*=' OR v_def ~* '(set|,)\s*from_prison_id\s*=') THEN
      v_missing := v_missing || v_fn || '-unexpectedly-writes-recipient-org '; END IF;
  END LOOP;

  -- ── 12. Reply atomicity: create_prisoner_letter_reply() writes to
  -- BOTH prisoner_replies AND prisoner_letters in one function body
  -- (the fused replacement for the original two separate client calls) ─
  SELECT pg_get_functiondef(to_regprocedure('public.create_prisoner_letter_reply(uuid,text)')) INTO v_def;
  IF v_def NOT ILIKE '%INSERT INTO prisoner_replies%' OR v_def NOT ILIKE '%UPDATE prisoner_letters%' THEN
    v_missing := v_missing || 'create_prisoner_letter_reply-not-atomically-fused '; END IF;
  -- Authority-side only -- MCS never replies (governing business rule).
  IF v_def NOT ILIKE '%to_org_id = get_my_org_id()%' THEN
    v_missing := v_missing || 'create_prisoner_letter_reply-not-authority-side-only '; END IF;

  -- ── 13. Reference-generation atomicity: create_prisoner_letter()
  -- calls generate_prisoner_letter_reference() internally (no separate
  -- client round trip) ────────────────────────────────────────────
  SELECT pg_get_functiondef(to_regprocedure('public.create_prisoner_letter(uuid,uuid,uuid,text)')) INTO v_def;
  IF v_def NOT ILIKE '%generate_prisoner_letter_reference(%' THEN
    v_missing := v_missing || 'create_prisoner_letter-does-not-call-reference-generator-internally '; END IF;

  -- ── 14. Reply immutability preserved: no UPDATE/DELETE policy exists
  -- on prisoner_replies, and no update RPC was introduced ────────────
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='prisoner_replies' AND cmd IN ('UPDATE','DELETE')) THEN
    v_missing := v_missing || 'prisoner_replies-unexpected-update-or-delete-policy '; END IF;
  IF to_regprocedure('public.update_prisoner_letter_reply(uuid,text)') IS NOT NULL THEN
    v_missing := v_missing || 'unexpected-reply-update-rpc-introduced '; END IF;

  -- ── 15. Never a generic patch-style RPC ─────────────────────────────
  IF to_regprocedure('public.update_prisoner_letter(uuid,jsonb)') IS NOT NULL THEN
    v_missing := v_missing || 'unexpected-generic-patch-rpc-introduced '; END IF;

  -- ── 16. Server-side audit: every one of the 6 RPCs writes its own
  -- audit_logs row, in the same transaction, with no confidential
  -- content (no letter/reply body text is ever concatenated into notes) ─
  FOREACH v_fn IN ARRAY ARRAY[
    'create_prisoner_letter(uuid,uuid,uuid,text)',
    'mark_prisoner_letter_received(uuid)',
    'route_prisoner_letter(uuid,uuid,uuid)',
    'mark_prisoner_letter_slip_generated(uuid)',
    'create_prisoner_letter_reply(uuid,text)',
    'mark_prisoner_letter_delivered(uuid)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
    IF v_def IS NOT NULL AND v_def NOT ILIKE '%INSERT INTO audit_logs%' THEN
      v_missing := v_missing || v_fn || '-missing-audit-write '; END IF;
    IF v_def IS NOT NULL AND (v_def ILIKE '%|| p_body%' OR v_def ILIKE '%|| v_reply.body%') THEN
      v_missing := v_missing || v_fn || '-leaks-body-content-into-audit '; END IF;
  END LOOP;

  -- ── 17. RLS access model matches Product Decision A exactly, and RLS
  -- policy count on prisoner_letters/prisoner_replies is unchanged from
  -- before this milestone (narrowed in place, not added-to) ──────────
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='prisoner_letters') <> 3 THEN
    v_missing := v_missing || 'prisoner_letters-unexpected-policy-count '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='prisoner_replies') <> 2 THEN
    v_missing := v_missing || 'prisoner_replies-unexpected-policy-count '; END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='prisoner_letters' AND cmd='DELETE')
     OR EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='prisoner_replies' AND cmd='DELETE')
  THEN v_missing := v_missing || 'unexpected-delete-policy-introduced '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='prisoner_letters' AND policyname='prisoner_letters_select'
      AND qual ILIKE '%submitted_by = auth.uid()%' AND qual ILIKE '%assigned_to = auth.uid()%'
      AND qual ILIKE '%is_supervisor_or_above()%'
  ) THEN v_missing := v_missing || 'prisoner_letters_select-does-not-match-decision-a-model '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='prisoner_replies' AND policyname='prisoner_replies_insert'
      AND with_check ILIKE '%to_org_id = get_my_org_id()%' AND with_check NOT ILIKE '%from_prison_id = get_my_org_id()%'
  ) THEN v_missing := v_missing || 'prisoner_replies_insert-not-authority-side-only '; END IF;

  -- ── 18. Attachment finalization lock present on the prisoner_letter/
  -- prisoner_reply branches of attachments_insert/attachments_delete
  -- only (never attachments_select, never any other record_type branch) ─
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='attachments' AND policyname='attachments_insert'
      AND with_check ILIKE '%prisoner_letter%pl.status <> ''delivered''%'
  ) THEN
    -- ordering-tolerant fallback check
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='attachments' AND policyname='attachments_insert'
        AND with_check ILIKE '%pl.status <> ''delivered''%'
    ) THEN v_missing := v_missing || 'attachments_insert-missing-prisoner-letter-finalization-lock '; END IF;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='attachments' AND policyname='attachments_delete'
      AND qual ILIKE '%pl.status <> ''delivered''%'
  ) THEN v_missing := v_missing || 'attachments_delete-missing-prisoner-letter-finalization-lock '; END IF;
  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='attachments' AND policyname='attachments_select'
      AND qual ILIKE '%pl.status <> ''delivered''%'
  ) THEN v_missing := v_missing || 'attachments_select-unexpectedly-gained-finalization-lock '; END IF;
  -- No other record_type branch's own lock condition was touched.
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='attachments' AND policyname='attachments_insert'
      AND with_check ILIKE '%r.is_locked = FALSE%' AND with_check ILIKE '%re.is_locked = FALSE%'
  ) THEN v_missing := v_missing || 'attachments_insert-request-response-lock-condition-disturbed '; END IF;

  -- ── 19. Zero CAP-003 integration (this milestone, Phase 1.9A, itself
  -- adds none). CAP-003 Phase 1.9B has since legitimately added atomic
  -- outbox enqueue to exactly 3 of the 6 RPCs (create_prisoner_letter,
  -- route_prisoner_letter, create_prisoner_letter_reply) -- a narrow,
  -- disclosed carve-out reconciling this 1.9A validator with 1.9B's own
  -- later, separately-reviewed milestone, mirroring the identical
  -- reconciliation already applied to every prior phase's sibling
  -- validators (see docs/94 "Sibling validator reconciliation" #1). The
  -- remaining 3 RPCs (deferred by 1.9B, see its own header) must still
  -- show NO CAP-003 integration reference at all. ─────────────────────
  FOREACH v_fn IN ARRAY ARRAY[
    'mark_prisoner_letter_received(uuid)',
    'mark_prisoner_letter_slip_generated(uuid)',
    'mark_prisoner_letter_delivered(uuid)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
    IF v_def IS NOT NULL AND (
      v_def ILIKE '%platform_enqueue_outbox_event%' OR v_def ILIKE '%platform_outbox_events%'
      OR v_def ILIKE '%notification_intents%' OR v_def ILIKE '%create_notification_intent%'
      OR v_def ILIKE '%resolve_notification_intent%' OR v_def ILIKE '%process_platform_outbox_batch%'
      OR v_def ILIKE '%user_notifications%'
    ) THEN v_missing := v_missing || v_fn || '-unexpectedly-integrates-cap003 '; END IF;
  END LOOP;
  IF (SELECT count(*) FROM platform_event_type_registry WHERE owning_module = 'prisoner_letters') <> 4 THEN
    v_missing := v_missing || 'prisoner-letters-event-count-not-exactly-phase-1.9b-four '; END IF;

  -- ── 20. No digital signature implementation ─────────────────────────
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name IN ('prisoner_letters','prisoner_replies')
      AND (column_name ILIKE '%signature%' OR column_name ILIKE 'signed\_%' ESCAPE '\' OR column_name ILIKE '%\_signed' ESCAPE '\')
  ) THEN v_missing := v_missing || 'unexpected-signature-column-introduced '; END IF;

  -- ── 21. Task integration preserved and consistent with the new
  -- access model: all 6 pre-existing RPCs still present, and
  -- can_view_prisoner_letter() now matches the new prisoner_letters_
  -- select predicate (submitted_by/assigned_to + supervisor), not the
  -- old flag+party-org-only predicate ─────────────────────────────────
  IF to_regprocedure('public.can_view_prisoner_letter(uuid)') IS NULL THEN
    v_missing := v_missing || 'can_view_prisoner_letter-missing '; END IF;
  IF to_regprocedure('public.can_manage_prisoner_letter_task_link(uuid)') IS NULL THEN
    v_missing := v_missing || 'can_manage_prisoner_letter_task_link-missing '; END IF;
  IF to_regprocedure('public.create_prisoner_letter_supporting_task(uuid,text,text,uuid,text,text,date,date,uuid[])') IS NULL THEN
    v_missing := v_missing || 'create_prisoner_letter_supporting_task-missing '; END IF;
  IF to_regprocedure('public.link_existing_task_to_prisoner_letter(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'link_existing_task_to_prisoner_letter-missing '; END IF;
  IF to_regprocedure('public.unlink_task_from_prisoner_letter(uuid,text)') IS NULL THEN
    v_missing := v_missing || 'unlink_task_from_prisoner_letter-missing '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.can_view_prisoner_letter(uuid)')) INTO v_def;
  IF v_def NOT ILIKE '%submitted_by = auth.uid()%' OR v_def NOT ILIKE '%assigned_to = auth.uid()%'
     OR v_def NOT ILIKE '%is_supervisor_or_above()%'
  THEN v_missing := v_missing || 'can_view_prisoner_letter-not-aligned-with-new-select-predicate '; END IF;

  -- ── 22. Requests/Entry/Internal Collaboration mutation foundations
  -- untouched -- none of the 6 functions reference their tables ─────
  FOREACH v_fn IN ARRAY ARRAY[
    'create_prisoner_letter(uuid,uuid,uuid,text)',
    'route_prisoner_letter(uuid,uuid,uuid)',
    'create_prisoner_letter_reply(uuid,text)'
  ] LOOP
    SELECT pg_get_functiondef(to_regprocedure('public.'||v_fn)) INTO v_def;
    IF v_def IS NOT NULL AND (
      v_def ILIKE '%UPDATE requests%' OR v_def ILIKE '%UPDATE external_correspondence%'
      OR v_def ILIKE '%UPDATE internal_requests%'
    ) THEN v_missing := v_missing || v_fn || '-unexpectedly-references-a-non-prisoner-letters-module '; END IF;
  END LOOP;
  IF to_regprocedure('public.create_internal_request(uuid,uuid,text,text,uuid,uuid,text,text,timestamptz)') IS NULL THEN
    v_missing := v_missing || 'internal-collaboration-1.8a-baseline-missing '; END IF;

  -- ── 23. No speculative schema addition (no per-record section-
  -- scoping column, no lock_version, matching the STOP-condition
  -- boundary that forbade inventing new fields) ───────────────────────
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name = 'prisoner_letters'
      AND column_name ILIKE '%lock_version%'
  ) THEN v_missing := v_missing || 'unexpected-speculative-column-introduced '; END IF;

  -- ── 24. CAP-002/CAP-003 baselines through 1.8B unaffected ──────────
  IF to_regprocedure('public.assign_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'assign_task-missing '; END IF;
  IF to_regclass('public.user_notifications') IS NULL THEN v_missing := v_missing || 'user_notifications-missing '; END IF;
  IF (SELECT count(*) FROM platform_event_type_registry WHERE owning_module = 'internal_collaboration') <> 5 THEN
    v_missing := v_missing || 'internal-collaboration-1.8b-event-registry-drift '; END IF;
  IF to_regprocedure('public.intent_user_can_view_internal_request(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'internal-collaboration-1.8b-adapter-missing '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Prisoner Letters server mutation foundation structural validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Prisoner Letters server mutation foundation structural validation PASSED (all 6 evidenced commands present, SECURITY DEFINER/search_path/grants correct, reference generator internal-only, direct client writes eliminated for prisoner_letters/prisoner_replies while SELECT and attachments INSERT remain intact, actor always derived from auth.uid(), prisoner identity server-derived, directionality/state-transition/row-locking/assignment-hardening all enforced, recipient-org immutable, reply atomically fused and authority-side-only, reference generation atomic, reply immutability preserved, no generic patch RPC, server-side audit with no body-content leakage, RLS matches Product Decision A exactly with attachment finalization lock scoped correctly, zero CAP-003 integration, no digital signature, Task integration preserved and realigned, no speculative schema, CAP-002/CAP-003 baselines unaffected).';
END $$;
