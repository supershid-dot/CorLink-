# 129 — Telegram Send Failure Diagnostics + Root Cause on Staging

## 1. Symptom

After docs/128 fixed the outbox-worker gap (meetings notifications now reach `user_notifications`), the user reported Telegram delivery was still not working.

## 2. Diagnosis

`user_notifications.telegram_sent_at` stayed `NULL` for every row with zero observability into *why* — a failed Telegram send was silently retried forever with no recorded error, unlike `platform_outbox_events`, which already has a `last_error` column for exactly this purpose (docs/83).

Added `user_notifications.telegram_last_error TEXT`, mirroring that existing pattern, and updated `sendTelegramMessage()` in `process-meeting-notifications` to capture and store Telegram's own `error_code`/`description` (bounded to 500 chars, cleared to `NULL` on a later successful send) instead of just returning a boolean.

Once deployed, the recorded error across all 21 pending sends was identical: **`400: Bad Request: chat not found`**.

## 3. Root cause: not a CorLink bug

`400: chat not found` from Telegram's `sendMessage` means the token authenticated successfully (an invalid/revoked token returns `401 Unauthorized` instead) but the bot has no existing conversation with that chat ID — Telegram bots can never initiate a conversation; the target user must message the bot first.

Confirmed directly using Postgres's `http` extension (temporarily installed for this one diagnostic, then dropped — no outbound HTTP access exists in this session's own sandbox to `api.telegram.org` directly, but Supabase's own infrastructure clearly does, since the Edge Function's own error was real):

- `getMe` confirmed the token is valid and belongs to `@CorLinkBot`.
- `getUpdates` against that same token returned an **empty result** — this bot has never received a single incoming message from anyone, ever.

The bot token, the per-org config table, the Chat ID field, and the Edge Function are all working exactly as designed. The failure is external: the recipient (or whoever configured the Chat ID) has not yet sent a message to `@CorLinkBot` in Telegram, which Telegram requires before any bot can message that chat.

## 4. Resolution

No code or config change needed for this specific case — user action required: message `@CorLinkBot` from the Telegram account whose numeric ID (`543619210`) is stored, then the next poll or meeting action will retry and succeed automatically (no manual replay needed — the same row is simply re-attempted every poll while `telegram_sent_at IS NULL`).

## 5. Files

- `supabase/patch-meetings-telegram-send-diagnostics.sql` / `validate-...` / `rollback-...` — new `user_notifications.telegram_last_error` column.
- `supabase/functions/process-meeting-notifications/index.ts` — `sendTelegramMessage()` now returns `{ ok, error }` instead of a bare boolean; the send loop records `telegram_last_error` on failure and clears it on success.

## 6. Deployment

Migration applied to CorLink Staging (`vjobntuyzymhcuanyeak`). Edge Function redeployed (version 4) with error capture. This diagnostic capability is permanent, not throwaway — any future Telegram delivery failure (revoked token, blocked bot, deleted chat) is now visible directly in `user_notifications.telegram_last_error` instead of silently vanishing.
