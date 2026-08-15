-- ============================================================
-- NON-PRODUCTION. Local disposable-Postgres test harness only.
-- Applied ONLY by apply-canonical-schema.sh --local-test-harness, as
-- the FIRST step, before any real migration. NEVER apply this against
-- a real Supabase project — it recreates, crudely, the `auth` schema
-- (GoTrue) that a real Supabase project already provides. Table
-- grants are handled separately, at the END of the chain, by
-- 99-grant-shim.sql — see that file for why grants can't be applied
-- this early (they need every table to already exist).
-- ============================================================

-- ─── auth schema + auth.uid()/auth.role() ───────────────────────────
CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT
);

CREATE OR REPLACE FUNCTION auth.uid() RETURNS UUID
LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN NULLIF(current_setting('request.jwt.claims', true), '') IS NULL THEN NULL
    ELSE NULLIF(current_setting('request.jwt.claims', true)::json->>'sub','')::UUID
  END
$$;

CREATE OR REPLACE FUNCTION auth.role() RETURNS TEXT
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.current_role', true), '')
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN BYPASSRLS;
  END IF;
END $$;
-- Roles are cluster-level and survive DROP DATABASE/CREATE DATABASE,
-- so the guard above only fires once per cluster lifetime; this ALTER
-- (idempotent) guarantees service_role always carries BYPASSRLS
-- regardless of when it was first created in this disposable cluster.
ALTER ROLE service_role BYPASSRLS;

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
