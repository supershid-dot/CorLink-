# 132 — Fix: Ambiguous `meeting_participants` → `users` Embed Silently Broke Participants List and RSVP Buttons

## 1. Symptom

After docs/131 (RSVP buttons) was deployed and the webhook correctly registered, a real invitation message ("Legal meeting", sent after registration completed) still had no Accept/Decline buttons — and, on closer inspection, no `👥` participants line either, going all the way back to the first docs/130 rich-format test.

## 2. Root cause

`meeting_participants` has **three** foreign keys into `users`: `user_id`, `invited_by`, and `removed_by` (confirmed directly: `pg_constraint` lists four constraints from `meeting_participants` referencing `users`). `fetchMeetingInfoMap()`'s participants query used a bare PostgREST embed, `user:users(full_name, designations(name))`, which is ambiguous whenever more than one foreign key exists between two tables — PostgREST cannot infer which one to follow and rejects the query.

That rejection was never surfaced: the original code only destructured `{ data: participants }`, discarding `error`. A silently-empty `participants` array meant both consumers of that query — the `👥` participants list in the message body, *and* `participantIdByMeetingAndUser` (which supplies the `participant_id` used to build each recipient's own RSVP `callback_data`) — silently went empty on every single send since docs/130 shipped. The buttons were never actually attached to any message; the webhook-registration issues found along the way (wrong org, `gen_random_bytes` schema) were real and needed fixing, but this was the underlying reason buttons still didn't appear even after those were resolved.

## 3. Fix

Disambiguated the embed with an explicit foreign-key hint: `user:users!user_id(full_name, designations(name))`. Also stopped discarding the query's `error` — a failure is now logged (`console.error`), so a future regression of this kind is visible in function logs instead of silently degrading two features at once.

## 4. Files

- `supabase/functions/process-meeting-notifications/index.ts` — `!user_id` embed hint, `participantsError` now checked and logged.

## 5. Deployment

Redeployed to CorLink Staging (version 8). Reset one already-sent notification's `telegram_sent_at` to `NULL` on staging to force an immediate resend under the fixed code, for verification without waiting on a new meeting.
