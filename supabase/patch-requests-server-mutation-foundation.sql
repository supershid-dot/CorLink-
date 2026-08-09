-- ============================================================
-- CAP-003 Phase 1.6A -- Requests Server-Authoritative Mutation
-- Foundation.
--
-- ─── Purpose ────────────────────────────────────────────────────
-- Requests currently accepts every business mutation as a direct
-- browser INSERT/UPDATE against `requests`/`responses`/`approvals`,
-- shaped only by js/data/requests-api.js and gated only by RLS. This
-- migrates the full evidenced Requests lifecycle to focused,
-- SECURITY DEFINER business-command RPCs that independently enforce
-- authorization, validate state transitions, and (where the current
-- client-side composition is genuinely non-atomic) commit multiple
-- related writes as one transaction. RLS on requests/responses is
-- left completely intact -- it remains the backstop for any read and
-- for any write path this milestone doesn't migrate.
--
-- This is Phase 1.6A ONLY: the mutation boundary. No Requests CAP-003
-- event is enqueued, no legacy notification is removed or changed, no
-- Entry/Internal Collaboration/Prisoner Letters migration. See
-- docs/89 for the full inventory, design rationale, and deviations.
--
-- ─── Method: mirror RLS's own USING/WITH CHECK logic verbatim ─────
-- Every authorization check below is transcribed directly from the
-- corresponding policy in supabase/rls.sql (requests_update,
-- requests_update_supervisor, requests_update_cancel, requests_update_
-- assigned_receiver, requests_update_section_receiver, responses_
-- update, responses_update_supervisor, responses_update_assigned_
-- receiver, responses_insert, approvals_insert) -- not redesigned,
-- not loosened, not tightened beyond the two explicitly-documented
-- deviations in docs/89 (to_section_id org-consistency validation in
-- route_request/receive_and_route_request, and deriving previous_
-- section_id/from_section_id server-side instead of trusting a
-- client-supplied value). SECURITY DEFINER bypasses RLS by
-- definition, so every one of these checks has to be restated
-- explicitly in each function body; nothing here relies on RLS firing
-- underneath the function.
--
-- ─── Concurrency: state-guarded UPDATE, no new lock_version column ──
-- Every transition UPDATE's WHERE clause requires the row's CURRENT
-- status (and is_locked/received_by-is-null where relevant) to still
-- match the expected pre-transition value; a zero-row result (another
-- request already moved it) raises a clear error instead of silently
-- no-op'ing or overwriting. This is the exact pattern already
-- established by this repository's Task/Workflow RPCs (guarded
-- UPDATE, RAISE on no match) -- reused here rather than inventing a
-- second concurrency model or a new lock_version column. It also
-- makes every migrated command naturally reject a duplicate replay:
-- retrying a call after it already succeeded finds the row no longer
-- in the expected prior state and raises, rather than double-applying.
-- ============================================================
\set ON_ERROR_STOP on
BEGIN;

-- ─── create_request ────────────────────────────────────────────────
-- Mirrors requests_insert exactly, EXCEPT from_org_id and created_by
-- are no longer accepted as client parameters at all -- both are
-- derived server-side (get_my_org_id(), auth.uid()) rather than
-- accepted-then-checked, removing the class of "client-provided
-- organization identity" risk entirely instead of merely validating
-- it. from_section_id remains a parameter (a user can hold assignments
-- in more than one section and must choose which one they're sending
-- as) but is still validated against my_section_ids() server-side.
CREATE OR REPLACE FUNCTION create_request(
  p_from_section_id   UUID,
  p_to_org_id         UUID,
  p_subject           TEXT,
  p_body              TEXT,
  p_subject_language  TEXT DEFAULT 'en',
  p_language          TEXT DEFAULT 'en',
  p_deadline          TIMESTAMPTZ DEFAULT NULL,
  p_parent_request_id UUID DEFAULT NULL
) RETURNS SETOF requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_request requires an authenticated caller';
  END IF;
  IF p_from_section_id IS NULL OR p_to_org_id IS NULL OR p_subject IS NULL OR btrim(p_subject) = '' OR p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'from_section_id, to_org_id, subject, and body are all required';
  END IF;
  IF p_from_section_id NOT IN (SELECT my_section_ids()) THEN
    RAISE EXCEPTION 'Not authorized to send on behalf of that section';
  END IF;

  INSERT INTO requests (
    from_org_id, to_org_id, from_section_id, created_by,
    subject, subject_language, body, language, deadline, status, parent_request_id
  ) VALUES (
    get_my_org_id(), p_to_org_id, p_from_section_id, v_actor,
    p_subject, COALESCE(p_subject_language, 'en'), p_body, COALESCE(p_language, 'en'),
    p_deadline, 'draft', p_parent_request_id
  ) RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'created', 'request', v_row.id, 'Created request "' || p_subject || '"');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── update_request_draft ──────────────────────────────────────────
