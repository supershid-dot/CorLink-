-- ============================================================
-- CorLink — Remove leftover auth user before re-creating super admin
-- Run this if create-super-admin.sql fails with a duplicate email error.
-- ============================================================

DELETE FROM auth.identities WHERE provider_id = '10108@corlink.internal';
DELETE FROM auth.users WHERE email = '10108@corlink.internal';
