-- ============================================================
-- CorLink — Prisoner Letters: Server-Authoritative Mutation
-- Foundation
-- ============================================================
-- Implements the milestone approved after docs/95 (Prisoner Letters
-- Architecture, Confidentiality & Security Review). Migrates all six
-- evidenced Prisoner Letters business mutations from direct client
-- .insert()/.update() calls to SECURITY DEFINER RPCs, mirroring the
-- Requests (1.6A), Entry (1.7A), and Internal Collaboration (1.8A)
-- precedent. This is NOT CAP-003 notification integration — no
-- platform_enqueue_outbox_event/create_notification_intent/
-- resolve_notification_intent/process_platform_outbox_batch/
-- user_notifications reference exists anywhere in this patch, and no
-- event type is registered. Legacy NotificationsAPI.notify() call
-- sites remain entirely in the frontend, unchanged.
--
-- ─── Inventory (all 6 evidenced direct-write commands, docs/95 §8) ──
-- submitLetter()       -> create_prisoner_letter()
-- markReceived()       -> mark_prisoner_letter_received()
-- routeLetter()        -> route_prisoner_letter()
-- markSlipGenerated()  -> mark_prisoner_letter_slip_generated()
-- createReply()        -> create_prisoner_letter_reply()  -- fused
--   atomic (was: separate INSERT prisoner_replies + UPDATE
--   prisoner_letters.status, docs/95 §20/§25 highest-priority defect)
-- markDelivered()      -> mark_prisoner_letter_delivered()
--
-- No approval workflow, draft/review state, cancellation, or
-- multi-reply-cycle concept exists in the current implementation, so
-- none is invented here — the six commands above are the complete,
-- evidenced set.
--
-- ─── Product decision A: narrower authorization model ──────────────
-- docs/95 §11/§25 confirmed the live RLS grants any is_prisoner_
-- letters_staff-flagged member of EITHER participating org full
-- reply/route/receive/deliver access to EVERY letter between those two
-- orgs — broader than either this app's own UI copy or its own API
-- file header comment claim, and already self-documented as a gap in
-- patch-prisoner-letter-task-integration.sql. Approved replacement
-- model, built entirely from EXISTING columns (no new field invented):
--   MCS side   (from_prison_id = caller's org): the letter's own
--     submitted_by (creator, still gated by is_prisoner_letters_staff)
--     OR is_supervisor_or_above() (org-wide oversight, independent of
--     the flag — matching every other module's own supervisor-bypass
--     convention, and explicitly approved: "responsible supervisor/
--     admin with oversight authority").
--   Authority side (to_org_id = caller's org): the letter's own
--     assigned_to (assignee, still gated by is_prisoner_letters_staff)
--     OR is_supervisor_or_above(), same independence.
-- "Same organization = authorized" is deliberately never used alone.
-- Before a letter is routed/assigned (assigned_to IS NULL), only an
-- authority-side supervisor/admin can see or act on it — matching the
-- pre-existing "Route (receiving org, supervisor/admin)" comment
-- already in js/data/prisoner-letters-api.js, i.e. this milestone
-- formalizes a role restriction the frontend already documented as
-- intentional, it does not invent one.
-- Replies are additionally restricted to the AUTHORITY side only
-- (to_org_id match) — the previous RLS allowed either side to insert a
-- reply, which contradicts the governing business rule ("the external
-- authority replies... MCS does not") more directly than any other
-- single finding in docs/95; this migration corrects it.
-- Known, disclosed consequence: an MCS/authority admin or supervisor
-- who lacks the individual is_prisoner_letters_staff flag now has
-- read/oversight access at the RLS/RPC layer that the frontend's own
-- nav-gating (AppShell.canAccessPrisonerLetters, js/views/shell.js)
-- does not yet expose a navigation path to — this milestone does not
-- touch that frontend gate ("preserve current UI behavior, do not
-- redesign screens" per its own governing instruction); documented as
-- a known limitation in docs/96 for a future frontend milestone.
--
-- ─── Product decision B: terminal immutability ──────────────────────
-- 'delivered' is the sole terminal state (docs/95 §7 already
-- identified it as the de facto terminal status, confirmed by
-- patch-prisoner-letter-task-integration.sql's own v_status <>
-- 'delivered' task-capability gate). Once a letter reaches 'delivered':
--   - no RPC below accepts it as a valid starting state for any further
--     mutation (each RPC's own status guard structurally enforces
--     this — no separate global trigger was needed, since every
--     mutation already goes through a single-purpose, narrowly-guarded
--     RPC; a global trigger would duplicate logic already enforced at
--     the one place each transition can occur).
--   - to_org_id/from_prison_id are never written by ANY RPC after
--     creation (not even route_prisoner_letter, which only ever
--     touches to_section_id/assigned_to) — this makes both columns
--     structurally immutable for the entire lifetime of a letter, not
--     merely post-'delivered', which is a strictly stronger property
--     than the minimum required and needs no extra guard.
--   - attachments_insert/attachments_delete's own prisoner_letter/
--     prisoner_reply branches (rls.sql) gain a `pl.status <>
--     'delivered'` condition, mirroring the exact pattern the
--     'request'/'external_correspondence' branches of the SAME two
--     policies already use (r.is_locked = FALSE / ec.status !=
--     'closed') — scoped to exactly these two record_type branches,
--     touching no other module's attachment rules.
-- No amendment/versioning subsystem is introduced — docs/95 §14/§26
-- already concluded none is required for this milestone; if an
-- operational correction is ever needed after delivery, it is a future,
-- explicit amendment/reissue capability, not silent mutation.
--
-- ─── Reference-generation atomicity (Section 14) ────────────────────
-- generate_prisoner_letter_reference() is folded INTO
-- create_prisoner_letter()'s own transaction (called internally, no
-- longer a separate client RPC round trip) and its own EXECUTE grant
-- to authenticated/anon is revoked — it is now callable only from
-- within create_prisoner_letter() itself (a nested SECURITY DEFINER
-- call executes with ITS OWN definer's privileges, the same working
-- pattern platform_enqueue_outbox_event already relies on elsewhere in
-- this codebase). Its own missing search_path pin (docs/95 §10) is
-- fixed in the same CREATE OR REPLACE. No new sequence system —
-- letter_reference_sequences and its (org_id, year) counter are reused
-- exactly as they already exist.
--
-- ─── Reply atomicity (Section 13) ───────────────────────────────────
-- create_prisoner_letter_reply() fuses the INSERT INTO prisoner_replies
-- and the UPDATE prisoner_letters SET status='replied' into one
-- transaction — the exact same class of fix already applied to
-- approve_response()/approve_entry_reply()/approve_internal_request_
-- reply() in this codebase.
--
-- ─── Reply immutability preserved ───────────────────────────────────
-- prisoner_replies gains NO new UPDATE policy and no update RPC —
-- docs/95 §16 confirmed this "immutable by omission" property is a
-- genuine strength; it is preserved exactly, not touched.
--
-- ─── Assignment hardening (Section 9) ───────────────────────────────
-- route_prisoner_letter() validates server-side that a supplied
-- assignee is_active, belongs to the destination (to_org_id)
-- organization, and holds is_prisoner_letters_staff — the same three
-- checks the frontend's own route-modal dropdown already filters for
-- client-side (prisoner-letter-detail.js), now independently enforced
-- server-side rather than trusted from the client.
--
-- ─── Audit (Section 15) ──────────────────────────────────────────────
-- Every RPC below writes its own audit_logs row in the SAME
-- transaction as its domain mutation (server-side, atomic — replacing
-- js/data/prisoner-letters-api.js's own client-side logAudit() calls,
-- removed from the frontend by the companion frontend-migration
-- change). Notes preserve the EXACT existing text from the current
-- client-side calls (including submitLetter's own inclusion of the
-- prisoner's full name, and createReply's own reuse of the 'created'
-- action) — this migration neither reduces nor expands what is
-- recorded; docs/95 §15/§21 already documented that existing note as
-- confidentiality-adjacent, not newly introduced here.
-- mark_prisoner_letter_slip_generated() gains an audit write it
-- previously never had (docs/95 §15 flagged this omission) — a narrow,
-- justified addition (one more structural-only row, action='edited',
-- matching mark_prisoner_letter_delivered's own existing action
-- choice), not "excessive telemetry."
-- No handwritten letter body, reply body, or prisoner registry detail
-- beyond the already-evidenced full_name is ever written into
-- audit_logs by any RPC below.
--
-- ─── Zero CAP-003 integration ────────────────────────────────────────
-- None of the RPCs below reference platform_enqueue_outbox_event,
-- create_notification_intent, resolve_notification_intent,
-- process_platform_outbox_batch, user_notifications,
-- notification_intents, or platform_outbox_events, anywhere. No
-- platform_event_type_registry row is inserted. Legacy
-- NotificationsAPI.notify() call sites remain entirely in the
-- frontend, unchanged, called by the frontend itself immediately after
-- each RPC call succeeds — exactly the same "RPC writes state+audit,
-- frontend still fires the legacy notify() afterward" shape Requests/
-- Entry/Internal Collaboration's own foundation phases (1.6A/1.7A/
-- 1.8A) each used. A future milestone will handle CAP-003 integration
-- separately, after this boundary is reviewed and pushed.
--
-- ─── No digital signature ────────────────────────────────────────────
-- Nothing below implements a signer field, signature image, external
-- PDF signing, or official-letter rendering. The eventual integration
-- point for a future signature system is create_prisoner_letter_
-- reply() — whichever future command finalizes/issues an official
-- authority reply will need to be revisited once that system exists;
-- this milestone's version of that command remains a plain-text,
-- single-shot, immutable reply exactly as today.
--
-- Idempotent — safe to re-run (CREATE OR REPLACE only for functions
-- already defined by this patch; DROP POLICY IF EXISTS/CREATE POLICY
-- pairs and the REVOKE/GRANT block at the end are naturally
-- idempotent).
-- ============================================================

BEGIN;

-- ─── 1. generate_prisoner_letter_reference(): pin search_path, make
--    internal-only (no longer directly client-callable — see header).
CREATE OR REPLACE FUNCTION generate_prisoner_letter_reference(p_org_id UUID)
RETURNS TEXT AS $$
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION generate_prisoner_letter_reference(UUID) FROM PUBLIC, anon, authenticated;

-- ─── 2. create_prisoner_letter() ────────────────────────────────────
-- Directionality (Section 7): from_prison_id forced to the caller's
-- own org, both organizations' type independently verified server-side
-- — an authority-org caller fails on two independent grounds. Prisoner
-- identity (prisoner_id/prisoner_name) is derived server-side from the
-- prisoners registry row (org-matched), never trusted from the client.
CREATE OR REPLACE FUNCTION create_prisoner_letter(
  p_prisoner_ref UUID,
  p_from_prison_id UUID,
  p_to_org_id UUID,
  p_body TEXT
) RETURNS SETOF prisoner_letters AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   prisoner_letters;
  v_prisoner prisoners;
  v_ref   TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_prisoner_letter requires an authenticated caller';
  END IF;
  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'body is required';
  END IF;
  IF p_prisoner_ref IS NULL THEN
    RAISE EXCEPTION 'prisoner_ref is required';
  END IF;

  IF NOT is_prisoner_letters_staff() THEN
    RAISE EXCEPTION 'Not authorized to submit prisoner letters';
  END IF;
  IF p_from_prison_id IS DISTINCT FROM get_my_org_id() THEN
    RAISE EXCEPTION 'You may only submit prisoner letters on behalf of your own organization';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM organizations o WHERE o.id = p_from_prison_id AND o.type = 'mcs') THEN
    RAISE EXCEPTION 'The sending organization must be an MCS organization';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM organizations o WHERE o.id = p_to_org_id AND o.type = 'authority') THEN
    RAISE EXCEPTION 'The destination organization must be an authority organization';
  END IF;

  SELECT * INTO v_prisoner FROM prisoners WHERE id = p_prisoner_ref AND org_id = p_from_prison_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prisoner not found in your organization''s registry';
  END IF;

  v_ref := generate_prisoner_letter_reference(p_from_prison_id);

  INSERT INTO prisoner_letters (
    prisoner_ref, prisoner_id, prisoner_name, from_prison_id, to_org_id, body,
    submitted_by, status, reference_number, slip_generated
  ) VALUES (
    p_prisoner_ref, v_prisoner.id_card_number, v_prisoner.full_name, p_from_prison_id, p_to_org_id, p_body,
    v_actor, 'submitted', v_ref, FALSE
  ) RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'created', 'prisoner_letter', v_row.id, 'Submitted prisoner letter for ' || v_prisoner.full_name);

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. mark_prisoner_letter_received() ─────────────────────────────
CREATE OR REPLACE FUNCTION mark_prisoner_letter_received(
  p_letter_id UUID
) RETURNS SETOF prisoner_letters AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   prisoner_letters;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'mark_prisoner_letter_received requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM prisoner_letters WHERE id = p_letter_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prisoner letter not found';
  END IF;
  IF NOT (
    v_row.to_org_id = get_my_org_id()
    AND ((is_prisoner_letters_staff() AND v_row.assigned_to IS NOT NULL AND v_row.assigned_to = v_actor) OR is_supervisor_or_above())
  ) THEN
    RAISE EXCEPTION 'Not authorized to receive this prisoner letter';
  END IF;
  IF v_row.status <> 'submitted' THEN
    RAISE EXCEPTION 'This prisoner letter is not awaiting receipt. Refresh and try again.';
  END IF;

  UPDATE prisoner_letters SET status = 'received', received_by = v_actor, received_at = now()
  WHERE id = p_letter_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'received', 'prisoner_letter', p_letter_id, 'Marked prisoner letter as received');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 4. route_prisoner_letter() ─────────────────────────────────────
