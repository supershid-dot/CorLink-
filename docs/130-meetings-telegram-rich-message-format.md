# 130 — Telegram Message Content: Full MeetFlow Parity

## 1. Requirement

After confirming Telegram delivery works end-to-end (docs/128, docs/129), the user sent a screenshot of MeetFlow's own "New meeting" message — icon + bare title, then date, time range, location, full participant list (rank + name), a blank line, and "Organised by {rank} {name}" — with the instruction: "New meeting message should come in this format."

## 2. Scope decision — confirmed with the user first

CorLink's original Telegram message design (docs/126) was deliberately minimal: title and start time only, explicitly never description/agenda/location/participants — a "confidentiality-first" restraint, since Telegram is a third-party channel outside the organization's control, and this codebase serves defense/law-enforcement-style organizations (ranks visible in the screenshot: SP, DCP, SSG, PVT, CPO). Matching MeetFlow's format exactly means exposing the full participant roster and meeting location over that same third-party channel — a real change, not a formatting tweak.

Asked the user directly (three options: full MeetFlow parity / date-time-location only, no participant list / keep the existing minimal format). The user chose **full MeetFlow parity**, an explicit, informed decision — not the tool's default.

## 3. Implementation

Enriched entirely inside `process-meeting-notifications` (no SQL migration, no change to `create_meeting()`/`update_meeting()`/`cancel_meeting()`), specifically to avoid any risk to those already-complex, carefully-reproduced functions:

- `fetchMeetingInfoMap()` — one batched lookup per poll (not per notification) against `meetings`, `users`/`designations` (organizer), `meeting_room_bookings`/`meeting_rooms` (room name, when `location_mode = 'room'`), and `meeting_participants`/`users`/`designations` (participant roster) — all via the existing service-role `adminClient`, which already bypasses RLS for this function's other work.
- `renderMessage()` rewritten to build:
  ```
  📋 {title}

  📅 {weekday, month day}
  ⏱ {start}–{end}
  📍 {location}
  👥 {participant1, participant2, ...}

  Organised by {designation} {organizer name}
  ```
  Times are formatted in the meeting's own `timezone` column (default `Indian/Maldives`), not server/UTC time. Location resolves per `location_mode`: the booked room's name, the free-text external location, or `"Virtual"`. Participant/organizer names are `{designation.name} {full_name}` (falls back to bare name if no designation set; falls back to `external_name` for non-CorLink-user participants).
- The `meetings.scheduled` header is bare `📋 {title}` — no "New meeting:" prefix, no quotes — matching MeetFlow's screenshot exactly, since that was the one format explicitly shown. The other four event types (`rescheduled`/`updated`/`cancelled`/`reminder`) keep a short distinguishing verb in the header (not demonstrated in the screenshot, kept for clarity between event types) but now share the same rich date/time/location/participants/organizer body.
- A meeting that's since been hard-deleted (rare) falls back to the original minimal title+time rendering rather than failing.

## 4. Files

- `supabase/functions/process-meeting-notifications/index.ts` — `fetchMeetingInfoMap()`, `formatDesignatedName()`, `formatDate()`, `formatTimeRange()` added; `TEMPLATES`/`renderMessage()` replaced with `EVENT_HEADERS`/the new `renderMessage()`; the send loop now batches meeting info once per poll and passes it through.

## 5. Deployment

Redeployed to CorLink Staging (version 5). Verified by resetting an already-sent `user_notifications` row's `telegram_sent_at` back to `NULL` on staging and confirming the resend renders in the new format on the next poll.
