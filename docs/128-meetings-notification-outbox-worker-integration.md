# 128 — Meetings Notifications: Wiring Up the Never-Deployed CAP-003 Outbox Worker

## 1. Symptom

After docs/126/127 shipped and were deployed to CorLink Staging, the user scheduled a real test meeting with a Telegram bot token and a linked Chat ID both correctly configured — and no Telegram message arrived. Reported as: "the notification does not get through telegram."

## 2. Root cause — not a Telegram bug at all

CAP-003's pipeline has two distinct steps: (1) a module (Meetings, Tasks, Requests, ...) enqueues a row into `platform_outbox_events` via `platform_enqueue_outbox_event()`, and (2) a separate worker, `process_platform_outbox_batch()`, claims pending outbox rows and materializes them into `notification_intents` + `user_notifications` — the table both the in-app bell **and** the Telegram-flush step in `process-meeting-notifications` actually read from. Direct inspection of CorLink Staging confirmed:

- The user's test meeting's `meetings.scheduled.v1`, `meetings.reminder.v1`, and `meetings.cancelled.v1` events were all present in `platform_outbox_events`, correctly enqueued, `status = 'pending'`, `processed_at = NULL`.
- **Every** row in `platform_outbox_events` on this project — 19 rows, spanning Meetings, Tasks, and Requests — was `status = 'pending'`. Zero rows had ever reached `'completed'`.
- `user_notifications` had **zero** rows with `source_module = 'meetings'` — confirming nothing had ever been delivered, in-app or via Telegram, for any meeting event on this project, ever.

docs/83 (the outbox worker's own design doc) documents this exact gap under "Limitations": *"No scheduler/cron deployment. This patch adds only the worker-facing SQL entry point; how and how often it is invoked... remains an implementation-phase deployment decision."* That decision was never made — nothing in this codebase, on any branch, had ever called `process_platform_outbox_batch()`. This predates docs/126/127 entirely; it is a pre-existing, platform-wide gap that the Telegram feature simply exposed first (Telegram delivery made the missing notification impossible to miss, where the in-app bell's absence had gone unnoticed).

## 3. Fix

`process_platform_outbox_batch(p_limit, p_worker_id)` is `SECURITY DEFINER`, granted to `service_role` only (by design — see docs/83 "Security boundary"), so it cannot be polled directly from the client the way `dispatch_due_meeting_reminders()` is. The `process-meeting-notifications` Edge Function already runs under a service-role client (`adminClient`) and is already invoked on the same no-cron cadence this session's design uses throughout (a 60s client poll from any open tab, plus immediately after every meeting create/update/cancel) — so it is the natural, minimal place to drain the outbox, with no new scheduler introduced.

Added as a new step 2 (between the existing reminder-dispatch and Telegram-flush steps):

```ts
const { data: outboxResults, error: outboxError } = await adminClient.rpc('process_platform_outbox_batch', {
  p_limit: 100,
  p_worker_id: 'process-meeting-notifications',
});
```

This call is deliberately **not scoped to Meetings** — `process_platform_outbox_batch()` is a generic, registry-driven worker (docs/83 §"module-integration-foundation" redefinition) that processes any module's pending event. Draining it here is a system-wide side effect of any open CorLink tab polling: Tasks and Requests notifications that were equally stuck now flow correctly too, as a consequence of fixing the underlying gap Meetings happened to expose. Failure here is caught and logged, never thrown — it must not undo the reminder dispatch that already succeeded in step 1, nor block the Telegram-flush step from running against whatever the outbox already held on entry.

## 4. Verification

Ran `process_platform_outbox_batch(50, 'manual-diagnostic-drain')` directly against CorLink Staging to unblock the existing backlog immediately (rather than waiting on the next poll): all 19 pending events processed cleanly (`outcome: 'processed'` or `'processed_zero_recipients'`, `final_status: 'completed'`), producing 36 new `user_notifications` rows, including the user's own test meeting's scheduled/reminder/cancelled events for the recipient with a linked Telegram Chat ID. The Edge Function fix was then deployed (version 3) so this never silently re-accumulates.

## 5. Files

- `supabase/functions/process-meeting-notifications/index.ts` — new step 2 (outbox drain), updated header comment, `outbox_processed` added to the JSON response.

No schema change, no new migration — `process_platform_outbox_batch()` already existed (docs/83); this milestone only wires it into an already-deployed, already-polled caller for the first time anywhere in this codebase.

## 6. Deployment

Manually drained the 19-event backlog on CorLink Staging (`vjobntuyzymhcuanyeak`) via a direct RPC call to unblock the user's existing test meeting immediately. Redeployed `process-meeting-notifications` (version 3) with the fix. No cache-buster change needed (Edge Function only, no frontend file touched).
