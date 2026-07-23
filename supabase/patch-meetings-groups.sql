-- ─── Patch: Meeting Groups (docs/22 Phase E, docs/23 §Phase E) ──────
-- Requires patch-meetings-foundation.sql already applied (uses
-- can_manage_meeting(), meetings_module_active_for(), add_participant()).
-- Named, reusable, org-scoped invite lists. Idempotent — safe to
-- re-run.
--
-- ─── Design deviation from docs/23's literal wording, and why ──────
-- docs/23 §Phase E/§2 specifies THREE tables, adding a separate
-- meeting_group_access grant table ("who may use this group") on top
-- of meeting_group_members ("who is in this group"), with group
-- visibility gated by that access list rather than by organization
-- membership. This step's actual instructions are more specific and
-- simpler: requirement 3 says any meeting creator may USE an
-- existing group when composing a meeting they can manage — with no
-- separate per-user access grant — and requirement 8 scopes the
-- boundary to ORGANIZATION, not an access list. Implemented exactly
-- as currently instructed: two tables (meeting_groups,
-- meeting_group_members), group visibility scoped to same-org (or
-- super admin), and group USE gated by can_manage_meeting() on the
-- target meeting plus a same-organization check between the group
-- and the meeting — no meeting_group_access table exists.
--
-- Also extends meeting_group_members with a `position` column beyond
-- docs/23's literal shape, to satisfy this step's explicit "ordered
-- member list" requirement — set_group_members() persists the
-- caller-supplied array order (de-duplicated by user_id, first
-- occurrence wins) and every read returns members ORDER BY position.
BEGIN;

-- ─── 1. meeting_groups ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS meeting_groups (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID        NOT NULL REFERENCES organizations(id),
  name             TEXT        NOT NULL,
  description      TEXT,
  created_by       UUID        NOT NULL REFERENCES users(id),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT meeting_groups_name_check CHECK (btrim(name) <> '')
);
CREATE INDEX IF NOT EXISTS idx_meeting_groups_org ON meeting_groups(organization_id);

DROP TRIGGER IF EXISTS set_updated_at ON meeting_groups;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON meeting_groups
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ─── 2. meeting_group_members ────────────────────────────────────
CREATE TABLE IF NOT EXISTS meeting_group_members (
  group_id   UUID        NOT NULL REFERENCES meeting_groups(id) ON DELETE CASCADE,
  user_id    UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  position   INTEGER     NOT NULL,
  added_by   UUID        NOT NULL REFERENCES users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (group_id, user_id),
  CONSTRAINT meeting_group_members_position_check CHECK (position >= 0)
);
CREATE INDEX IF NOT EXISTS idx_meeting_group_members_group ON meeting_group_members(group_id);

