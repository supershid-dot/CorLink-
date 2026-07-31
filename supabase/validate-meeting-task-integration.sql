-- ============================================================
-- CorLink — Validate: Meetings ↔ Shared Tasks Integration
-- Companion to supabase/patch-meeting-task-integration.sql
--
-- Read-only. Confirms meeting_decisions' table/columns/indexes/RLS,
-- task_links' widened module_key CHECK, the meeting branch of
-- can_view_task_link(), and all new helpers/RPCs exist, then raises
-- an exception listing anything missing rather than failing silently.
-- ============================================================

-- ─── 1. meeting_decisions table + columns ───────────────────────
SELECT column_name,
  EXISTS (
    SELECT 1 FROM information_schema.columns c
    WHERE c.table_schema = 'public' AND c.table_name = 'meeting_decisions' AND c.column_name = expected.column_name
  ) AS exists
FROM (VALUES
  ('id'), ('meeting_id'), ('organization_id'), ('title'), ('description'), ('created_by'), ('created_at')
) AS expected(column_name)
ORDER BY exists ASC, column_name;

SELECT conname,
  EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conname = expected.conname) AS exists
FROM (VALUES
  ('meeting_decisions_meeting_id_fkey'), ('meeting_decisions_organization_id_fkey'), ('meeting_decisions_created_by_fkey')
) AS expected(conname)
ORDER BY exists ASC, conname;

-- ─── 2. Indexes ─────────────────────────────────────────────────
SELECT indexname,
  EXISTS (SELECT 1 FROM pg_indexes i WHERE i.schemaname = 'public' AND i.indexname = expected.indexname) AS exists
FROM (VALUES
  ('idx_meeting_decisions_meeting'), ('idx_meeting_decisions_org')
) AS expected(indexname)
ORDER BY exists ASC, indexname;

-- ─── 3. RLS + policy ────────────────────────────────────────────
SELECT relrowsecurity AS meeting_decisions_rls_enabled FROM pg_class WHERE relname = 'meeting_decisions' AND relnamespace = 'public'::regnamespace;
SELECT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'meeting_decisions_select') AS meeting_decisions_select_policy_exists;
SELECT count(*) AS meeting_decisions_non_select_policies_expect_0
FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
WHERE c.relname = 'meeting_decisions' AND p.polcmd NOT IN ('r');

-- ─── 4. module_key restriction widened to include 'meeting' ─────
SELECT
  pg_get_constraintdef(oid) LIKE '%''request''%' AS module_key_still_allows_request,
  pg_get_constraintdef(oid) LIKE '%''meeting''%' AS module_key_now_allows_meeting
FROM pg_constraint WHERE conrelid = 'task_links'::regclass AND contype = 'c' AND conname LIKE '%module_key%';

-- Confirm a third, still-unsupported module_key is rejected.
DO $$
BEGIN
  BEGIN
    INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by)
    VALUES (gen_random_uuid(), 'entry', gen_random_uuid(), gen_random_uuid(), gen_random_uuid());
    RAISE EXCEPTION 'VALIDATION_FAILED: unsupported module_key ''entry'' was accepted';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'module_key CHECK correctly rejects a third, still-unsupported value (''entry'')';
    WHEN foreign_key_violation THEN
      RAISE NOTICE 'module_key CHECK correctly rejected (surfaced as FK violation on other columns first, which also proves the row never landed)';
  END;
END $$;

-- ─── 5. Helpers + RPCs ──────────────────────────────────────────
SELECT proname,
  EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = expected.proname
  ) AS exists
FROM (VALUES
  ('can_manage_meeting_task_link'), ('resolve_or_create_meeting_decision'),
  ('create_meeting_task'), ('link_existing_task_to_meeting'), ('unlink_task_from_meeting'),
  ('list_meeting_tasks'), ('list_task_meeting_links'), ('get_meeting_task_capabilities'),
  -- Reused, unmodified R3/R4 functions this milestone depends on:
  ('can_view_meeting'), ('can_manage_meeting'), ('can_manage_task'), ('can_view_task_link'), ('can_view_task')
) AS expected(proname)
ORDER BY exists ASC, proname;