-- Authority side, supervisor/admin only (matches the pre-existing
-- "Route (receiving org, supervisor/admin)" comment in js/data/
-- prisoner-letters-api.js — a role restriction the frontend already
-- documented as intentional). Assignment hardening (Section 9): the
-- supplied assignee must be active, belong to the destination org, and
-- hold is_prisoner_letters_staff.
CREATE OR REPLACE FUNCTION route_prisoner_letter(
  p_letter_id UUID,
  p_to_section_id UUID,
  p_assigned_to UUID DEFAULT NULL
) RETURNS SETOF prisoner_letters AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   prisoner_letters;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'route_prisoner_letter requires an authenticated caller';
  END IF;
  IF p_to_section_id IS NULL THEN
    RAISE EXCEPTION 'to_section_id is required';
  END IF;

  SELECT * INTO v_row FROM prisoner_letters WHERE id = p_letter_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prisoner letter not found';
  END IF;
  IF v_row.status = 'delivered' THEN
    RAISE EXCEPTION 'This prisoner letter has already been delivered and can no longer be routed';
  END IF;
  IF NOT (v_row.to_org_id = get_my_org_id() AND is_supervisor_or_above()) THEN
    RAISE EXCEPTION 'Not authorized to route this prisoner letter';
  END IF;
  IF scope_org_id('section', p_to_section_id) IS DISTINCT FROM v_row.to_org_id THEN
    RAISE EXCEPTION 'That section does not belong to the destination organization';
  END IF;
  IF p_assigned_to IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM users u WHERE u.id = p_assigned_to
      AND u.is_active AND u.org_id = v_row.to_org_id AND u.is_prisoner_letters_staff
  ) THEN
    RAISE EXCEPTION 'Cannot assign to a user who is inactive, in a different organization, or not designated for Prisoner Letters duty';
  END IF;

  UPDATE prisoner_letters SET to_section_id = p_to_section_id, assigned_to = p_assigned_to
  WHERE id = p_letter_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'routed', 'prisoner_letter', p_letter_id, 'Routed prisoner letter to section');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 5. mark_prisoner_letter_slip_generated() ───────────────────────
