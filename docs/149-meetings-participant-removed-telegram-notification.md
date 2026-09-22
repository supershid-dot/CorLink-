# 149 — Participant Removed Now Gets a Telegram Notification Too

## 1. UAT

Direct follow-up to docs/148: "when removed from participant list, also should be notified" — the removal side of the same gap.

## 2. Fix

`remove_participant()` already wrote a legacy in-app notification ("You have been removed from a meeting: {title}"), but never touched the CAP-003/Telegram pipeline. It now also enqueues a **new** event type, `meetings.participant_removed.v1` — the first genuinely new `meetings.*` event since docs/126-132 (every event docs/144-148 used already existed).

Targeting follows the same shape docs/148 established for `add_participant()`: `target_type: 'specific_users'` with `target_user_ids := [the removed user's id]` only — never `'meeting_participants'`, which would notify everyone still in the meeting about someone else's removal.

Message content (rendered by `process-meeting-notifications`, same as every other `meetings.*` type) drops the location and participant-roster lines a removed person no longer needs — they're not attending, and the roster isn't theirs to see anymore — and includes the removal reason when the remover gave one:

```
🚫 Removed from meeting: {title}
📅 {date}
⏱ {time range}
📝 {reason, if given}

{organizer name}
```

No RSVP buttons (those only ever attach to `meetings.scheduled` sends). Fires under the exact same guard the existing legacy notification already used: never for a self-removal, an external guest, or a still-unannounced draft meeting.

## 3. Files

- `supabase/patch-meetings-participant-removed-notification.sql` / `validate-…` / `rollback-…` — registers `meetings.participant_removed.v1`; `remove_participant()`'s trailing block only.
- `supabase/functions/process-meeting-notifications/index.ts` — new `EVENT_HEADERS` entry; `renderMessage()` suppresses location/participants and adds the reason line for this type.
- `js/data/notifications-api.js` — new `NOTIFICATION_TEMPLATES['meetings.participant_removed']` entry, for the in-app bell.

## 4. Deployment

Migration applied + validated on CorLink Staging. `process-meeting-notifications` redeployed (v12).
