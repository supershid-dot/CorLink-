-- ============================================================
-- CorLink — Rollback: per-organization Telegram bot token
-- (undoes supabase/patch-meetings-telegram-org-config.sql)
--
-- Refuses if any row exists in organization_telegram_config (a
-- configured bot token would be silently destroyed) — same "refuse if
-- real work exists" precedent used elsewhere in this codebase.
-- ============================================================

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM organization_telegram_config) THEN
    RAISE EXCEPTION 'Refusing to roll back: at least one organization has a Telegram bot token configured — it would be destroyed. Clear it first via the Admin screen if you are certain, or keep this patch applied.';
  END IF;
END $$;

DROP FUNCTION IF EXISTS update_org_telegram_bot_token(UUID, TEXT);
DROP TABLE IF EXISTS organization_telegram_config;

COMMIT;
