-- ============================================================
-- CorLink — Rollback: Telegram send failure diagnostics
-- (undoes supabase/patch-meetings-telegram-send-diagnostics.sql)
--
-- Refuses if any row has a non-NULL telegram_last_error (real
-- diagnostic evidence of a still-unresolved delivery failure would be
-- silently destroyed) -- same "refuse if real work exists" precedent
-- used elsewhere in this codebase.
-- ============================================================

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM user_notifications WHERE telegram_last_error IS NOT NULL) THEN
    RAISE EXCEPTION 'Refusing to roll back: at least one user_notifications row has a recorded telegram_last_error -- it would be destroyed. Resolve or clear it first if you are certain, or keep this patch applied.';
  END IF;
END $$;

ALTER TABLE user_notifications DROP COLUMN IF EXISTS telegram_last_error;

COMMIT;
