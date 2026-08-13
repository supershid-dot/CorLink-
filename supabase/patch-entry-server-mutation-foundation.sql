-- ============================================================
-- CAP-003 Phase 1.7A -- Entry / External Correspondence
-- Server-Authoritative Mutation Foundation.
--
-- ─── Recovery note ──────────────────────────────────────────────
-- This file is a from-scratch reimplementation against the protected
-- remote baseline a89cef433f13c32839e1ff3c9c827c76312ac25f ("feat
-- (notifications): integrate requests events"). An earlier local
-- commit of this same milestone (6badf5ac...) was lost when its
-- ephemeral workspace was reclaimed before it could be pushed. That
-- commit was never recovered or reconstructed from its own object --
-- every finding below was re-derived directly from the repository at
-- the recovered baseline.
--
-- ─── Purpose ────────────────────────────────────────────────────
-- Entry (external_correspondence / external_correspondence_replies)
-- currently accepts every business mutation as a direct browser
-- INSERT/UPDATE, shaped only by js/data/entry-api.js and gated only by
-- RLS. This migrates the full evidenced Entry lifecycle to focused,
-- SECURITY DEFINER business-command RPCs that independently enforce
-- authorization, validate state transitions, and (where the current
-- client-side composition is genuinely non-atomic) commit multiple
-- related writes as one transaction. RLS on external_correspondence /
-- external_correspondence_replies is left completely intact -- it
-- remains the backstop for any read and for any write path this
-- milestone doesn't migrate.
--
-- This is Phase 1.7A ONLY: the mutation boundary. No Entry CAP-003
-- event is enqueued, no legacy notification is removed or changed
-- (NotificationsAPI.notify() calls stay in entry-api.js exactly where
-- they are today -- see docs/91). No cross-module changes. See docs/91
-- for the full inventory, design rationale, and the architecture-gap
-- finding below.
--
-- ─── Architecture-gap finding (reported per the governing spec) ────
-- The approved milestone brief describes Entry ownership in terms of
-- "receiving prison/facility" and "prisoner transfer between prisons/
-- facilities" driving Entry reassignment. Repository evidence does not
-- support a distinct prison/facility entity anywhere in Entry's data
-- model:
--   * organizations.type IN ('mcs','authority') and seed.sql seed exactly
--     ONE 'mcs' row ("Maldives Correctional Service") -- there is no
--     per-prison organization.
--   * external_correspondence has no facility/prison column at all.
--     Its only ownership axes are org_id (the single MCS org) and
--     to_section_id (an internal section, via entry_sections/
--     sections) -- i.e. exactly the axes "receiving prison/facility
--     section" maps onto once org_id is understood as "MCS" rather
--     than "a specific prison."
--   * prisoners.prison is a free-text CHECK enum ('Maafushi Prison',
--     'Asseyri Prison', 'Hulhumale Prison') describing where a given
--     PRISONER is held. It is informational only -- nothing in
--     schema.sql, rls.sql, or any *-api.js file reads it to scope,
--     own, route, or reassign an external_correspondence row. No
--     "prisoner transfer" table, trigger, or event exists anywhere in
--     the repository (verified by full-repo search).
--   * external_correspondence.prisoner_ref is OPTIONAL and only ever
--     populated for sender_category IN ('prisoner_family',
--     'prisoner_complaint') -- most Entry rows (public enquiries,
--     external-office correspondence) reference no prisoner at all,
--     so "prisoner transfer drives Entry reassignment" could never be
--     a module-wide rule even if the linkage existed.
-- Per the governing spec's own explicit instruction for exactly this
-- situation ("if the architecture requires automatic/coordinated Entry
-- reassignment but no implementation currently exists, do not silently
-- invent a new transfer engine ... document the gap, identify the
-- required future command/integration, leave implementation for an
-- explicitly approved future milestone"): this patch implements ZERO
-- prisoner-transfer/facility-reassignment command. "Receiving-section
-- ownership" (org_id + to_section_id, already fully evidenced) is what
-- route_entry/assign_entry below make server-authoritative.
--
-- ─── Method: mirror RLS's own USING/WITH CHECK logic verbatim ─────
-- Every authorization check below is transcribed directly from the
-- corresponding policy in supabase/rls.sql (external_correspondence_
-- select, external_correspondence_insert, external_correspondence_
-- update_entry, external_correspondence_update_section, external_
-- correspondence_replies_select/_insert/_update, is_entry_staff()) --
-- not redesigned, not loosened, not tightened beyond the one
-- explicitly-documented deviation below (to_section_id org-consistency
-- validation in route_entry, same class of gap already closed for
-- Requests' route_request in Phase 1.6A). RLS's two external_
-- correspondence UPDATE policies (_update_entry, _update_section) are
-- both column-blind (they gate ROWS, not which columns change), so
-- every one of the row-mutating commands below (update_entry_draft,
-- route_entry, mark_entry_received, assign_entry, close_entry) uses
-- the same combined check both policies together already allow:
-- is_entry_staff(org_id) OR to_section_id IN (SELECT my_section_ids()).
-- Before routing, to_section_id IS NULL, so only Entry staff satisfy
-- the second branch's "the receiving section" -- exactly matching
-- today's real behavior (only Entry staff can act on an unrouted
-- entry; either Entry staff or the receiving section can act once
-- routed).
--
-- ─── State transitions: reuse existing triggers ────────────────────
-- check_entry_status / valid_entry_status_transition and check_entry_
-- reply_status / valid_entry_reply_status_transition (schema.sql,
-- pre-existing, not introduced by this milestone) already enforce the
-- real state machines:
--   external_correspondence.status:        logged -> routed -> responded -> closed
--   external_correspondence_replies.status: draft -> pending_approval -> {sent, draft}
-- No second, competing lifecycle graph is created here. Each command
-- RPC still enforces its own command-specific precondition beyond bare
-- trigger legality (e.g. mark_entry_received requires received_by IS
-- NULL; submit_entry_reply requires status = 'draft') exactly mirroring
-- entry-api.js's own current guards.
--
-- ─── Concurrency: state-guarded UPDATE, no new lock_version column ──
-- Same pattern as Phase 1.6A: every transition UPDATE's WHERE clause
-- (or an explicit precondition check against a FOR UPDATE-locked row)
-- requires the row's current state to still match what the command
-- expects; a mismatch raises a clear error instead of silently
-- no-op'ing, double-applying, or overwriting concurrent work.
-- ============================================================
\set ON_ERROR_STOP on
BEGIN;

-- ─── create_entry ───────────────────────────────────────────────────
-- Mirrors external_correspondence_insert exactly, except entered_by
-- and org_id are derived server-side (auth.uid(), get_my_org_id())
-- rather than accepted-then-checked. generate_entry_reference() is
-- called from inside the same transaction instead of as a separate
-- client round-trip, so a failure after reference generation can no
-- longer burn a reference number with no row to show for it.
CREATE OR REPLACE FUNCTION create_entry(
  p_source_channel      TEXT,
  p_sender_category     TEXT,
  p_sender_name         TEXT,
  p_subject             TEXT,
  p_body                TEXT,
  p_sender_contact      TEXT DEFAULT NULL,
  p_external_office_name TEXT DEFAULT NULL,
  p_prisoner_ref        UUID DEFAULT NULL,
  p_prisoner_name       TEXT DEFAULT NULL,
  p_subject_language    TEXT DEFAULT 'en',
  p_language            TEXT DEFAULT 'en',
  p_received_date       DATE DEFAULT CURRENT_DATE,
  p_deadline            DATE DEFAULT NULL
) RETURNS SETOF external_correspondence AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_org   UUID;
  v_ref   TEXT;
  v_row   external_correspondence;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_entry requires an authenticated caller';
  END IF;
  IF p_sender_name IS NULL OR btrim(p_sender_name) = '' OR p_subject IS NULL OR btrim(p_subject) = '' OR p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'sender_name, subject, and body are all required';
  END IF;

  v_org := get_my_org_id();
  IF NOT is_entry_staff(v_org) THEN
    RAISE EXCEPTION 'Not authorized to log external correspondence';
  END IF;

  v_ref := generate_entry_reference(v_org);

  INSERT INTO external_correspondence (
    org_id, source_channel, sender_category, sender_name, sender_contact,
    external_office_name, prisoner_ref, prisoner_name,
    subject, subject_language, body, language,
    received_date, deadline, entered_by, status, reference_number
  ) VALUES (
    v_org, p_source_channel, p_sender_category, p_sender_name, p_sender_contact,
    p_external_office_name, p_prisoner_ref, p_prisoner_name,
    p_subject, COALESCE(p_subject_language, 'en'), p_body, COALESCE(p_language, 'en'),
    COALESCE(p_received_date, CURRENT_DATE), p_deadline, v_actor, 'logged', v_ref
  ) RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'created', 'external_correspondence', v_row.id, 'Logged external correspondence from ' || p_sender_name);

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── update_entry_draft ─────────────────────────────────────────────
-- Explicit, required fields only -- no arbitrary JSON patch. The one
-- real call site (js/views/entry-detail.js's edit-entry-form) always
-- submits all five fields together as a full-form save, never a true
-- partial patch. No status guard is added: external_correspondence_
-- update_entry RLS doesn't itself narrow by status either (entry-api.js
-- documents this explicitly -- "UI is the courtesy gate" is Entry's own
-- deliberate design, not an oversight to correct), so this RPC
-- preserves that exact behavior rather than importing Requests'
-- stricter status guard.
CREATE OR REPLACE FUNCTION update_entry_draft(
  p_entry_id         UUID,
  p_subject          TEXT,
  p_subject_language TEXT,
  p_body             TEXT,
  p_language         TEXT,
  p_deadline         DATE DEFAULT NULL
) RETURNS SETOF external_correspondence AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'update_entry_draft requires an authenticated caller';
  END IF;
  IF p_subject IS NULL OR btrim(p_subject) = '' OR p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'subject and body are required';
  END IF;

  SELECT * INTO v_row FROM external_correspondence WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entry not found';
  END IF;
  IF NOT (is_entry_staff(v_row.org_id) OR v_row.to_section_id IN (SELECT my_section_ids())) THEN
    RAISE EXCEPTION 'Not authorized to edit this entry';
  END IF;

  UPDATE external_correspondence SET
    subject = p_subject, subject_language = COALESCE(p_subject_language, 'en'),
    body = p_body, language = COALESCE(p_language, 'en'), deadline = p_deadline
  WHERE id = p_entry_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'edited', 'external_correspondence', p_entry_id, 'Edited entry draft');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── route_entry ────────────────────────────────────────────────────
