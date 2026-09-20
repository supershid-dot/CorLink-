-- ============================================================
-- CorLink — Patch: Telegram send failure diagnostics
--
-- docs/129: every meetings.* Telegram send has been failing silently
-- since docs/126/127 shipped — user_notifications.telegram_sent_at
-- stays NULL forever on failure with zero record of *why* (bad token,
-- chat not started, wrong chat id, etc.), and the same failing row is
-- silently retried on every single poll indefinitely. Adds a
-- telegram_last_error column, mirroring the existing
-- platform_outbox_events.last_error pattern (docs/83) already
-- established in this codebase: bounded text, safe to store (only the
-- Telegram API's own error description/code, never token/payload
-- content), cleared back to NULL on a later successful send.
--
-- Idempotent — ADD COLUMN IF NOT EXISTS.
-- ============================================================

BEGIN;

ALTER TABLE user_notifications ADD COLUMN IF NOT EXISTS telegram_last_error TEXT;

COMMIT;