-- Explicit, required fields only -- no arbitrary JSON patch. The one
-- real call site (js/views/request-detail.js's edit-request-form)
-- always submits all four text fields together as a full-form save,
-- never a true partial patch, so all four are required here rather
-- than optional-with-COALESCE; p_deadline is nullable (clearing the
-- deadline is a legitimate save, unambiguous since this is always a
-- full-form submit). Guard mirrors requests_update's USING/WITH CHECK
-- exactly: creator, unlocked, still draft/pending_approval.
CREATE OR REPLACE FUNCTION update_request_draft(
  p_request_id       UUID,
  p_subject          TEXT,
  p_subject_language TEXT,
  p_body             TEXT,
  p_language         TEXT,
  p_deadline         TIMESTAMPTZ DEFAULT NULL
) RETURNS SETOF requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'update_request_draft requires an authenticated caller';
  END IF;
  IF p_subject IS NULL OR btrim(p_subject) = '' OR p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'subject and body are required';
  END IF;

  UPDATE requests SET
    subject = p_subject, subject_language = COALESCE(p_subject_language, 'en'),
    body = p_body, language = COALESCE(p_language, 'en'), deadline = p_deadline
  WHERE id = p_request_id
    AND created_by = v_actor AND is_locked = FALSE AND status IN ('draft', 'pending_approval')
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'This request may have already been submitted, approved, or you no longer have permission to edit it. Refresh and try again.';
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'edited', 'request', p_request_id, 'Edited request draft');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── submit_request ────────────────────────────────────────────────
-- p_approver_id remains informational-routing-only, exactly as today
-- (see requests-api.js's own comment) -- any qualifying supervisor of
-- from_section_id can still approve regardless; the FK to users(id)
-- is the only validation, matching current behavior exactly.
CREATE OR REPLACE FUNCTION submit_request(
  p_request_id UUID,
  p_approver_id UUID DEFAULT NULL
) RETURNS SETOF requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'submit_request requires an authenticated caller';
  END IF;

  UPDATE requests SET status = 'pending_approval', pending_approval_by = p_approver_id
  WHERE id = p_request_id
    AND created_by = v_actor AND is_locked = FALSE AND status = 'draft'
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'This request is not in a state that can be submitted for approval, or you no longer have permission. Refresh and try again.';
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'submitted', 'request', p_request_id, 'Submitted request for approval');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── approve_request ───────────────────────────────────────────────
-- Atomic: status/lock/reference-number + approvals row + audit, one
-- transaction (the current JS does these as three separate calls; a
-- failure between them today can leave a 'sent' request with no
-- approvals row, or a generated reference number burned with no
-- status change). from_section_id for the reference number is read
-- from the row itself, never accepted as a client parameter (the
-- current JS call site DOES pass fromSectionId as a caller-supplied
-- argument -- removed here on purpose, see docs/89).
CREATE OR REPLACE FUNCTION approve_request(
  p_request_id UUID,
  p_comment TEXT DEFAULT NULL
) RETURNS SETOF requests AS $$
DECLARE
  v_actor    UUID := auth.uid();
  v_row      requests;
  v_ref      TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'approve_request requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;
  IF NOT (v_row.from_org_id = get_my_org_id() OR v_row.to_org_id = get_my_org_id()) OR NOT is_supervisor_or_above() THEN
    RAISE EXCEPTION 'Not authorized to approve this request';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This request is not awaiting approval. Refresh and try again.';
  END IF;

  v_ref := generate_reference_number(v_row.from_section_id, 'request');

  UPDATE requests SET status = 'sent', is_locked = TRUE, reference_number = v_ref
  WHERE id = p_request_id RETURNING * INTO v_row;

  INSERT INTO approvals (record_type, record_id, reviewed_by, decision, comment)
  VALUES ('request', p_request_id, v_actor, 'approved', p_comment);

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'approved', 'request', p_request_id, 'Approved and sent request');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── return_request ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION return_request(
  p_request_id UUID,
  p_comment TEXT DEFAULT NULL
) RETURNS SETOF requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'return_request requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;
  IF NOT (v_row.from_org_id = get_my_org_id() OR v_row.to_org_id = get_my_org_id()) OR NOT is_supervisor_or_above() THEN
    RAISE EXCEPTION 'Not authorized to return this request';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This request is not awaiting approval. Refresh and try again.';
  END IF;

  UPDATE requests SET status = 'draft' WHERE id = p_request_id RETURNING * INTO v_row;

  INSERT INTO approvals (record_type, record_id, reviewed_by, decision, comment)
  VALUES ('request', p_request_id, v_actor, 'returned', p_comment);

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'returned', 'request', p_request_id, 'Returned request for changes');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── mark_request_received ─────────────────────────────────────────
-- OR of requests_update_assigned_receiver and requests_update_
-- supervisor, exactly as RLS currently permits both.
CREATE OR REPLACE FUNCTION mark_request_received(
  p_request_id UUID
) RETURNS SETOF requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   requests;
  v_authorized BOOLEAN;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'mark_request_received requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;

  v_authorized := (
    (v_row.to_org_id = get_my_org_id() AND v_row.to_section_id IS NULL AND is_default_section_receiver(v_row.to_org_id))
    OR ((v_row.from_org_id = get_my_org_id() OR v_row.to_org_id = get_my_org_id()) AND is_supervisor_or_above())
  );
  IF NOT v_authorized THEN
    RAISE EXCEPTION 'Not authorized to receive this request';
  END IF;
  IF v_row.status <> 'sent' THEN
    RAISE EXCEPTION 'This request is not awaiting receipt. Refresh and try again.';
  END IF;

  UPDATE requests SET status = 'received', received_by = v_actor, received_at = now()
  WHERE id = p_request_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'received', 'request', p_request_id, 'Marked request as received');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── route_request ──────────────────────────────────────────────────
