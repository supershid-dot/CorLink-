-- CAP-003 Phase 1.0A legacy notification INSERT-RLS correction
-- structural validator (hard fail)
--
-- Updated by CAP-003 Phase 1.0B (docs/80): create_legacy_notification()
-- is a live, shared function -- 1.0B legitimately CREATE OR REPLACEs
-- it with a stricter, record-authoritative implementation that no
-- longer contains the literal "v_recipient_org = v_actor_org"
-- unconditional same-org bypass this validator used to require, and
-- moves the cross-organization requests/prisoner_letters checks out of
-- the top-level function body into per-record-type helper functions.
-- Those two now-obsolete body-content assertions are removed below;
-- everything else here (RLS policy shape, grants, enum, no new
-- row-locking) remains true and unchanged. The current function body's
-- own correctness is asserted by validate-legacy-notification-
-- record-authorization-fix.sql, which supersedes this file for that
-- purpose specifically.
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- The insecure policy must be gone: no INSERT policy on notifications
  -- at all for authenticated/anon remains, closing the unrestricted
  -- cross-user INSERT hole structurally rather than narrowing it.
  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications'
      AND policyname = 'notif_insert'
  ) THEN v_missing := v_missing || 'insecure-notif-insert-policy-still-present '; END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications' AND cmd = 'INSERT'
  ) THEN v_missing := v_missing || 'unexpected-insert-policy-present '; END IF;

  -- (Table-level INSERT grants to anon/authenticated are harmless and
  -- expected in this disposable test harness and in real Supabase --
  -- it mirrors Supabase's own default of broad table grants with RLS
  -- as the actual gate. The check above -- zero INSERT policy exists --
  -- is the real boundary: RLS denies every INSERT by default once
  -- enabled with no matching policy, regardless of the table grant.)

  -- SELECT/UPDATE policies (the parts that were already correct) must
  -- remain completely untouched.
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications'
      AND policyname = 'notif_select' AND cmd = 'SELECT'
      AND qual = '(user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'notif_select-policy-drift '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications'
      AND policyname = 'notif_update' AND cmd = 'UPDATE'
      AND qual = '(user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'notif_update-policy-drift '; END IF;

  -- No DELETE policy was added -- notifications remain effectively
  -- append-only, exactly as before this correction.
  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications' AND cmd = 'DELETE'
  ) THEN v_missing := v_missing || 'unexpected-delete-policy-introduced '; END IF;

  -- The new RPC exists, is SECURITY DEFINER, pinned search_path,
  -- granted to authenticated only (never anon/PUBLIC).
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

  -- Recipient validation is genuinely present in the function body --
  -- not merely a docstring claim. Checks for the actual guard clauses:
  -- an authenticated-caller check, an active-user check applied to
  -- both actor and recipient, an organization-match branch, and the
  -- two named cross-organization tables (never a generic/unbounded
  -- cross-org allowance).
  SELECT pg_get_functiondef(to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)')) INTO v_def;
  IF v_def NOT ILIKE '%auth.uid()%' THEN v_missing := v_missing || 'rpc-missing-auth-check '; END IF;
  IF v_def NOT ILIKE '%is_active%' THEN v_missing := v_missing || 'rpc-missing-active-user-check '; END IF;
  -- The 1.0A-era same-org-unconditional-bypass and inline requests/
  -- prisoner_letters table checks are deliberately NOT asserted here
  -- anymore -- 1.0B legitimately removed/relocated them (see header
  -- comment above). validate-legacy-notification-record-authorization-
  -- fix.sql is the authoritative check of the function body's current
  -- (post-1.0B) recipient-validation logic.
  IF v_def ILIKE '%FOR UPDATE%' THEN
    v_missing := v_missing || 'rpc-unexpectedly-takes-row-locks '; -- policy-only correction, no new concurrency surface expected
  END IF;

  -- No CAP-003 outbox/persistence objects were accidentally created by
  -- this security-only correction milestone.
  IF to_regclass('public.platform_outbox_events') IS NOT NULL
     OR to_regclass('public.user_notifications') IS NOT NULL
  THEN v_missing := v_missing || 'unexpected-cap003-object-created '; END IF;

  -- notifications.type CHECK constraint (the 30-value enum) is
  -- deliberately untouched by this milestone -- still present, not
  -- widened, not narrowed, not removed.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass('public.notifications') AND conname = 'notifications_type_check'
  ) THEN v_missing := v_missing || 'notifications-type-check-missing '; END IF;

  -- notifications table itself, RLS enabled, unchanged row count of
  -- policies overall (select + update only, insert removed, no delete).
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.notifications')) THEN
    v_missing := v_missing || 'notifications-rls-not-enabled ';
  END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications') <> 2 THEN
    v_missing := v_missing || 'unexpected-notifications-policy-count ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Legacy notification INSERT-RLS correction structural check FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Legacy notification INSERT-RLS correction structural check PASSED (insecure notif_insert policy removed with zero INSERT policies remaining -- RLS denies every direct insert regardless of table grants, notif_select/notif_update untouched, no DELETE policy introduced, create_legacy_notification is SECURITY DEFINER/pinned search_path/authenticated-only with genuine active-user validation and no new row-locking surface, notifications.type enum untouched, zero CAP-003 objects created; the function body''s own recipient-validation logic is now record-authoritative per CAP-003 Phase 1.0B and is asserted by validate-legacy-notification-record-authorization-fix.sql).';
END $$;
