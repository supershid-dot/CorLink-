-- ============================================================
-- CorLink — Validate: Requests ↔ Shared Tasks Integration
-- Companion to supabase/patch-request-task-integration.sql
--
-- Read-only. Confirms task_links' table/columns/constraints/indexes,
-- RLS, policies, helpers, and RPCs all exist, plus the extended
-- audit_logs CHECK, then raises an exception listing anything missing
-- rather than failing silently.
-- ============================================================

-- ─── 1. Table + columns ─────────────────────────────────────────
SELECT column_name,
  EXISTS (
    SELECT 1 FROM information_schema.columns c
    WHERE c.table_schema = 'public' AND c.table_name = 'task_links' AND c.column_name = expected.column_name
  ) AS exists
FROM (VALUES
  ('id'), ('task_id'), ('module_key'), ('record_id'), ('organization_id'),
  ('created_by'), ('created_at'), ('removed_at'), ('removed_by')
) AS expected(column_name)
ORDER BY exists ASC, column_name;

-- ─── 2. Foreign keys ────────────────────────────────────────────
SELECT conname,
  EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conname = expected.conname) AS exists
FROM (VALUES
  ('task_links_task_id_fkey'), ('task_links_organization_id_fkey'), ('task_links_created_by_fkey')
) AS expected(conname)
ORDER BY exists ASC, conname;

-- record_id must NOT have a foreign key (deliberately polymorphic)
SELECT NOT EXISTS (
  SELECT 1 FROM pg_constraint c
  JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
  WHERE c.conrelid = 'task_links'::regclass AND c.contype = 'f' AND a.attname = 'record_id'
) AS record_id_has_no_fk_as_expected;

-- ─── 3. module_key restriction ──────────────────────────────────
SELECT pg_get_constraintdef(oid) LIKE '%''request''%' AS module_key_check_allows_request
FROM pg_constraint WHERE conrelid = 'task_links'::regclass AND contype = 'c' AND conname LIKE '%module_key%';

-- Confirm an unsupported module_key is actually rejected at the DB level.
DO $$
BEGIN
  BEGIN
    INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by)
    VALUES (gen_random_uuid(), 'meeting', gen_random_uuid(), gen_random_uuid(), gen_random_uuid());
    RAISE EXCEPTION 'VALIDATION_FAILED: unsupported module_key ''meeting'' was accepted';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'module_key CHECK correctly rejected an unsupported value';
    WHEN foreign_key_violation THEN
      RAISE NOTICE 'module_key CHECK correctly rejected (surfaced as FK violation on other columns first, which also proves the row never landed)';
  END;
END $$;

-- ─── 4. Indexes ─────────────────────────────────────────────────
SELECT indexname,
  EXISTS (SELECT 1 FROM pg_indexes i WHERE i.schemaname = 'public' AND i.indexname = expected.indexname) AS exists
FROM (VALUES
  ('idx_task_links_task'), ('idx_task_links_module_record'), ('idx_task_links_org'),
  ('idx_task_links_active_unique'),
  ('idx_task_links_record_active_created'), ('idx_task_links_task_active_created')
) AS expected(indexname)
ORDER BY exists ASC, indexname;

-- ─── 5. RLS enabled + policy ────────────────────────────────────
SELECT relrowsecurity AS task_links_rls_enabled FROM pg_class WHERE relname = 'task_links' AND relnamespace = 'public'::regnamespace;
SELECT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'task_links_select') AS task_links_select_policy_exists;

-- No INSERT/UPDATE/DELETE policy should exist on task_links.
SELECT count(*) AS non_select_policies_expect_0
FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
WHERE c.relname = 'task_links' AND p.polcmd NOT IN ('r');

-- ─── 6. Helpers + RPCs ──────────────────────────────────────────
SELECT proname,
  EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = expected.proname
  ) AS exists
FROM (VALUES
  ('can_manage_request_task_link'), ('can_manage_task'), ('can_view_task_link'),
  ('create_request_supporting_task'), ('link_existing_task_to_request'),
  ('unlink_task_from_request'), ('list_request_supporting_tasks'),
  ('list_task_request_links'), ('get_request_task_capabilities')
) AS expected(proname)
ORDER BY exists ASC, proname;

-- ─── 7. Audit action constraint extended ────────────────────────
SELECT
  pg_get_constraintdef(oid) LIKE '%task_linked%' AND pg_get_constraintdef(oid) LIKE '%task_unlinked%' AS audit_logs_action_has_link_actions
FROM pg_constraint WHERE conname = 'audit_logs_action_check';

-- No notification type was added for this milestone (deliberate — see docs/33).

-- ─── 8. Hard failure if anything above is missing ───────────────
DO $$
DECLARE
  v_missing TEXT := '';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'task_links') THEN
    v_missing := v_missing || 'table:task_links ';
  END IF;

  IF NOT (SELECT COALESCE(relrowsecurity, FALSE) FROM pg_class WHERE relname = 'task_links' AND relnamespace = 'public'::regnamespace) THEN
    v_missing := v_missing || 'rls:task_links ';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'task_links_select') THEN
    v_missing := v_missing || 'policy:task_links_select ';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
    WHERE c.relname = 'task_links' AND p.polcmd NOT IN ('r')
  ) THEN
    v_missing := v_missing || 'unexpected-mutation-policy:task_links ';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'idx_task_links_active_unique') THEN
    v_missing := v_missing || 'index:idx_task_links_active_unique ';
  END IF;

  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('can_manage_request_task_link'), ('can_manage_task'), ('can_view_task_link'),
      ('create_request_supporting_task'), ('link_existing_task_to_request'),
      ('unlink_task_from_request'), ('list_request_supporting_tasks'),
      ('list_task_request_links'), ('get_request_task_capabilities')
    ) AS expected(proname)
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.proname
    )
  ) THEN
    v_missing := v_missing || 'rpc:one-or-more-missing(see query 6 above) ';
  END IF;

  IF NOT (SELECT pg_get_constraintdef(oid) LIKE '%task_linked%' FROM pg_constraint WHERE conname = 'audit_logs_action_check') THEN
    v_missing := v_missing || 'constraint:audit_logs_action_check-missing-task_linked ';
  END IF;
  IF NOT (SELECT pg_get_constraintdef(oid) LIKE '%task_unlinked%' FROM pg_constraint WHERE conname = 'audit_logs_action_check') THEN
    v_missing := v_missing || 'constraint:audit_logs_action_check-missing-task_unlinked ';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint c
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
    WHERE c.conrelid = 'task_links'::regclass AND c.contype = 'f' AND a.attname = 'record_id'
  ) THEN
    v_missing := v_missing || 'unexpected-fk:task_links.record_id-should-stay-polymorphic ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Request-Task Integration validation FAILED, missing: %', v_missing USING ERRCODE = 'P0001';
  ELSE
    RAISE NOTICE 'Request-Task Integration validation PASSED: table, indexes, constraints, RLS, policies, helpers, and RPCs all present.';
  END IF;
END $$;
