-- CAP-003 Phase 1.0B legacy notification RECORD-authorization
-- correction rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- Every 1.0B-introduced object must be gone.
  IF to_regprocedure('public.notif_request_legitimate_recipient(uuid,uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'notif_request_legitimate_recipient-still-present ';
  END IF;
  IF to_regprocedure('public.notif_entry_legitimate_recipient(uuid,uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'notif_entry_legitimate_recipient-still-present ';
  END IF;
  IF to_regprocedure('public.notif_prisoner_letter_legitimate_recipient(uuid,uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'notif_prisoner_letter_legitimate_recipient-still-present ';
  END IF;
  IF to_regprocedure('public.notif_type_allowed(text,text)') IS NOT NULL THEN
    v_missing := v_missing || 'notif_type_allowed-still-present ';
  END IF;
  IF to_regprocedure('public.notif_user_org_id(uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'notif_user_org_id-still-present ';
  END IF;
  IF to_regprocedure('public.notif_user_covers_section(uuid,uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'notif_user_covers_section-still-present ';
  END IF;
  IF to_regprocedure('public.notif_user_has_notify_role(uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'notif_user_has_notify_role-still-present ';
  END IF;
  IF to_regprocedure('public.notif_user_is_prisoner_letters_staff(uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'notif_user_is_prisoner_letters_staff-still-present ';
  END IF;

  -- create_legacy_notification must be back, byte-identical to its
  -- exact 1.0A-era definition -- same-org unconditional bypass
  -- present again, cross-org named-table checks present, no
  -- record-authoritative dispatch, no allowlist call.
  IF to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)') IS NULL THEN
    v_missing := v_missing || 'create_legacy_notification-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)')) INTO v_def;
    IF v_def NOT ILIKE '%v_recipient_org = v_actor_org%' THEN
      v_missing := v_missing || 'create_legacy_notification-same-org-bypass-not-restored ';
    END IF;
    IF v_def ILIKE '%notif_request_legitimate_recipient%' OR v_def ILIKE '%notif_type_allowed%'
       OR v_def ILIKE '%v_record_exists%'
    THEN v_missing := v_missing || 'create_legacy_notification-still-record-authoritative '; END IF;
    IF v_def NOT ILIKE '%requests%' OR v_def NOT ILIKE '%prisoner_letters%' THEN
      v_missing := v_missing || 'create_legacy_notification-cross-org-tables-missing ';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)')
        AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || 'create_legacy_notification-security-drift '; END IF;
    IF has_function_privilege('anon', to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)'), 'EXECUTE') THEN
      v_missing := v_missing || 'create_legacy_notification-anon-leak ';
    END IF;
    IF NOT has_function_privilege('authenticated', to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)'), 'EXECUTE') THEN
      v_missing := v_missing || 'create_legacy_notification-not-granted-to-authenticated ';
    END IF;
  END IF;

  -- notif_select/notif_update/policy count/RLS/type-enum/CAP-002
  -- baseline: this rollback never touches any of these, so they must
  -- be completely unaffected either way (same checks as 1.0A's own
  -- rollback validator, since 1.0B's rollback target IS the 1.0A state).
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications'
      AND policyname = 'notif_select' AND cmd = 'SELECT' AND qual = '(user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'notif_select-drift '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications'
      AND policyname = 'notif_update' AND cmd = 'UPDATE' AND qual = '(user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'notif_update-drift '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications') <> 2 THEN
    v_missing := v_missing || 'unexpected-policy-count-after-rollback ';
  END IF;
  IF to_regclass('public.notifications') IS NULL
     OR to_regclass('public.workflow_events') IS NULL
     OR to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL
  THEN v_missing := v_missing || 'baseline-drift-after-rollback '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Legacy notification RECORD-authorization correction rollback validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Legacy notification RECORD-authorization correction rollback validation PASSED (all 1.0B objects absent, create_legacy_notification restored to its exact 1.0A-era same-org-unconditional-bypass definition, notif_select/notif_update/policy-count/CAP-002 baseline all unaffected).';
END $$;
