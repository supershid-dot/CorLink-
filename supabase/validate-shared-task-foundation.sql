-- ============================================================
-- CorLink — Validate: Shared Task Foundation
-- Companion to supabase/patch-shared-task-foundation.sql
--
-- Read-only. Confirms tables, indexes, constraints, RLS, policies,
-- and RPCs all exist as expected, then raises an exception listing
-- anything missing rather than failing silently.
-- ============================================================

-- ─── 1. Tables ──────────────────────────────────────────────────
SELECT table_name,
  EXISTS (SELECT 1 FROM information_schema.tables t WHERE t.table_schema = 'public' AND t.table_name = expected.table_name) AS exists
FROM (VALUES
  ('task_number_sequences'), ('tasks'), ('task_assignments'), ('task_watchers'), ('task_comments')
) AS expected(table_name)
ORDER BY exists ASC, table_name;

-- ─── 2. Indexes ─────────────────────────────────────────────────
SELECT indexname,
  EXISTS (SELECT 1 FROM pg_indexes i WHERE i.schemaname = 'public' AND i.indexname = expected.indexname) AS exists
FROM (VALUES
  ('idx_tasks_org'), ('idx_tasks_section'), ('idx_tasks_created_by'), ('idx_tasks_status'), ('idx_tasks_due_date'),
  ('idx_task_assignments_active_unique'), ('idx_task_assignments_task'), ('idx_task_assignments_user'),
  ('idx_task_watchers_task'), ('idx_task_watchers_user'),
  ('idx_task_comments_task')
) AS expected(indexname)
ORDER BY exists ASC, indexname;

-- ─── 3. Constraints (status/priority/visibility CHECKs + numbering PK) ──
SELECT conname,
  EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conname = expected.conname) AS exists
FROM (VALUES
  ('tasks_status_check'), ('tasks_priority_check'), ('tasks_visibility_check'),
  ('tasks_organization_id_task_number_key'),
  ('task_number_sequences_pkey'),
  ('audit_logs_record_type_check'), ('audit_logs_action_check'), ('notifications_type_check')
) AS expected(conname)
ORDER BY exists ASC, conname;

-- Extended CHECK lists actually include the new task-specific values
SELECT
  pg_get_constraintdef(oid) LIKE '%''task''%' AS audit_logs_record_type_has_task,
  (SELECT pg_get_constraintdef(oid) LIKE '%''completed''%' FROM pg_constraint WHERE conname = 'audit_logs_action_check') AS audit_logs_action_has_completed,
  (SELECT pg_get_constraintdef(oid) LIKE '%''commented''%' FROM pg_constraint WHERE conname = 'audit_logs_action_check') AS audit_logs_action_has_commented
FROM pg_constraint WHERE conname = 'audit_logs_record_type_check';

SELECT
  pg_get_constraintdef(oid) LIKE '%task_assigned%'
  AND pg_get_constraintdef(oid) LIKE '%task_completed%'
  AND pg_get_constraintdef(oid) LIKE '%task_comment_added%' AS notifications_type_has_task_types
FROM pg_constraint WHERE conname = 'notifications_type_check';

-- ─── 4. RLS enabled ─────────────────────────────────────────────
SELECT c.relname AS table_name, c.relrowsecurity AS rls_enabled
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN ('task_number_sequences', 'tasks', 'task_assignments', 'task_watchers', 'task_comments')
ORDER BY c.relname;

-- ─── 5. Policies exist ──────────────────────────────────────────
SELECT polname,
  EXISTS (SELECT 1 FROM pg_policy p WHERE p.polname = expected.polname) AS exists
FROM (VALUES
  ('tasks_select'), ('task_assignments_select'), ('task_watchers_select'), ('task_comments_select')
) AS expected(polname)
ORDER BY exists ASC, polname;

-- ─── 6. RPCs exist ──────────────────────────────────────────────
SELECT proname,
  EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = expected.proname
  ) AS exists
FROM (VALUES
  ('generate_task_number'), ('can_view_task'),
  ('create_task'), ('update_task'), ('cancel_task'), ('complete_task'),
  ('assign_task'), ('unassign_task'), ('watch_task'), ('unwatch_task'),
  ('add_task_comment'), ('get_task'), ('list_tasks'),
  ('valid_task_status_transition'), ('trigger_check_task_status')
) AS expected(proname)
ORDER BY exists ASC, proname;

-- ─── 7. Hard failure if anything above is missing ───────────────
DO $$
DECLARE
  v_missing TEXT := '';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'tasks') THEN
    v_missing := v_missing || 'table:tasks ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'task_assignments') THEN
    v_missing := v_missing || 'table:task_assignments ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'task_watchers') THEN
    v_missing := v_missing || 'table:task_watchers ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'task_comments') THEN
    v_missing := v_missing || 'table:task_comments ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'task_number_sequences') THEN
    v_missing := v_missing || 'table:task_number_sequences ';
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE relname = 'tasks' AND relnamespace = 'public'::regnamespace) THEN
    v_missing := v_missing || 'rls:tasks ';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE relname = 'task_assignments' AND relnamespace = 'public'::regnamespace) THEN
    v_missing := v_missing || 'rls:task_assignments ';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE relname = 'task_watchers' AND relnamespace = 'public'::regnamespace) THEN
    v_missing := v_missing || 'rls:task_watchers ';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE relname = 'task_comments' AND relnamespace = 'public'::regnamespace) THEN
    v_missing := v_missing || 'rls:task_comments ';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'tasks_select') THEN
    v_missing := v_missing || 'policy:tasks_select ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'task_assignments_select') THEN
    v_missing := v_missing || 'policy:task_assignments_select ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'task_watchers_select') THEN
    v_missing := v_missing || 'policy:task_watchers_select ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'task_comments_select') THEN
    v_missing := v_missing || 'policy:task_comments_select ';
  END IF;

  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('generate_task_number'), ('can_view_task'),
      ('create_task'), ('update_task'), ('cancel_task'), ('complete_task'),
      ('assign_task'), ('unassign_task'), ('watch_task'), ('unwatch_task'),
      ('add_task_comment'), ('get_task'), ('list_tasks'),
      ('valid_task_status_transition'), ('trigger_check_task_status')
    ) AS expected(proname)
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.proname
    )
  ) THEN
    v_missing := v_missing || 'rpc:one-or-more-missing(see query 6 above) ';
  END IF;

  IF NOT (SELECT pg_get_constraintdef(oid) LIKE '%''task''%' FROM pg_constraint WHERE conname = 'audit_logs_record_type_check') THEN
    v_missing := v_missing || 'constraint:audit_logs_record_type_check-missing-task ';
  END IF;
  IF NOT (SELECT pg_get_constraintdef(oid) LIKE '%task_assigned%' FROM pg_constraint WHERE conname = 'notifications_type_check') THEN
    v_missing := v_missing || 'constraint:notifications_type_check-missing-task-types ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Shared Task Foundation validation FAILED, missing: %', v_missing USING ERRCODE = 'P0001';
  ELSE
    RAISE NOTICE 'Shared Task Foundation validation PASSED: all tables, indexes, constraints, RLS, policies, and RPCs present.';
  END IF;
END $$;