-- Deviation from current behavior (documented in docs/89): also
-- validates p_to_section_id actually belongs to the request's own
-- to_org_id. Today's requests_update_assigned_receiver/_supervisor
-- policies check the ACTOR's org membership but never that the
-- TARGET section resolves to the same org, so a caller could
-- currently route a request to a section belonging to a different
-- organization entirely (a data-integrity gap, not a visibility leak
-- -- requests_select still requires org membership independently).
-- Writing this authorization out explicitly, rather than trusting
-- RLS's existing shape, surfaced the gap; closing it is in scope
-- ("the server must become authoritative for ... organization/section
-- consistency").
CREATE OR REPLACE FUNCTION route_request(
  p_request_id UUID,
  p_to_section_id UUID
) RETURNS SETOF requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   requests;
  v_authorized BOOLEAN;
  v_section_org UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'route_request requires an authenticated caller';
  END IF;
  IF p_to_section_id IS NULL THEN
    RAISE EXCEPTION 'to_section_id is required';
  END IF;

  SELECT * INTO v_row FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;

  SELECT org_id INTO v_section_org FROM sections WHERE id = p_to_section_id;
  IF v_section_org IS DISTINCT FROM v_row.to_org_id THEN
    RAISE EXCEPTION 'That section does not belong to the receiving organization';
  END IF;

  v_authorized := (
    (v_row.to_org_id = get_my_org_id() AND v_row.to_section_id IS NULL AND is_default_section_receiver(v_row.to_org_id))
    OR ((v_row.from_org_id = get_my_org_id() OR v_row.to_org_id = get_my_org_id()) AND is_supervisor_or_above())
    OR (v_row.to_section_id IS NOT NULL AND has_role_in_section(v_row.to_section_id, 'assigned_receiver'))
  );
  IF NOT v_authorized THEN
    RAISE EXCEPTION 'Not authorized to route this request';
  END IF;

  UPDATE requests SET to_section_id = p_to_section_id, status = 'in_progress', assigned_to = NULL
  WHERE id = p_request_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'routed', 'request', p_request_id, 'Routed to ' || COALESCE((SELECT name FROM sections WHERE id = p_to_section_id), 'a section'));

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── return_request_to_previous_section ────────────────────────────
-- Deviation from current behavior (documented in docs/89): the target
-- section is derived server-side from requests.previous_section_id
-- (trigger-maintained by trigger_track_previous_section, schema.sql)
-- rather than accepted as a client parameter. The current JS caller
-- already only ever passes the value it read back from the server a
-- moment earlier, so this changes no legitimate behavior; it just
-- removes the last client-supplied section-identity parameter in the
-- routing surface.
CREATE OR REPLACE FUNCTION return_request_to_previous_section(
  p_request_id UUID,
  p_comment TEXT DEFAULT NULL
) RETURNS SETOF requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   requests;
  v_authorized BOOLEAN;
  v_note TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'return_request_to_previous_section requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;
  IF v_row.previous_section_id IS NULL THEN
    RAISE EXCEPTION 'This request has no previous section to return to';
  END IF;

  v_authorized := (
    (v_row.to_org_id = get_my_org_id() AND v_row.to_section_id IS NULL AND is_default_section_receiver(v_row.to_org_id))
    OR ((v_row.from_org_id = get_my_org_id() OR v_row.to_org_id = get_my_org_id()) AND is_supervisor_or_above())
    OR (v_row.to_section_id IS NOT NULL AND has_role_in_section(v_row.to_section_id, 'assigned_receiver'))
  );
  IF NOT v_authorized THEN
    RAISE EXCEPTION 'Not authorized to return this request to the previous section';
  END IF;

  UPDATE requests SET to_section_id = v_row.previous_section_id, status = 'in_progress', assigned_to = NULL
  WHERE id = p_request_id RETURNING * INTO v_row;

  v_note := regexp_replace(COALESCE(p_comment, ''), '<[^>]+>', '', 'g');
  v_note := left(btrim(v_note), 200);

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'returned_to_sender', 'request', p_request_id,
    'Sent back to previous section' || CASE WHEN v_note <> '' THEN ': ' || v_note ELSE '' END);

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── assign_request ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION assign_request(
  p_request_id UUID,
  p_user_id UUID DEFAULT NULL
) RETURNS SETOF requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   requests;
  v_authorized BOOLEAN;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'assign_request requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;
  IF p_user_id IS NOT NULL AND NOT COALESCE((SELECT is_active FROM users WHERE id = p_user_id), FALSE) THEN
    RAISE EXCEPTION 'Cannot assign to an inactive user';
  END IF;

  v_authorized := (
    (v_row.to_section_id IS NOT NULL AND has_role_in_section(v_row.to_section_id, 'assigned_receiver'))
    OR ((v_row.from_org_id = get_my_org_id() OR v_row.to_org_id = get_my_org_id()) AND is_supervisor_or_above())
  );
  IF NOT v_authorized THEN
    RAISE EXCEPTION 'Not authorized to assign this request';
  END IF;

  UPDATE requests SET assigned_to = p_user_id WHERE id = p_request_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'assigned', 'request', p_request_id,
    CASE WHEN p_user_id IS NULL THEN 'Unassigned'
      ELSE 'Assigned to ' || COALESCE((SELECT full_name FROM users WHERE id = p_user_id), 'a staff member') END);

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── receive_and_route_request (atomic composed command) ──────────
-- Replaces the current client-side composition of up to three
-- separate network calls (markRequestReceived, routeRequest,
-- assignRequest) with one transaction: a failure at any step now
-- rolls back the whole thing instead of leaving a request received-
-- but-unrouted, or routed-but-unassigned when the assignment step
-- failed. Reuses mark_request_received/route_request/assign_request
-- directly (nested SECURITY DEFINER calls inside the same top-level
-- transaction -- either all commit or all roll back together).
CREATE OR REPLACE FUNCTION receive_and_route_request(
  p_request_id UUID,
  p_to_section_id UUID,
  p_assigned_to UUID DEFAULT NULL
) RETURNS SETOF requests AS $$
DECLARE
  v_status TEXT;
  v_row    requests;
