-- ─── Validation: Meeting Groups ─────────────────────────────────
-- Read-only. Run manually against a project AFTER
-- patch-meetings-groups.sql has been applied there, to confirm the
-- migration behaved as designed. Every query below is a SELECT —
-- nothing here writes data. A query returning zero rows in the
-- "should be empty" checks means that check passed.
--
-- Corresponds to docs/22-rooms-meetings-meetflow-parity-roadmap.md
-- and docs/23-rooms-meetings-implementation-specification.md
-- "Phase E — Meeting groups". See patch-meetings-groups.sql's own
-- header for the two deliberate deviations from docs/23's literal
-- wording (no meeting_group_access table; added `position` column)
-- and why.

-- ─── 1. Tables + columns present, correct type ──────────────────
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'meeting_groups'
ORDER BY column_name;
-- Expect: created_at, created_by (uuid NOT NULL), description
-- (nullable), id (uuid NOT NULL), name (text NOT NULL),
-- organization_id (uuid NOT NULL), updated_at.

SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'meeting_group_members'
ORDER BY column_name;
-- Expect: added_by (uuid NOT NULL), created_at, group_id (uuid NOT
-- NULL), position (integer NOT NULL), user_id (uuid NOT NULL).

SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
WHERE conname IN ('meeting_groups_name_check', 'meeting_group_members_position_check')
ORDER BY conname;
-- Expect: 2 rows.

-- ─── 2. meeting_group_access is ABSENT — confirms the ──────────
-- ─── deliberate 2-table (not 3-table) design was actually used ───
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public' AND table_name = 'meeting_group_access';
-- Expect: 0 rows.

-- ─── 3. RPCs exist, SECURITY DEFINER, search_path pinned ───────
SELECT p.proname, p.prosecdef, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN (
  'create_meeting_group', 'update_meeting_group', 'delete_meeting_group',
  'set_group_members', 'add_group_as_participants'
)
ORDER BY p.proname;
-- Expect: 5 rows, all prosecdef = true, all proconfig containing
-- 'search_path=public, pg_temp'.

SELECT p.proname, COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN (
  'create_meeting_group', 'update_meeting_group', 'delete_meeting_group',
  'set_group_members', 'add_group_as_participants'
)
GROUP BY p.proname HAVING COUNT(*) <> 1;
-- Expect: 0 rows.

-- ─── 4. RLS: SELECT-only, no manager-role reference in qual ────
-- ─── beyond is_super_admin()/organization scoping ────────────────
SELECT policyname, cmd, qual FROM pg_policies
WHERE tablename IN ('meeting_groups', 'meeting_group_members')
ORDER BY tablename, policyname;
-- Expect: exactly 2 rows total, both SELECT, no INSERT/UPDATE/DELETE
-- policy on either table for any role.

-- ─── 5. audit_logs CHECK extended correctly (full accumulated ──
-- ─── list, not a bare addition) ───────────────────────────────────
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_action_check';
-- Expect: includes 'meeting_group_created', 'meeting_group_updated',
-- 'meeting_group_deleted', 'meeting_group_members_updated' alongside
-- every pre-existing value (including 'meeting_locked'/
-- 'meeting_unlocked' from the lock patch).
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'audit_logs_record_type_check';
-- Expect: includes 'meeting_group'.

-- ─── 6. notifications.type UNCHANGED — reuses the existing ─────
-- ─── 'participant_added' value via add_participant() ──────────────
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'notifications_type_check';
-- Expect: identical to the value already confirmed by
-- validate-meetings-lock.sql — no new value added here.

