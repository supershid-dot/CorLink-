-- ─── Validator: audit_logs_action_check allows module_enabled/disabled ──
-- Run manually against a project AFTER
-- patch-audit-logs-module-actions.sql has been applied there.

\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO v_def
  FROM pg_constraint WHERE conname = 'audit_logs_action_check';

  IF v_def IS NULL THEN
    v_missing := v_missing || 'constraint-missing ';
  ELSE
    IF v_def NOT ILIKE '%''module_enabled''%' THEN
      v_missing := v_missing || 'missing-module_enabled ';
    END IF;
    IF v_def NOT ILIKE '%''module_disabled''%' THEN
      v_missing := v_missing || 'missing-module_disabled ';
    END IF;
    IF v_def NOT ILIKE '%''task_relationship_added''%' THEN
      v_missing := v_missing || 'lost-preexisting-value ';
    END IF;
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'validate-audit-logs-module-actions FAILED: %', v_missing;
  END IF;

  RAISE NOTICE 'validate-audit-logs-module-actions: all checks passed';
END $$;