BEGIN
  SELECT status INTO v_status FROM requests WHERE id = p_request_id;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Request not found';
  END IF;

  IF v_status = 'sent' THEN
    PERFORM mark_request_received(p_request_id);
  END IF;
  PERFORM route_request(p_request_id, p_to_section_id);
  IF p_assigned_to IS NOT NULL THEN
    PERFORM assign_request(p_request_id, p_assigned_to);
  END IF;

  SELECT * INTO v_row FROM requests WHERE id = p_request_id;
  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── close_request ──────────────────────────────────────────────────
-- No status-transition guard is written here in application code --
-- but this is NOT unrestricted: schema.sql's pre-existing
-- check_request_status trigger (valid_request_status_transition(),
-- baseline behavior, not introduced by this milestone) already
-- enforces the real state machine on every UPDATE of requests.status
-- regardless of caller, and only allows ('responded', 'closed') to
-- reach 'closed' -- discovered while writing this RPC's own
-- concurrency test (a race that tried to close from 'in_progress'
-- correctly failed against the trigger, exposing that the true
-- precondition was never "no restriction," just never independently
-- re-stated by requests_update_supervisor RLS or by requests-api.js's
-- closeRequest()). Left for the trigger to enforce, exactly like
-- production already relies on it to -- adding a second, redundant
-- guard here would risk drifting out of sync with schema.sql's own
-- transition table over time.
CREATE OR REPLACE FUNCTION close_request(
  p_request_id UUID
) RETURNS SETOF requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'close_request requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;
  IF NOT (v_row.from_org_id = get_my_org_id() OR v_row.to_org_id = get_my_org_id()) OR NOT is_supervisor_or_above() THEN
    RAISE EXCEPTION 'Not authorized to close this request';
  END IF;

  UPDATE requests SET status = 'closed' WHERE id = p_request_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'edited', 'request', p_request_id, 'Closed request');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── cancel_request ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION cancel_request(
  p_request_id UUID,
  p_reason TEXT DEFAULT NULL
) RETURNS SETOF requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   requests;
  v_authorized BOOLEAN;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'cancel_request requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;
  IF v_row.from_org_id <> get_my_org_id() THEN
    RAISE EXCEPTION 'Not authorized to cancel this request';
  END IF;
  IF v_row.status NOT IN ('sent', 'received', 'in_progress', 'overdue') THEN
    RAISE EXCEPTION 'This request can no longer be cancelled. Refresh and try again.';
  END IF;
  v_authorized := (v_row.created_by = v_actor OR (is_supervisor_or_above() AND v_row.from_section_id IN (SELECT my_section_ids())));
  IF NOT v_authorized THEN
    RAISE EXCEPTION 'Not authorized to cancel this request';
  END IF;

  UPDATE requests SET
    status = 'cancelled', is_locked = TRUE,
    cancelled_by = v_actor, cancelled_at = now(), cancellation_reason = p_reason
  WHERE id = p_request_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'cancelled', 'request', p_request_id, 'Cancelled request: ' || COALESCE(p_reason, ''));

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ═══════════════════════════════════════════════════════════════════
-- ─── Responses ────────────────────────────────────────────────────
-- ═══════════════════════════════════════════════════════════════════

