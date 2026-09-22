# 145 — Telegram Message Format Corrections

## 1. UAT

Screenshot of a real Telegram thread with the docs/144 "Notify Participants" panel's output — an invitation, a reminder, and a custom "Message" send — with the instruction:

> "Sending [a] text message format needs to be corrected, Also when sending schedule and other messages don't write organized by, just write [e.g.] CPO Hussain Zareer"

Asked whether "just write CPO Hussain Zareer" meant literal italics via Telegram's markdown, or just the plain name with no prefix — the user confirmed **plain name, no prefix** (avoids the real risk of Telegram rejecting a message if a title/name happened to contain a markdown special character, since messages aren't currently sent with any `parse_mode`).

## 2. Two corrections

- **Organizer line**: every rich message (Schedule/invitation, Reminder, and the automatic `scheduled`/`rescheduled`/`updated`/`cancelled`/`reminder` events) previously ended with `Organised by {name}`. Now just `{name}` — no prefix.
- **"Message" kind's format**: the manual free-text send (docs/144's "Message" tab) previously auto-prefixed every custom message with `💬 {meeting title}\n\n` before the sender's own text. A short message like "cancelled" then read as `💬 Board meeting\n\ncancelled` — indistinguishable from an automated cancellation notice for the whole meeting. Now sends exactly what the sender typed, nothing added.

## 3. Files

- `supabase/functions/process-meeting-notifications/index.ts` — `renderMessage()`'s organizer line.
- `supabase/functions/send-meeting-telegram-notification/index.ts` — `renderRichMessage()`'s organizer line (Schedule/Reminder kinds); the `message`-kind branch no longer builds a `💬 {title}\n\n{text}` preamble.

## 4. Deployment

Both Edge Functions redeployed to CorLink Staging (`process-meeting-notifications` v11, `send-meeting-telegram-notification` v2). No database migration — pure message-rendering changes.
