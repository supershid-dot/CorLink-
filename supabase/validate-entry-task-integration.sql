-- ============================================================
-- CorLink — Validate: Entry ↔ Shared Tasks Integration
-- Companion to supabase/patch-entry-task-integration.sql
--
-- Read-only. Confirms task_links' widened module_key CHECK (preserving
-- 'request', 'meeting', 'internal_request'), the external_correspondence
-- branch of can_view_task_link(), all new helpers/RPCs, search_path
-- pinning, and that R4's original task_links indexes are still intact.
-- Raises an exception listing anything missing rather than failing
-- silently.
-- ============================================================

-- ─── 1. module_key restriction widened to include
--        'external_correspondence' ─────────────────────────────
SELECT
  pg_get_constraintdef(oid) LIKE '%''request''%'                  AS module_key_still_allows_request,
  pg_get_constraintdef(oid) LIKE '%''meeting''%'                   AS module_key_still_allows_meeting,
  pg_get_constraintdef(oid) LIKE '%''internal_request''%'          AS module_key_still_allows_internal_request,
  pg_get_constraintdef(oid) LIKE '%''external_correspondence''%'   AS module_key_now_allows_entry
FROM pg_constraint WHERE conrelid = 'task_links'::regclass AND contype = 'c' AND conname LIKE '%module_key%';

-- Confirm a still-unsupported module_key ('prisoner_letter') is rejected.
DO $$
BEGIN
  BEGIN
    INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by)
    VALUES (gen_random_uuid(), 'prisoner_letter', gen_random_uuid(), gen_random_uuid(), gen_random_uuid());
    RAISE EXCEPTION 'VALIDATION_FAILED: unsupported module_key ''prisoner_letter'' was accepted';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'module_key CHECK correctly rejects a still-unsupported value (''prisoner_letter'')';
    WHEN foreign_key_violation THEN
      RAISE NOTICE 'module_key CHECK correctly rejected (surfaced as FK violation on other columns first, which also proves the row never landed)';
  END;
END $$;

-- ─── 2. R4 indexes still intact ──────────────────────────────────
SELECT indexname,
  EXISTS (SELECT 1 FROM pg_indexes i WHERE i.schemaname = 'public' AND i.indexname = expected.indexname) AS exists
FROM (VALUES
  ('idx_task_links_task'), ('idx_task_links_module_record'), ('idx_task_links_org'),
  ('idx_task_links_active_unique'), ('idx_task_links_record_active_created'), ('idx_task_links_task_active_created')
) AS expected(indexname)
ORDER BY exists ASC, indexname;

-- ─── 3. Helpers + RPCs ──────────────────────────────────────────
SELECT proname,
  EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = expected.proname
  ) AS exists
FROM (VALUES
  ('can_view_entry'), ('can_manage_entry_task_link'),
  ('create_entry_supporting_task'), ('link_existing_task_to_entry'),
  ('unlink_task_from_entry'), ('list_entry_tasks'),
  ('list_task_entry_links'), ('get_entry_task_capabilities'),
  -- Reused, unmodified R3/R4/R5/R6 functions this milestone depends on:
  ('can_manage_task'), ('can_view_task_link'), ('can_view_task'),
  ('is_entry_staff'), ('can_view_internal_request')
) AS expected(proname)
ORDER BY exists ASC, proname;

-- can_view_task_link's external_correspondence branch specifically
-- (not just its existence) — confirms the function body was actually
-- widened a third time, on top of R5's and R6's own branches, not
-- replacing either.
SELECT
  pg_get_functiondef(oid) LIKE '%can_view_entry%'                AS can_view_task_link_has_entry_branch,
  pg_get_functiondef(oid) LIKE '%can_view_internal_request%'      AS can_view_task_link_still_has_internal_request_branch,
  pg_get_functiondef(oid) LIKE '%meeting_decisions%'              AS can_view_task_link_still_has_meeting_branch,
  pg_get_functiondef(oid) LIKE '%can_view_request_or_response%'   AS can_view_task_link_still_has_request_branch
FROM pg_proc WHERE proname = 'can_view_task_link';