-- ─── create_response ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION create_response(
  p_request_id UUID,
  p_body TEXT,
  p_language TEXT DEFAULT 'en'
) RETURNS SETOF responses AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   responses;
  v_req   requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_response requires an authenticated caller';
  END IF;
  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'body is required';
  END IF;

  SELECT * INTO v_req FROM requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Request not found';
  END IF;
  IF v_req.to_org_id <> get_my_org_id() OR v_req.status = 'cancelled' THEN
    RAISE EXCEPTION 'Not authorized to respond to this request';
  END IF;

  INSERT INTO responses (request_id, created_by, body, language, status)
  VALUES (p_request_id, v_actor, p_body, COALESCE(p_language, 'en'), 'draft')
  RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'created', 'response', v_row.id, 'Drafted response');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── update_response_draft ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION update_response_draft(
  p_response_id UUID,
  p_body TEXT,
  p_language TEXT DEFAULT NULL
) RETURNS SETOF responses AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   responses;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'update_response_draft requires an authenticated caller';
  END IF;
  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'body is required';
  END IF;

  UPDATE responses SET body = p_body, language = COALESCE(p_language, language)
  WHERE id = p_response_id
    AND created_by = v_actor AND is_locked = FALSE AND status IN ('draft', 'pending_approval')
    AND EXISTS (SELECT 1 FROM requests r WHERE r.id = responses.request_id AND r.status <> 'cancelled')
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'This response may have already been submitted, approved, or you no longer have permission to edit it. Refresh and try again.';
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'edited', 'response', p_response_id, 'Edited response draft');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── submit_response ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION submit_response(
  p_response_id UUID,
  p_approver_id UUID DEFAULT NULL
) RETURNS SETOF responses AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   responses;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'submit_response requires an authenticated caller';
  END IF;

  UPDATE responses SET status = 'pending_approval', pending_approval_by = p_approver_id
  WHERE id = p_response_id
    AND created_by = v_actor AND is_locked = FALSE AND status = 'draft'
    AND EXISTS (SELECT 1 FROM requests r WHERE r.id = responses.request_id AND r.status <> 'cancelled')
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'This response is not in a state that can be submitted for approval, or you no longer have permission. Refresh and try again.';
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'submitted', 'response', p_response_id, 'Submitted response for approval');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── approve_response ───────────────────────────────────────────────
-- Atomic: responses status/lock/reference-number + approvals row +
-- requests.status='responded' + audit, one transaction. The current
-- JS performs the responses UPDATE and the requests UPDATE as two
-- separate, non-atomic calls -- a failure between them today can
-- leave a response marked 'sent' while its parent request never
-- advances past 'in_progress'. request.to_section_id is read from the
-- row itself for the reference number, never accepted as a client
-- parameter (current JS re-fetches it via a separate SELECT first;
-- folded into this one transaction instead).
CREATE OR REPLACE FUNCTION approve_response(
  p_response_id UUID,
  p_comment TEXT DEFAULT NULL
) RETURNS SETOF responses AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   responses;
  v_req   requests;
  v_ref   TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'approve_response requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM responses WHERE id = p_response_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Response not found';
  END IF;
  SELECT * INTO v_req FROM requests WHERE id = v_row.request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent request not found';
  END IF;
  IF NOT (v_req.from_org_id = get_my_org_id() OR v_req.to_org_id = get_my_org_id()) OR NOT is_supervisor_or_above() OR v_req.status = 'cancelled' THEN
    RAISE EXCEPTION 'Not authorized to approve this response';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This response is not awaiting approval. Refresh and try again.';
  END IF;

  v_ref := generate_reference_number(v_req.to_section_id, 'response');

  UPDATE responses SET status = 'sent', is_locked = TRUE, reference_number = v_ref
  WHERE id = p_response_id RETURNING * INTO v_row;

  UPDATE requests SET status = 'responded' WHERE id = v_req.id;

  INSERT INTO approvals (record_type, record_id, reviewed_by, decision, comment)
  VALUES ('response', p_response_id, v_actor, 'approved', p_comment);

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'approved', 'response', p_response_id, 'Approved and sent response');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── return_response ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION return_response(
  p_response_id UUID,
  p_comment TEXT DEFAULT NULL
) RETURNS SETOF responses AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   responses;
  v_req   requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'return_response requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM responses WHERE id = p_response_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Response not found';
  END IF;
  SELECT * INTO v_req FROM requests WHERE id = v_row.request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent request not found';
  END IF;
  IF NOT (v_req.from_org_id = get_my_org_id() OR v_req.to_org_id = get_my_org_id()) OR NOT is_supervisor_or_above() OR v_req.status = 'cancelled' THEN
    RAISE EXCEPTION 'Not authorized to return this response';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This response is not awaiting approval. Refresh and try again.';
  END IF;

  UPDATE responses SET status = 'draft' WHERE id = p_response_id RETURNING * INTO v_row;

  INSERT INTO approvals (record_type, record_id, reviewed_by, decision, comment)
  VALUES ('response', p_response_id, v_actor, 'returned', p_comment);

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'returned', 'response', p_response_id, 'Returned response for changes');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── mark_response_received ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION mark_response_received(
  p_response_id UUID
) RETURNS SETOF responses AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   responses;
  v_req   requests;
  v_authorized BOOLEAN;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'mark_response_received requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM responses WHERE id = p_response_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Response not found';
  END IF;
  SELECT * INTO v_req FROM requests WHERE id = v_row.request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent request not found';
  END IF;

  v_authorized := (
    (v_row.status = 'sent' AND v_row.received_by IS NULL AND v_req.from_org_id = get_my_org_id() AND is_default_section_receiver(v_req.from_org_id))
    OR ((v_req.from_org_id = get_my_org_id() OR v_req.to_org_id = get_my_org_id()) AND is_supervisor_or_above() AND v_req.status <> 'cancelled')
  );
  IF NOT v_authorized THEN
    RAISE EXCEPTION 'Not authorized to receive this response';
  END IF;

  UPDATE responses SET received_by = v_actor, received_at = now()
  WHERE id = p_response_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'received', 'response', p_response_id, 'Marked response as received');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── acknowledge_and_close (atomic composed command) ────────────────
