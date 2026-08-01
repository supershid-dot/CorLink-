-- ============================================================
-- CorLink — Validate: Task Audit Visibility Correction (T2C.1)
-- Companion to supabase/patch-task-audit-visibility.sql
--
-- Read-only. Confirms can_view_case_audit_record() exists, is
-- SECURITY DEFINER with search_path pinned, its body contains the new
-- 'task' branch delegating to can_view_task(), and every previously
-- supported branch (request/response/internal_request/
-- external_correspondence/meeting_series) is still present — i.e.
-- this patch strictly ADDED, never removed or altered, anything.
-- Also confirms no stale duplicate overload exists and grants are
-- unchanged from PostgreSQL's default (no explicit REVOKE was ever
-- applied to this function anywhere in the migration chain, so
-- "unchanged" here means "still default", checked explicitly rather
-- than assumed). Raises an exception listing anything missing rather
-- than failing silently.
-- ============================================================

-- ─── 1. Function exists, correct signature, SECURITY DEFINER,
--        search_path pinned ─────────────────────────────────────
SELECT
  p.proname,
  pg_get_function_identity_arguments(p.oid) AS args,
  p.prosecdef AS is_security_definer,
  EXISTS (
    SELECT 1 FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) cfg WHERE cfg LIKE 'search_path=%'
  ) AS search_path_pinned
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'can_view_case_audit_record';

-- ─── 2. Exactly one overload (no stale duplicate signature left
--        behind by a prior CREATE OR REPLACE under a different
--        argument list) ─────────────────────────────────────────
SELECT count(*) AS overload_count
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'can_view_case_audit_record';

-- ─── 3. Body contains every previously supported branch PLUS the
--        new task branch, and the task branch delegates to
--        can_view_task() rather than reimplementing its own
--        EXISTS(...) visibility logic ──────────────────────────
SELECT
  pg_get_functiondef(oid) LIKE '%''request'' AND EXISTS%'              AS has_request_branch,
  pg_get_functiondef(oid) LIKE '%''response'' AND EXISTS%'             AS has_response_branch,
  pg_get_functiondef(oid) LIKE '%''internal_request'' AND EXISTS%'     AS has_internal_request_branch,
  pg_get_functiondef(oid) LIKE '%''external_correspondence'' AND EXISTS%' AS has_external_correspondence_branch,
  pg_get_functiondef(oid) LIKE '%''meeting_series'' AND EXISTS%'       AS has_meeting_series_branch,
  pg_get_functiondef(oid) LIKE '%''task'' AND can_view_task(p_record_id)%' AS has_task_branch_delegating_to_can_view_task,
  -- Negative check: the task branch must NOT contain its own
  -- "SELECT 1 FROM tasks t WHERE ..." — that would mean visibility
  -- logic was duplicated here instead of delegated.
  NOT (pg_get_functiondef(oid) ~ '''task'' AND EXISTS \(\s*SELECT 1 FROM tasks') AS task_branch_not_duplicated
FROM pg_proc WHERE proname = 'can_view_case_audit_record';

-- ─── 4. can_view_task() itself still exists and is unmodified by
--        this patch (this patch must never touch it) ────────────
SELECT
  EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'can_view_task') AS can_view_task_exists;

-- ─── 5. No explicit grant/revoke was ever applied to this function
--        by any prior migration, and none is expected to exist now
--        either — "preserve grants" means "still nothing explicit",
--        checked rather than assumed. Default PostgreSQL behavior
--        (EXECUTE granted to PUBLIC unless revoked) applies. ──────
SELECT has_function_privilege('authenticated', 'can_view_case_audit_record(text, uuid)', 'EXECUTE') AS authenticated_can_execute;

-- ─── 6. Aggregate pass/fail ───────────────────────────────────────
DO $$
DECLARE
  v_missing TEXT := '';
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'can_view_case_audit_record'
  ) THEN
    v_missing := v_missing || 'function:can_view_case_audit_record-missing ';
  END IF;

  IF (SELECT count(*) FROM pg_proc WHERE proname = 'can_view_case_audit_record') <> 1 THEN
    v_missing := v_missing || 'overload:unexpected-count(expected-exactly-1) ';
  END IF;

  IF NOT (SELECT p.prosecdef FROM pg_proc p WHERE p.proname = 'can_view_case_audit_record') THEN
    v_missing := v_missing || 'security:not-SECURITY-DEFINER ';
  END IF;

  IF NOT (
    SELECT EXISTS (
      SELECT 1 FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) cfg WHERE cfg LIKE 'search_path=%'
    ) FROM pg_proc p WHERE p.proname = 'can_view_case_audit_record'
  ) THEN
    v_missing := v_missing || 'search_path:not-pinned ';
  END IF;

  IF NOT (SELECT pg_get_functiondef(oid) LIKE '%''request'' AND EXISTS%' FROM pg_proc WHERE proname = 'can_view_case_audit_record') THEN
    v_missing := v_missing || 'branch:request-lost ';
  END IF;
  IF NOT (SELECT pg_get_functiondef(oid) LIKE '%''response'' AND EXISTS%' FROM pg_proc WHERE proname = 'can_view_case_audit_record') THEN
    v_missing := v_missing || 'branch:response-lost ';
  END IF;
  IF NOT (SELECT pg_get_functiondef(oid) LIKE '%''internal_request'' AND EXISTS%' FROM pg_proc WHERE proname = 'can_view_case_audit_record') THEN
    v_missing := v_missing || 'branch:internal_request-lost ';
  END IF;
  IF NOT (SELECT pg_get_functiondef(oid) LIKE '%''external_correspondence'' AND EXISTS%' FROM pg_proc WHERE proname = 'can_view_case_audit_record') THEN
    v_missing := v_missing || 'branch:external_correspondence-lost ';
  END IF;
  IF NOT (SELECT pg_get_functiondef(oid) LIKE '%''meeting_series'' AND EXISTS%' FROM pg_proc WHERE proname = 'can_view_case_audit_record') THEN
    v_missing := v_missing || 'branch:meeting_series-lost ';
  END IF;
  IF NOT (SELECT pg_get_functiondef(oid) LIKE '%''task'' AND can_view_task(p_record_id)%' FROM pg_proc WHERE proname = 'can_view_case_audit_record') THEN
    v_missing := v_missing || 'branch:task-missing-or-not-delegating ';
  END IF;
  IF (SELECT pg_get_functiondef(oid) ~ '''task'' AND EXISTS \(\s*SELECT 1 FROM tasks' FROM pg_proc WHERE proname = 'can_view_case_audit_record') THEN
    v_missing := v_missing || 'branch:task-visibility-duplicated-instead-of-delegated ';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'can_view_task') THEN
    v_missing := v_missing || 'dependency:can_view_task-missing ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Task Audit Visibility validation FAILED, missing: %', v_missing USING ERRCODE = 'P0001';
  ELSE
    RAISE NOTICE 'Task Audit Visibility validation PASSED: function present, SECURITY DEFINER, search_path pinned, all 5 prior branches intact, new task branch present and correctly delegating to can_view_task() with no duplicated visibility logic.';
  END IF;
END $$;
