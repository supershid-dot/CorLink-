-- ─── Patch: block self-escalation via the users table ──────────
-- users_update_own_prefs ("id = auth.uid()") and users_update_admin
-- ("is_super_admin() OR (is_admin() AND org_id = get_my_org_id())")
-- both have USING but no WITH CHECK. RLS only restricts which ROW an
-- UPDATE can touch — with no WITH CHECK, Postgres re-checks the SAME
-- USING expression against the post-update row, and neither expression
-- above says anything about which COLUMNS changed. Concretely:
--   - Any authenticated user could PATCH their own row via
--     users_update_own_prefs with {"is_super_admin": true} (or
--     org_id/is_active/is_prisoner_letters_staff) — still just
--     "id = auth.uid()" on both sides — self-escalating to super admin.
--   - Any org admin, via users_update_admin, could do the same to
--     ANY user in their own org, including granting super-admin (a
--     privilege the app's own UI never grants — it's only ever set by
--     the one-time create-super-admin.sql script).
--
-- Postgres RLS's WITH CHECK can't compare OLD vs NEW in one expression
-- (it only sees the post-update row), so a WITH CHECK addition can't
-- fix this — this patch adds a BEFORE UPDATE trigger instead, same
-- pattern as the existing status-transition guards on
-- requests/responses/external_correspondence.
--
-- Two tiers, matching what the app's admin UI actually does today:
--   - is_active / is_prisoner_letters_staff: org admins legitimately
--     toggle these on their own org's users (admin.js) — allowed for
--     any is_admin().
--   - is_super_admin / org_id: no UI flow ever touches these —
--     restricted to is_super_admin() specifically, so an org admin
--     can't grant super-admin (to themselves or anyone else) or move
--     a user to a different org.
--
-- Idempotent — safe to run more than once.

BEGIN;

CREATE OR REPLACE FUNCTION trigger_protect_privileged_user_columns()
RETURNS TRIGGER AS $$
BEGIN
  IF (NEW.is_super_admin IS DISTINCT FROM OLD.is_super_admin
      OR NEW.org_id IS DISTINCT FROM OLD.org_id)
     AND NOT is_super_admin() THEN
    RAISE EXCEPTION 'Only a super admin can change is_super_admin or org_id on a user';
  END IF;
  IF (NEW.is_active IS DISTINCT FROM OLD.is_active
      OR NEW.is_prisoner_letters_staff IS DISTINCT FROM OLD.is_prisoner_letters_staff)
     AND NOT is_admin() THEN
    RAISE EXCEPTION 'Only an admin can change privilege or account-status fields on a user';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS protect_privileged_user_columns ON users;
CREATE TRIGGER protect_privileged_user_columns BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION trigger_protect_privileged_user_columns();

COMMIT;
