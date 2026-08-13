-- ============================================================
-- CorLink — CAP-003 Phase 1.8A: Internal Collaboration
-- Server-Authoritative Mutation Foundation
-- ============================================================
-- Migrates every evidenced Internal Collaboration business mutation
-- (js/data/internal-requests-api.js) from direct client
-- .insert()/.update() calls to SECURITY DEFINER RPCs, mirroring the
-- Requests (Phase 1.6A, patch-requests-server-mutation-foundation.sql)
-- and Entry (Phase 1.7A, patch-entry-server-mutation-foundation.sql)
-- precedent. This is a PURE mutation-boundary migration: no CAP-003
-- event integration, no new lifecycle states, no new business
-- behavior, no notification changes.
--
-- ─── Inventory (all 11 evidenced direct-write commands) ────────────
-- create() -> create_internal_request()
-- markReceived() -> mark_internal_request_received()
-- reroute() -> reroute_internal_request()
-- returnToSender() -> return_internal_request_to_sender()
-- assign() -> assign_internal_request()
-- draftReply() -> draft_internal_request_reply()
-- updateReplyDraft() -> update_internal_request_reply_draft()
-- submitReplyForApproval() -> submit_internal_request_reply()
-- approveReply() -> approve_internal_request_reply()  -- fused atomic,
--   see below (was 2 separate client UPDATE calls)
-- returnReply() -> return_internal_request_reply()
-- close() -> close_internal_request()
--
-- ─── Genuine non-atomicity fix (Section 7) ──────────────────────────
-- approveReply() in the current frontend issues TWO separate UPDATE
-- calls: internal_request_replies.status='sent' (+approved_by/at),
-- then a SEPARATE internal_requests.status='responded' update. A
-- failure between them today can leave a reply marked 'sent' with its
-- parent thread stuck at its old status forever (no trigger or
-- constraint reconciles the two). This is the exact same class of gap
-- already found and fixed in approve_response() (docs/89 Sec2) and
-- approve_entry_reply() (docs/91 Sec16). approve_internal_request_reply()
-- below fuses both writes into one transaction.
--
-- ─── No status-transition trigger exists (genuine architecture gap,
-- documented, resolved per established precedent, no STOP needed) ───
-- Unlike requests (check_request_status trigger) and external_
-- correspondence (check_entry_status trigger), NEITHER internal_requests
-- NOR internal_request_replies has ever had a status-transition-
-- validating trigger — confirmed by exhaustive grep of every
-- CREATE TRIGGER across supabase/schema.sql. The CHECK constraints only
-- constrain the *set* of allowed values, never the transition graph.
-- Per the governing instruction ("a local implementation detail that
-- can be safely resolved using established repository precedent does
-- not require a STOP"), this migration does NOT invent a new trigger
-- (that would be an unrequested schema addition beyond migrating
-- existing behavior). Instead, each RPC below embeds its own inline
-- starting-state guard, grounded EXACTLY in the closest real precedent
-- evidenced directly from the live patch bodies of
-- patch-requests-server-mutation-foundation.sql (verified via direct
-- read, not memory):
--   * mark_request_received() guards status <> 'sent'                -> mirrored for mark_internal_request_received()
--   * submit_request()/submit_response() guard via WHERE status='draft' -> mirrored for submit_internal_request_reply()
--   * approve_request()/approve_response() guard status <> 'pending_approval' -> mirrored for approve_internal_request_reply()
--   * return_request()/return_response() guard status <> 'pending_approval' -> mirrored for return_internal_request_reply()
--   * route_request()/assign_request()/close_request() have NO status
--     guard at all (verified directly) -> mirrored: reroute_internal_
--     request()/assign_internal_request()/close_internal_request() add
--     NO new status restriction beyond what RLS already enforces today,
--     since inventing one would be new business behavior, not a
--     migration of existing behavior.
--
-- ─── Authorization: reproduced from real RLS, not invented ─────────
-- SECURITY DEFINER bypasses RLS, so every RPC below independently
-- reproduces the exact real, live authorization clause it replaces
-- (quoted directly from the live internal_requests_update/
-- internal_request_replies_update/internal_requests_insert/
-- internal_request_replies_insert policies — read via \d on the live
-- disposable harness, not from memory):
--   internal_requests row mutations (mark-received/reroute/assign/close):
--     (to_section_id IN my_section_ids() OR from_section_id IN
--     my_section_ids() OR (supervisor AND org match on to_section_id))
--     AND internal_requests_parent_not_frozen(...) -- this is the ONE
--     real authorization boundary for ALL internal_requests mutations
--     today; no per-command narrower rule exists in RLS for any of
--     these four, so none is invented here either.
--   return_internal_request_to_sender(): additionally narrowed to
--     to_section_id membership ONLY (no supervisor bypass, no
--     from_section_id branch) and a starting-status allow-list,
--     matching the EVIDENCED UI gate in js/views/request-detail.js:
--     `canReturnToSender = inToSection && ['sent','received',
--     'in_progress'].includes(ir.status)` -- "Any member of the
--     wrongly-routed section, not supervisor-only" (request-detail.js's
--     own comment). This is the one command with a real, evidenced,
--     narrower-than-RLS authorization boundary, so it is the one place
--     this migration departs from the blanket internal_requests_update
--     reproduction above -- a deliberate, evidenced choice, not an
--     invention.
--   create_internal_request(): reproduces internal_requests_insert's
--     own WITH CHECK verbatim (from_section membership/supervisor,
--     to_section org match, parent-startable, parent-deadline-ok).
--   draft_internal_request_reply(): reproduces internal_request_
--     replies_insert's own WITH CHECK verbatim (created_by=actor,
--     to_section membership, parent-not-frozen).
--   update_internal_request_reply_draft(): reproduces internal_request_
--     replies_update's own USING clause verbatim (creator-while-draft-
--     or-pending_approval OR supervisor-with-org-match) AND
--     parent-not-frozen -- no additional restriction invented.
--   submit_internal_request_reply()/approve_internal_request_reply()/
--     return_internal_request_reply(): author-only for submit (matching
--     submit_request()'s own created_by=v_actor requirement -- an
--     evidenced, established precedent for "submit" specifically, never
--     just "any RLS-permitted party"); supervisor-with-org-match for
--     approve/return (matching approve_response()/return_response()'s
--     own identical requirement exactly).
--
-- ─── No shared `approvals` table write for reply approve/return ────
-- Confirmed directly: `approvals.record_type` CHECK constraint does
-- NOT include 'internal_request'/'internal_reply' (schema.sql), and
-- neither approveReply() nor returnReply() in the current frontend
-- ever inserts into `approvals` -- internal reply approval/return
-- decisions are recorded ENTIRELY inline via internal_request_replies'
-- own approved_by/approved_at/pending_approval_by columns. This is a
-- genuine, evidenced architectural difference from BOTH Requests
-- (which does write to `approvals`) and Entry (whose return_entry_
-- reply() also writes to `approvals`, under record_type=
-- 'external_correspondence_reply', added by its own Phase 1.7A patch).
-- Widening the `approvals` CHECK constraint here would be inventing new
-- schema/business behavior beyond migrating what exists today, so this
-- migration deliberately does NOT do it -- approve_internal_request_
-- reply()/return_internal_request_reply() below write audit_logs only,
-- matching the real current frontend exactly.
--
-- ─── Return-to-sender: already exists, migrated as-is (Section 6) ──
-- returnToSender() already exists in the frontend (js/data/internal-
-- requests-api.js:267-284) and is wired into two views. It targets
-- from_section_id directly (the thread's own permanent, immutable-
-- since-creation origin -- never touched by reroute()), NOT a separate
-- previous_section_id-based "one hop back" mechanism the way Requests'
-- own return_request_to_previous_section() does. previous_section_id/
-- track_internal_previous_section exist for RLS-visibility continuity
-- only (letting a section that was routed away from a thread keep
-- seeing it), never as the return target. No schema change was needed
-- for this feature when it originally shipped (patch-return-to-sender.
-- sql's own header comment says so explicitly), and none is needed
-- here either -- this migration only moves the existing, already-
-- correct business logic into an RPC.
--
-- ─── Task integration (Section 9): completely untouched ────────────
-- The 6 existing Task-linking RPCs (get_internal_collaboration_task_
-- capabilities, list_internal_collaboration_tasks, create_internal_
-- collaboration_supporting_task, link_existing_task_to_internal_
-- collaboration, unlink_task_from_internal_collaboration,
-- list_task_internal_collaboration_links -- all from
-- patch-internal-collaboration-task-integration.sql) are not modified,
-- referenced, or re-created by this patch at all. No new Task event
-- producer is added.
--
-- ─── Zero CAP-003 integration (Section 10) ──────────────────────────
-- None of the RPCs below reference platform_enqueue_outbox_event,
-- create_notification_intent, resolve_notification_intent,
-- process_platform_outbox_batch, user_notifications,
-- notification_intents, or platform_outbox_events, anywhere. Legacy
-- NotificationsAPI.notify() call sites remain entirely in the frontend,
-- unchanged, called by the frontend itself immediately after each RPC
-- call succeeds -- exactly the same "RPC writes state+audit, frontend
-- still fires the legacy notify() afterward" shape Requests/Entry
-- Phase 1.6A/1.7A both used. Phase 1.8B (not started here) will handle
-- CAP-003 event integration separately, after this boundary is
-- reviewed and pushed.
--
-- ─── Organization/section security (Section 11) ─────────────────────
-- Internal Collaboration is confirmed single-organization-only (no
-- org_id column on either table; schema.sql's own header comment:
-- "org-only collaboration, never cross-org"; from_section_id/
-- to_section_id are both validated at INSERT time to resolve to the
-- SAME org, which is what structurally guarantees a foreign org can
-- never see or touch these rows). reroute_internal_request() validates
-- the target section belongs to the caller's own org server-side
-- (scope_org_id('section', p_to_section_id) = get_my_org_id()) --
-- mirroring route_request()'s own analogous cross-org guard -- so a
-- caller can never reroute a thread out of its home organization by
-- supplying an arbitrary section UUID.
--
-- Idempotent -- safe to re-run (CREATE OR REPLACE only for functions
-- already defined by this patch; the REVOKE/GRANT block at the end is
-- naturally idempotent).
-- ============================================================

BEGIN;

-- ─── 1. create_internal_request() ───────────────────────────────────
CREATE OR REPLACE FUNCTION create_internal_request(
  p_from_section_id UUID,
  p_to_section_id UUID,
  p_subject TEXT,
  p_body TEXT,
  p_parent_request_id UUID DEFAULT NULL,
  p_parent_entry_id UUID DEFAULT NULL,
  p_subject_language TEXT DEFAULT 'en',
  p_language TEXT DEFAULT 'en',
  p_deadline TIMESTAMPTZ DEFAULT NULL
) RETURNS SETOF internal_requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_internal_request requires an authenticated caller';
  END IF;
  IF p_subject IS NULL OR btrim(p_subject) = '' OR p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'subject and body are required';
  END IF;
  IF (p_parent_request_id IS NULL) = (p_parent_entry_id IS NULL) THEN
    RAISE EXCEPTION 'Exactly one of parent_request_id or parent_entry_id is required';
  END IF;

  IF NOT (
    p_from_section_id IN (SELECT my_section_ids())
    OR (is_supervisor_or_above() AND scope_org_id('section', p_from_section_id) = get_my_org_id())
  ) THEN
    RAISE EXCEPTION 'Not authorized to loop in a section on behalf of the sending section';
  END IF;
  IF scope_org_id('section', p_to_section_id) IS DISTINCT FROM get_my_org_id() THEN
    RAISE EXCEPTION 'That section does not belong to your organization';
  END IF;
  IF NOT internal_requests_parent_startable(p_parent_request_id, p_parent_entry_id) THEN
    RAISE EXCEPTION 'The parent case cannot accept a new internal collaboration thread right now';
  END IF;
  IF NOT internal_requests_parent_deadline_ok(p_parent_request_id, p_parent_entry_id, p_deadline) THEN
    RAISE EXCEPTION 'Deadline cannot be later than the parent case''s own deadline';
  END IF;

  INSERT INTO internal_requests (
    parent_request_id, parent_entry_id, from_section_id, to_section_id, created_by,
    subject, subject_language, body, language, deadline
  ) VALUES (
    p_parent_request_id, p_parent_entry_id, p_from_section_id, p_to_section_id, v_actor,
    p_subject, COALESCE(p_subject_language, 'en'), p_body, COALESCE(p_language, 'en'), p_deadline
  ) RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'created', 'internal_request', v_row.id, 'Created internal request "' || p_subject || '"');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 2. mark_internal_request_received() ────────────────────────────
