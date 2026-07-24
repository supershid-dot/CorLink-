-- ─── Patch: Meeting Personal Notes (docs/22 Phase B, docs/23 §Phase B) ──
-- Requires patch-meetings-foundation.sql, patch-meetings-rsvp.sql,
-- patch-meetings-attendance.sql, patch-meetings-minutes.sql, and
-- patch-meetings-lock.sql already applied. Implements only the
-- personal-notes portion of docs/23's Phase B specification —
-- private, per-participant, per-meeting notes visible and editable
-- only by the participant who wrote them. Idempotent — safe to
-- re-run.
--
-- ─── Design deviation from docs/23's literal wording, and why ──────
-- docs/23 §Phase B/§2 describes personal_notes as a plain column on
-- meeting_participants, redacted only inside meeting_participant_
-- list()'s own output. That design has a real gap: meeting_
-- participants' existing SELECT policy (meeting_participants_select,
-- patch-meetings-foundation.sql §9) already grants full ROW access to
-- any can_manage_meeting()-true caller (creator, org supervisor/
-- admin, super admin) — RLS is row-level, not column-level, so a
-- plain personal_notes column would be directly SELECTable by every
-- meeting manager via a raw table read, completely bypassing any
-- redaction performed inside meeting_participant_list(). That
-- directly contradicts this feature's explicit requirements 3-6
-- (creator/supervisor/same-org admin/super admin must NOT read
-- another participant's notes) and requirement 8 (server-side
-- enforcement, not just hiding UI/RPC output).
--
-- Instead: a dedicated meeting_participant_notes table, one row per
-- participant, with its OWN SELECT policy restricted to
-- user_id = auth.uid() and no manager carve-out at all — the same
-- row-level-RLS technique already used everywhere else in this
-- schema, just scoped to a table whose only column-shape need is
-- "this participant's own note." No INSERT/UPDATE/DELETE policy
-- exists on it either — every write still goes through a SECURITY
-- DEFINER RPC, matching this module's ironclad convention.
BEGIN;

-- ─── 1. meeting_participant_notes ───────────────────────────────
CREATE TABLE IF NOT EXISTS meeting_participant_notes (
  participant_id  UUID        PRIMARY KEY REFERENCES meeting_participants(id) ON DELETE CASCADE,
  user_id         UUID        NOT NULL REFERENCES users(id),
  notes           TEXT,
  updated_at      TIMESTAMPTZ,
  CONSTRAINT meeting_participant_notes_notes_check CHECK (notes IS NULL OR btrim(notes) <> ''),
  -- Mirrors meetings_lock_alignment_check's bidirectional shape:
  -- notes and updated_at only ever change together (set together on
  -- write, both NULL on a never-written row).
  CONSTRAINT meeting_participant_notes_alignment_check
    CHECK ((notes IS NULL) = (updated_at IS NULL))
);
CREATE INDEX IF NOT EXISTS idx_meeting_participant_notes_user ON meeting_participant_notes(user_id);

ALTER TABLE meeting_participant_notes ENABLE ROW LEVEL SECURITY;

-- Strictly own-row, no is_super_admin()/is_admin()/can_manage_meeting()
-- branch at all — the one deliberate difference from every other
-- SELECT policy in this module, because requirements 3-6 give none of
-- those roles a read exception (docs/23 defines no super-admin
-- exception for personal notes, unlike minutes/lock).
DROP POLICY IF EXISTS "meeting_participant_notes_select" ON meeting_participant_notes;
CREATE POLICY "meeting_participant_notes_select" ON meeting_participant_notes
  FOR SELECT USING (user_id = auth.uid());

-- ─── 2. get_my_notes() — dedicated own-row read RPC ─────────────
-- Deliberately NOT folded into meeting_participant_list()'s return
-- shape (per this feature's explicit design directive) — that
-- function is read by can_view_meeting()-true callers generally
-- (including every manager), so adding personal_notes there at all,
-- even nulled for non-owners, would still require every caller of
-- that function to receive a column whose non-null value only ever
-- makes sense for one specific caller — this dedicated RPC keeps
-- personal notes completely outside that broader read path.
CREATE OR REPLACE FUNCTION get_my_notes(
  p_participant_id UUID
) RETURNS TEXT AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_participant meeting_participants;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'get_my_notes requires an authenticated caller';
  END IF;

  SELECT * INTO v_participant FROM meeting_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Participant not found';
  END IF;
  -- Own row only — IS DISTINCT FROM also correctly rejects an
  -- external participant's NULL user_id against any possible actor,
  -- same as respond_to_invitation's identical guard. No can_view_
  -- meeting()/can_manage_meeting() branch: a participant row only
  -- exists for someone already able to view the meeting, and no
  -- other caller is ever allowed to read this value regardless of
  -- their own view/manage authority (requirements 2-6).
  IF v_participant.user_id IS DISTINCT FROM v_actor THEN
    RAISE EXCEPTION 'Not authorized to view these notes';
  END IF;

  -- Deliberately NOT gated on removed_at/meeting status/module-active
  -- — a participant may always read their own past notes, mirroring
  -- meeting_participant_list()'s own read-path convention of gating
  -- only on visibility, never on lifecycle state.
  RETURN (SELECT notes FROM meeting_participant_notes WHERE participant_id = p_participant_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 3. update_my_notes() — own-row write RPC (create/update/clear) ──
-- p_notes = NULL or blank clears the note (same "blank clears" UX
-- convention already used by update_minutes). Deliberately NOT
-- gated on meetings.is_locked/is_meeting_lock_overridable() at all —
-- per this feature's explicit instruction, personal notes are an
-- individual participant action, not a meeting-management action,
-- exactly the same carve-out already established for
-- respond_to_invitation (patch-meetings-rsvp.sql's own documented
-- scope). A locked meeting never blocks this call.
CREATE OR REPLACE FUNCTION update_my_notes(
  p_participant_id UUID,
  p_notes TEXT
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_participant meeting_participants;
  v_meeting meetings;
  v_notes TEXT;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'update_my_notes requires an authenticated caller';
  END IF;

  SELECT * INTO v_participant FROM meeting_participants WHERE id = p_participant_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Participant not found';
  END IF;
  IF v_participant.user_id IS DISTINCT FROM v_actor THEN
    RAISE EXCEPTION 'Not authorized to update these notes';
  END IF;
  IF v_participant.removed_at IS NOT NULL THEN
    RAISE EXCEPTION 'This participant record has been removed';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = v_participant.meeting_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot update notes on a cancelled meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  v_notes := NULLIF(btrim(COALESCE(p_notes, '')), '');

  INSERT INTO meeting_participant_notes (participant_id, user_id, notes, updated_at)
  VALUES (p_participant_id, v_actor, v_notes, CASE WHEN v_notes IS NULL THEN NULL ELSE now() END)
  ON CONFLICT (participant_id) DO UPDATE SET
    notes = EXCLUDED.notes,
    updated_at = EXCLUDED.updated_at;

  -- Deliberately NOT audited. docs/23 specifies no audit action for
  -- update_my_notes (unlike every other Phase A/B RPC, which each
  -- have an explicit audit_logs.action value). audit_logs is
  -- additionally visible to org admins (own-org actors) and super
  -- admins via the general audit_select policy (patch-user-
  -- assignments-scope.sql) — an audit row here, even with no note
  -- content, would still reveal to exactly the roles barred by
  -- requirements 5/6 that a given participant edited their notes and
  -- when, which is metadata this feature's privacy intent should not
  -- leak either. No audit_logs row is written by this RPC.
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMIT;
