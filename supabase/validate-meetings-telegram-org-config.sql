-- ─── Validator: per-organization Telegram bot token ─────────────────
-- Run manually against a project AFTER
-- patch-meetings-telegram-org-config.sql has been applied there.
-- Structural checks, then a behavioral fixture-based smoke test
-- (distinct '7d000000-...' test-UUID prefix) inside a transaction
-- that ROLLS BACK at the end.

DO $$
DECLARE
  v_missing TEXT := '';
BEGIN
  IF to_regclass('public.organization_telegram_config') IS NULL THEN
    v_missing := v_missing || 'organization_telegram_config-table-missing ';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='organization_telegram_config' AND policyname='organization_telegram_config_select') THEN
    v_missing := v_missing || 'select-policy-missing ';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='organization_telegram_config' AND cmd IN ('INSERT','UPDATE','DELETE')) THEN
    v_missing := v_missing || 'unexpected-direct-write-policy-present ';
  END IF;
  IF to_regprocedure('public.update_org_telegram_bot_token(uuid,text)') IS NULL THEN
    v_missing := v_missing || 'update_org_telegram_bot_token-missing ';
  END IF;
  IF has_function_privilege('anon', 'update_org_telegram_bot_token(uuid,text)', 'EXECUTE') THEN
    v_missing := v_missing || 'update_org_telegram_bot_token-exposed-to-anon ';
  END IF;
  IF NOT has_function_privilege('authenticated', 'update_org_telegram_bot_token(uuid,text)', 'EXECUTE') THEN
    v_missing := v_missing || 'update_org_telegram_bot_token-not-granted-to-authenticated ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'STRUCTURAL VALIDATION FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'PASS: structural checks all present';
END $$;

BEGIN;

INSERT INTO organizations (id, name, type, code) VALUES
  ('7d000000-0000-0000-0000-000000000001', 'TGC Test Org', 'mcs', 'TGCT'),
  ('7d000000-0000-0000-0000-000000000002', 'TGC Other Org', 'mcs', 'TGCO');
INSERT INTO auth.users (id, email) VALUES
  ('7d000000-0004-0000-0000-000000000001', 'tgc-admin@t.local'),
  ('7d000000-0004-0000-0000-000000000002', 'tgc-staff@t.local'),
  ('7d000000-0004-0000-0000-000000000003', 'tgc-otheradmin@t.local');
INSERT INTO users (id, org_id, service_number, full_name, email, is_active) VALUES
  ('7d000000-0004-0000-0000-000000000001', '7d000000-0000-0000-0000-000000000001', 'TGC-1', 'Org Admin', 'tgc-admin@t.local', TRUE),
  ('7d000000-0004-0000-0000-000000000002', '7d000000-0000-0000-0000-000000000001', 'TGC-2', 'Plain Staff', 'tgc-staff@t.local', TRUE),
  ('7d000000-0004-0000-0000-000000000003', '7d000000-0000-0000-0000-000000000002', 'TGC-3', 'Other Org Admin', 'tgc-otheradmin@t.local', TRUE);
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
  ('7d000000-0004-0000-0000-000000000001', 'organization', '7d000000-0000-0000-0000-000000000001', 'mcs_admin', TRUE, TRUE),
  ('7d000000-0004-0000-0000-000000000003', 'organization', '7d000000-0000-0000-0000-000000000002', 'mcs_admin', TRUE, TRUE);

SET ROLE authenticated;

DO $$
DECLARE
  v_token TEXT;
BEGIN
  -- Org admin sets a token.
  PERFORM set_config('request.jwt.claims', '{"sub":"7d000000-0004-0000-0000-000000000001"}', true);
  PERFORM update_org_telegram_bot_token('7d000000-0000-0000-0000-000000000001', '123456:ABC-DEF');

  SELECT bot_token INTO v_token FROM organization_telegram_config WHERE organization_id = '7d000000-0000-0000-0000-000000000001';
  IF v_token <> '123456:ABC-DEF' THEN
    RAISE EXCEPTION 'FAIL: token not saved correctly, got %', v_token;
  END IF;

  -- Plain staff (same org) cannot read it via RLS.
  PERFORM set_config('request.jwt.claims', '{"sub":"7d000000-0004-0000-0000-000000000002"}', true);
  IF EXISTS (SELECT 1 FROM organization_telegram_config WHERE organization_id = '7d000000-0000-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'FAIL: plain staff must not be able to read the bot token';
  END IF;

  -- An admin of a DIFFERENT org cannot read or write this org's token.
  PERFORM set_config('request.jwt.claims', '{"sub":"7d000000-0004-0000-0000-000000000003"}', true);
  IF EXISTS (SELECT 1 FROM organization_telegram_config WHERE organization_id = '7d000000-0000-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'FAIL: an admin of a different org must not be able to read this org''s token';
  END IF;
  BEGIN
    PERFORM update_org_telegram_bot_token('7d000000-0000-0000-0000-000000000001', 'hijacked-token');
    RAISE EXCEPTION 'FAIL: an admin of a different org must not be able to write this org''s token';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%Not authorized%' THEN
      RAISE EXCEPTION 'FAIL: expected an authorization rejection, got: %', SQLERRM;
    END IF;
  END;

  -- Org admin clears the token (blank input).
  PERFORM set_config('request.jwt.claims', '{"sub":"7d000000-0004-0000-0000-000000000001"}', true);
  PERFORM update_org_telegram_bot_token('7d000000-0000-0000-0000-000000000001', '');
  IF EXISTS (SELECT 1 FROM organization_telegram_config WHERE organization_id = '7d000000-0000-0000-0000-000000000001') THEN
    RAISE EXCEPTION 'FAIL: a blank token must delete the row, not save an empty string';
  END IF;

  RAISE NOTICE 'PASS: all organization Telegram config behavioral scenarios behaved as designed';
END $$;

ROLLBACK;