-- Deviation from current behavior (documented in docs/91, same class of
-- gap already closed for Requests' route_request in Phase 1.6A): also
-- validates p_to_section_id actually belongs to the entry's own org_id.
-- Today's external_correspondence_update_entry policy checks the
-- ACTOR's org membership but never that the TARGET section resolves to
-- the same org. Single UPDATE already atomically sets to_section_id/
-- status/assigned_to together, exactly as entry-api.js's route() does
-- today (no atomicity defect to fix here). Callable again on an
-- already-routed entry to reroute it to a different section -- the
-- status trigger allows 'routed' -> 'routed' (old = new), matching
-- current unrestricted behavior.
CREATE OR REPLACE FUNCTION route_entry(
  p_entry_id UUID,
  p_to_section_id UUID,
  p_assigned_to UUID DEFAULT NULL
) RETURNS SETOF external_correspondence AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence;
  v_section_org UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'route_entry requires an authenticated caller';
  END IF;
  IF p_to_section_id IS NULL THEN
    RAISE EXCEPTION 'to_section_id is required';
  END IF;

  SELECT * INTO v_row FROM external_correspondence WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entry not found';
  END IF;
  IF NOT is_entry_staff(v_row.org_id) THEN
    RAISE EXCEPTION 'Not authorized to route this entry';
  END IF;

  SELECT org_id INTO v_section_org FROM sections WHERE id = p_to_section_id;
  IF v_section_org IS DISTINCT FROM v_row.org_id THEN
    RAISE EXCEPTION 'That section does not belong to this organization';
  END IF;

  IF p_assigned_to IS NOT NULL AND NOT COALESCE((SELECT is_active FROM users WHERE id = p_assigned_to), FALSE) THEN
    RAISE EXCEPTION 'Cannot assign to an inactive user';
  END IF;

  UPDATE external_correspondence SET
    to_section_id = p_to_section_id, status = 'routed', assigned_to = p_assigned_to
  WHERE id = p_entry_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'routed', 'external_correspondence', p_entry_id,
    'Routed to ' || COALESCE((SELECT name FROM sections WHERE id = p_to_section_id), 'a section'));

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── mark_entry_received ────────────────────────────────────────────
-- Guard mirrors entry-api.js's own .is('received_by', null) race guard.
CREATE OR REPLACE FUNCTION mark_entry_received(
  p_entry_id UUID
) RETURNS SETOF external_correspondence AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'mark_entry_received requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM external_correspondence WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entry not found';
  END IF;
  IF NOT (is_entry_staff(v_row.org_id) OR v_row.to_section_id IN (SELECT my_section_ids())) THEN
    RAISE EXCEPTION 'Not authorized to receive this entry';
  END IF;
  IF v_row.received_by IS NOT NULL THEN
    RAISE EXCEPTION 'This entry has already been marked received. Refresh and try again.';
  END IF;

  UPDATE external_correspondence SET received_by = v_actor, received_at = now()
  WHERE id = p_entry_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'received', 'external_correspondence', p_entry_id, 'Marked entry as received by section');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── assign_entry ───────────────────────────────────────────────────
