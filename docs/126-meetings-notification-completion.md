# 126 — Meetings Notification Completion (MeetFlow parity)

## 1. Requirement

"Analyze MeetFlow, there's a feature that meeting notifications are sent (when scheduled, rescheduled, updated, cancelled, reminder etc). I want to add the same feature to the CorLink meeting module as well."

## 2. What MeetFlow actually does

Read `supershid-dot/meetflow` directly. Its `notifications` table carries `type IN ('invitation','update','reminder','cancellation')`, delivered as Telegram bot messages (with inline ✅/❌ RSVP buttons for invitations) plus a client-triggered `mailto:` fallback for participants without Telegram linked. Reminders are computed as **30 minutes before start**, stored as a `pending` row with `scheduled_for`, and dispatched by a **client-side `setInterval` poll** (`checkPendingNotifs()`, every 60s, in any open browser tab) — MeetFlow has no server-side cron of any kind.

## 3. What CorLink already had

A much more mature, two-tier notification pipeline: a legacy `notifications` table (still dual-written for backward compatibility across other modules) plus a newer, event-sourced "CAP-003" outbox pipeline (`platform_outbox_events` → `user_notifications`, rendered by the existing bell/notification center in `shell.js`). **`meetings.rescheduled.v1` and `meetings.cancelled.v1` were already fully implemented** this way (`patch-task-meeting-notification-events.sql`). Missing: a "scheduled" (create) event, an "updated" (non-time-change edit) event, and — the real gap — **reminders had zero infrastructure of any kind** (no cron/pg_net/timer anywhere in this codebase; `docs/16-meetings-frontend.md` explicitly documented that a reminder type was deliberately never built).

User's decisions (asked up front, since they change scope significantly): deliver via **in-app + Telegram**, and reminders via a **client-side poll — the same mechanism MeetFlow itself uses** — rather than standing up a new pg_cron job.

## 4. Design

### 4.1 Three new CAP-003 events, reusing the existing pipeline exactly

- **`meetings.scheduled.v1`** — fires once, either from `create_meeting(p_status := 'scheduled')` directly, or from `update_meeting()`'s existing `v_publishing` branch (draft → scheduled), whichever happens first for a given meeting. This resolves a gap the docs explicitly flagged as deferred ("no single authoritative business intent to mirror").
- **`meetings.updated.v1`** — fires only for a genuine non-time edit of an already-scheduled meeting (title/location/etc.), narrowly excluding any edit `meetings.rescheduled.v1` already covers (`NOT v_time_changed`), so a single edit never fires both.
- **`meetings.reminder.v1`** — fires when a meeting's `reminder_at` (new column, `start_at - 30 minutes`, maintained by `create_meeting()`/`update_meeting()`) comes due.

No new worker/target-kind code was needed for any of these — `'meeting'` and `'meeting_participants'` were already fully wired as a `source_record_type`/`target_type` pair from the existing two events, so registering the three new event types in `platform_event_type_registry` (`uses_generic_notification_envelope = TRUE`) was sufficient.

### 4.2 Series creation spam guard

`create_recurring_meeting()` calls `create_meeting()` once per occurrence internally (up to 260 times for one series). `create_meeting()` gained a new `p_suppress_notification BOOLEAN DEFAULT FALSE` parameter (mirroring the one `update_meeting()`/`cancel_meeting()` already had), and `create_recurring_meeting()` passes `TRUE` for it — series creation keeps its existing single consolidated legacy notification instead of one `meetings.scheduled.v1` per occurrence. The **reminder** schedule (`reminder_at`) is set regardless of this flag; every individual occurrence still needs its own "starting soon" ping.

Series bulk edit/cancel (`update_entire_series`, `update_series_this_and_future`, `cancel_entire_series`, `cancel_series_this_and_future`) all already `PERFORM update_meeting()`/`cancel_meeting()` per affected occurrence with `p_suppress_notification := TRUE` — since the new events and `reminder_at` maintenance live inside those two base functions, every series bulk-op cascades correctly with **zero changes needed to any of those four files**.

### 4.3 The reminder mechanism — a client poll, not a cron job

This codebase genuinely has no scheduler infrastructure (`docs/83-notification-outbox-worker.md` says so explicitly: "No scheduler/cron deployment... remains an implementation-phase deployment decision"). Rather than introduce one, the new `dispatch_due_meeting_reminders()` RPC is designed to be safely callable by any authenticated user, as often as any open client tab likes:

```sql
UPDATE meetings SET reminder_dispatched_at = NOW()
WHERE reminder_at IS NOT NULL AND reminder_at <= NOW()
  AND reminder_dispatched_at IS NULL AND status = 'scheduled'
RETURNING id, organization_id, title, start_at, created_by
```

