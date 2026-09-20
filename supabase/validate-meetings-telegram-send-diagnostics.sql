-- ─── Validator: Telegram send failure diagnostics ───────────────────
-- Run manually against a project AFTER
-- patch-meetings-telegram-send-diagnostics.sql has been applied there.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'user_notifications' AND column_name = 'telegram_last_error'
  ) THEN
    RAISE EXCEPTION 'STRUCTURAL VALIDATION FAILED: user_notifications.telegram_last_error column missing';
  END IF;
  RAISE NOTICE 'PASS: user_notifications.telegram_last_error column present';
END $$;
