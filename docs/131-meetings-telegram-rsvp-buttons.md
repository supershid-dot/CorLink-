# 131 — Telegram RSVP: Accept/Decline Inline Buttons

## 1. Requirement

After docs/130 shipped the rich MeetFlow-parity message content, the user sent two more MeetFlow screenshots showing inline ✅ Accept / ❌ Decline buttons under the "New meeting" message, and the message being edited afterward to show "— {name}" plus a follow-up "You responded: accepted" confirmation. Instruction: "New meeting message send to telegram must have accept and decline button that can be clicked to accept or decline the meeting through telegram like in meetflow."

## 2. Why this needs a webhook (not just an outbound message)

Every prior Telegram feature in this codebase was one-directional: CorLink sends a message, nothing comes back. A tappable inline button is different — Telegram calls back into CorLink (a `callback_query` webhook) when a recipient taps it, and that call carries no Supabase session at all (it's an unauthenticated external HTTP request from Telegram's own servers). This required three new pieces working together, none of which existed before this milestone.

## 3. Design

### 3.1 `respond_to_invitation_via_telegram()` — a Telegram-safe sibling of the existing RSVP RPC

CorLink already has in-app RSVP: `respond_to_invitation(p_participant_id, p_response, p_note)` (`supabase/patch-meetings-rsvp.sql`), authorized by `auth.uid() = meeting_participants.user_id`. A Telegram callback has no `auth.uid()` to check — so `supabase/patch-meetings-telegram-rsvp.sql` adds a **new**, separate RPC, `respond_to_invitation_via_telegram(p_participant_id, p_response, p_telegram_chat_id)`, reproducing the same validation/update logic but substituting the identity check: it requires `users.telegram_chat_id = p_telegram_chat_id` for the participant's own `user_id`. This is a wholly new function — `respond_to_invitation()` itself is untouched, so there is no risk to the existing in-app RSVP flow. `SECURITY DEFINER`, granted to `service_role` only (never a client), since it substitutes a real identity check with a value only a trusted server-side caller should ever supply.

### 3.2 Per-organization `webhook_secret` — authenticating Telegram's callback

One shared Edge Function URL serves every organization's own bot (each org has its own token, from docs/127). Telegram signs every webhook call with an `X-Telegram-Bot-Api-Secret-Token` header, set once via `setWebhook`'s own `secret_token` parameter — so `organization_telegram_config` gains a `webhook_secret` column, a random value regenerated every time `update_org_telegram_bot_token()` saves a real token (paired 1:1 with the webhook being re-registered right after, in the same save action). The receiving webhook can't know which org a call belongs to until it parses the payload (the `callback_data` carries the participant id, which resolves to a meeting → organization), at which point it compares the request's header against that org's own stored `webhook_secret`. A mismatch is rejected before any RSVP write is attempted — a defense-in-depth layer independent of `respond_to_invitation_via_telegram()`'s own `telegram_chat_id` check.

### 3.3 Two new Edge Functions

- **`register-telegram-webhook`** — called by `js/data/admin-api.js`'s `updateOrgTelegramBotToken()` right after a real (non-blank) token is saved. Authorization is delegated entirely to `organization_telegram_config`'s existing RLS `SELECT` policy: the function reads the row through the **caller's own** forwarded session — if RLS lets the read through, the caller is an admin of that org (or a super admin); if not, the read returns nothing and the function refuses. No separate `is_admin()` check was written — reusing the policy that already exists avoids a second, possibly-divergent authorization path. On success, calls Telegram's `setWebhook` with the org's own token, the shared `telegram-webhook` URL, and that org's `webhook_secret`. Best-effort from the caller's side (`js/data/admin-api.js` catches and only logs a failure) — a transient registration failure must never undo the token save that already succeeded.
- **`telegram-webhook`** — `verify_jwt` **off** (Telegram never sends a Supabase JWT). Parses `callback_query.data` (`rsvp:accepted:<participant_id>` / `rsvp:declined:<participant_id>`), resolves the organization, checks the `webhook_secret` header, then calls `respond_to_invitation_via_telegram()` via the service-role client. On success: answers the callback query (clears Telegram's own tap-loading spinner, shows a short confirmation toast) and edits the original message to append a response line and remove the buttons — the same two-step feedback MeetFlow's own screenshots showed. Always returns `200` to Telegram, even on an internal error, so Telegram doesn't retry the same tap indefinitely; failures are logged server-side instead.

### 3.4 `process-meeting-notifications` — attaching the buttons

`fetchMeetingInfoMap()` now also returns `participantIdByMeetingAndUser`, resolving each recipient's own `meeting_participants.id` for a given meeting. The send loop attaches an inline keyboard **only** to `meetings.scheduled` messages (matching MeetFlow's own behavior — updates/cancellations/reminders don't get RSVP buttons), built from that recipient's own participant id: `callback_data: "rsvp:accepted:<id>"` / `"rsvp:declined:<id>"` (well under Telegram's 64-byte `callback_data` limit).

## 4. Files

- `supabase/patch-meetings-telegram-rsvp.sql` / `validate-...` / `rollback-...` — `webhook_secret` column, `update_org_telegram_bot_token()` extended to generate it, new `respond_to_invitation_via_telegram()` RPC.
- `supabase/functions/register-telegram-webhook/index.ts` — new Edge Function (`verify_jwt: true`).
- `supabase/functions/telegram-webhook/index.ts` — new Edge Function (`verify_jwt: false`).
- `supabase/functions/process-meeting-notifications/index.ts` — RSVP button attachment on invitation messages.
- `js/data/admin-api.js` — `updateOrgTelegramBotToken()` now also (best-effort) registers the webhook.

## 5. Deployment

Migration applied to CorLink Staging; validator's structural and behavioral halves both passed (a mismatched Telegram chat id is rejected, a correct one updates `invitation_status`, an invalid response value is rejected). Both new Edge Functions deployed; `process-meeting-notifications` redeployed with button attachment. `js/data/admin-api.js` cache-buster bumped. An admin must re-save their organization's bot token once (even to the same value) for the webhook to register for the first time, since the webhook_secret/registration didn't exist before this milestone.
