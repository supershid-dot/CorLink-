-- ============================================================
-- CorLink — Server-Side Login Security
-- Run AFTER schema.sql, rls.sql, seed.sql.
--
-- Client-side-only lockout (localStorage) is trivially bypassed by
-- clearing browser storage or switching devices/browsers. These RPCs
-- make the login_attempts table (already in schema.sql) the source of
-- truth, enforced server-side regardless of client state.
-- ============================================================

-- ─── Check lockout status ─────────────────────────────────────
-- Counts failed attempts since the last successful login. If the
-- threshold is met and the most recent failure is within the lockout
-- window, the account is locked.
CREATE OR REPLACE FUNCTION check_login_lockout(p_service_number TEXT)
RETURNS JSON AS $$
DECLARE
  v_service_number  TEXT := UPPER(TRIM(p_service_number));
  v_last_success    TIMESTAMPTZ;
  v_fail_count      INTEGER;
  v_last_fail       TIMESTAMPTZ;
  v_lockout_minutes INTEGER := 30;
  v_max_attempts    INTEGER := 5;
  v_locked_until    TIMESTAMPTZ;
BEGIN
  SELECT MAX(attempted_at) INTO v_last_success
  FROM login_attempts
  WHERE service_number = v_service_number AND success = TRUE;

  SELECT COUNT(*), MAX(attempted_at) INTO v_fail_count, v_last_fail
  FROM login_attempts
  WHERE service_number = v_service_number
    AND success = FALSE
    AND attempted_at > COALESCE(v_last_success, 'epoch'::TIMESTAMPTZ);

  IF v_fail_count >= v_max_attempts THEN
    v_locked_until := v_last_fail + (v_lockout_minutes || ' minutes')::INTERVAL;
    IF v_locked_until > NOW() THEN
      RETURN json_build_object(
        'locked', TRUE,
        'remaining_seconds', GREATEST(0, EXTRACT(EPOCH FROM (v_locked_until - NOW()))::INTEGER),
        'fail_count', v_fail_count
      );
    END IF;
  END IF;

  RETURN json_build_object(
    'locked', FALSE,
    'remaining_seconds', 0,
    'fail_count', v_fail_count
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Must be callable by unauthenticated visitors (they aren't logged in yet).
GRANT EXECUTE ON FUNCTION check_login_lockout(TEXT) TO anon, authenticated;

-- ─── Record a login attempt ───────────────────────────────────
-- Called for both successful and failed attempts, before and after
-- Supabase Auth's own sign-in call. SECURITY DEFINER bypasses RLS
-- since anon has no INSERT grant on login_attempts directly.
CREATE OR REPLACE FUNCTION record_login_attempt(
  p_service_number TEXT,
  p_success        BOOLEAN
)
RETURNS VOID AS $$
BEGIN
  INSERT INTO login_attempts (service_number, success)
  VALUES (UPPER(TRIM(p_service_number)), p_success);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION record_login_attempt(TEXT, BOOLEAN) TO anon, authenticated;

-- ─── Audit log helper for auth events ─────────────────────────
-- Wraps the audit_logs insert for login/logout so the frontend
-- doesn't need to duplicate this logic. Only callable when authenticated
-- (login success / logout), since audit_logs.user_id is NOT NULL and
-- tied to auth.uid().
CREATE OR REPLACE FUNCTION log_auth_event(p_action TEXT)
RETURNS VOID AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN; -- No authenticated user to attribute this to; caller should no-op.
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (auth.uid(), p_action, 'session', auth.uid());
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION log_auth_event(TEXT) TO authenticated;
