-- ============================================================
-- CorLink — Validate: SECURITY DEFINER search_path hardening
-- Companion to supabase/patch-security-definer-search-path-hardening.sql
--
-- Read-only. Enumerates every SECURITY DEFINER function in the
-- `public` schema and reports whether it pins an explicit
-- search_path, then raises an exception if any remain unprotected.
-- Run this after applying the full migration chain (through at
-- least patch-security-definer-search-path-hardening.sql) against
-- any environment to confirm coverage — does not depend on manual
-- inspection.
-- ============================================================

-- ─── 1. Full inventory — every SECURITY DEFINER function, protected or not ───
SELECT
  p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS function_signature,
  EXISTS (
    SELECT 1 FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) cfg
    WHERE cfg LIKE 'search_path=%'
  ) AS search_path_pinned
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prosecdef = true
ORDER BY search_path_pinned ASC, p.proname;

-- ─── 2. Summary counts ─────────────────────────────────────────
SELECT
  COUNT(*) AS total_security_definer_functions,
  COUNT(*) FILTER (
    WHERE EXISTS (
      SELECT 1 FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) cfg
      WHERE cfg LIKE 'search_path=%'
    )
  ) AS protected,
  COUNT(*) FILTER (
    WHERE NOT EXISTS (
      SELECT 1 FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) cfg
      WHERE cfg LIKE 'search_path=%'
    )
  ) AS unprotected
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prosecdef = true;

-- ─── 3. Hard failure if any SECURITY DEFINER function remains unprotected ───
DO $$
DECLARE
  v_unprotected INTEGER;
  v_list TEXT;
BEGIN
  SELECT COUNT(*), STRING_AGG(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ')
  INTO v_unprotected, v_list
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prosecdef = true
    AND NOT EXISTS (
      SELECT 1 FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) cfg
      WHERE cfg LIKE 'search_path=%'
    );

  IF v_unprotected > 0 THEN
    RAISE EXCEPTION
      'search-path validation FAILED: % SECURITY DEFINER function(s) still lack an explicit search_path: %',
      v_unprotected, v_list
      USING ERRCODE = 'P0001';
  ELSE
    RAISE NOTICE 'search-path validation PASSED: every SECURITY DEFINER function in the public schema pins an explicit search_path.';
  END IF;
END $$;
