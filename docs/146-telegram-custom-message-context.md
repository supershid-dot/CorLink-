# 146 — Telegram Custom "Message" Send: Restore Meeting Context + Sender

## 1. UAT

Follow-up to docs/145: after removing the "Message" tab's auto-added header, a custom send ("cancelled for now") arrived with zero context — no indication of which meeting it referred to or who sent it.

> "Custom message still not correct, it should know regarding which (meeting header, date and duration) meeting i am sending the message and who is sending"

## 2. Fix

docs/145 over-corrected: it went from "confusing auto-header" straight to "no context at all." The actual ask was narrower — keep meeting identification, drop the part that made it read like an automated notice. New shape, `renderCustomMessage()`:

```
💬 {title}
📅 {date}
⏱ {time range}

{the sender's own text, verbatim}

— {sender's name}
```

No location or participant list (redundant with the invitation the recipient already has for this meeting) — just enough to identify which meeting and who's speaking. The sender's name is resolved server-side from the authenticated caller (`callerAuthUser.id`), the same `formatDesignatedName()` shape (`{designation} {full name}`) used for the organizer line elsewhere, never client-supplied.

## 3. Files

- `supabase/functions/send-meeting-telegram-notification/index.ts` — new `renderCustomMessage()`; the `message`-kind branch now fetches the caller's own name and calls it instead of sending bare `customText`.

## 4. Deployment

Redeployed to CorLink Staging (`send-meeting-telegram-notification` v3). No migration.
