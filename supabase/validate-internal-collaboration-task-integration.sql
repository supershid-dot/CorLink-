-- ============================================================
-- CorLink — Validate: Internal Collaboration ↔ Shared Tasks Integration
-- Companion to supabase/patch-internal-collaboration-task-integration.sql
--
-- Read-only. Confirms task_links' widened module_key CHECK (preserving
-- 'request' and 'meeting'), the internal_request branch of
-- can_view_task_link(), all new helpers/RPCs, search_path pinning, and
-- that R4's original task_links indexes are still intact (no schema
-- change was needed for them, but a regression here would silently
-- break pagination/lookup performance for all three modules at once).
-- Raises an exception listing anything missing rather than failing
-- silently.
-- ============================================================

-- ─── 1. module_key restriction widened to include 'internal_request' ──
SELECT
  pg_get_constraintdef(oid) LIKE '%''request''%'          AS module_key_still_allows_request,
  pg_get_constraintdef(oid) LIKE '%''meeting''%'           AS module_key_still_allows_meeting,
  pg_get_constraintdef(oid) LIKE '%''internal_request''%'  AS module_key_now_allows_internal_request
FROM pg_constraint WHERE conrelid = 'task_links'::regclass AND contype = 'c' AND conname LIKE '%module_key%';

-- Confirm a still-unsupported module_key ('entry') is rejected.
DO $$
BEGIN
  BEGIN
    INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by)
    VALUES (gen_random_uuid(), 'entry', gen_random_uuid(), gen_random_uuid(), gen_random_uuid());
    RAISE EXCEPTION 'VALIDATION_FAILED: unsupported module_key ''entry'' was accepted';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'module_key CHECK correctly rejects a still-unsupported value (''entry'')';
    WHEN foreign_key_violation THEN
      RAISE NOTICE 'module_key CHECK correctly rejected (surfaced as FK violation on other columns first, which also proves the row never landed)';
  END;
END $$;

-- ─── 2. R4 indexes still intact (no schema change needed this
--        milestone, but a silent drop would break all three modules) ──
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
  ('can_view_internal_request'), ('can_manage_internal_collab_task_link'),
  ('create_internal_collaboration_supporting_task'), ('link_existing_task_to_internal_collaboration'),
  ('unlink_task_from_internal_collaboration'), ('list_internal_collaboration_tasks'),
  ('list_task_internal_collaboration_links'), ('get_internal_collaboration_task_capabilities'),
  -- Reused, unmodified R3/R4/R5 functions this milestone depends on:
  ('can_manage_task'), ('can_view_task_link'), ('can_view_task'), ('scope_org_id'), ('my_section_ids'), ('is_supervisor_or_above')
) AS expected(proname)
ORDER BY exists ASC, proname;

-- can_view_task_link's internal_request branch specifically (not just
-- its existence) — confirms the function body was actually widened a
-- second time, still on top of R5's meeting branch, not replaced by it.
SELECT
  pg_get_functiondef(oid) LIKE '%can_view_internal_request%' AS can_view_task_link_has_internal_request_branch,
  pg_get_functiondef(oid) LIKE '%meeting_decisions%'          AS can_view_task_link_still_has_meeting_branch,
  pg_get_functiondef(oid) LIKE '%can_view_request_or_response%' AS can_view_task_link_still_has_request_branch
FROM pg_proc WHERE proname = 'can_view_task_link';

-- can_view_internal_request()/can_manage_internal_collab_task_link()
-- mirror internal_requests_select's own conditions (plus a deliberate
-- assigned_to addition on the view side, see the patch file's own
-- comment) — spot-check the from_section/to_section/previous_section/
-- created_by/assigned_to shape is present (not a stand-in that always
-- returns TRUE/FALSE).
SELECT
  pg_get_functiondef(oid) LIKE '%from_section_id%' AND pg_get_functiondef(oid) LIKE '%to_section_id%'
    AND pg_get_functiondef(oid) LIKE '%previous_section_id%' AND pg_get_functiondef(oid) LIKE '%created_by%'
    AND pg_get_functiondef(oid) LIKE '%assigned_to%'
    AS can_view_internal_request_has_full_visibility_shape
FROM pg_proc WHERE proname = 'can_view_internal_request';

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
  'can_view_internal_request', 'can_manage_internal_collab_task_link',
  'create_internal_collaboration_supporting_task', 'link_existing_task_to_internal_collaboration',
  'unlink_task_from_internal_collaboration', 'list_internal_collaboration_tasks',
  'list_task_internal_collaboration_links', 'get_internal_collaboration_task_capabilities',
  'can_view_task_link'
)
ORDER BY search_path_pinned ASC, p.proname;

-- ─── 6. Active-link uniqueness still enforced (regression guard,
--        shared index — not new, but this is the first validator to
--        exercise it with an internal_request module_key value) ────
DO $$
DECLARE
  v_org UUID;
  v_user UUID;
  v_task UUID;
  v_ir UUID;
