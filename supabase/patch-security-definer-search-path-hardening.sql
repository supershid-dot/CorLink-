-- ─── Patch: SECURITY DEFINER search_path hardening ──────────────
-- The Step R1 repository audit found that roughly half of this
-- codebase's SECURITY DEFINER functions (38 of 85 in the live
-- schema) do not pin an explicit search_path — including the core
-- authorization helpers every RLS policy in the app depends on
-- (get_my_org_id, is_admin, is_super_admin, has_role,
-- has_role_in_section, scope_org_id, scope_section_ids,
-- my_section_ids, etc.).
--
-- A SECURITY DEFINER function executes with the privileges of its
-- owner, but by default still resolves unqualified identifiers
-- (table/function names with no schema prefix) using the CALLER's
-- current `search_path`. If a caller can influence that search_path
-- (e.g. by creating an object of the same name in a schema they
-- control, or via `SET search_path` in their own session before
-- calling an exposed RPC), an unqualified reference inside the
-- function body can resolve to an attacker-controlled object instead
-- of the intended one — a schema-injection / search-path-hijack risk
-- that is exactly why Postgres's own documentation recommends every
-- SECURITY DEFINER function pin its search_path explicitly.
--
-- This patch re-declares the 38 affected functions via
-- CREATE OR REPLACE FUNCTION, adding
--   SET search_path = public, pg_temp
-- to each. Every signature, return type, and function body is
-- otherwise byte-for-byte identical to what the existing migration
-- chain produces (verified by generating this patch directly from
-- pg_get_functiondef() output against a freshly built database, then
-- only inserting the SET clause) — no logic, no RLS policies, no
-- permissions/grants, and no ownership are changed by this patch.
-- The remaining 47 SECURITY DEFINER functions already pin
-- search_path correctly (established practice in the later
-- Meetings/Rooms/Platform-module work) and are left untouched.
--
-- Idempotent — safe to run more than once. Functions are grouped
-- below in the priority order the R1 audit specified: core security
-- helpers first, then Notifications, Audit, Requests, Entry, Internal
-- Collaboration, Prisoner Letters, and Administration.
-- ============================================================

BEGIN;

-- ─── 1. Core security helpers ───────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_my_org_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT org_id FROM users WHERE id = auth.uid();
$function$
;