-- MCS side ("MCS marks the hand-over slip as generated (after
-- printing)" — existing comment). Gains an audit write it previously
-- never had (Section 15).
CREATE OR REPLACE FUNCTION mark_prisoner_letter_slip_generated(
  p_letter_id UUID
) RETURNS SETOF prisoner_letters AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   prisoner_letters;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'mark_prisoner_letter_slip_generated requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM prisoner_letters WHERE id = p_letter_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prisoner letter not found';
  END IF;
  IF v_row.status = 'delivered' THEN
    RAISE EXCEPTION 'This prisoner letter has already been delivered';
  END IF;
  IF NOT (
    v_row.from_prison_id = get_my_org_id()
    AND ((is_prisoner_letters_staff() AND v_row.submitted_by = v_actor) OR is_supervisor_or_above())
  ) THEN
    RAISE EXCEPTION 'Not authorized to mark this prisoner letter''s slip as generated';
  END IF;

  UPDATE prisoner_letters SET slip_generated = TRUE WHERE id = p_letter_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'edited', 'prisoner_letter', p_letter_id, 'Marked prisoner letter slip generated');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 6. create_prisoner_letter_reply() (atomic composed command) ────
-- Fuses the two previously-separate client writes (INSERT prisoner_
-- replies + UPDATE prisoner_letters.status) into one transaction — see
-- header. Authority side ONLY (governing business rule: MCS never
-- replies to its own letter) — a genuine, evidenced-justified
-- tightening versus the prior either-side RLS.
CREATE OR REPLACE FUNCTION create_prisoner_letter_reply(
  p_letter_id UUID,
  p_body TEXT
) RETURNS SETOF prisoner_replies AS $$
DECLARE
  v_actor  UUID := auth.uid();
  v_letter prisoner_letters;
  v_reply  prisoner_replies;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_prisoner_letter_reply requires an authenticated caller';
  END IF;
  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'body is required';
  END IF;

  SELECT * INTO v_letter FROM prisoner_letters WHERE id = p_letter_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prisoner letter not found';
  END IF;
  IF NOT (
    v_letter.to_org_id = get_my_org_id()
    AND ((is_prisoner_letters_staff() AND v_letter.assigned_to IS NOT NULL AND v_letter.assigned_to = v_actor) OR is_supervisor_or_above())
  ) THEN
    RAISE EXCEPTION 'Not authorized to reply to this prisoner letter';
  END IF;
  IF v_letter.status NOT IN ('submitted', 'received') THEN
    RAISE EXCEPTION 'This prisoner letter is not awaiting a reply. Refresh and try again.';
  END IF;

  INSERT INTO prisoner_replies (letter_id, body, replied_by)
  VALUES (p_letter_id, p_body, v_actor) RETURNING * INTO v_reply;

  UPDATE prisoner_letters SET status = 'replied' WHERE id = p_letter_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'created', 'prisoner_letter', p_letter_id, 'Replied to prisoner letter');

  RETURN NEXT v_reply;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 7. mark_prisoner_letter_delivered() ────────────────────────────