-- Replaces the current client-side composition (markResponseReceived
-- then closeRequest as two separate calls) with one transaction.
-- responseAlreadyReceived is no longer a client-supplied boolean --
-- whether to mark the response received is derived from the row's own
-- received_by column, removing a client-trust point without changing
-- any legitimate outcome (a response already received is simply
-- skipped, exactly as today).
CREATE OR REPLACE FUNCTION acknowledge_and_close(
  p_response_id UUID,
  p_request_id UUID
) RETURNS SETOF requests AS $$
DECLARE
  v_received_by UUID;
  v_row requests;
BEGIN
  SELECT received_by INTO v_received_by FROM responses WHERE id = p_response_id AND request_id = p_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Response not found for this request';
  END IF;

  IF v_received_by IS NULL THEN
    PERFORM mark_response_received(p_response_id);
  END IF;
  PERFORM close_request(p_request_id);

  SELECT * INTO v_row FROM requests WHERE id = p_request_id;
  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── Grants ──────────────────────────────────────────────────────────
-- Every function above: REVOKE from PUBLIC/anon, GRANT EXECUTE only to
-- authenticated (auth.uid() is derived server-side in every one; no
-- function trusts a client-supplied identity/org/section value where
-- an authoritative alternative exists).
REVOKE ALL ON FUNCTION create_request(UUID,UUID,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_request(UUID,UUID,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ,UUID) TO authenticated;
-- (parameter TYPE order is unchanged by the p_subject_language/p_body
-- reorder above -- both are still UUID,UUID,TEXT,TEXT,TEXT,TEXT,
-- TIMESTAMPTZ,UUID textually, so this signature string is unaffected;
-- kept as one statement, not duplicated.)

REVOKE ALL ON FUNCTION update_request_draft(UUID,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION update_request_draft(UUID,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ) TO authenticated;

REVOKE ALL ON FUNCTION submit_request(UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION submit_request(UUID,UUID) TO authenticated;

REVOKE ALL ON FUNCTION approve_request(UUID,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION approve_request(UUID,TEXT) TO authenticated;

REVOKE ALL ON FUNCTION return_request(UUID,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION return_request(UUID,TEXT) TO authenticated;

REVOKE ALL ON FUNCTION mark_request_received(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION mark_request_received(UUID) TO authenticated;

REVOKE ALL ON FUNCTION route_request(UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION route_request(UUID,UUID) TO authenticated;

REVOKE ALL ON FUNCTION return_request_to_previous_section(UUID,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION return_request_to_previous_section(UUID,TEXT) TO authenticated;

REVOKE ALL ON FUNCTION assign_request(UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION assign_request(UUID,UUID) TO authenticated;

REVOKE ALL ON FUNCTION receive_and_route_request(UUID,UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION receive_and_route_request(UUID,UUID,UUID) TO authenticated;

REVOKE ALL ON FUNCTION close_request(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION close_request(UUID) TO authenticated;

REVOKE ALL ON FUNCTION cancel_request(UUID,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cancel_request(UUID,TEXT) TO authenticated;

REVOKE ALL ON FUNCTION create_response(UUID,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_response(UUID,TEXT,TEXT) TO authenticated;

REVOKE ALL ON FUNCTION update_response_draft(UUID,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION update_response_draft(UUID,TEXT,TEXT) TO authenticated;

REVOKE ALL ON FUNCTION submit_response(UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION submit_response(UUID,UUID) TO authenticated;

REVOKE ALL ON FUNCTION approve_response(UUID,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION approve_response(UUID,TEXT) TO authenticated;

REVOKE ALL ON FUNCTION return_response(UUID,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION return_response(UUID,TEXT) TO authenticated;

REVOKE ALL ON FUNCTION mark_response_received(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION mark_response_received(UUID) TO authenticated;

REVOKE ALL ON FUNCTION acknowledge_and_close(UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION acknowledge_and_close(UUID,UUID) TO authenticated;

-- ─── Direct client-write elimination ─────────────────────────────────
-- Once the frontend migration (js/data/requests-api.js) below routes
-- every one of the commands above through its RPC instead of a direct
-- table write, direct INSERT/UPDATE on `requests`/`responses` from
-- authenticated is no longer needed for any MIGRATED command. Revoked
-- narrowly -- SELECT remains (every list/detail read in requests-api.js
-- stays a direct table read, unmigrated and unaffected), and `approvals`
-- keeps its existing INSERT policy/grant AS IS since approvals rows are
-- now only ever written from inside these SECURITY DEFINER functions
-- (running as the function owner, not as `authenticated`) -- RLS on
-- approvals is therefore no longer reachable via a direct authenticated
-- INSERT for the migrated commands either, but the policy itself is
-- left untouched per the task's explicit instruction not to remove
-- required policies beyond what's proven safe; the grant narrowing
-- below is the actual enforcement.
REVOKE INSERT, UPDATE ON TABLE requests FROM authenticated;
REVOKE INSERT, UPDATE ON TABLE responses FROM authenticated;

COMMIT;
