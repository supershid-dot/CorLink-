-- ─── Validator: Calendar Staff filter is own-org only (142) ────────
-- Run manually against a project AFTER
-- patch-calendar-staff-own-org-only.sql has been applied there.

\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  IF to_regprocedure('public.viewable_calendar_staff()') IS NULL THEN
    v_missing := v_missing || 'viewable_calendar_staff-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.viewable_calendar_staff()')) INTO v_def;
    IF v_def ILIKE '%is_super_admin()%' THEN
      v_missing := v_missing || 'viewable_calendar_staff-still-has-cross-org-super-admin-branch ';
    END IF;
    IF v_def NOT ILIKE '%u.org_id = v_org%' THEN
      v_missing := v_missing || 'viewable_calendar_staff-missing-own-org-scope ';
    END IF;
    IF v_def NOT ILIKE '%can_view_user_schedule%' THEN
      v_missing := v_missing || 'viewable_calendar_staff-missing-permission-check ';
    END IF;
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'validate-calendar-staff-own-org-only FAILED: %', v_missing;
  END IF;

  RAISE NOTICE 'validate-calendar-staff-own-org-only: all checks passed';
END $$;