-- ─── 7. Functional test — full permission + behavior matrix ────
-- Run interactively as a real authenticated session (SET ROLE
-- authenticated + a valid auth.uid() context) against a 2-org
-- fixture: org1 with an admin (admin1), a super admin (superadmin),
-- an ordinary staff member (staff1) who is also a meeting creator,
-- and two more org1 users (member_a, member_b); org2 with its own
-- admin (admin2) and a user (member_c):
--   a) As staff1 (not admin): SELECT create_meeting_group(<org1_id>,
--      'Ops Team', NULL); Expect: raises "Not authorized to create a
--      meeting group for this organization" (requirement 1's
--      converse — non-admins cannot create).
--   b) As admin1: SELECT create_meeting_group(<org1_id>, 'Ops Team',
--      'Weekly sync attendees'); Expect: succeeds, returns a group id.
--   c) As admin2 (org2 admin) on org1's group id from (b):
--      SELECT update_meeting_group(<group_id>, p_name := 'tampered');
--      Expect: raises "Not authorized to update this meeting group"
--      — cross-org admin rejected.
--   d) As admin1: SELECT update_meeting_group(<group_id>, p_name :=
--      'Ops Team (renamed)'); Expect: succeeds.
--   e) As admin1: SELECT set_group_members(<group_id>,
--      ARRAY[<member_a_id>, <member_b_id>]::UUID[]);
--      Expect: succeeds; SELECT user_id, position FROM
--      meeting_group_members WHERE group_id = <group_id> ORDER BY
--      position; returns member_a at position 0, member_b at
--      position 1 (ordered member list, requirement 4).
--   f) As admin1: SELECT set_group_members(<group_id>,
--      ARRAY[<member_c_id>]::UUID[]); (member_c belongs to org2, not
--      org1) Expect: raises "One or more selected members do not
--      belong to this group's organization" (cross-tenant check).
--   g) As admin1: SELECT set_group_members(<group_id>,
--      ARRAY[<member_a_id>, <member_a_id>]::UUID[]); (same id twice)
--      Expect: succeeds with exactly ONE row for member_a (dedup by
--      user_id, first occurrence's position wins) — restore
--      membership to (e)'s state afterward for the next checks.
--   h) As staff1 (ordinary, not admin) on org1's own group:
--      SELECT * FROM meeting_groups WHERE organization_id = <org1_id>;
--      Expect: the group IS visible (requirement 3 — meeting
--      creators can see/use existing groups, no access-list gate).
--   i) As a member of org2 (member_c or admin2):
--      SELECT * FROM meeting_groups WHERE id = <group_id>;
--      Expect: 0 rows (cross-org isolation, requirement 8).
--   j) As staff1: create a meeting they manage (create_meeting),
--      then SELECT add_group_as_participants(<meeting_id>, <group_id>);
--      Expect: succeeds, returns 2 (member_a and member_b both newly
--      added as participants) — confirms an ordinary meeting creator
--      CAN use an existing group (requirement 3) despite never being
--      able to create/edit the group itself.
--   k) Re-run the SAME call again: SELECT add_group_as_participants(
--      <meeting_id>, <group_id>);
--      Expect: succeeds, returns 0 — both members are already active
--      participants, skipped gracefully, no error (requirement 7).
--   l) Add member_a as an EXTERNAL-style pre-existing participant
--      is not applicable (member_a is internal) — instead: remove
--      member_a via remove_participant(), then re-run
--      add_group_as_participants(<meeting_id>, <group_id>) once more;
--      Expect: returns 1 (member_a re-added; member_b skipped as
--      still active) — confirms re-adding after removal works
--      through the same path as a lone add_participant() call would.
--   m) Create a SEPARATE meeting in org2 (as admin2 or member_c), then
--      as admin2 (or whoever manages that org2 meeting): SELECT
--      add_group_as_participants(<org2_meeting_id>, <group_id>);
--      (group_id belongs to org1) Expect: raises "This meeting group
--      belongs to a different organization and cannot be used on
--      this meeting" — including if attempted as super admin
--      (requirement 8, unconditional org-scope check).
--   n) LOCK the org1 meeting from (j) as its creator (lock_meeting),
--      then as staff1 (the creator, who IS overridable):
--      SELECT add_group_as_participants(<meeting_id>, <group_id>);
--      Expect: succeeds (creator can always manage their own locked
--      meeting, inherited from add_participant()'s own lock check).
--      Then as a DIFFERENT org1 user with can_manage_meeting()=true
--      but NOT overridable (e.g. a supervisor who is not the
--      creator): the same call raises the locked/not-authorized
--      message inherited from add_participant() — confirms group
--      application is lock-gated exactly like a single add_participant()
--      call, with no separate bypass.
--   o) As admin1: SELECT delete_meeting_group(<group_id>);
--      Expect: succeeds; meeting_group_members rows for that group
--      are gone too (ON DELETE CASCADE); the meeting from (j)/(n)
--      still has its participants (member_a, member_b) completely
--      unaffected — confirms requirement 6: no permanent dependency,
--      deleting the group never retroactively changes the meeting it
--      was applied to.
--   p) As unauthenticated (no request.jwt.claim.sub set):
--      SELECT create_meeting_group(<org1_id>, 'x'); and
--      SELECT set_group_members(<any_group_id>, ARRAY[]::UUID[]);
--      Expect: both raise "requires an authenticated caller".
--   q) Confirm one audit_logs row per successful mutation above
--      (created/updated/members_updated ×2/deleted), each with
--      record_type = 'meeting_group'.

-- ─── 8. Direct table write still rejected by RLS ───────────────
-- As admin1: attempt
--   INSERT INTO meeting_groups (organization_id, name, created_by)
--     VALUES (<org1_id>, 'direct insert', auth.uid());
-- Expect: "permission denied for table meeting_groups" — no
-- INSERT/UPDATE/DELETE policy exists for any role; the RPCs above
-- are the only path that can ever write either table.

-- ─── 9. Idempotency ─────────────────────────────────────────────
-- Re-run patch-meetings-groups.sql a second time against the same
-- project, then re-run checks 1, 3, 4, 5 above — all must return
-- identical results, and any group/member data already set by
-- check 7 must be unchanged (the patch contains no seed/UPDATE
-- statement touching existing rows, only DDL and function
-- definitions).