-- Mirrors entry-api.js's assign() -- sets assigned_to and the reply
-- deadline together (the responding section, not Entry front-desk, is
-- the one who knows the right turnaround time). p_user_id eligibility
-- check mirrors assign_request's own bar exactly (active user), same
-- as the current app enforces (no stricter section-membership check
-- existed before this milestone either).
CREATE OR REPLACE FUNCTION assign_entry(
  p_entry_id UUID,
  p_user_id UUID DEFAULT NULL,
  p_deadline DATE DEFAULT NULL
) RETURNS SETOF external_correspondence AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'assign_entry requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM external_correspondence WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entry not found';
  END IF;
  IF NOT (is_entry_staff(v_row.org_id) OR v_row.to_section_id IN (SELECT my_section_ids())) THEN
    RAISE EXCEPTION 'Not authorized to assign this entry';
  END IF;
  IF p_user_id IS NOT NULL AND NOT COALESCE((SELECT is_active FROM users WHERE id = p_user_id), FALSE) THEN
    RAISE EXCEPTION 'Cannot assign to an inactive user';
  END IF;

  UPDATE external_correspondence SET assigned_to = p_user_id, deadline = p_deadline
  WHERE id = p_entry_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'assigned', 'external_correspondence', p_entry_id,
    CASE WHEN p_user_id IS NULL THEN 'Unassigned'
      ELSE 'Assigned to ' || COALESCE((SELECT full_name FROM users WHERE id = p_user_id), 'a staff member') END);

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── close_entry ────────────────────────────────────────────────────
-- No status-transition guard is written here in application code --
-- check_entry_status (schema.sql, pre-existing) already enforces the
-- real state machine on every UPDATE of external_correspondence.status
-- and only allows 'responded' -> 'closed'. Left for the trigger to
-- enforce, exactly like close_request already does for Requests.
CREATE OR REPLACE FUNCTION close_entry(
  p_entry_id UUID
) RETURNS SETOF external_correspondence AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'close_entry requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM external_correspondence WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Entry not found';
  END IF;
  IF NOT (is_entry_staff(v_row.org_id) OR v_row.to_section_id IN (SELECT my_section_ids())) THEN
    RAISE EXCEPTION 'Not authorized to close this entry';
  END IF;

  UPDATE external_correspondence SET status = 'closed' WHERE id = p_entry_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'edited', 'external_correspondence', p_entry_id, 'Closed external correspondence entry');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ═══════════════════════════════════════════════════════════════════