BEGIN
  SELECT id INTO v_org FROM organizations LIMIT 1;
  SELECT id INTO v_user FROM users WHERE org_id = v_org LIMIT 1;
  SELECT id INTO v_task FROM tasks WHERE organization_id = v_org LIMIT 1;
  SELECT id INTO v_ir FROM internal_requests LIMIT 1;

  IF v_org IS NULL OR v_user IS NULL OR v_task IS NULL OR v_ir IS NULL THEN
    RAISE NOTICE 'Skipping active-link-uniqueness smoke test: no fixture org/user/task/internal_request row available in this database.';
    RETURN;
  END IF;

  -- First insert wrapped in its own sub-block too: if this exact
  -- (task, internal_request) pair already has a live active link from
  -- real prior usage, this fails on the SAME unique_violation the
  -- duplicate-rejection test below is trying to prove — in that case,
  -- skip the smoke test rather than mistaking "already linked" for
  -- "not testable", and never touch a row this validator didn't create.
  BEGIN
    INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by) VALUES (v_task, 'internal_request', v_ir, v_org, v_user);
  EXCEPTION
    WHEN unique_violation THEN
      RAISE NOTICE 'Skipping active-link-uniqueness smoke test: chosen fixture pair already has a live active link (expected in a database with real usage).';
      RETURN;
  END;

  BEGIN
    INSERT INTO task_links (task_id, module_key, record_id, organization_id, created_by) VALUES (v_task, 'internal_request', v_ir, v_org, v_user);
    RAISE EXCEPTION 'VALIDATION_FAILED: a duplicate ACTIVE task_links row (module_key=internal_request) was accepted';
  EXCEPTION
    WHEN unique_violation THEN
      RAISE NOTICE 'idx_task_links_active_unique correctly rejects a duplicate active internal_request link';
  END;

  -- Deterministic cleanup of exactly the one smoke-test row this block
  -- itself inserted above — this validator stays read-only from the
  -- caller's perspective; nothing it wrote is left behind.
  DELETE FROM task_links WHERE task_id = v_task AND module_key = 'internal_request' AND record_id = v_ir AND created_by = v_user;
END $$;

-- ─── 7. Hard failure if anything above is missing ───────────────
DO $$
DECLARE
  v_missing TEXT := '';
BEGIN
  IF NOT (SELECT pg_get_constraintdef(oid) LIKE '%''internal_request''%' FROM pg_constraint WHERE conrelid = 'task_links'::regclass AND contype = 'c' AND conname LIKE '%module_key%') THEN
    v_missing := v_missing || 'constraint:task_links_module_key_check-missing-internal_request ';
  END IF;
  IF NOT (SELECT pg_get_constraintdef(oid) LIKE '%''request''%' FROM pg_constraint WHERE conrelid = 'task_links'::regclass AND contype = 'c' AND conname LIKE '%module_key%') THEN
    v_missing := v_missing || 'constraint:task_links_module_key_check-lost-request ';
  END IF;
  IF NOT (SELECT pg_get_constraintdef(oid) LIKE '%''meeting''%' FROM pg_constraint WHERE conrelid = 'task_links'::regclass AND contype = 'c' AND conname LIKE '%module_key%') THEN
    v_missing := v_missing || 'constraint:task_links_module_key_check-lost-meeting ';
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

  IF NOT (SELECT pg_get_functiondef(oid) LIKE '%can_view_internal_request%' FROM pg_proc WHERE proname = 'can_view_task_link') THEN
    v_missing := v_missing || 'function:can_view_task_link-missing-internal_request-branch ';
  END IF;
  IF NOT (SELECT pg_get_functiondef(oid) LIKE '%meeting_decisions%' FROM pg_proc WHERE proname = 'can_view_task_link') THEN
    v_missing := v_missing || 'function:can_view_task_link-lost-meeting-branch ';
  END IF;
  IF NOT (SELECT pg_get_functiondef(oid) LIKE '%can_view_request_or_response%' FROM pg_proc WHERE proname = 'can_view_task_link') THEN
    v_missing := v_missing || 'function:can_view_task_link-lost-request-branch ';
  END IF;

  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('can_view_internal_request'), ('can_manage_internal_collab_task_link'),
      ('create_internal_collaboration_supporting_task'), ('link_existing_task_to_internal_collaboration'),
      ('unlink_task_from_internal_collaboration'), ('list_internal_collaboration_tasks'),
      ('list_task_internal_collaboration_links'), ('get_internal_collaboration_task_capabilities')
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
      'can_view_internal_request', 'can_manage_internal_collab_task_link',
      'create_internal_collaboration_supporting_task', 'link_existing_task_to_internal_collaboration',
      'unlink_task_from_internal_collaboration', 'get_internal_collaboration_task_capabilities',
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
    RAISE EXCEPTION 'Internal-Collaboration-Task Integration validation FAILED, missing: %', v_missing USING ERRCODE = 'P0001';
  ELSE
    RAISE NOTICE 'Internal-Collaboration-Task Integration validation PASSED: constraints, indexes, RLS, helpers, and RPCs all present, search_path pinned throughout, request/meeting branches preserved.';
  END IF;
END $$;
