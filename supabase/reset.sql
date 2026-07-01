-- ============================================================
-- CorLink — Full Reset
-- Drops all CorLink tables/functions so schema.sql can be re-run cleanly.
-- Run this FIRST if you already executed an earlier version of the schema.
-- ============================================================

DROP TABLE IF EXISTS login_attempts CASCADE;
DROP TABLE IF EXISTS notifications CASCADE;
DROP TABLE IF EXISTS audit_logs CASCADE;
DROP TABLE IF EXISTS deadline_extensions CASCADE;
DROP TABLE IF EXISTS prisoner_replies CASCADE;
DROP TABLE IF EXISTS prisoner_letters CASCADE;
DROP TABLE IF EXISTS attachments CASCADE;
DROP TABLE IF EXISTS approvals CASCADE;
DROP TABLE IF EXISTS responses CASCADE;
DROP TABLE IF EXISTS requests CASCADE;
DROP TABLE IF EXISTS reference_sequences CASCADE;
DROP TABLE IF EXISTS user_password_history CASCADE;
DROP TABLE IF EXISTS user_assignments CASCADE;
DROP TABLE IF EXISTS users CASCADE;
DROP TABLE IF EXISTS sections CASCADE;
DROP TABLE IF EXISTS divisions CASCADE;
DROP TABLE IF EXISTS departments CASCADE;
DROP TABLE IF EXISTS commands CASCADE;
DROP TABLE IF EXISTS organizations CASCADE;

DROP FUNCTION IF EXISTS generate_reference_number(UUID) CASCADE;
DROP FUNCTION IF EXISTS trigger_set_updated_at() CASCADE;
DROP FUNCTION IF EXISTS is_super_admin() CASCADE;
DROP FUNCTION IF EXISTS has_role(TEXT) CASCADE;
DROP FUNCTION IF EXISTS has_role_in_section(UUID, TEXT) CASCADE;
DROP FUNCTION IF EXISTS my_section_ids() CASCADE;
DROP FUNCTION IF EXISTS my_supervised_section_ids() CASCADE;
DROP FUNCTION IF EXISTS is_admin() CASCADE;
DROP FUNCTION IF EXISTS is_supervisor_or_above() CASCADE;
DROP FUNCTION IF EXISTS get_my_org_id() CASCADE;
DROP FUNCTION IF EXISTS get_my_role() CASCADE;
DROP FUNCTION IF EXISTS get_my_section_id() CASCADE;

-- Also remove any auth users created by the old create-super-admin.sql,
-- so you can re-create them cleanly. Uncomment and adjust if needed:
-- DELETE FROM auth.identities WHERE provider_id = '10108@corlink.internal';
-- DELETE FROM auth.users WHERE email = '10108@corlink.internal';
