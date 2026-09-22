# 148 — Participant Added After Creation Now Gets the Telegram Invitation

## 1. UAT

> "after creating a meeting, and when i add new participants from this window, how are they going to get telegram and system notification for the meeting"

Traced `add_participant()`: it already wrote a legacy in-app `notifications` row ("You have been added to a meeting: {title}"), but never touched the CAP-003/Telegram pipeline — a participant added after the meeting was created got no Telegram invitation and no RSVP buttons, unlike someone added at creation time. Confirmed with the user: auto-send the same invitation on add.

## 2. Fix

`add_participant()` now also enqueues a `meetings.scheduled.v1` outbox event — the same event type, `title_template_key`, and rich message/RSVP-button rendering `create_meeting()`/`update_meeting()` already use, so `process-meeting-notifications` treats it identically.

The one deliberate difference: **`target_type: 'specific_users'` with `target_user_ids := [p_user_id]`**, not `'meeting_participants'`. `resolve_notification_intent()`'s `'meeting_participants'` branch fans an event out to every current participant — reusing it here would re-notify everyone already invited each time one more person is added. Targeting just the new participant's own id keeps this to exactly one invitation, to exactly the person who's new.

Fires under the same guard the existing legacy notification already used: `p_user_id IS NOT NULL` (external guests have no Telegram concept in this schema), `p_user_id <> v_actor` (never notify yourself), `v_meeting.status <> 'draft'` (a draft isn't announced to anyone yet).

## 3. Files

- `supabase/patch-meetings-participant-added-notification.sql` / `validate-…` / `rollback-…` — `add_participant()`'s trailing block only; nothing else in the function changes.

## 4. Deployment

Migration applied + validated on CorLink Staging.