CREATE OR REPLACE FUNCTION public.scope_org_id(p_scope_type text, p_scope_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT CASE p_scope_type
    WHEN 'organization' THEN (SELECT id FROM organizations WHERE id = p_scope_id AND is_active = TRUE)
    WHEN 'command'    THEN (SELECT org_id FROM commands WHERE id = p_scope_id AND is_active = TRUE)
    WHEN 'department' THEN (
      SELECT c.org_id FROM departments d JOIN commands c ON c.id = d.command_id
      WHERE d.id = p_scope_id AND d.is_active = TRUE AND c.is_active = TRUE
    )
    WHEN 'division'   THEN (SELECT org_id FROM divisions WHERE id = p_scope_id AND is_active = TRUE)
    WHEN 'section'    THEN (SELECT org_id FROM sections  WHERE id = p_scope_id AND is_active = TRUE)
    ELSE NULL
  END;
$function$
;

CREATE OR REPLACE FUNCTION public.scope_section_ids(p_scope_type text, p_scope_id uuid)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT s.id
  FROM sections s
  WHERE s.is_active = TRUE
    AND (
      (p_scope_type = 'section'    AND s.id = p_scope_id) OR
      (p_scope_type = 'department' AND s.department_id = p_scope_id
         AND EXISTS (SELECT 1 FROM departments d WHERE d.id = p_scope_id AND d.is_active = TRUE)) OR
      (p_scope_type = 'division'   AND s.division_id = p_scope_id
         AND EXISTS (SELECT 1 FROM divisions dv WHERE dv.id = p_scope_id AND dv.is_active = TRUE)) OR
      (p_scope_type = 'command'    AND EXISTS (
         SELECT 1 FROM departments d
         WHERE d.id = s.department_id AND d.command_id = p_scope_id AND d.is_active = TRUE
           AND EXISTS (SELECT 1 FROM commands c WHERE c.id = p_scope_id AND c.is_active = TRUE)
      )) OR
      (p_scope_type = 'organization' AND s.org_id = p_scope_id
         AND EXISTS (SELECT 1 FROM organizations o WHERE o.id = p_scope_id AND o.is_active = TRUE))
    );
$function$
;

CREATE OR REPLACE FUNCTION public.my_section_ids()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT DISTINCT sid
  FROM user_assignments ua
  CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
  WHERE ua.user_id = auth.uid() AND ua.is_active = TRUE;
$function$
;

CREATE OR REPLACE FUNCTION public.my_supervised_section_ids()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT DISTINCT sid
  FROM user_assignments ua
  CROSS JOIN LATERAL scope_section_ids(ua.scope_type, ua.scope_id) AS sid
  WHERE ua.user_id = auth.uid() AND ua.is_active = TRUE
    AND ua.role IN ('mcs_admin', 'authority_admin', 'supervisor');
$function$
;

CREATE OR REPLACE FUNCTION public.has_role(p_role text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT is_super_admin() OR EXISTS (
    SELECT 1 FROM user_assignments
    WHERE user_id = auth.uid() AND role = p_role AND is_active = TRUE
  );
$function$
;

CREATE OR REPLACE FUNCTION public.has_role_in_section(p_section_id uuid, p_role text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT is_super_admin() OR EXISTS (
    SELECT 1 FROM user_assignments ua
    WHERE ua.user_id = auth.uid() AND ua.role = p_role AND ua.is_active = TRUE
      AND p_section_id IN (SELECT scope_section_ids(ua.scope_type, ua.scope_id))
  );
$function$
;

CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT is_super_admin() OR has_role('mcs_admin') OR has_role('authority_admin');
$function$
;

CREATE OR REPLACE FUNCTION public.is_super_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT COALESCE((SELECT is_super_admin FROM users WHERE id = auth.uid()), FALSE);
$function$
;

CREATE OR REPLACE FUNCTION public.is_supervisor_or_above()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT is_admin() OR has_role('supervisor');
$function$
;

CREATE OR REPLACE FUNCTION public.user_org_id(p_user_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT org_id FROM users WHERE id = p_user_id;
$function$
;


-- ─── 2. Notifications helpers ───────────────────────────────────

CREATE OR REPLACE FUNCTION public.section_user_ids(p_section_id uuid, p_roles text[] DEFAULT NULL::text[])
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT DISTINCT ua.user_id
  FROM user_assignments ua
  WHERE ua.is_active = TRUE
    AND p_section_id IN (SELECT scope_section_ids(ua.scope_type, ua.scope_id))
    AND (p_roles IS NULL OR ua.role = ANY(p_roles));
$function$
;

CREATE OR REPLACE FUNCTION public.org_supervisor_user_ids(p_org_id uuid)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT DISTINCT ua.user_id
  FROM user_assignments ua
  JOIN users u ON u.id = ua.user_id
  WHERE ua.is_active = TRUE
    AND u.org_id = p_org_id
    AND ua.role IN ('mcs_admin', 'authority_admin', 'supervisor');
$function$
;

CREATE OR REPLACE FUNCTION public.check_deadlines()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT id, from_section_id, to_section_id, subject, deadline
    FROM requests
    WHERE deadline IS NOT NULL
      AND deadline < CURRENT_DATE
      AND status NOT IN ('draft', 'closed', 'responded', 'overdue', 'cancelled')
  LOOP
    UPDATE requests SET status = 'overdue' WHERE id = r.id;

    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    SELECT uid, 'deadline_warning', 'request', r.id,
           'Request "' || r.subject || '" is overdue (deadline was ' || r.deadline || ')'
    FROM (
      SELECT user_id AS uid FROM section_user_ids(
        COALESCE(r.to_section_id, r.from_section_id),
        ARRAY['mcs_admin', 'authority_admin', 'supervisor']
      )
    ) recipients;
  END LOOP;
END;
$function$
;


-- ─── 3. Audit helpers ───────────────────────────────────

CREATE OR REPLACE FUNCTION public.can_view_case_audit_record(p_record_type text, p_record_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT
    (p_record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = p_record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          is_supervisor_or_above()
          OR r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id   IN (SELECT my_section_ids())
          OR r.created_by      = auth.uid()
          OR r.received_by     = auth.uid()
        )
    ))
    OR (p_record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses resp
      JOIN requests r ON r.id = resp.request_id
      WHERE resp.id = p_record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          is_supervisor_or_above()
          OR r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id   IN (SELECT my_section_ids())
          OR r.created_by      = auth.uid()
          OR resp.created_by   = auth.uid()
          OR resp.received_by  = auth.uid()
        )
    ))
    -- Mirrors internal_requests_select's own visibility conditions —
    -- reroute() (js/data/internal-requests-api.js) resets one row's
    -- received_by/received_at/assigned_to on every re-route, so the
    -- audit trail is the only place the full received-then-routed-
    -- then-received-again history survives; request-detail.js's
    -- internal collaboration panel needs it visible to the same
    -- audience that can already see the internal_request itself, not
    -- just org admins (the base audit_select policy above).
    OR (p_record_type = 'internal_request' AND EXISTS (
      SELECT 1 FROM internal_requests ir
      WHERE ir.id = p_record_id
        AND (
          ir.from_section_id IN (SELECT my_section_ids())
          OR ir.to_section_id IN (SELECT my_section_ids())
          OR ir.created_by = auth.uid()
          OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
        )
    ))
    -- Mirrors external_correspondence_select's own visibility shape —
    -- entry-detail.js's timeline needs "routed to X by Y at [time]"
    -- visible to the same audience that can see the entry itself.
    OR (p_record_type = 'external_correspondence' AND EXISTS (
      SELECT 1 FROM external_correspondence ec
      WHERE ec.id = p_record_id
        AND ec.org_id = get_my_org_id()
        AND (
          is_entry_staff(ec.org_id)
          OR ec.to_section_id IN (SELECT my_section_ids())
          OR ec.assigned_to = auth.uid()
          OR ec.entered_by  = auth.uid()
        )
    ))
    -- New branch (this patch) — see header comment above for the full
    -- rationale, particularly why can_manage_series() is deliberately
    -- NOT called from here.
    OR (p_record_type = 'meeting_series' AND EXISTS (
      SELECT 1 FROM meeting_series s
      WHERE s.id = p_record_id
        AND (
          is_super_admin()
          OR s.created_by = auth.uid()
          OR (s.organization_id = get_my_org_id() AND is_supervisor_or_above())
          OR EXISTS (
            SELECT 1 FROM meetings m
            WHERE m.series_id = s.id AND can_view_meeting(m.id)
          )
        )
    ));
$function$
;

CREATE OR REPLACE FUNCTION public.appears_in_visible_audit_trail(p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM audit_logs al
    WHERE al.user_id = p_user_id
      AND can_view_case_audit_record(al.record_type, al.record_id)
  );
$function$
;

CREATE OR REPLACE FUNCTION public.log_auth_event(p_action text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN; -- No authenticated user to attribute this to; caller should no-op.
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (auth.uid(), p_action, 'session', auth.uid());
END;
$function$
;

CREATE OR REPLACE FUNCTION public.check_login_lockout(p_service_number text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.record_login_attempt(p_service_number text, p_success boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
BEGIN
  INSERT INTO login_attempts (service_number, success)
  VALUES (UPPER(TRIM(p_service_number)), p_success);
END;
$function$
;


-- ─── 4. Requests ───────────────────────────────────

CREATE OR REPLACE FUNCTION public.generate_reference_number(p_section_id uuid, p_record_type text DEFAULT 'request'::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_year     INTEGER := EXTRACT(YEAR FROM NOW());
  v_seq      INTEGER;
  v_org_code TEXT;
  v_sec_code TEXT;
  v_format   TEXT;
  v_result   TEXT;
BEGIN
  -- Upsert sequence row and grab the next value atomically — keyed by
  -- record_type too, so requests and responses never share a counter.
  INSERT INTO reference_sequences (section_id, year, record_type, next_sequence)
  VALUES (p_section_id, v_year, p_record_type, 2)
  ON CONFLICT (section_id, year, record_type)
  DO UPDATE SET next_sequence = reference_sequences.next_sequence + 1
  RETURNING next_sequence - 1 INTO v_seq;

  SELECT o.code, s.code, o.reference_number_format
  INTO v_org_code, v_sec_code, v_format
  FROM sections s
  JOIN organizations o ON o.id = s.org_id
  WHERE s.id = p_section_id;

  v_result := replace(v_format, '{ORG}', v_org_code);
  v_result := replace(v_result, '{SECTION}', v_sec_code);
  v_result := replace(v_result, '{YEAR}', v_year::TEXT);
  v_result := replace(v_result, '{SEQ}', LPAD(v_seq::TEXT, 4, '0'));

  IF p_record_type = 'response' THEN
    v_result := 'RES-' || v_result;
  END IF;

  RETURN v_result;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.can_view_request_or_response(p_record_type text, p_record_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT
    (p_record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r WHERE r.id = p_record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          is_admin()
          OR r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id   IN (SELECT my_section_ids())
          OR r.created_by      = auth.uid()
          OR r.received_by     = auth.uid()
        )
    ))
    OR (p_record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses re JOIN requests r ON r.id = re.request_id
      WHERE re.id = p_record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          is_admin()
          OR r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id   IN (SELECT my_section_ids())
          OR r.created_by      = auth.uid()
          OR re.created_by     = auth.uid()
          OR re.received_by    = auth.uid()
        )
    ));
$function$
;

CREATE OR REPLACE FUNCTION public.is_cc_recipient(p_record_type text, p_record_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM cc_recipients cc
    WHERE cc.record_type = p_record_type AND cc.record_id = p_record_id AND cc.user_id = auth.uid()
  );
$function$
;

CREATE OR REPLACE FUNCTION public.is_cc_recipient_via_response(p_request_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM responses re
    JOIN cc_recipients cc ON cc.record_type = 'response' AND cc.record_id = re.id
    WHERE re.request_id = p_request_id AND cc.user_id = auth.uid()
  );
$function$
;

CREATE OR REPLACE FUNCTION public.is_default_section_receiver(p_org_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT CASE
    WHEN (SELECT default_receiving_section_id FROM organizations WHERE id = p_org_id) IS NOT NULL
      THEN has_role_in_section((SELECT default_receiving_section_id FROM organizations WHERE id = p_org_id), 'assigned_receiver')
    ELSE has_role('assigned_receiver')
  END;
$function$
;


-- ─── 5. Entry ───────────────────────────────────

CREATE OR REPLACE FUNCTION public.generate_entry_reference(p_org_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_year INTEGER := EXTRACT(YEAR FROM NOW());
  v_seq  INTEGER;
  v_code TEXT;
BEGIN
  INSERT INTO entry_reference_sequences (org_id, year, next_sequence)
  VALUES (p_org_id, v_year, 2)
  ON CONFLICT (org_id, year)
  DO UPDATE SET next_sequence = entry_reference_sequences.next_sequence + 1
  RETURNING next_sequence - 1 INTO v_seq;

  SELECT code INTO v_code FROM organizations WHERE id = p_org_id;
  RETURN 'ENT-' || COALESCE(v_code, 'ORG') || '-' || v_year || '-' || LPAD(v_seq::TEXT, 4, '0');
END;
$function$
;

CREATE OR REPLACE FUNCTION public.is_entry_staff(p_org_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM entry_sections WHERE org_id = p_org_id)
      THEN EXISTS (
        SELECT 1 FROM entry_sections es
        WHERE es.org_id = p_org_id AND es.section_id IN (SELECT my_section_ids())
      )
    ELSE get_my_org_id() = p_org_id
  END;
$function$
;


-- ─── 6. Internal Collaboration ───────────────────────────────────

CREATE OR REPLACE FUNCTION public.internal_requests_parent_deadline_ok(p_parent_request_id uuid, p_parent_entry_id uuid, p_deadline timestamp with time zone)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT
    p_deadline IS NULL
    OR (p_parent_request_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM requests r WHERE r.id = p_parent_request_id
        AND r.deadline IS NOT NULL AND p_deadline > r.deadline
    ))
    OR (p_parent_entry_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM external_correspondence ec WHERE ec.id = p_parent_entry_id
        AND ec.deadline IS NOT NULL AND p_deadline::date > ec.deadline
    ));
$function$
;

CREATE OR REPLACE FUNCTION public.internal_requests_parent_not_frozen(p_parent_request_id uuid, p_parent_entry_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT
    (p_parent_request_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM requests r WHERE r.id = p_parent_request_id AND r.status <> 'cancelled'
    ))
    OR (p_parent_entry_id IS NOT NULL);
$function$
;

CREATE OR REPLACE FUNCTION public.internal_requests_parent_startable(p_parent_request_id uuid, p_parent_entry_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT
    (p_parent_request_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM requests r WHERE r.id = p_parent_request_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND r.status NOT IN ('cancelled', 'closed', 'responded')
    ))
    OR (p_parent_entry_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM external_correspondence ec WHERE ec.id = p_parent_entry_id
        AND ec.org_id = get_my_org_id()
        AND ec.status NOT IN ('closed', 'responded')
    ));
$function$
;

CREATE OR REPLACE FUNCTION public.looped_in_via_internal_collab(p_request_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM internal_requests ir
    WHERE ir.parent_request_id = p_request_id
      AND ir.to_section_id IN (SELECT my_section_ids())
  );
$function$
;

CREATE OR REPLACE FUNCTION public.looped_in_via_internal_collab_entry(p_entry_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM internal_requests ir
    WHERE ir.parent_entry_id = p_entry_id
      AND ir.to_section_id IN (SELECT my_section_ids())
  );
$function$
;


-- ─── 7. Prisoner Letters ───────────────────────────────────

CREATE OR REPLACE FUNCTION public.generate_prisoner_letter_reference(p_org_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_year INTEGER := EXTRACT(YEAR FROM NOW());
  v_seq  INTEGER;
  v_code TEXT;
BEGIN
  INSERT INTO letter_reference_sequences (org_id, year, next_sequence)
  VALUES (p_org_id, v_year, 2)
  ON CONFLICT (org_id, year)
  DO UPDATE SET next_sequence = letter_reference_sequences.next_sequence + 1
  RETURNING next_sequence - 1 INTO v_seq;

  SELECT code INTO v_code FROM organizations WHERE id = p_org_id;
  RETURN 'PL-' || COALESCE(v_code, 'ORG') || '-' || v_year || '-' || LPAD(v_seq::TEXT, 4, '0');
END;
$function$
;

CREATE OR REPLACE FUNCTION public.is_prisoner_letters_staff()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT COALESCE((SELECT is_prisoner_letters_staff FROM users WHERE id = auth.uid()), FALSE);
$function$
;

CREATE OR REPLACE FUNCTION public.is_prisoner_registry_manager(p_org_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT
    (get_my_org_id() = p_org_id AND is_supervisor_or_above())
    OR CASE
      WHEN (SELECT prisoner_registry_section_id FROM organizations WHERE id = p_org_id) IS NOT NULL
        THEN (SELECT prisoner_registry_section_id FROM organizations WHERE id = p_org_id) IN (SELECT my_section_ids())
      ELSE get_my_org_id() = p_org_id
    END;
$function$
;


-- ─── 8. Administration ───────────────────────────────────

CREATE OR REPLACE FUNCTION public.update_org_workflow_settings(p_org_id uuid, p_default_receiving_section_id uuid, p_reference_number_format text, p_prisoner_registry_section_id uuid DEFAULT NULL::uuid, p_entry_section_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
BEGIN
  IF NOT (is_super_admin() OR (is_admin() AND p_org_id = get_my_org_id())) THEN
    RAISE EXCEPTION 'Not authorized to update this organization';
  END IF;

  IF p_default_receiving_section_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sections WHERE id = p_default_receiving_section_id AND org_id = p_org_id
  ) THEN
    RAISE EXCEPTION 'default_receiving_section_id must belong to the target organization';
  END IF;

  IF p_prisoner_registry_section_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sections WHERE id = p_prisoner_registry_section_id AND org_id = p_org_id
  ) THEN
    RAISE EXCEPTION 'prisoner_registry_section_id must belong to the target organization';
  END IF;

  IF p_entry_section_ids IS NOT NULL AND EXISTS (
    SELECT 1 FROM unnest(p_entry_section_ids) sid
    WHERE NOT EXISTS (SELECT 1 FROM sections WHERE id = sid AND org_id = p_org_id)
  ) THEN
    RAISE EXCEPTION 'entry_section_ids must all belong to the target organization';
  END IF;

  IF p_reference_number_format IS NULL OR trim(p_reference_number_format) = ''
     OR p_reference_number_format NOT LIKE '%{SEQ}%' THEN
    RAISE EXCEPTION 'reference_number_format must be non-empty and include the {SEQ} token';
  END IF;

  UPDATE organizations
  SET default_receiving_section_id = p_default_receiving_section_id,
      reference_number_format = p_reference_number_format,
      prisoner_registry_section_id = p_prisoner_registry_section_id
  WHERE id = p_org_id;

  DELETE FROM entry_sections WHERE org_id = p_org_id;
  IF p_entry_section_ids IS NOT NULL THEN
    INSERT INTO entry_sections (org_id, section_id)
    SELECT p_org_id, sid FROM unnest(p_entry_section_ids) sid;
  END IF;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.is_module_active(p_module_key text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT COALESCE((SELECT is_active FROM platform_modules WHERE module_key = p_module_key), FALSE);
$function$
;

CREATE OR REPLACE FUNCTION public.module_enabled_for_org(p_org_id uuid, p_module_key text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM organization_modules om
    JOIN platform_modules pm ON pm.id = om.module_id
    WHERE om.organization_id = p_org_id
      AND pm.module_key = p_module_key
      AND om.is_enabled = TRUE
      AND pm.is_active = TRUE
  );
$function$
;

CREATE OR REPLACE FUNCTION public.current_user_module_enabled(p_module_key text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
  SELECT is_super_admin() OR module_enabled_for_org(get_my_org_id(), p_module_key);
$function$
;

DO $$
BEGIN
  RAISE NOTICE 'search-path hardening: 38 SECURITY DEFINER functions retrofitted with SET search_path = public, pg_temp.';
  RAISE NOTICE 'search-path hardening: no signatures, return types, logic, RLS policies, permissions, or grants were changed.';
END $$;

COMMIT;