-- ─── Replies ─────────────────────────────────────────────────────
-- ═══════════════════════════════════════════════════════════════════

-- ─── draft_entry_reply ──────────────────────────────────────────────
-- Mirrors external_correspondence_replies_insert exactly.
CREATE OR REPLACE FUNCTION draft_entry_reply(
  p_entry_id UUID,
  p_body TEXT,
  p_language TEXT DEFAULT 'en'
) RETURNS SETOF external_correspondence_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence_replies;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'draft_entry_reply requires an authenticated caller';
  END IF;
  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'body is required';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM external_correspondence ec
    WHERE ec.id = p_entry_id AND ec.to_section_id IN (SELECT my_section_ids())
  ) THEN
    RAISE EXCEPTION 'Not authorized to draft a reply to this entry';
  END IF;

  INSERT INTO external_correspondence_replies (entry_id, created_by, body, language, status)
  VALUES (p_entry_id, v_actor, p_body, COALESCE(p_language, 'en'), 'draft')
  RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'created', 'external_correspondence', p_entry_id, 'Drafted a reply to external correspondence');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── update_entry_reply_draft ───────────────────────────────────────
CREATE OR REPLACE FUNCTION update_entry_reply_draft(
  p_reply_id UUID,
  p_body TEXT,
  p_language TEXT DEFAULT NULL
) RETURNS SETOF external_correspondence_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence_replies;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'update_entry_reply_draft requires an authenticated caller';
  END IF;
  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'body is required';
  END IF;

  UPDATE external_correspondence_replies SET
    body = p_body, language = COALESCE(p_language, language)
  WHERE id = p_reply_id
    AND created_by = v_actor AND status IN ('draft', 'pending_approval')
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'This reply may have already been submitted, approved, or you no longer have permission to edit it. Refresh and try again.';
  END IF;

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── submit_entry_reply ─────────────────────────────────────────────
-- entry_id is read from the reply row itself, never accepted as a
-- client parameter -- the current JS call site (submitReplyForApproval)
-- already only ever passes back the entry object it already has, so
-- this removes a redundant client-supplied identity without changing
-- any legitimate behavior.
CREATE OR REPLACE FUNCTION submit_entry_reply(
  p_reply_id UUID,
  p_approver_id UUID DEFAULT NULL
) RETURNS SETOF external_correspondence_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence_replies;
  v_entry external_correspondence;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'submit_entry_reply requires an authenticated caller';
  END IF;

  UPDATE external_correspondence_replies SET
    status = 'pending_approval', pending_approval_by = p_approver_id
  WHERE id = p_reply_id AND created_by = v_actor AND status = 'draft'
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'This reply is not in a state that can be submitted for approval, or you no longer have permission. Refresh and try again.';
  END IF;

  SELECT * INTO v_entry FROM external_correspondence WHERE id = v_row.entry_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'submitted', 'external_correspondence', v_entry.id, 'Submitted reply for approval');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── approve_entry_reply (atomic composed command) ──────────────────