-- MCS side ("MCS side confirms hand-off to the prisoner" — existing
-- comment). Terminal transition — see header for the immutability
-- consequences that follow from this status.
CREATE OR REPLACE FUNCTION mark_prisoner_letter_delivered(
  p_letter_id UUID
) RETURNS SETOF prisoner_letters AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_row   prisoner_letters;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'mark_prisoner_letter_delivered requires an authenticated caller';
  END IF;

  SELECT * INTO v_row FROM prisoner_letters WHERE id = p_letter_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prisoner letter not found';
  END IF;
  IF NOT (
    v_row.from_prison_id = get_my_org_id()
    AND ((is_prisoner_letters_staff() AND v_row.submitted_by = v_actor) OR is_supervisor_or_above())
  ) THEN
    RAISE EXCEPTION 'Not authorized to mark this prisoner letter as delivered';
  END IF;
  IF v_row.status <> 'replied' THEN
    RAISE EXCEPTION 'This prisoner letter is not awaiting delivery confirmation. Refresh and try again.';
  END IF;

  UPDATE prisoner_letters SET status = 'delivered' WHERE id = p_letter_id RETURNING * INTO v_row;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'edited', 'prisoner_letter', p_letter_id, 'Marked prisoner letter delivered');

  RETURN NEXT v_row;
  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 8. SECURITY DEFINER grant posture ──────────────────────────────