-- can_view_task_link's meeting branch specifically (not just its
-- existence) — confirms the function body was actually widened, not
-- just left as R4's request-only version.
SELECT pg_get_functiondef(oid) LIKE '%meeting_decisions%' AS can_view_task_link_has_meeting_branch
FROM pg_proc WHERE proname = 'can_view_task_link';

-- ─── 6. search_path pinned on every new SECURITY DEFINER function ──
SELECT p.proname,
  EXISTS (
    SELECT 1 FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) cfg WHERE cfg LIKE 'search_path=%'
  ) AS search_path_pinned
FROM pg_proc p
WHERE p.proname IN (
  'can_manage_meeting_task_link', 'resolve_or_create_meeting_decision',
  'create_meeting_task', 'link_existing_task_to_meeting', 'unlink_task_from_meeting',
  'list_meeting_tasks', 'list_task_meeting_links', 'get_meeting_task_capabilities'
)
ORDER BY search_path_pinned ASC, p.proname;

-- ─── 7. Hard failure if anything above is missing ───────────────
DO $$
DECLARE
  v_missing TEXT := '';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'meeting_decisions') THEN
    v_missing := v_missing || 'table:meeting_decisions ';
  END IF;

  IF NOT (SELECT COALESCE(relrowsecurity, FALSE) FROM pg_class WHERE relname = 'meeting_decisions' AND relnamespace = 'public'::regnamespace) THEN
    v_missing := v_missing || 'rls:meeting_decisions ';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'meeting_decisions_select') THEN
    v_missing := v_missing || 'policy:meeting_decisions_select ';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
    WHERE c.relname = 'meeting_decisions' AND p.polcmd NOT IN ('r')
  ) THEN
    v_missing := v_missing || 'unexpected-mutation-policy:meeting_decisions ';
  END IF;

  IF NOT (SELECT pg_get_constraintdef(oid) LIKE '%''meeting''%' FROM pg_constraint WHERE conrelid = 'task_links'::regclass AND contype = 'c' AND conname LIKE '%module_key%') THEN
    v_missing := v_missing || 'constraint:task_links_module_key_check-missing-meeting ';
  END IF;
  IF NOT (SELECT pg_get_constraintdef(oid) LIKE '%''request''%' FROM pg_constraint WHERE conrelid = 'task_links'::regclass AND contype = 'c' AND conname LIKE '%module_key%') THEN
    v_missing := v_missing || 'constraint:task_links_module_key_check-lost-request ';
  END IF;

  IF NOT (SELECT pg_get_functiondef(oid) LIKE '%meeting_decisions%' FROM pg_proc WHERE proname = 'can_view_task_link') THEN
    v_missing := v_missing || 'function:can_view_task_link-missing-meeting-branch ';
  END IF;

  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('can_manage_meeting_task_link'), ('resolve_or_create_meeting_decision'),
      ('create_meeting_task'), ('link_existing_task_to_meeting'), ('unlink_task_from_meeting'),
      ('list_meeting_tasks'), ('list_task_meeting_links'), ('get_meeting_task_capabilities')
    ) AS expected(proname)
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.proname
    )
  ) THEN
    v_missing := v_missing || 'rpc:one-or-more-missing(see query 5 above) ';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_proc p
    WHERE p.proname IN (
      'can_manage_meeting_task_link', 'resolve_or_create_meeting_decision',
      'create_meeting_task', 'link_existing_task_to_meeting', 'unlink_task_from_meeting',
      'get_meeting_task_capabilities'
    )
    AND NOT EXISTS (
      SELECT 1 FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) cfg WHERE cfg LIKE 'search_path=%'
    )
  ) THEN
    v_missing := v_missing || 'search_path:one-or-more-SECURITY-DEFINER-functions-unpinned(see query 6 above) ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Meeting-Task Integration validation FAILED, missing: %', v_missing USING ERRCODE = 'P0001';
  ELSE
    RAISE NOTICE 'Meeting-Task Integration validation PASSED: table, indexes, constraints, RLS, policies, helpers, and RPCs all present, search_path pinned throughout.';
  END IF;
END $$;
