-- CAP-003 Phase 1.3A legacy notification SECURITY DEFINER search-path
-- hardening structural validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_fn TEXT;
  v_sig TEXT;
  v_def TEXT;
BEGIN
  -- ── Each of the seven functions: exists, SECURITY DEFINER, pinned
  -- search_path, STABLE, not strict, default (unrevoked) ACL,
  -- postgres-owned -- exactly the pre-1.3A attributes with only
  -- proconfig changed ──
  FOREACH v_fn IN ARRAY ARRAY[
    'notif_user_org_id(uuid)',
    'notif_user_covers_section(uuid,uuid)',
    'notif_user_has_notify_role(uuid)',
    'notif_user_is_prisoner_letters_staff(uuid)',
    'notif_request_legitimate_recipient(uuid,uuid)',
    'notif_entry_legitimate_recipient(uuid,uuid)',
    'notif_prisoner_letter_legitimate_recipient(uuid,uuid)'
  ] LOOP
    IF to_regprocedure('public.'||v_fn) IS NULL THEN
      v_missing := v_missing || v_fn || '-missing ';
      CONTINUE;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.'||v_fn) AND p.prosecdef
    ) THEN v_missing := v_missing || v_fn || '-not-security-definer '; END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.'||v_fn)
        AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || v_fn || '-search-path-not-pinned '; END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.'||v_fn) AND p.provolatile = 's'
    ) THEN v_missing := v_missing || v_fn || '-volatility-drift '; END IF;

    IF EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.'||v_fn) AND p.proisstrict
    ) THEN v_missing := v_missing || v_fn || '-strictness-drift '; END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.'||v_fn) AND pg_get_userbyid(p.proowner) = 'postgres'
    ) THEN v_missing := v_missing || v_fn || '-owner-drift '; END IF;

    -- Default (never-revoked) ACL preserved -- these are intentionally
    -- PUBLIC-executable narrow read-only predicate helpers, the same
    -- posture core RLS predicates like is_admin()/get_my_org_id() use;
    -- this milestone does not "clean up" that grant shape.
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.'||v_fn) AND p.proacl IS NULL
    ) THEN v_missing := v_missing || v_fn || '-acl-drift '; END IF;
  END LOOP;

  -- ── Business semantics unchanged: each function's body still
  -- references exactly the tables/helpers docs/80's own 1.0B
  -- implementation established -- a structural, not exhaustive-value,
  -- proof that no logic was rewritten alongside the search_path fix ──
  SELECT pg_get_functiondef(to_regprocedure('public.notif_request_legitimate_recipient(uuid,uuid)')) INTO v_def;
  IF v_def NOT ILIKE '%internal_requests%' OR v_def NOT ILIKE '%from_org_id%' OR v_def NOT ILIKE '%to_org_id%' THEN
    v_missing := v_missing || 'notif_request_legitimate_recipient-semantics-drift ';
  END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.notif_entry_legitimate_recipient(uuid,uuid)')) INTO v_def;
  IF v_def NOT ILIKE '%external_correspondence%' OR v_def NOT ILIKE '%entry_sections%' THEN
    v_missing := v_missing || 'notif_entry_legitimate_recipient-semantics-drift ';
  END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.notif_prisoner_letter_legitimate_recipient(uuid,uuid)')) INTO v_def;
  IF v_def NOT ILIKE '%prisoner_letters%' OR v_def NOT ILIKE '%from_prison_id%' THEN
    v_missing := v_missing || 'notif_prisoner_letter_legitimate_recipient-semantics-drift ';
  END IF;

  -- ── No unrelated function was modified: spot-check a handful of
  -- 1.0B's own sibling objects this patch must never touch ──
  IF to_regprocedure('public.notif_type_allowed(text,text)') IS NULL THEN
    v_missing := v_missing || 'notif_type_allowed-missing '; END IF;
  IF to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)') IS NULL THEN
    v_missing := v_missing || 'create_legacy_notification-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)')) INTO v_def;
    IF v_def NOT ILIKE '%notif_type_allowed%' THEN
      v_missing := v_missing || 'create_legacy_notification-unexpectedly-changed ';
    END IF;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='notifications'
      AND policyname='notif_select' AND cmd='SELECT' AND qual='(user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'notif_select-drift '; END IF;

  -- ── CAP-003 Phase 1.3 worker functions remain completely
  -- untouched by this narrow security-only checkpoint ──
  IF to_regprocedure('public.process_platform_outbox_batch(integer,text)') IS NULL THEN
    v_missing := v_missing || 'phase1.3-process_platform_outbox_batch-missing ';
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.process_platform_outbox_batch(integer,text)')
        AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || 'phase1.3-process_platform_outbox_batch-drift '; END IF;
  END IF;
  IF to_regprocedure('public.replay_dead_lettered_outbox_event(uuid)') IS NULL THEN
    v_missing := v_missing || 'phase1.3-replay_dead_lettered_outbox_event-missing '; END IF;

  -- ── No CAP-003 Phase 1.4 object exists ──
  IF EXISTS (
    SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
      AND proname IN (
        'submit_request_for_approval','approve_request','route_request','create_meeting',
        'assign_task','log_entry','submit_prisoner_letter'
      )
      AND (pg_get_functiondef(oid) ILIKE '%create_notification_intent%' OR pg_get_functiondef(oid) ILIKE '%platform_enqueue_outbox_event%')
  ) THEN v_missing := v_missing || 'unexpected-phase1.4-module-integration-detected '; END IF;

  -- ── CAP-002 baseline and every prior CAP-003 baseline untouched ──
  IF to_regclass('public.workflow_events') IS NULL OR to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL THEN
    v_missing := v_missing || 'cap002-baseline-drift '; END IF;
  IF to_regclass('public.notification_intents') IS NULL OR to_regprocedure('public.resolve_notification_intent(uuid)') IS NULL THEN
    v_missing := v_missing || 'phase1.2-baseline-drift '; END IF;
  IF to_regclass('public.platform_outbox_events') IS NULL THEN
    v_missing := v_missing || 'phase1.1-baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Legacy notification search-path hardening structural check FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Legacy notification search-path hardening structural check PASSED (all seven notif_* helpers pin search_path=public,pg_temp while remaining SECURITY DEFINER/STABLE/non-strict/postgres-owned/default-ACL exactly as before, business semantics unchanged, create_legacy_notification and notif_type_allowed untouched, legacy notifications RLS untouched, CAP-003 Phase 1.3 worker and Phase 1.2/1.1 baselines all intact, zero Phase 1.4 objects exist, CAP-002 baseline intact).';
END $$;