REVOKE ALL ON FUNCTION create_prisoner_letter(UUID,UUID,UUID,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_prisoner_letter(UUID,UUID,UUID,TEXT) TO authenticated;

REVOKE ALL ON FUNCTION mark_prisoner_letter_received(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION mark_prisoner_letter_received(UUID) TO authenticated;

REVOKE ALL ON FUNCTION route_prisoner_letter(UUID,UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION route_prisoner_letter(UUID,UUID,UUID) TO authenticated;

REVOKE ALL ON FUNCTION mark_prisoner_letter_slip_generated(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION mark_prisoner_letter_slip_generated(UUID) TO authenticated;

REVOKE ALL ON FUNCTION create_prisoner_letter_reply(UUID,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_prisoner_letter_reply(UUID,TEXT) TO authenticated;

REVOKE ALL ON FUNCTION mark_prisoner_letter_delivered(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION mark_prisoner_letter_delivered(UUID) TO authenticated;

-- ─── 9. RLS realignment (Section 17/18) — access model narrowed to
--    match the approved product decision; defense-in-depth even though
--    direct authenticated writes are revoked in section 11 below (RLS
--    still governs SELECT, and remains correct if grants were ever
--    reopened). ──────────────────────────────────────────────────────
DROP POLICY IF EXISTS "prisoner_letters_select" ON prisoner_letters;
CREATE POLICY "prisoner_letters_select" ON prisoner_letters
  FOR SELECT USING (
    (from_prison_id = get_my_org_id() AND (
      (is_prisoner_letters_staff() AND submitted_by = auth.uid())
      OR is_supervisor_or_above()
    ))
    OR (to_org_id = get_my_org_id() AND (
      (is_prisoner_letters_staff() AND assigned_to = auth.uid())
      OR is_supervisor_or_above()
    ))
  );

DROP POLICY IF EXISTS "prisoner_letters_insert" ON prisoner_letters;
CREATE POLICY "prisoner_letters_insert" ON prisoner_letters
  FOR INSERT WITH CHECK (
    submitted_by = auth.uid()
    AND is_prisoner_letters_staff()
    AND from_prison_id = get_my_org_id()
    AND EXISTS (SELECT 1 FROM organizations o WHERE o.id = from_prison_id AND o.type = 'mcs')
    AND EXISTS (SELECT 1 FROM organizations o WHERE o.id = to_org_id AND o.type = 'authority')
  );

DROP POLICY IF EXISTS "prisoner_letters_update" ON prisoner_letters;
CREATE POLICY "prisoner_letters_update" ON prisoner_letters
  FOR UPDATE USING (
    (from_prison_id = get_my_org_id() AND (
      (is_prisoner_letters_staff() AND submitted_by = auth.uid())
      OR is_supervisor_or_above()
    ))
    OR (to_org_id = get_my_org_id() AND (
      (is_prisoner_letters_staff() AND assigned_to = auth.uid())
      OR is_supervisor_or_above()
    ))
  );

DROP POLICY IF EXISTS "prisoner_replies_select" ON prisoner_replies;
CREATE POLICY "prisoner_replies_select" ON prisoner_replies
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE pl.id = letter_id
        AND (
          (pl.from_prison_id = get_my_org_id() AND (
            (is_prisoner_letters_staff() AND pl.submitted_by = auth.uid())
            OR is_supervisor_or_above()
          ))
          OR (pl.to_org_id = get_my_org_id() AND (
            (is_prisoner_letters_staff() AND pl.assigned_to = auth.uid())
            OR is_supervisor_or_above()
          ))
        )
    )
  );

-- Authority-only (Section 7/governing business rule: MCS never
-- replies). No update/delete policy exists or is added — replies
-- remain immutable by omission (Section 16).
DROP POLICY IF EXISTS "prisoner_replies_insert" ON prisoner_replies;
CREATE POLICY "prisoner_replies_insert" ON prisoner_replies
  FOR INSERT WITH CHECK (
    replied_by = auth.uid()
    AND EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE pl.id = letter_id
        AND pl.to_org_id = get_my_org_id()
        AND (
          (is_prisoner_letters_staff() AND pl.assigned_to = auth.uid())
          OR is_supervisor_or_above()
        )
    )
  );

-- ─── 10. Attachments: narrow the prisoner_letter/prisoner_reply
--    branches to the same access model, and add the finalization lock
--    (Section 11) to attachments_insert/attachments_delete only —
--    mirroring the exact pattern the 'request'/'external_
--    correspondence' branches of these SAME two policies already use
--    (is_locked=FALSE / status!='closed'). No other record_type branch
--    is touched. SELECT keeps the two-sided (MCS + authority) predicate
--    since both parties may legitimately need to VIEW a reply's
--    attachments; attachments_insert/attachments_delete's own
--    prisoner_reply branches are authority-side ONLY (to_org_id match +
--    assigned_to/supervisor), matching create_prisoner_letter_reply()'s
--    own directionality exactly — an MCS user never uploads to or
--    deletes from a reply it did not and cannot author. ─────────────
DROP POLICY IF EXISTS "attachments_select" ON attachments;
CREATE POLICY "attachments_select" ON attachments
  FOR SELECT USING (
    uploaded_by = auth.uid()
    OR (record_type = 'request' AND EXISTS (
      SELECT 1 FROM requests r
      WHERE r.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id IN (SELECT my_section_ids())
          OR r.created_by = auth.uid()
          OR is_admin()
        )
    ))
    OR (record_type = 'response' AND EXISTS (
      SELECT 1 FROM responses re
      JOIN requests r ON r.id = re.request_id
      WHERE re.id = record_id
        AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
        AND (
          r.from_section_id IN (SELECT my_section_ids())
          OR r.to_section_id IN (SELECT my_section_ids())
          OR r.created_by = auth.uid()
          OR is_admin()
        )
    ))
    OR (record_type = 'internal_request' AND EXISTS (
      SELECT 1 FROM internal_requests ir
      WHERE ir.id = record_id
        AND (
          ir.from_section_id IN (SELECT my_section_ids())
          OR ir.to_section_id IN (SELECT my_section_ids())
          OR ir.created_by = auth.uid()
          OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
        )
    ))
    OR (record_type = 'prisoner_letter' AND EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE pl.id = record_id
        AND (
          (pl.from_prison_id = get_my_org_id() AND (
            (is_prisoner_letters_staff() AND pl.submitted_by = auth.uid())
            OR is_supervisor_or_above()
          ))
          OR (pl.to_org_id = get_my_org_id() AND (
            (is_prisoner_letters_staff() AND pl.assigned_to = auth.uid())
            OR is_supervisor_or_above()
          ))
        )
    ))
    OR (record_type = 'prisoner_reply' AND EXISTS (
      SELECT 1 FROM prisoner_replies pr
      JOIN prisoner_letters pl ON pl.id = pr.letter_id
      WHERE pr.id = record_id
        AND (
          (pl.from_prison_id = get_my_org_id() AND (
            (is_prisoner_letters_staff() AND pl.submitted_by = auth.uid())
            OR is_supervisor_or_above()
          ))
          OR (pl.to_org_id = get_my_org_id() AND (
            (is_prisoner_letters_staff() AND pl.assigned_to = auth.uid())
            OR is_supervisor_or_above()
          ))
        )
    ))
    OR (record_type = 'internal_reply' AND EXISTS (
      SELECT 1 FROM internal_request_replies irr
      JOIN internal_requests ir ON ir.id = irr.internal_request_id
      WHERE irr.id = record_id
        AND (
          ir.to_section_id IN (SELECT my_section_ids())
          OR irr.created_by = auth.uid()
          OR (is_supervisor_or_above() AND get_my_org_id() = scope_org_id('section', ir.to_section_id))
          OR (
            irr.status = 'sent'
            AND (ir.from_section_id IN (SELECT my_section_ids()) OR ir.created_by = auth.uid())
          )
        )
    ))
  );

DROP POLICY IF EXISTS "attachments_insert" ON attachments;
CREATE POLICY "attachments_insert" ON attachments
  FOR INSERT WITH CHECK (
    uploaded_by = auth.uid()
    AND (
      (record_type = 'request' AND EXISTS (
        SELECT 1 FROM requests r WHERE r.id = record_id
          AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
          AND r.is_locked = FALSE
      ))
      OR (record_type = 'response' AND EXISTS (
        SELECT 1 FROM responses re JOIN requests r ON r.id = re.request_id
        WHERE re.id = record_id
          AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
          AND re.is_locked = FALSE
      ))
      OR (record_type = 'internal_request' AND EXISTS (
        SELECT 1 FROM internal_requests ir WHERE ir.id = record_id
          AND (
            ir.from_section_id IN (SELECT my_section_ids())
            OR ir.to_section_id IN (SELECT my_section_ids())
            OR ir.created_by = auth.uid()
          )
      ))
      OR (record_type = 'prisoner_letter' AND EXISTS (
        SELECT 1 FROM prisoner_letters pl WHERE pl.id = record_id
          AND pl.status <> 'delivered'
          AND (
            (pl.from_prison_id = get_my_org_id() AND (
              (is_prisoner_letters_staff() AND pl.submitted_by = auth.uid())
              OR is_supervisor_or_above()
            ))
            OR (pl.to_org_id = get_my_org_id() AND (
              (is_prisoner_letters_staff() AND pl.assigned_to = auth.uid())
              OR is_supervisor_or_above()
            ))
          )
      ))
      OR (record_type = 'prisoner_reply' AND EXISTS (
        SELECT 1 FROM prisoner_replies pr JOIN prisoner_letters pl ON pl.id = pr.letter_id
        WHERE pr.id = record_id
          AND pl.status <> 'delivered'
          AND pl.to_org_id = get_my_org_id()
          AND (
            (is_prisoner_letters_staff() AND pl.assigned_to = auth.uid())
            OR is_supervisor_or_above()
          )
      ))
      OR (record_type = 'internal_reply' AND EXISTS (
        SELECT 1 FROM internal_request_replies irr WHERE irr.id = record_id
          AND irr.created_by = auth.uid() AND irr.status IN ('draft', 'pending_approval')
      ))
    )
  );

DROP POLICY IF EXISTS "attachments_delete" ON attachments;
CREATE POLICY "attachments_delete" ON attachments
  FOR DELETE USING (
    uploaded_by = auth.uid()
    AND (
      (record_type = 'request' AND EXISTS (
        SELECT 1 FROM requests r WHERE r.id = record_id
          AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
          AND r.is_locked = FALSE
      ))
      OR (record_type = 'response' AND EXISTS (
        SELECT 1 FROM responses re JOIN requests r ON r.id = re.request_id
        WHERE re.id = record_id
          AND (r.from_org_id = get_my_org_id() OR r.to_org_id = get_my_org_id())
          AND re.is_locked = FALSE
      ))
      OR (record_type = 'internal_request' AND EXISTS (
        SELECT 1 FROM internal_requests ir WHERE ir.id = record_id
          AND (
            ir.from_section_id IN (SELECT my_section_ids())
            OR ir.to_section_id IN (SELECT my_section_ids())
            OR ir.created_by = auth.uid()
          )
      ))
      OR (record_type = 'prisoner_letter' AND EXISTS (
        SELECT 1 FROM prisoner_letters pl WHERE pl.id = record_id
          AND pl.status <> 'delivered'
          AND (
            (pl.from_prison_id = get_my_org_id() AND (
              (is_prisoner_letters_staff() AND pl.submitted_by = auth.uid())
              OR is_supervisor_or_above()
            ))
            OR (pl.to_org_id = get_my_org_id() AND (
              (is_prisoner_letters_staff() AND pl.assigned_to = auth.uid())
              OR is_supervisor_or_above()
            ))
          )
      ))
      OR (record_type = 'prisoner_reply' AND EXISTS (
        SELECT 1 FROM prisoner_replies pr JOIN prisoner_letters pl ON pl.id = pr.letter_id
        WHERE pr.id = record_id
          AND pl.status <> 'delivered'
          AND pl.to_org_id = get_my_org_id()
          AND (
            (is_prisoner_letters_staff() AND pl.assigned_to = auth.uid())
            OR is_supervisor_or_above()
          )
      ))
      OR (record_type = 'internal_reply' AND EXISTS (
        SELECT 1 FROM internal_request_replies irr WHERE irr.id = record_id
          AND irr.created_by = auth.uid() AND irr.status IN ('draft', 'pending_approval')
      ))
      OR (record_type = 'external_correspondence' AND EXISTS (
        SELECT 1 FROM external_correspondence ec WHERE ec.id = record_id
          AND ec.org_id = get_my_org_id() AND is_entry_staff(ec.org_id) AND ec.status != 'closed'
      ))
      OR (record_type = 'external_correspondence_reply' AND EXISTS (
        SELECT 1 FROM external_correspondence_replies ecr WHERE ecr.id = record_id
          AND ecr.created_by = auth.uid() AND ecr.status IN ('draft', 'pending_approval')
      ))
    )
  );

-- Storage bucket delete policy is bucket-level only (owner=auth.uid(),
-- no record_type awareness — see storage-policies.sql's own comment on
-- why: the table-level attachments_delete policy above is the real,
-- record-type-aware gate; an object can only ever be deleted here if
-- its DB row would also independently satisfy attachments_delete,
-- since a storage-only delete leaves a dangling attachments row that
-- itself becomes unreadable) — unchanged, no modification needed here.

-- ─── 11. Direct-write closure (Section 19) ──────────────────────────
-- Ordinary browser mutation privileges are no longer necessary for
-- prisoner_letters/prisoner_replies now that every evidenced business
-- command has a safe RPC equivalent. SELECT is untouched (every read
-- path — listInbox/listSent/globalSearch/getLetter/listReplies —
-- remains a direct .from(...).select(...) call, unmigrated, per the
-- governing instruction). attachments remains client-writable (the
-- browser-upload architecture requires it); its business-state rules
-- are enforced via the RLS finalization lock in section 10 above, not
-- by revoking the table grant.
REVOKE INSERT, UPDATE, DELETE ON TABLE prisoner_letters, prisoner_replies FROM authenticated;

COMMIT;