-- Guard mirrors mark_request_received()'s own `status <> 'sent'` check
-- exactly (verified against the live patch body).
CREATE OR REPLACE FUNCTION mark_internal_request_received(
  p_internal_request_id UUID
) RETURNS SETOF internal_requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'mark_internal_request_received requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM internal_requests WHERE id = p_internal_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Internal request not found';
  END IF;
  IF NOT (
    (
      v_row.to_section_id IN (SELECT my_section_ids())
      OR v_row.from_section_id IN (SELECT my_section_ids())
      OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', v_row.to_section_id))
    )
    AND internal_requests_parent_not_frozen(v_row.parent_request_id, v_row.parent_entry_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to receive this internal request';
  END IF;
  IF v_row.status <> 'sent' THEN
    RAISE EXCEPTION 'This internal request is not awaiting receipt. Refresh and try again.';
  END IF;

  UPDATE internal_requests SET status = 'received', received_by = v_actor, received_at = now()
  WHERE id = p_internal_request_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'received', 'internal_request', p_internal_request_id, 'Marked internal request as received');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. reroute_internal_request() ──────────────────────────────────
-- No status guard (route_request()/assign_request() have none either,
-- verified directly) -- only authorization + cross-org protection are
-- new here (SECURITY DEFINER bypasses RLS, which never re-checked
-- to_section's org on UPDATE, unlike its own INSERT policy).
CREATE OR REPLACE FUNCTION reroute_internal_request(
  p_internal_request_id UUID,
  p_to_section_id UUID
) RETURNS SETOF internal_requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'reroute_internal_request requires an authenticated caller';
  END IF;
  IF p_to_section_id IS NULL THEN
    RAISE EXCEPTION 'to_section_id is required';
  END IF;

  SELECT * INTO v_row FROM internal_requests WHERE id = p_internal_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Internal request not found';
  END IF;
  IF NOT (
    (
      v_row.to_section_id IN (SELECT my_section_ids())
      OR v_row.from_section_id IN (SELECT my_section_ids())
      OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', v_row.to_section_id))
    )
    AND internal_requests_parent_not_frozen(v_row.parent_request_id, v_row.parent_entry_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to reroute this internal request';
  END IF;
  IF scope_org_id('section', p_to_section_id) IS DISTINCT FROM get_my_org_id() THEN
    RAISE EXCEPTION 'That section does not belong to your organization';
  END IF;

  UPDATE internal_requests SET
    to_section_id = p_to_section_id, status = 'sent',
    received_by = NULL, received_at = NULL, assigned_to = NULL
  WHERE id = p_internal_request_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'routed', 'internal_request', p_internal_request_id,
    'Re-routed internal request to ' || COALESCE((SELECT name FROM sections WHERE id = p_to_section_id), 'another section'));

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. return_internal_request_to_sender() ─────────────────────────
-- Authorization deliberately narrower than the general internal_
-- requests_update reproduction above: to_section_id membership ONLY
-- (no supervisor bypass, no from_section_id branch), matching the
-- evidenced UI gate in js/views/request-detail.js exactly
-- (`canReturnToSender = inToSection && ['sent','received',
-- 'in_progress'].includes(ir.status)`). Targets from_section_id
-- directly (permanent since creation) -- see header comment.
CREATE OR REPLACE FUNCTION return_internal_request_to_sender(
  p_internal_request_id UUID,
  p_comment TEXT DEFAULT NULL
) RETURNS SETOF internal_requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_requests;
  v_note  TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'return_internal_request_to_sender requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM internal_requests WHERE id = p_internal_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Internal request not found';
  END IF;
  IF NOT (
    v_row.to_section_id IN (SELECT my_section_ids())
    AND internal_requests_parent_not_frozen(v_row.parent_request_id, v_row.parent_entry_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to return this internal request to its sending section';
  END IF;
  IF v_row.status NOT IN ('sent', 'received', 'in_progress') THEN
    RAISE EXCEPTION 'This internal request can no longer be returned to its sending section. Refresh and try again.';
  END IF;

  UPDATE internal_requests SET
    to_section_id = v_row.from_section_id, status = 'sent',
    received_by = NULL, received_at = NULL, assigned_to = NULL
  WHERE id = p_internal_request_id RETURNING * INTO v_row;

  v_note := regexp_replace(COALESCE(p_comment, ''), '<[^>]+>', '', 'g');
  v_note := left(btrim(v_note), 200);

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'returned_to_sender', 'internal_request', p_internal_request_id,
    'Sent back to originating section' || CASE WHEN v_note <> '' THEN ': ' || v_note ELSE '' END);

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 5. assign_internal_request() ───────────────────────────────────
-- No status guard (assign_request() has none either, verified
-- directly).
CREATE OR REPLACE FUNCTION assign_internal_request(
  p_internal_request_id UUID,
  p_user_id UUID DEFAULT NULL
) RETURNS SETOF internal_requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'assign_internal_request requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM internal_requests WHERE id = p_internal_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Internal request not found';
  END IF;
  IF NOT (
    (
      v_row.to_section_id IN (SELECT my_section_ids())
      OR v_row.from_section_id IN (SELECT my_section_ids())
      OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', v_row.to_section_id))
    )
    AND internal_requests_parent_not_frozen(v_row.parent_request_id, v_row.parent_entry_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to assign this internal request';
  END IF;
  IF p_user_id IS NOT NULL AND NOT COALESCE((SELECT is_active FROM users WHERE id = p_user_id), FALSE) THEN
    RAISE EXCEPTION 'Cannot assign to an inactive user';
  END IF;

  UPDATE internal_requests SET
    assigned_to = p_user_id, status = CASE WHEN p_user_id IS NOT NULL THEN 'in_progress' ELSE 'received' END
  WHERE id = p_internal_request_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'assigned', 'internal_request', p_internal_request_id,
    CASE WHEN p_user_id IS NULL THEN 'Unassigned'
      ELSE 'Assigned to ' || COALESCE((SELECT full_name FROM users WHERE id = p_user_id), 'a staff member') END);

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 6. close_internal_request() ────────────────────────────────────
-- No status guard (close_request() has none either -- verified
-- directly, only a supervisor+org-match authorization check; Internal
-- Collaboration's own close() has no evidenced narrower UI gate either,
-- so this migration reproduces the general internal_requests_update
-- authorization -- NOT Requests' own supervisor-only restriction,
-- since that narrower rule is not evidenced here and mechanically
-- copying it would be inventing new business behavior).
CREATE OR REPLACE FUNCTION close_internal_request(
  p_internal_request_id UUID
) RETURNS SETOF internal_requests AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'close_internal_request requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM internal_requests WHERE id = p_internal_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Internal request not found';
  END IF;
  IF NOT (
    (
      v_row.to_section_id IN (SELECT my_section_ids())
      OR v_row.from_section_id IN (SELECT my_section_ids())
      OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', v_row.to_section_id))
    )
    AND internal_requests_parent_not_frozen(v_row.parent_request_id, v_row.parent_entry_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to close this internal request';
  END IF;

  UPDATE internal_requests SET status = 'closed' WHERE id = p_internal_request_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'edited', 'internal_request', p_internal_request_id, 'Closed internal request');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 7. draft_internal_request_reply() ──────────────────────────────
CREATE OR REPLACE FUNCTION draft_internal_request_reply(
  p_internal_request_id UUID,
  p_body TEXT,
  p_language TEXT DEFAULT 'en'
) RETURNS SETOF internal_request_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_request_replies;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'draft_internal_request_reply requires an authenticated caller';
  END IF;
  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'body is required';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM internal_requests ir
    WHERE ir.id = p_internal_request_id
      AND ir.to_section_id IN (SELECT my_section_ids())
      AND internal_requests_parent_not_frozen(ir.parent_request_id, ir.parent_entry_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to draft a reply to this internal request';
  END IF;

  INSERT INTO internal_request_replies (internal_request_id, created_by, body, language, status)
  VALUES (p_internal_request_id, v_actor, p_body, COALESCE(p_language, 'en'), 'draft')
  RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'created', 'internal_request', p_internal_request_id, 'Drafted a reply to an internal request');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 8. update_internal_request_reply_draft() ───────────────────────
-- Authorization reproduces internal_request_replies_update's own USING
-- clause verbatim -- no additional status restriction invented.
CREATE OR REPLACE FUNCTION update_internal_request_reply_draft(
  p_reply_id UUID,
  p_body TEXT,
  p_language TEXT DEFAULT NULL
) RETURNS SETOF internal_request_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_request_replies;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'update_internal_request_reply_draft requires an authenticated caller';
  END IF;
  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'body is required';
  END IF;

  SELECT * INTO v_row FROM internal_request_replies WHERE id = p_reply_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reply not found';
  END IF;
  IF NOT (
    (
      (v_row.created_by = v_actor AND v_row.status IN ('draft', 'pending_approval'))
      OR EXISTS (
        SELECT 1 FROM internal_requests ir WHERE ir.id = v_row.internal_request_id
          AND is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id)
      )
    )
    AND EXISTS (
      SELECT 1 FROM internal_requests ir WHERE ir.id = v_row.internal_request_id
        AND internal_requests_parent_not_frozen(ir.parent_request_id, ir.parent_entry_id)
    )
  ) THEN
    RAISE EXCEPTION 'Not authorized to edit this reply';
  END IF;

  UPDATE internal_request_replies SET body = p_body, language = COALESCE(p_language, language)
  WHERE id = p_reply_id RETURNING * INTO v_row;

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 9. submit_internal_request_reply() ─────────────────────────────
-- Author-only, guarded on status='draft' -- mirrors submit_request()/
-- submit_response()'s own identical WHERE-clause guard exactly.
CREATE OR REPLACE FUNCTION submit_internal_request_reply(
  p_reply_id UUID,
  p_approver_id UUID DEFAULT NULL
) RETURNS SETOF internal_request_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_request_replies;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'submit_internal_request_reply requires an authenticated caller';
  END IF;

  UPDATE internal_request_replies SET status = 'pending_approval', pending_approval_by = p_approver_id
  WHERE id = p_reply_id AND created_by = v_actor AND status = 'draft'
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'This reply is not in a state that can be submitted for approval, or you no longer have permission. Refresh and try again.';
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'submitted', 'internal_request', v_row.internal_request_id, 'Submitted internal reply for approval');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 10. approve_internal_request_reply() (atomic composed command) ──
-- Fuses the two separate client UPDATE calls (reply status='sent' +
-- parent status='responded') into one transaction -- see header
-- comment. Guard mirrors approve_response()'s own status<>'pending_
-- approval' check exactly. No approvals-table write -- see header
-- comment (Internal Collaboration never uses the shared `approvals`
-- table).
CREATE OR REPLACE FUNCTION approve_internal_request_reply(
  p_reply_id UUID
) RETURNS SETOF internal_request_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_request_replies;
  v_ir    internal_requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'approve_internal_request_reply requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM internal_request_replies WHERE id = p_reply_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reply not found';
  END IF;
  SELECT * INTO v_ir FROM internal_requests WHERE id = v_row.internal_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent internal request not found';
  END IF;
  IF NOT (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', v_ir.to_section_id)) THEN
    RAISE EXCEPTION 'Not authorized to approve this reply';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This reply is not awaiting approval. Refresh and try again.';
  END IF;

  UPDATE internal_request_replies SET
    status = 'sent', approved_by = v_actor, approved_at = now()
  WHERE id = p_reply_id RETURNING * INTO v_row;

  UPDATE internal_requests SET status = 'responded' WHERE id = v_ir.id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'approved', 'internal_request', v_ir.id, 'Approved and sent internal reply');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 11. return_internal_request_reply() ────────────────────────────
-- Guard mirrors return_response()'s own status<>'pending_approval'
-- check exactly. No approvals-table write -- see header comment.
CREATE OR REPLACE FUNCTION return_internal_request_reply(
  p_reply_id UUID
) RETURNS SETOF internal_request_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   internal_request_replies;
  v_ir    internal_requests;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'return_internal_request_reply requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM internal_request_replies WHERE id = p_reply_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reply not found';
  END IF;
  SELECT * INTO v_ir FROM internal_requests WHERE id = v_row.internal_request_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent internal request not found';
  END IF;
  IF NOT (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', v_ir.to_section_id)) THEN
    RAISE EXCEPTION 'Not authorized to return this reply';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This reply is not awaiting approval. Refresh and try again.';
  END IF;

  UPDATE internal_request_replies SET
    status = 'draft', pending_approval_by = NULL
  WHERE id = p_reply_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'returned', 'internal_request', v_ir.id, 'Returned internal reply for changes');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 12. SECURITY DEFINER grant posture: REVOKE from PUBLIC/anon,
-- GRANT EXECUTE only to authenticated -- matching Requests/Entry's own
-- identical per-function block exactly (a newly-created function
-- otherwise inherits PUBLIC's default EXECUTE grant, which anon also
-- inherits -- verified directly against the live disposable harness
-- during this milestone's own implementation, not assumed). ─────────
REVOKE ALL ON FUNCTION create_internal_request(UUID,UUID,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_internal_request(UUID,UUID,TEXT,TEXT,UUID,UUID,TEXT,TEXT,TIMESTAMPTZ) TO authenticated;

REVOKE ALL ON FUNCTION mark_internal_request_received(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION mark_internal_request_received(UUID) TO authenticated;

REVOKE ALL ON FUNCTION reroute_internal_request(UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION reroute_internal_request(UUID,UUID) TO authenticated;

REVOKE ALL ON FUNCTION return_internal_request_to_sender(UUID,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION return_internal_request_to_sender(UUID,TEXT) TO authenticated;

REVOKE ALL ON FUNCTION assign_internal_request(UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION assign_internal_request(UUID,UUID) TO authenticated;

REVOKE ALL ON FUNCTION close_internal_request(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION close_internal_request(UUID) TO authenticated;

REVOKE ALL ON FUNCTION draft_internal_request_reply(UUID,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION draft_internal_request_reply(UUID,TEXT,TEXT) TO authenticated;

REVOKE ALL ON FUNCTION update_internal_request_reply_draft(UUID,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION update_internal_request_reply_draft(UUID,TEXT,TEXT) TO authenticated;

REVOKE ALL ON FUNCTION submit_internal_request_reply(UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION submit_internal_request_reply(UUID,UUID) TO authenticated;

REVOKE ALL ON FUNCTION approve_internal_request_reply(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION approve_internal_request_reply(UUID) TO authenticated;

REVOKE ALL ON FUNCTION return_internal_request_reply(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION return_internal_request_reply(UUID) TO authenticated;

-- ─── 13. Direct-write closure (Section 5) ───────────────────────────
-- Ordinary browser mutation privileges are no longer necessary for
-- these two tables now that every evidenced business command has a
-- safe RPC equivalent. SELECT is untouched (every read path -- list/
-- listForEntry/listOutstandingForSections/listAssignedToUser/
-- listReplies/listForParents/listRepliesForRequests -- remains a
-- direct .from(...).select(...) call, unmigrated, per the governing
-- instruction).
REVOKE INSERT, UPDATE, DELETE ON TABLE internal_requests, internal_request_replies FROM authenticated;

COMMIT;