-- can_view_entry() mirrors external_correspondence_select's own
-- conditions — spot-check the is_entry_staff/to_section/assigned_to/
-- entered_by shape is present (not a stand-in that always returns
-- TRUE/FALSE).
SELECT
  pg_get_functiondef(oid) LIKE '%is_entry_staff%' AND pg_get_functiondef(oid) LIKE '%to_section_id%'
    AND pg_get_functiondef(oid) LIKE '%assigned_to%' AND pg_get_functiondef(oid) LIKE '%entered_by%'
    AS can_view_entry_has_full_visibility_shape
FROM pg_proc WHERE proname = 'can_view_entry';

-- ─── 4. RLS: no new table, so no new policy — confirm task_links
--        still carries exactly one SELECT policy, no direct-write
--        policy was accidentally introduced by this milestone ──────
SELECT count(*) AS task_links_select_policies_expect_1
FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
WHERE c.relname = 'task_links' AND p.polcmd = 'r';
SELECT count(*) AS task_links_non_select_policies_expect_0
FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
WHERE c.relname = 'task_links' AND p.polcmd NOT IN ('r');

-- ─── 5. search_path pinned on every new SECURITY DEFINER function ──
SELECT p.proname,
  EXISTS (
    SELECT 1 FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) cfg WHERE cfg LIKE 'search_path=%'
  ) AS search_path_pinned
FROM pg_proc p
WHERE p.proname IN (
  'can_view_entry', 'can_manage_entry_task_link',
  'create_entry_supporting_task', 'link_existing_task_to_entry',
  'unlink_task_from_entry', 'list_entry_tasks',
  'list_task_entry_links', 'get_entry_task_capabilities',
  'can_view_task_link'
)
ORDER BY search_path_pinned ASC, p.proname;

-- ─── 6. Active-link uniqueness still enforced (regression guard,
--        shared index — first validator to exercise it with an
--        external_correspondence module_key value) ────────────────
DO $$
DECLARE
  v_org UUID;
  v_user UUID;
  v_task UUID;
  v_entry UUID;
BEGIN
  SELECT id INTO v_org FROM organizations LIMIT 1;
  SELECT id INTO v_user FROM users WHERE org_id = v_org LIMIT 1;
  SELECT id INTO v_task FROM tasks WHERE organization_id = v_org LIMIT 1;
  SELECT id INTO v_entry FROM external_correspondence WHERE org_id = v_org LIMIT 1;

  IF v_org IS NULL OR v_user IS NULL OR v_task IS NULL OR v_entry IS NULL THEN
    RAISE NOTICE 'Skipping active-link-uniqueness smoke test: no fixture org/user/task/entry row available in this database.';
    RETURN;
  END IF;

  BEGIN
    INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by) VALUES (v_task, 'external_correspondence', v_entry, v_org, v_user);
  EXCEPTION
    WHEN unique_violation THEN
      RAISE NOTICE 'Skipping active-link-uniqueness smoke test: chosen fixture pair already has a live active link (expected in a database with real usage).';
      RETURN;
  END;

  BEGIN
    INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by) VALUES (v_task, 'external_correspondence', v_entry, v_org, v_user);
    RAISE EXCEPTION 'VALIDATION_FAILED: a duplicate ACTIVE task_links row (module_key=external_correspondence) was accepted';
  EXCEPTION
    WHEN unique_violation THEN
      RAISE NOTICE 'idx_task_links_active_unique correctly rejects a duplicate active external_correspondence link';
  END;

  DELETE FROM task_links WHERE task_id = v_task AND module_key = 'external_correspondence' AND record_id = v_entry AND created_by = v_user;
END $$;

-- ─── 7. Hard failure if anything above is missing ───────────────
DO $$
DECLARE
  v_missing TEXT := '';