-- Fixes a genuine atomicity defect: entry-api.js's current approveReply()
-- performs the reply UPDATE (status='sent') and the entry UPDATE
-- (status='responded') as two separate, non-atomic network calls -- a
-- failure between them today can leave a reply marked 'sent' while its
-- parent entry never advances past 'routed'. Folded into one
-- transaction here.
CREATE OR REPLACE FUNCTION approve_entry_reply(
  p_reply_id UUID
) RETURNS SETOF external_correspondence_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence_replies;
  v_entry external_correspondence;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'approve_entry_reply requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM external_correspondence_replies WHERE id = p_reply_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reply not found';
  END IF;
  SELECT * INTO v_entry FROM external_correspondence WHERE id = v_row.entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent entry not found';
  END IF;
  IF NOT (
    is_supervisor_or_above() AND v_entry.to_section_id IS NOT NULL
    AND get_my_org_id() = scope_org_id('section', v_entry.to_section_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to approve this reply';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This reply is not awaiting approval. Refresh and try again.';
  END IF;

  UPDATE external_correspondence_replies SET
    status = 'sent', approved_by = v_actor, approved_at = now()
  WHERE id = p_reply_id RETURNING * INTO v_row;

  UPDATE external_correspondence SET status = 'responded' WHERE id = v_entry.id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'approved', 'external_correspondence', v_entry.id, 'Approved reply to external correspondence');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── return_entry_reply (atomic composed command) ───────────────────
-- Folds the reply UPDATE and the approvals audit-trail INSERT
-- (entry-api.js's returnReply() writes both today, already in the same
-- client call sequence but as two separate network round-trips) into
-- one transaction.
CREATE OR REPLACE FUNCTION return_entry_reply(
  p_reply_id UUID,
  p_comment TEXT DEFAULT NULL
) RETURNS SETOF external_correspondence_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence_replies;
  v_entry external_correspondence;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'return_entry_reply requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM external_correspondence_replies WHERE id = p_reply_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reply not found';
  END IF;
  SELECT * INTO v_entry FROM external_correspondence WHERE id = v_row.entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent entry not found';
  END IF;
  IF NOT (
    is_supervisor_or_above() AND v_entry.to_section_id IS NOT NULL
    AND get_my_org_id() = scope_org_id('section', v_entry.to_section_id)
  ) THEN
    RAISE EXCEPTION 'Not authorized to return this reply';
  END IF;
  IF v_row.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'This reply is not awaiting approval. Refresh and try again.';
  END IF;

  UPDATE external_correspondence_replies SET
    status = 'draft', pending_approval_by = NULL
  WHERE id = p_reply_id RETURNING * INTO v_row;

  INSERT INTO approvals (record_type, record_id, reviewed_by, decision, comment)
  VALUES ('external_correspondence_reply', p_reply_id, v_actor, 'returned', p_comment);

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'returned', 'external_correspondence', v_entry.id, 'Returned reply for changes');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── mark_entry_reply_sent ──────────────────────────────────────────
-- Mirrors external_correspondence_replies_update's third branch
-- (status = 'sent' AND is_entry_staff(entry.org_id)) exactly. Only
-- delivery_method/sent_at are settable -- RLS gates rows not columns
-- on the underlying table, but this RPC's own parameter list is
-- inherently narrower than that, same convention entry-api.js's own
-- comment already documents for this call.
CREATE OR REPLACE FUNCTION mark_entry_reply_sent(
  p_reply_id UUID,
  p_delivery_method TEXT
) RETURNS SETOF external_correspondence_replies AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   external_correspondence_replies;
  v_entry external_correspondence;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'mark_entry_reply_sent requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM external_correspondence_replies WHERE id = p_reply_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reply not found';
  END IF;
  SELECT * INTO v_entry FROM external_correspondence WHERE id = v_row.entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent entry not found';
  END IF;
  IF NOT (v_row.status = 'sent' AND is_entry_staff(v_entry.org_id)) THEN
    RAISE EXCEPTION 'Not authorized to record delivery for this reply';
  END IF;

  UPDATE external_correspondence_replies SET
    delivery_method = p_delivery_method, sent_at = now()
  WHERE id = p_reply_id RETURNING * INTO v_row;

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── Grants ──────────────────────────────────────────────────────────
-- Every function above: REVOKE from PUBLIC/anon, GRANT EXECUTE only to
-- authenticated (auth.uid() is derived server-side in every one; no
-- function trusts a client-supplied identity/org/section value where
-- an authoritative alternative exists).
REVOKE ALL ON FUNCTION create_entry(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,TEXT,TEXT,DATE,DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_entry(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,TEXT,TEXT,DATE,DATE) TO authenticated;

REVOKE ALL ON FUNCTION update_entry_draft(UUID,TEXT,TEXT,TEXT,TEXT,DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION update_entry_draft(UUID,TEXT,TEXT,TEXT,TEXT,DATE) TO authenticated;

REVOKE ALL ON FUNCTION route_entry(UUID,UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION route_entry(UUID,UUID,UUID) TO authenticated;

REVOKE ALL ON FUNCTION mark_entry_received(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION mark_entry_received(UUID) TO authenticated;

REVOKE ALL ON FUNCTION assign_entry(UUID,UUID,DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION assign_entry(UUID,UUID,DATE) TO authenticated;

REVOKE ALL ON FUNCTION close_entry(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION close_entry(UUID) TO authenticated;

REVOKE ALL ON FUNCTION draft_entry_reply(UUID,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION draft_entry_reply(UUID,TEXT,TEXT) TO authenticated;

REVOKE ALL ON FUNCTION update_entry_reply_draft(UUID,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION update_entry_reply_draft(UUID,TEXT,TEXT) TO authenticated;

REVOKE ALL ON FUNCTION submit_entry_reply(UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION submit_entry_reply(UUID,UUID) TO authenticated;

REVOKE ALL ON FUNCTION approve_entry_reply(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION approve_entry_reply(UUID) TO authenticated;

REVOKE ALL ON FUNCTION return_entry_reply(UUID,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION return_entry_reply(UUID,TEXT) TO authenticated;

REVOKE ALL ON FUNCTION mark_entry_reply_sent(UUID,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION mark_entry_reply_sent(UUID,TEXT) TO authenticated;

-- ─── Direct client-write elimination ─────────────────────────────────
-- Once the frontend migration (js/data/entry-api.js) routes every one
-- of the commands above through its RPC instead of a direct table
-- write, direct INSERT/UPDATE on external_correspondence / external_
-- correspondence_replies from authenticated is no longer needed for any
-- MIGRATED command. Revoked narrowly -- SELECT remains (every list/
-- detail read in entry-api.js stays a direct table read, unmigrated and
-- unaffected), and `approvals` keeps its existing INSERT policy/grant AS
-- IS since approvals rows are now only ever written from inside these
-- SECURITY DEFINER functions (running as the function owner, not as
-- `authenticated`) for the Entry reply path -- same reasoning as Phase
-- 1.6A's identical note for requests/responses.
REVOKE INSERT, UPDATE ON TABLE external_correspondence FROM authenticated;
REVOKE INSERT, UPDATE ON TABLE external_correspondence_replies FROM authenticated;

COMMIT;