The `UPDATE ... RETURNING` is what makes concurrent polls from multiple open tabs safe — row-level locking means only one caller ever observes a given due meeting, so `platform_enqueue_outbox_event()`'s own idempotency check (same key ⇒ must be same payload, else it raises) is a backstop, never the primary safety mechanism in the concurrent case. A meeting cancelled after its reminder was queued is naturally excluded by the `status = 'scheduled'` filter — `cancel_meeting()` didn't need any change to clear `reminder_at` itself.

`update_meeting()` resets `reminder_dispatched_at` back to `NULL` whenever `reminder_at` actually changes (a reschedule after the original reminder already fired gets a fresh dispatch opportunity at the new time).

### 4.4 Telegram, kept off the client entirely

MeetFlow stores its bot token in a DB config table (with a `localStorage` fallback) and calls `api.telegram.org` directly from browser JS. CorLink's CSP (`index.html`) restricts `connect-src` to `'self'` plus the Supabase project's own domain — a direct browser→Telegram call would be **blocked outright**, on top of exposing the token client-side. The already-shipped `create-user`/`reset-password` Edge Functions proved the right pattern: a new `supabase/functions/process-meeting-notifications/index.ts`, invoked via `db.functions.invoke(...)` (same origin, already proven to work under the current CSP by those two functions), does two jobs every call:

1. `adminClient.rpc('dispatch_due_meeting_reminders')` — enqueues any due reminders.
2. Queries up to 50 undelivered `user_notifications` rows sourced from `meetings` (new `telegram_sent_at` column, `IS NULL`), joins to `users.telegram_chat_id` (new column, admin-entered on the Manage User screen — mirrors MeetFlow's own admin-enters-it-for-staff model), and sends each via Telegram's `sendMessage`, marking `telegram_sent_at` on success.

The bot token itself is an Edge Function secret (`TELEGRAM_BOT_TOKEN`, `supabase secrets set`) — never in the database, never in the browser.

Auth mirrors `reset-password/index.ts` exactly: a valid CorLink session is required to invoke the function at all (an anonymous outsider who finds the URL cannot trigger it), even though the work itself is system-wide, not caller-scoped — the same defense-in-depth reasoning already used everywhere else Edge Functions run privileged work in this codebase.

### 4.5 Frontend wiring

- `js/data/notifications-api.js`: 3 new `NOTIFICATION_TEMPLATES` entries (title-only, same "confidentiality-first" restraint the existing `meetings.rescheduled`/`meetings.cancelled` entries already use — never description/agenda/minutes). No `CAP003_ROUTES` change needed (the existing `meeting` key already covers any `source_record_type: 'meeting'` event). No `MIGRATED_EVENT_MAP` entry — unlike `rescheduled`/`cancelled` (which had a legacy sibling before CAP-003 existed), these three are brand-new notifications with no prior legacy behavior to dual-write against, so they go straight to CAP-003 only. New `processMeetingNotifications()`, fire-and-forget (same reasoning as `notify()` — a missed poll tick must never break the page that called it).
- `js/views/shell.js`: `_startMeetingNotificationsPoll()`, guarded by `_meetingNotificationsPollBound` the same way `_subscribeRealtime()` already guards its own one-per-session realtime subscription against `bindTopbar()` re-running on every navigation. One immediate call plus a 60s `setInterval` — MeetFlow's own polling cadence.
- `js/views/meetings.js`: an immediate (unawaited) `NotificationsAPI.processMeetingNotifications()` right after `createMeeting`/`updateMeeting`/`cancelMeeting`/`createRecurringMeeting` succeeds — this is what sends the Telegram message right away instead of waiting up to 60s, mirroring MeetFlow's own "immediate send + background poller" two-track design.
- `js/views/admin.js`: a "Telegram Chat ID" field added to the existing Profile section of the Manage User modal, saved via the already-generic `AdminAPI.updateUser(user.id, { telegram_chat_id })` — no `admin-api.js` change needed.

## 5. Files

- `supabase/patch-meetings-notification-completion.sql` — the migration (columns, registry rows, `create_meeting()`/`update_meeting()`/`create_recurring_meeting()` extended, new `dispatch_due_meeting_reminders()` RPC). `cancel_meeting()` deliberately untouched (a cancelled meeting simply never passes the reminder dispatcher's own `status = 'scheduled'` filter — cheaper and equally correct).
- `supabase/validate-meetings-notification-completion.sql` — structural checks (columns/registry/function-literal presence) plus a behavioral fixture-based smoke test (create → scheduled event; title edit → updated event, not rescheduled; time edit → rescheduled event, not a second updated; force-due reminder → dispatched once, re-poll is a no-op; cancel → reminder never dispatchable).
- `supabase/rollback-meetings-notification-completion.sql` — restores the three RPCs to their exact pre-patch bodies, refuses if any meeting has `reminder_at` set, any user has `telegram_chat_id` set, or any `user_notifications` row has `telegram_sent_at` set (real data that would otherwise be silently destroyed).
- `supabase/functions/process-meeting-notifications/index.ts` — the new Edge Function.
- `js/data/notifications-api.js`, `js/views/shell.js`, `js/views/meetings.js`, `js/views/admin.js` — frontend wiring above.

## 6. Tests

- `tests/admin-manage-user-modal-frontend.test.js`: the Telegram Chat ID field renders prefilled, saves via `AdminAPI.updateUser`, and a blank value saves as `null` (not an empty string).
- `tests/meetings-notification-integration-frontend.test.js` (new): the 3 new templates render correctly with a safe fallback for an unrecognized key; `CAP003_ROUTES.meeting` needs no change; `processMeetingNotifications()` calls the Edge Function and never throws even on a failed invoke; `meetings.js` fires it after a successful create and after a successful cancel.
- `tests/frontend-bootstrap-integrity-frontend.test.js`: its full real-app-boot fake Supabase client gained a minimal `functions.invoke` stub — the new post-login poll call surfaced that this test's fake client didn't have one yet (a real `@supabase/supabase-js` client always does; this was a test-fixture gap, not a production bug).
- Backend RPC/Edge Function correctness (reminder scheduling, event mutual exclusion, idempotent dispatch, Telegram send/mark-sent) is verified via the `validate-*.sql` script plus manual end-to-end testing on staging (schedule/edit/cancel a real meeting with a linked Telegram chat id, confirm both the bell and Telegram message arrive, confirm a reminder fires ~30 minutes before a test meeting) — the Playwright harness has no live Postgres/Edge Function runtime.

Full regression sweep across all 21 test files: clean (same 4 pre-existing files needing `PLAYWRIGHT_CORE_PATH`/`EDGE_PATH` this sandbox doesn't set, unrelated to this change).

## 7. Two bugs caught during staging deployment

- **`dispatch_due_meeting_reminders()` called via the wrong client.** The Edge Function's first draft called it through `adminClient` (the service-role client) — but the RPC requires `auth.uid() IS NOT NULL`, and `auth.uid()` is derived from the request's JWT claims, which the service-role key doesn't carry (it isn't a user session). That would have made the reminder-dispatch step silently fail on every single invocation. Fixed by calling it through `callerClient` instead (the already-verified caller's own forwarded session) — the RPC is still `SECURITY DEFINER`, so it has full table access regardless of the caller's own RLS grants; only `auth.uid()` needed to come from a real session.
- **`dispatch_due_meeting_reminders()` was executable by `anon`.** `get_advisors` flagged this right after deploying — a new `SECURITY DEFINER` function is granted to `PUBLIC` by default unless explicitly revoked, and this one only had an explicit `GRANT ... TO authenticated`, no `REVOKE ... FROM PUBLIC, anon`. The function's own `auth.uid() IS NULL` check meant an anonymous call couldn't actually do anything, but it wasn't the *explicit*, intentional posture this codebase's other mutation RPCs consistently use (see `patch-entry-server-mutation-foundation.sql`'s own "REVOKE from PUBLIC/anon, GRANT EXECUTE only to authenticated" convention). Added the matching `REVOKE ALL ... FROM PUBLIC, anon` and re-verified via `information_schema.role_routine_grants` that only `postgres`/`authenticated`/`service_role` remain.

Both fixes are folded into `supabase/patch-meetings-notification-completion.sql` and `supabase/functions/process-meeting-notifications/index.ts` as committed — not left as a separate follow-up patch.

## 8. Deployment

Cache-busters bumped: `js/data/notifications-api.js?v=20260920`, `js/views/shell.js?v=20260920`, `js/views/admin.js?v=20260920`, `js/views/meetings.js?v=20260920a`. Migration applied to CorLink Staging (`vjobntuyzymhcuanyeak`) — confirmed via direct query as the actual project this whole session's migrations have been targeting, since `js/config.js`/`index.html`'s committed CSP default to the real `corlink-production` project (`infjjroktzzhaxjvfknr`) and staging is selected only via `scripts/set-frontend-environment.sh` at deploy time (see `docs/23`). Both the structural and behavioral halves of `validate-meetings-notification-completion.sql` passed. The `process-meeting-notifications` Edge Function is deployed (`verify_jwt: true`). The `TELEGRAM_BOT_TOKEN` secret still needs to be set once a bot is created via @BotFather and its token provided — until then, in-app (bell) notifications for all 5 events and reminder scheduling/dispatch work fully; only the Telegram send step no-ops.