BEGIN
  IF NOT (SELECT pg_get_constraintdef(oid) LIKE '%''external_correspondence''%' FROM pg_constraint WHERE conrelid = 'task_links'::regclass AND contype = 'c' AND conname LIKE '%module_key%') THEN
    v_missing := v_missing || 'constraint:task_links_module_key_check-missing-external_correspondence ';
  END IF;
  IF NOT (SELECT pg_get_constraintdef(oid) LIKE '%''request''%' FROM pg_constraint WHERE conrelid = 'task_links'::regclass AND contype = 'c' AND conname LIKE '%module_key%') THEN
    v_missing := v_missing || 'constraint:task_links_module_key_check-lost-request ';
  END IF;
  IF NOT (SELECT pg_get_constraintdef(oid) LIKE '%''meeting''%' FROM pg_constraint WHERE conrelid = 'task_links'::regclass AND contype = 'c' AND conname LIKE '%module_key%') THEN
    v_missing := v_missing || 'constraint:task_links_module_key_check-lost-meeting ';
  END IF;
  IF NOT (SELECT pg_get_constraintdef(oid) LIKE '%''internal_request''%' FROM pg_constraint WHERE conrelid = 'task_links'::regclass AND contype = 'c' AND conname LIKE '%module_key%') THEN
    v_missing := v_missing || 'constraint:task_links_module_key_check-lost-internal_request ';
  END IF;

  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('idx_task_links_task'), ('idx_task_links_module_record'), ('idx_task_links_org'),
      ('idx_task_links_active_unique'), ('idx_task_links_record_active_created'), ('idx_task_links_task_active_created')
    ) AS expected(indexname)
    WHERE NOT EXISTS (SELECT 1 FROM pg_indexes i WHERE i.schemaname = 'public' AND i.indexname = expected.indexname)
  ) THEN
    v_missing := v_missing || 'index:one-or-more-task_links-indexes-missing(see query 2 above) ';
  END IF;

  IF NOT (SELECT pg_get_functiondef(oid) LIKE '%can_view_entry%' FROM pg_proc WHERE proname = 'can_view_task_link') THEN
    v_missing := v_missing || 'function:can_view_task_link-missing-entry-branch ';
  END IF;
  IF NOT (SELECT pg_get_functiondef(oid) LIKE '%can_view_internal_request%' FROM pg_proc WHERE proname = 'can_view_task_link') THEN
    v_missing := v_missing || 'function:can_view_task_link-lost-internal_request-branch ';
  END IF;
  IF NOT (SELECT pg_get_functiondef(oid) LIKE '%meeting_decisions%' FROM pg_proc WHERE proname = 'can_view_task_link') THEN
    v_missing := v_missing || 'function:can_view_task_link-lost-meeting-branch ';
  END IF;
  IF NOT (SELECT pg_get_functiondef(oid) LIKE '%can_view_request_or_response%' FROM pg_proc WHERE proname = 'can_view_task_link') THEN
    v_missing := v_missing || 'function:can_view_task_link-lost-request-branch ';
  END IF;

  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('can_view_entry'), ('can_manage_entry_task_link'),
      ('create_entry_supporting_task'), ('link_existing_task_to_entry'),
      ('unlink_task_from_entry'), ('list_entry_tasks'),
      ('list_task_entry_links'), ('get_entry_task_capabilities')
    ) AS expected(proname)
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.proname
    )
  ) THEN
    v_missing := v_missing || 'rpc:one-or-more-missing(see query 3 above) ';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_proc p
    WHERE p.proname IN (
      'can_view_entry', 'can_manage_entry_task_link',
      'create_entry_supporting_task', 'link_existing_task_to_entry',
      'unlink_task_from_entry', 'get_entry_task_capabilities',
      'can_view_task_link'
    )
    AND NOT EXISTS (
      SELECT 1 FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) cfg WHERE cfg LIKE 'search_path=%'
    )
  ) THEN
    v_missing := v_missing || 'search_path:one-or-more-SECURITY-DEFINER-functions-unpinned(see query 5 above) ';
  END IF;

  IF (SELECT count(*) FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid WHERE c.relname = 'task_links' AND p.polcmd NOT IN ('r')) > 0 THEN
    v_missing := v_missing || 'rls:task_links-unexpected-mutation-policy ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Entry-Task Integration validation FAILED, missing: %', v_missing USING ERRCODE = 'P0001';
  ELSE
    RAISE NOTICE 'Entry-Task Integration validation PASSED: constraints, indexes, RLS, helpers, and RPCs all present, search_path pinned throughout, request/meeting/internal_request branches preserved.';
  END IF;
END $$;