-- ─── 3. RLS ───────────────────────────────────────────────────────
-- SELECT only — no INSERT/UPDATE/DELETE policy on either table;
-- every mutation goes exclusively through the RPCs below. Visibility
-- is same-organization (so any meeting creator can see/select their
-- own org's groups, per requirement 3) or super admin — never
-- cross-org, per requirement 8.
ALTER TABLE meeting_groups        ENABLE ROW LEVEL SECURITY;
ALTER TABLE meeting_group_members ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "meeting_groups_select" ON meeting_groups;
CREATE POLICY "meeting_groups_select" ON meeting_groups
  FOR SELECT USING (is_super_admin() OR organization_id = get_my_org_id());

DROP POLICY IF EXISTS "meeting_group_members_select" ON meeting_group_members;
CREATE POLICY "meeting_group_members_select" ON meeting_group_members
  FOR SELECT USING (
    is_super_admin() OR EXISTS (
      SELECT 1 FROM meeting_groups g
      WHERE g.id = meeting_group_members.group_id AND g.organization_id = get_my_org_id()
    )
  );

-- ─── 4. create_meeting_group() ───────────────────────────────────
-- Admin-only (own org) or super admin (any org) — requirements 1/2.
-- Ordinary meeting creators can never call this.
CREATE OR REPLACE FUNCTION create_meeting_group(
  p_organization_id UUID,
  p_name TEXT,
  p_description TEXT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_group_id UUID;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'create_meeting_group requires an authenticated caller';
  END IF;
  IF btrim(COALESCE(p_name, '')) = '' THEN
    RAISE EXCEPTION 'name must not be blank';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM organizations WHERE id = p_organization_id AND is_active = TRUE) THEN
    RAISE EXCEPTION 'Organization not found or inactive';
  END IF;
  IF NOT meetings_module_active_for(p_organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;
  IF NOT (is_super_admin() OR (is_admin() AND p_organization_id = get_my_org_id())) THEN
    RAISE EXCEPTION 'Not authorized to create a meeting group for this organization';
  END IF;

  INSERT INTO meeting_groups (organization_id, name, description, created_by)
  VALUES (p_organization_id, p_name, p_description, v_actor)
  RETURNING id INTO v_group_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'meeting_group_created', 'meeting_group', v_group_id);

  RETURN v_group_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 5. update_meeting_group() ───────────────────────────────────
CREATE OR REPLACE FUNCTION update_meeting_group(
  p_group_id UUID,
  p_name TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_group meeting_groups;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'update_meeting_group requires an authenticated caller';
  END IF;

  SELECT * INTO v_group FROM meeting_groups WHERE id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting group not found';
  END IF;
  IF NOT (is_super_admin() OR (is_admin() AND v_group.organization_id = get_my_org_id())) THEN
    RAISE EXCEPTION 'Not authorized to update this meeting group';
  END IF;
  IF NOT meetings_module_active_for(v_group.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;
  IF p_name IS NOT NULL AND btrim(p_name) = '' THEN
    RAISE EXCEPTION 'name must not be blank';
  END IF;

  UPDATE meeting_groups SET
    name = COALESCE(p_name, name),
    description = COALESCE(p_description, description)
    WHERE id = p_group_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'meeting_group_updated', 'meeting_group', p_group_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 6. delete_meeting_group() ───────────────────────────────────
-- Hard delete, cascading to meeting_group_members — groups carry no
-- historical/audit dependency the way bookings do (docs/23 §Phase E/
-- §4). Deleting a group never touches any meeting it was previously
-- applied to (requirement 6 — no stored link exists to begin with).
CREATE OR REPLACE FUNCTION delete_meeting_group(
  p_group_id UUID
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_group meeting_groups;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'delete_meeting_group requires an authenticated caller';
  END IF;

  SELECT * INTO v_group FROM meeting_groups WHERE id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting group not found';
  END IF;
  IF NOT (is_super_admin() OR (is_admin() AND v_group.organization_id = get_my_org_id())) THEN
    RAISE EXCEPTION 'Not authorized to delete this meeting group';
  END IF;
  IF NOT meetings_module_active_for(v_group.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  DELETE FROM meeting_groups WHERE id = p_group_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'meeting_group_deleted', 'meeting_group', p_group_id, v_group.name);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 7. set_group_members() ──────────────────────────────────────
-- Atomic replace-on-edit (deliberately not diffed, unlike meeting
-- participants — group membership carries no per-member history
-- worth preserving; docs/23 §Phase E/§4's explicit, narrow exception
-- to the general "diff, don't replace" rule). p_user_ids is
-- de-duplicated by user_id (first occurrence's position wins) and
-- every id is validated against the group's own organization before
-- write — the same cross-tenant check discipline already used by
-- create-user (docs/23's own explicit instruction).
CREATE OR REPLACE FUNCTION set_group_members(
  p_group_id UUID,
  p_user_ids UUID[]
) RETURNS VOID AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_group meeting_groups;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'set_group_members requires an authenticated caller';
  END IF;

  SELECT * INTO v_group FROM meeting_groups WHERE id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting group not found';
  END IF;
  IF NOT (is_super_admin() OR (is_admin() AND v_group.organization_id = get_my_org_id())) THEN
    RAISE EXCEPTION 'Not authorized to manage members of this meeting group';
  END IF;
  IF NOT meetings_module_active_for(v_group.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  IF p_user_ids IS NOT NULL AND EXISTS (
    SELECT 1 FROM unnest(p_user_ids) AS uid
    WHERE NOT EXISTS (
      SELECT 1 FROM users u WHERE u.id = uid AND u.org_id = v_group.organization_id AND u.is_active = TRUE
    )
  ) THEN
    RAISE EXCEPTION 'One or more selected members do not belong to this group''s organization';
  END IF;

  DELETE FROM meeting_group_members WHERE group_id = p_group_id;

  IF p_user_ids IS NOT NULL AND array_length(p_user_ids, 1) > 0 THEN
    INSERT INTO meeting_group_members (group_id, user_id, position, added_by)
    SELECT p_group_id, uid, MIN(ord) - 1, v_actor
    FROM unnest(p_user_ids) WITH ORDINALITY AS t(uid, ord)
    GROUP BY uid;
  END IF;

  INSERT INTO audit_logs (user_id, action, record_type, record_id)
  VALUES (v_actor, 'meeting_group_members_updated', 'meeting_group', p_group_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 8. add_group_as_participants() ──────────────────────────────
-- Reuses add_participant() per member (docs/23 §Phase E/§4's
-- explicit "reused, not duplicated" instruction) instead of
-- re-implementing insert/audit/notification logic. IMPORTANT: this
-- function does NOT rely on add_participant() being reached to
-- enforce cancelled/lock/module-active — found by live testing that
-- when every group member is already an active participant, the
-- per-member loop below skips all of them via CONTINUE and never
-- calls add_participant() at all, which would silently bypass its
-- checks and let a non-overriding caller "successfully" call this
-- function on a locked (or cancelled) meeting whenever the group's
-- membership happened to already be fully applied. Cancelled/lock/
-- module-active are therefore checked explicitly and unconditionally
-- here too, mirroring add_participant()'s own checks exactly, before
-- the loop runs at all — not just inherited from it. Each member
-- that is already an active participant is still pre-checked and
-- skipped (requirement 7 — duplicate participants handled
-- gracefully) rather than relying on catching add_participant()'s
-- own re-raised exception, which would be indistinguishable from a
-- genuine error. No permanent link to the group is stored anywhere
-- (requirement 6) — this is a one-time copy of the group's CURRENT
-- membership into meeting_participants; later edits to the group
-- never retroactively affect a meeting it was already applied to.
CREATE OR REPLACE FUNCTION add_group_as_participants(
  p_meeting_id UUID,
  p_group_id UUID
) RETURNS INTEGER AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_meeting meetings;
  v_group meeting_groups;
  v_member RECORD;
  v_added_count INTEGER := 0;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'add_group_as_participants requires an authenticated caller';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = p_meeting_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot add a participant to a cancelled meeting';
  END IF;

  SELECT * INTO v_group FROM meeting_groups WHERE id = p_group_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting group not found';
  END IF;
  -- Cross-org groups are never usable outside their own organization
  -- (requirement 8) — unconditional, including for a super admin:
  -- this is the group's own semantic scope, not a permission check.
  IF v_group.organization_id <> v_meeting.organization_id THEN
    RAISE EXCEPTION 'This meeting group belongs to a different organization and cannot be used on this meeting';
  END IF;

  IF v_meeting.is_locked AND NOT is_meeting_lock_overridable(p_meeting_id) THEN
    RAISE EXCEPTION 'This meeting is locked; only its creator, an organization administrator (within their own organization), or a super administrator may manage participants';
  END IF;
  IF NOT can_manage_meeting(p_meeting_id) THEN
    RAISE EXCEPTION 'Not authorized to manage participants for this meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  FOR v_member IN
    SELECT user_id FROM meeting_group_members WHERE group_id = p_group_id ORDER BY position
  LOOP
    IF EXISTS (
      SELECT 1 FROM meeting_participants
      WHERE meeting_id = p_meeting_id AND user_id = v_member.user_id AND removed_at IS NULL
    ) THEN
      CONTINUE;
    END IF;
    PERFORM add_participant(p_meeting_id, p_user_id := v_member.user_id);
    v_added_count := v_added_count + 1;
  END LOOP;

  RETURN v_added_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ─── 9. audit_logs CHECK extensions ──────────────────────────────
-- Full accumulated lists restated (per docs/23 §0's coordination
-- note), not a bare addition. No notifications.type change — reusing
-- add_participant() already fires the existing 'participant_added'
-- type per member (docs/23 §Phase E/§7's explicit "none new").
ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_action_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_action_check
  CHECK (action IN (
    'created', 'edited', 'submitted', 'approved', 'returned',
    'sent', 'received', 'routed', 'assigned',
    'returned_to_sender', 'cancelled',
    'extension_requested', 'extension_approved', 'extension_denied',
    'viewed', 'login', 'logout', 'login_failed', 'locked',
    'password_changed', 'user_created', 'user_deactivated',
    'rejected', 'rescheduled', 'conflict_overridden',
    'unassigned', 'participant_added', 'participant_removed',
    'attachment_added', 'attachment_removed',
    'invitation_responded', 'attendance_marked',
    'minutes_updated', 'minutes_finalized',
    'meeting_locked', 'meeting_unlocked',
    'meeting_group_created', 'meeting_group_updated', 'meeting_group_deleted',
    'meeting_group_members_updated'
  ));

ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_record_type_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_record_type_check
  CHECK (record_type IN (
    'request', 'response', 'internal_request', 'prisoner_letter', 'deadline_extension',
    'user', 'organization', 'section', 'session', 'attachment', 'external_correspondence',
    'meeting_room', 'meeting_room_block', 'meeting_room_booking', 'meeting', 'meeting_group'
  ));

COMMIT;
