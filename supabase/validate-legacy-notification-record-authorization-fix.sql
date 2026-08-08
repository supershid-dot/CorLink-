-- CAP-003 Phase 1.0B legacy notification RECORD-authorization
-- correction structural validator (hard fail)
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
  v_helper_def TEXT;
BEGIN
  -- notif_insert must still be absent -- this correction does not
  -- reintroduce any direct-INSERT path for ordinary authenticated
  -- users; create_legacy_notification() remains the sole creation
  -- boundary (unchanged from 1.0A).
  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications' AND cmd = 'INSERT'
  ) THEN v_missing := v_missing || 'unexpected-insert-policy-present '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications'
      AND policyname = 'notif_select' AND cmd = 'SELECT' AND qual = '(user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'notif_select-policy-drift '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications'
      AND policyname = 'notif_update' AND cmd = 'UPDATE' AND qual = '(user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'notif_update-policy-drift '; END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications' AND cmd = 'DELETE'
  ) THEN v_missing := v_missing || 'unexpected-delete-policy-introduced '; END IF;

  IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications') <> 2 THEN
    v_missing := v_missing || 'unexpected-notifications-policy-count ';
  END IF;

  -- create_legacy_notification() itself: same signature/security
  -- shape as 1.0A (SECURITY DEFINER, pinned search_path,
  -- authenticated-only), now with genuinely record-authoritative logic.
  IF to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)') IS NULL THEN
    v_missing := v_missing || 'create_legacy_notification-missing ';
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p WHERE p.oid = to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)')
        AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[]
    ) THEN v_missing := v_missing || 'create_legacy_notification-security '; END IF;
    IF has_function_privilege('anon', to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)'), 'EXECUTE') THEN
      v_missing := v_missing || 'create_legacy_notification-anon-leak ';
    END IF;
    IF NOT has_function_privilege('authenticated', to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)'), 'EXECUTE') THEN
      v_missing := v_missing || 'create_legacy_notification-not-granted-to-authenticated ';
    END IF;
  END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)')) INTO v_def;

  -- The 1.0A-era unconditional "same organization is always allowed"
  -- bypass must be genuinely GONE from the function body, not merely
  -- undocumented -- this is the one line whose removal defines this
  -- entire milestone.
  IF v_def ILIKE '%v_recipient_org = v_actor_org%' THEN
    v_missing := v_missing || 'rpc-still-contains-unconditional-same-org-bypass ';
  END IF;

  -- Closed record_type allowlist and per-record-type dispatch to the
  -- three legitimacy predicates must genuinely be present in the body.
  IF v_def NOT ILIKE '%record_type NOT IN (%request%external_correspondence%prisoner_letter%)%'
     AND v_def NOT ILIKE '%''request'', ''external_correspondence'', ''prisoner_letter''%'
  THEN v_missing := v_missing || 'rpc-missing-record-type-allowlist '; END IF;
  IF v_def NOT ILIKE '%notif_request_legitimate_recipient%' THEN v_missing := v_missing || 'rpc-missing-request-dispatch '; END IF;
  IF v_def NOT ILIKE '%notif_entry_legitimate_recipient%' THEN v_missing := v_missing || 'rpc-missing-entry-dispatch '; END IF;
  IF v_def NOT ILIKE '%notif_prisoner_letter_legitimate_recipient%' THEN v_missing := v_missing || 'rpc-missing-prisoner-letter-dispatch '; END IF;

  -- The record must be proven to exist before any authorization check
  -- (a nonexistent record_id must be rejected, distinctly).
  IF v_def NOT ILIKE '%v_record_exists%' THEN v_missing := v_missing || 'rpc-missing-record-existence-check '; END IF;

  -- The caller (not only the recipient) must be validated against the
  -- same record-legitimacy predicate -- "caller is authorized for this
  -- specific record" is a distinct requirement from "recipient is
  -- legitimately connected", and both must be present.
  IF v_def NOT ILIKE '%Caller is not authorized%' THEN v_missing := v_missing || 'rpc-missing-caller-authorization-check '; END IF;

  -- The (record_type, type) allowlist function must exist, be used by
  -- the RPC, and actually enumerate the closed combination set (not a
  -- stub that always returns TRUE).
  IF to_regprocedure('public.notif_type_allowed(text,text)') IS NULL THEN
    v_missing := v_missing || 'notif_type_allowed-missing ';
  ELSE
    IF v_def NOT ILIKE '%notif_type_allowed%' THEN v_missing := v_missing || 'rpc-does-not-call-notif_type_allowed '; END IF;
    SELECT pg_get_functiondef(to_regprocedure('public.notif_type_allowed(text,text)')) INTO v_helper_def;
    IF v_helper_def NOT ILIKE '%approval_requested%' OR v_helper_def NOT ILIKE '%new_prisoner_letter%'
       OR v_helper_def NOT ILIKE '%new_external_correspondence%'
    THEN v_missing := v_missing || 'notif_type_allowed-incomplete '; END IF;
  END IF;

  -- Per-record-type legitimacy predicates must exist, be
  -- STABLE/SECURITY DEFINER (so they can evaluate an arbitrary target
  -- user, not only the caller), and must genuinely derive recipients
  -- from the record's own columns -- not merely check organization
  -- membership. The cross-organization party-org columns 1.0A already
  -- validated must still appear (preserved, not weakened), alongside
  -- the new section/individual-reference derivation.
  IF to_regprocedure('public.notif_request_legitimate_recipient(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'notif_request_legitimate_recipient-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.notif_request_legitimate_recipient(uuid,uuid)')) INTO v_helper_def;
    IF v_helper_def NOT ILIKE '%SECURITY DEFINER%' THEN v_missing := v_missing || 'notif_request_legitimate_recipient-not-security-definer '; END IF;
    IF v_helper_def NOT ILIKE '%from_org_id%' OR v_helper_def NOT ILIKE '%to_org_id%' THEN
      v_missing := v_missing || 'notif_request_legitimate_recipient-cross-org-path-weakened ';
    END IF;
    IF v_helper_def NOT ILIKE '%created_by%' OR v_helper_def NOT ILIKE '%notif_user_covers_section%' THEN
      v_missing := v_missing || 'notif_request_legitimate_recipient-missing-section-or-individual-derivation ';
    END IF;
    IF v_helper_def NOT ILIKE '%internal_requests%' THEN
      v_missing := v_missing || 'notif_request_legitimate_recipient-missing-internal-collab-derivation ';
    END IF;
  END IF;

  IF to_regprocedure('public.notif_entry_legitimate_recipient(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'notif_entry_legitimate_recipient-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.notif_entry_legitimate_recipient(uuid,uuid)')) INTO v_helper_def;
    IF v_helper_def NOT ILIKE '%SECURITY DEFINER%' THEN v_missing := v_missing || 'notif_entry_legitimate_recipient-not-security-definer '; END IF;
    IF v_helper_def NOT ILIKE '%org_id%' THEN v_missing := v_missing || 'notif_entry_legitimate_recipient-missing-org-check '; END IF;
  END IF;

  IF to_regprocedure('public.notif_prisoner_letter_legitimate_recipient(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'notif_prisoner_letter_legitimate_recipient-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.notif_prisoner_letter_legitimate_recipient(uuid,uuid)')) INTO v_helper_def;
    IF v_helper_def NOT ILIKE '%SECURITY DEFINER%' THEN v_missing := v_missing || 'notif_prisoner_letter_legitimate_recipient-not-security-definer '; END IF;
    IF v_helper_def NOT ILIKE '%from_prison_id%' OR v_helper_def NOT ILIKE '%to_org_id%' THEN
      v_missing := v_missing || 'notif_prisoner_letter_legitimate_recipient-cross-org-path-weakened ';
    END IF;
  END IF;

  -- Generalized explicit-user helpers must exist and take an explicit
  -- target-user parameter (never rely on auth.uid() -- they must be
  -- able to answer for an arbitrary recipient, not just the caller).
  IF to_regprocedure('public.notif_user_covers_section(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || 'notif_user_covers_section-missing ';
  END IF;
  IF to_regprocedure('public.notif_user_has_notify_role(uuid)') IS NULL THEN
    v_missing := v_missing || 'notif_user_has_notify_role-missing ';
  END IF;
  IF to_regprocedure('public.notif_user_org_id(uuid)') IS NULL THEN
    v_missing := v_missing || 'notif_user_org_id-missing ';
  END IF;

  -- No new row-locking / concurrency surface was introduced.
  IF v_def ILIKE '%FOR UPDATE%' THEN
    v_missing := v_missing || 'rpc-unexpectedly-takes-row-locks ';
  END IF;

  -- CAP-003 Phase 1.1 (platform_outbox_events/user_notifications) is a
  -- separate, later, independently-approved milestone -- their
  -- existence is expected once that milestone has shipped and is not
  -- itself evidence this 1.0B correction did anything out of scope.
  -- notification_intents specifically remains never persisted as its
  -- own table (docs/78 SS6's own explicit design choice) regardless of
  -- how many later phases ship, so that check alone stays meaningful.
  IF to_regclass('public.notification_intents') IS NOT NULL THEN
    v_missing := v_missing || 'unexpected-cap003-object-created ';
  END IF;

  -- notifications.type CHECK constraint (the 30-value enum) remains
  -- deliberately untouched by this milestone too.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass('public.notifications') AND conname = 'notifications_type_check'
  ) THEN v_missing := v_missing || 'notifications-type-check-missing '; END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.notifications')) THEN
    v_missing := v_missing || 'notifications-rls-not-enabled ';
  END IF;

  -- CAP-002 baseline untouched.
  IF to_regclass('public.workflow_events') IS NULL OR to_regclass('public.workflow_sla_clocks') IS NULL
     OR to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL
  THEN v_missing := v_missing || 'baseline-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Legacy notification RECORD-authorization correction structural check FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Legacy notification RECORD-authorization correction structural check PASSED (unconditional same-org bypass genuinely removed from create_legacy_notification''s body, closed record_type allowlist + per-record-type dispatch to notif_request/entry/prisoner_letter_legitimate_recipient present, record-existence check present, caller-authorization check present, closed (record_type,type) allowlist present and used, all generalized explicit-user helpers present and SECURITY DEFINER, preserved cross-organization party-org columns for request/prisoner_letter, notif_select/notif_update/RLS/type-enum/CAP-002 baseline all untouched, no new row-locking surface, zero CAP-003 Phase 1.1 objects created).';
END $$;
