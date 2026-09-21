-- ─── Validator: Calendar staff schedule access (136... 137) ─────────
-- Run manually against a project AFTER
-- patch-calendar-staff-schedule-access.sql has been applied there.
-- Structural only (table/policy/function existence + a couple of
-- ILIKE body checks) — behavioral correctness (who actually sees whom)
-- is exercised via this session's own manual end-to-end pass on
-- CorLink Staging plus the frontend test suite's mocked-RPC coverage.

\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='user_schedule_grants')
    THEN v_missing := v_missing || 'user_schedule_grants-table-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_schedule_grants' AND policyname='user_schedule_grants_select'
  ) THEN v_missing := v_missing || 'user_schedule_grants_select-policy-missing '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_tables WHERE schemaname='public' AND tablename='user_schedule_grants' AND rowsecurity = TRUE
  ) THEN v_missing := v_missing || 'user_schedule_grants-rls-not-enabled '; END IF;

  -- No INSERT/UPDATE/DELETE policy exists — every write must go through
  -- admin_set_schedule_grants() (SECURITY DEFINER), not direct table access.
  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_schedule_grants'
      AND cmd IN ('INSERT','UPDATE','DELETE','ALL')
  ) THEN v_missing := v_missing || 'user_schedule_grants-has-unexpected-write-policy '; END IF;

  IF to_regprocedure('public.can_view_user_schedule(uuid)') IS NULL THEN
    v_missing := v_missing || 'can_view_user_schedule-missing ';
  END IF;

  IF to_regprocedure('public.viewable_calendar_staff()') IS NULL THEN
    v_missing := v_missing || 'viewable_calendar_staff-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.viewable_calendar_staff()')) INTO v_def;
    IF v_def NOT ILIKE '%can_view_user_schedule%' THEN
      v_missing := v_missing || 'viewable_calendar_staff-does-not-reuse-can_view_user_schedule ';
    END IF;
  END IF;

  IF to_regprocedure('public.fetch_user_calendar_events(uuid,timestamptz,timestamptz)') IS NULL THEN
    v_missing := v_missing || 'fetch_user_calendar_events-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.fetch_user_calendar_events(uuid,timestamptz,timestamptz)')) INTO v_def;
    IF v_def NOT ILIKE '%can_view_user_schedule%' THEN
      v_missing := v_missing || 'fetch_user_calendar_events-missing-permission-check ';
    END IF;
    IF v_def NOT ILIKE '%meeting_participants%' THEN
      v_missing := v_missing || 'fetch_user_calendar_events-missing-participant-join ';
    END IF;
  END IF;

  IF to_regprocedure('public.admin_set_schedule_grants(uuid,uuid[])') IS NULL THEN
    v_missing := v_missing || 'admin_set_schedule_grants-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.admin_set_schedule_grants(uuid,uuid[])')) INTO v_def;
    IF v_def NOT ILIKE '%is_admin()%' THEN
      v_missing := v_missing || 'admin_set_schedule_grants-missing-admin-check ';
    END IF;
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'validate-calendar-staff-schedule-access FAILED: %', v_missing;
  END IF;

  RAISE NOTICE 'validate-calendar-staff-schedule-access: all checks passed';
END $$;
