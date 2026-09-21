# 134 — Telegram Messages: Add Section, Fix Organizer Source

## 1. Requirement

User feedback on the rich Telegram message format (docs/130):
1. The message should mention the meeting's section name.
2. The meeting creator is not always the same person as the meeting's organizer — "Organised by" should not assume they're the same.

## 2. Fixes

### 2.1 Section name

`fetchMeetingInfoMap()`'s `meetings` query now embeds `section:sections(name)` (`meetings.section_id` is the only foreign key from `meetings` to `sections` — confirmed via `pg_constraint`, so this embed is unambiguous, unlike the `meeting_participants` → `users` case in docs/132). A new `🏢 {section name}` line is added to the message body, after location and before the participants list.

### 2.2 Organizer source

The message previously derived "Organised by" from `meetings.created_by` — the person who technically created the database row. That's frequently wrong: an EA or admin can schedule a meeting on someone else's behalf, and the actual organizer is whoever the meeting's `meeting_participants` row marks with `is_organizer = true` — the same field the in-app detail view's own "Organizer" badge already reads (`js/views/meetings.js`, `_renderParticipants`).

`fetchMeetingInfoMap()` now builds `organizerNameByMeeting` from the participants query (already fetching participant rows for the roster line), preferring the participant marked `is_organizer`. `meetings.created_by` is now only a fallback, used solely when no participant is marked organizer (should not happen for a properly-scheduled meeting, but kept as a safety net rather than leaving "Organised by" blank).

## 3. Files

- `supabase/functions/process-meeting-notifications/index.ts` — `MeetingInfo.section_name` added; `meetings` query embeds `section:sections(name)`; `meeting_participants` query now also selects `is_organizer`; `organizer_name` resolution changed from `created_by`-only to `is_organizer`-first with `created_by` fallback; `renderMessage()` adds the `🏢` section line.

## 4. Deployment

Redeployed to CorLink Staging (version 9). Verified the FK count from `meetings` to `sections` is exactly one (no ambiguity risk like docs/132's `meeting_participants` bug). Reset one already-sent notification's `telegram_sent_at` to `NULL` on staging to force an immediate resend under the fixed code.
