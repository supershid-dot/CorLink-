# CAP-003 Phase 1.5 — Realtime UI Integration + Legacy Notification Cutover

## Status

Implemented. Connects the notification bell in `js/views/shell.js` to CAP-003's
`user_notifications` (docs/78, docs/81) alongside the existing legacy
`notifications` table, using Realtime strictly as a signal to re-fetch — never
as a source of truth. No external delivery (email/push/SMS), no preferences,
no digest, no new module producers. No historical legacy row is migrated.

## 1. Existing frontend, inspected before any change

`js/data/notifications-api.js` wrapped only the legacy `notifications` table:
`listMine(limit)`, `countUnread()`, `markRead(id)`, `markAllRead()`, and
`notify(userIds, {...})` (fire-and-forget, calls `create_legacy_notification`).
Nothing in it touched `user_notifications`.

`js/views/shell.js` owns the topbar bell: a `#notif-badge` counter, a
`#notif-dropdown` with a bounded (`limit=15`) list, a `#notif-mark-all`
button, and one Realtime channel per SPA session
(`notifications-<uid>`, `postgres_changes` INSERT on `notifications`, filtered
to `user_id=eq.<self>`) bound once via a `_realtimeBound` guard and used
purely as a trigger for `loadNotifications()` — never read for its payload.
This existing pattern is exactly what docs/78 §2.6/§16 already documented as
the model to extend, not replace.

One pre-existing bug was found and deliberately left alone: the legacy
click-routing map (`{prisoner_letter: 'prisoner-letter-detail',
external_correspondence: 'entry-detail'}`, else `'request-detail'`) has no
`'task'` entry, so a *legacy* task-type notification mis-routes to
Request Detail. This predates Phase 1.5 and is out of scope — "preserve
legacy behavior for non-migrated modules" — CAP-003's own routing map
(`CAP003_ROUTES` below) correctly includes `task`, so this milestone's own
notifications never hit that bug.

`deep_link_module`/`deep_link_params` on `user_notifications` are always
`NULL` in production — `resolve_notification_intent()`'s call to
`platform_create_user_notification()` passes `NULL, NULL, NULL` for these
plus `p_expires_at`, confirmed by reading every current call site. Deep-link
routing is therefore derived directly from `source_record_type`/
`source_record_id`, not from those columns.

## 2. Per-event equivalence review — why no legacy dual-write was removed

The task required proving recipient/timing/authorization equivalence for each
of the four currently-migrated events before removing its legacy write. Every
one has a genuine, evidenced gap:

| Event | Legacy | CAP-003 | Gap |
|---|---|---|---|
| `task.assigned.v1` | `assign_task()`, synchronous, unconditional | `resolve_notification_intent()`, late-processing `intent_user_can_view_task()` revalidation | A candidate whose access is revoked between enqueue and worker processing gets nothing from CAP-003 but would have from legacy (Phase 1.4B behavioral scenario 17) |
| `task.completed.v1` | `complete_task()`, synchronous, unconditional | Same late-revalidation model | Same race window |
| `meetings.rescheduled.v1` | `meeting_participant_recipient_ids(id, v_actor)` **excludes the actor** | `meeting_participants` target resolution (Phase 1.4A) does **not** exclude the actor | Already documented as a known limitation in docs/87 §"actor self-notification" |
| `meetings.cancelled.v1` | Same actor-exclusion | Same non-exclusion | Same gap |

Per the milestone's own instruction ("if any gap exists: retain legacy
dual-write and dedupe visually"), `assign_task()`, `complete_task()`,
`update_meeting()`, `cancel_meeting()` are **completely untouched** by this
milestone — confirmed by the structural validator re-asserting each still
contains its legacy `INSERT INTO notifications` literal. Duplicate-visibility
prevention happens entirely in the frontend merge/dedup layer described below.

## 3. Merged-feed architecture (chosen over a split view)

Every notification either module currently produces is legacy-eligible, so a
CAP-003-only center alongside a separate legacy list would just make the same
bell show two different, confusing lists depending on which module fired. A
single merged feed — normalize both sources into one display shape, dedupe,
sort, render — was the least-confusing option and is what `loadNotifications()`
in `shell.js` now does.

Normalized shape: `{ source: 'legacy'|'cap003', id, isRead, createdAt,
message, recordType, recordId }`. `normalizeLegacyNotification`/
`normalizeCap003Notification` (both pure, in `notifications-api.js`) build it;
CAP-003's `message` comes from `renderNotificationTemplate(title_template_key,
template_params)`, never a raw source-record fetch.

## 4. CAP-003 data-access layer (`js/data/notifications-api.js`)

New methods, deliberately named apart from the legacy ones (different tables,
different id spaces — conflating names would make it easy to call the wrong
endpoint with the wrong id):

- `listNotifications({ limit, beforeCreatedAt, beforeId, unreadOnly })` — wraps
  `list_my_notifications` (keyset-paginated, hard-clamped to 100 server-side).
- `getUnreadCount()` — wraps `count_my_unread_notifications` (server-computed,
  never derived by fetching and counting rows client-side).
- `markNotificationRead(id)` / `markNotificationUnread(id)` — direct
  `UPDATE user_notifications SET read_at = ...`/`= NULL WHERE id = id`,
  protected by the existing `user_notifications_update` RLS policy exactly the
  way legacy `markRead()` already relies on the legacy table's RLS. No
  dedicated mark-read RPC exists (confirmed by inspection); `read_at` is the
  one business column `user_notifications_enforce_immutability()` leaves
  freely settable in both directions, which is what makes this direct-UPDATE
  shape correct rather than a workaround.
- `markAllNotificationsRead()` — same UPDATE, scoped to the caller's own
  unread rows.
- `subscribeToNotificationChanges(userId, onChange)` — one `postgres_changes`
  channel on `user_notifications`, `event: '*'`, filtered to
  `recipient_user_id=eq.<self>`. `'*'` (not `INSERT`-only, unlike the legacy
  channel) because `markNotificationRead`/`markNotificationUnread` from a
  second tab/device also need to trigger a refresh here.
- Pure helpers: `dedupeLegacyAgainstCap003`, `normalizeLegacyNotification`,
  `normalizeCap003Notification`, `renderNotificationTemplate`,
  `MIGRATED_EVENT_MAP`, `CAP003_ROUTES` — all DOM-free, shared verbatim by
  `shell.js` and by the test suite.

## 5. Dedup rule

Legacy `notifications.created_at` is written synchronously, in the same
transaction as the mutation. CAP-003 `user_notifications.created_at` is
written later, asynchronously, by the outbox worker, with no bound between
enqueue and processing (docs/78). The two timestamps are therefore never
exactly equal and can't be tightly matched — the rule instead uses structural
identity plus a generous time window:

1. `MIGRATED_EVENT_MAP` maps `(legacy type, record type)` →
   `(CAP-003 notification_type, record type)` for exactly the four migrated
   events: `task_assigned`↔`task.assigned.v1`, `task_completed`↔
   `task.completed.v1`, `meeting_cancelled`↔`meetings.cancelled.v1`,
   `meeting_updated`↔`meetings.rescheduled.v1`.
2. For each legacy row with a mapped type, the nearest (by `|Δt|`) unused
   CAP-003 row sharing `(record type, record id)` within **`DEDUP_WINDOW_MS`
   = 1 hour** is matched and consumed (each CAP-003 row can satisfy at most
   one legacy row, so repeated real occurrences on the same record — e.g. two
   separate completions over time — each keep their own distinct match rather
   than collapsing together).
3. A legacy row that finds no match survives and is displayed.
4. **`meeting_updated` superset caveat**: legacy `meeting_updated` also fires
   for title/location-only edits, which `meetings.rescheduled.v1` never
   represents (`update_meeting()` only enqueues on an actual time change).
   An unmatched `meeting_updated` row is therefore correctly left visible,
   not wrongly suppressed — proven by the "meeting_updated WITHOUT a
   rescheduled counterpart" test scenario.
5. Never matches on message text — only structural identity plus the time
   window, per the milestone's own explicit requirement.

Known limitation: the 1-hour window trades a small false-negative risk (an
outlier-slow worker run leaves a legacy duplicate briefly visible) for
near-zero false positives (two genuinely different events are never
collapsed). This is a heuristic, not a guarantee, and is deliberately biased
toward "briefly show a duplicate" over "wrongly hide a real notification."

## 6. Unread badge — dedup-aware, still bounded

Naively summing legacy-unread-count + CAP-003-unread-count would double-count
an unread migrated event that exists (unread) in both tables. The badge
instead: fetches up to 100 unread legacy rows (`listUnreadLegacy`, using the
existing `idx_notifications_user (user_id, is_read)` index) and up to 100
unread CAP-003 rows (`listNotifications({ unreadOnly: true, limit: 100 })`,
the function's own hard clamp), runs the same dedup match across just those
two bounded sets, and reports `dedupedUnreadLegacy.length + cap003UnreadCount`
— the *last* term is the true server-computed count
(`count_my_unread_notifications()`), not the bounded sample's length, so the
CAP-003 side of the badge is always exact even past 100 unread. The one
remaining edge case: a user with **more than 100 unread legacy notifications
for a migrated event type** can see the badge over-count by the number of
un-checked duplicates beyond that boundary — still a bounded query, never an
unbounded scan, just reduced dedup precision at an extreme volume. Every
constituent read stays bounded — no unbounded `SELECT`, no full-table scan.

## 7. Deep links

`CAP003_ROUTES` (`notifications-api.js`) maps `source_record_type` directly:
`task` → `{ route: 'task-detail', params: { id } }`, `meeting` → `{ route:
'meetings', params: { meetingId } }` — matching the router param names already
used elsewhere (`href="#task-detail?id=..."` in `task-detail.js`/
`tasks.js`; `Router.navigate('meetings', { meetingId })` in the pre-existing
legacy handler). No fallback branch exists on purpose: CAP-003 only ever
produces `task`/`meeting` source records today (docs/87), so inventing a
default for a type it never emits would be indistinguishable from a bug.

The notification row is never treated as proof of access. Clicking navigates
to the destination view, which enforces its own RLS on load exactly as it
already does for direct navigation — `TaskDetailView._renderNotFound()`
already renders a fail-closed "not found" state for an inaccessible task
(`task-detail.js` line 51, pre-existing, unmodified). If the CAP-003
notification itself remains visible for a record the user can no longer
access (allowed by CAP-003's own retention policy, unrelated to this
milestone), the destination route still fails closed — a stale notification
can surface the fact that *something* happened, never the record's content.

## 8. Realtime — signal-only, exactly as docs/78 §16 specifies

`_subscribeRealtime()` in `shell.js` now opens **two** channels under the same
existing `_realtimeBound` guard (bound once per SPA session, never duplicated
by re-render or re-navigation — verified by the "duplicate subscription
prevented" test): the pre-existing legacy `notifications-<uid>` channel,
unmodified, and a new `user-notifications-<uid>` channel
(`NotificationsAPI.subscribeToNotificationChanges`). Both callbacks do exactly
one thing — call `loadNotifications()` — and never read the Realtime payload
for rendering, verified directly: the test suite fires a channel callback with
a payload containing an obviously-poisoned value (`read_at: 'not-a-real-value'`)
and confirms only that `loadNotifications()` (a real re-fetch) is triggered.

**Reconnect/offline proof**: `loadNotifications()` always performs a full,
fresh fetch from both durable sources and *replaces* the rendered list — it
never incrementally patches on top of stale DOM. The "reconnect" test
scenario simulates exactly this: a notification appearing between two calls
to `loadNotifications()` (standing in for "created while the client was
offline, discovered on the next authorized fetch after reconnect") is present
in the new render and the old one is gone — proving the durable row, not the
Realtime message, is what the client ultimately displays.

### Realtime publication (`patch-notification-realtime-legacy-cutover.sql`)

A repository-wide search (`grep -rn "ALTER PUBLICATION\|supabase_realtime"
supabase/*.sql`, excluding test-/validate-/rollback- files) found **zero**
explicit publication statements anywhere in this migration history — not even
for the legacy `notifications` table, whose Realtime channel already works
today. That means legacy Realtime exposure is a Supabase-project-level
default outside any file this repository tracks, not something the migration
chain ever declared. This patch adds one explicit, idempotent statement
(`ALTER PUBLICATION supabase_realtime ADD TABLE user_notifications`, guarded
by existence/membership checks) so `user_notifications`' membership is
reviewable in source control going forward, rather than perpetuating that
same implicit state for a second table. The guard makes this a safe no-op on
any environment without a `supabase_realtime` publication object at all
(e.g. this repository's disposable local Postgres regression harness, which
has no Realtime extension installed) and a safe no-op if the table is already
a member.

This changes nothing about *who* can see *what*: `postgres_changes` always
re-evaluates RLS for the connecting user regardless of publication membership
— publication membership is necessary, not sufficient, for a client to
observe a row's changes. `user_notifications_select`'s
`recipient_user_id = auth.uid()` clause still governs exactly which rows any
client can be signaled about, identically to how it already governs ordinary
`SELECT`s. No publication statement was added for `platform_outbox_events` or
`notification_intents` — neither is ever read by any authenticated client,
and both remain `service_role`-only (asserted by the structural validator).

## 9. Read/unread and mark-all

Click-to-open marks the item read via the correct backend for its `source`
(`markNotificationRead` for `cap003`, legacy `markRead` for `legacy`) before
navigating — verified directly, including that clicking one never calls the
other's endpoint. "Mark all read" now runs both `NotificationsAPI.markAllRead()`
(legacy) and `NotificationsAPI.markAllNotificationsRead()` (CAP-003) together:
one button, one user-facing action, regardless of which table backs any given
item in the merged list.

## 10. Security / RLS

No RLS policy was changed. `supabase/validate-notification-realtime-legacy-
cutover.sql` re-asserts `user_notifications_select`/`user_notifications_update`
are byte-for-byte the Phase 1.1 policies, that `platform_outbox_events`/
`notification_intents` remain RLS-enabled with zero policies (so no
non-`service_role` caller — the frontend included — can read either), and
that `platform_create_user_notification`/`platform_enqueue_outbox_event`
remain unreachable to `authenticated`/`anon`. Cross-user read/mark-read denial
itself is not re-tested by this milestone's own suite: it's the exact
`user_notifications_update`/`_select` boundary
`supabase/test-notification-outbox-persistence-foundation-rls.sql` already
covers exhaustively, and this milestone made no change to it — re-testing
Postgres RLS from a browser DOM harness would test Postgres, not this
milestone's actual new surface. A live-socket proof that the CAP-003 Realtime
channel can't observe another user's activity was out of reach in this
offline harness (no live Supabase project) — the structural guarantee is:
`postgres_changes` always re-evaluates RLS server-side regardless of channel
filter, matching the already-accepted precedent docs/78 §2.6 documents for
the legacy channel, which had no live-socket test either.

## 11. Frontend UX

No visual redesign. Same topbar bell, same dropdown, same "Mark all read"
button, same bounded (15-item) preview list — functional cutover only, per
the milestone's own scope.

## 12. Performance

Every read `loadNotifications()` performs is bounded: `listMine(15)`,
`listUnreadLegacy(100)`, `listNotifications({limit:20})`,
`listNotifications({limit:100, unreadOnly:true})`, `getUnreadCount()` (single
index-backed aggregate). No N+1 source-record fetch (titles come from
`template_params`, already persisted by the producer). No duplicate
subscription re-queries data on every navigation (`_realtimeBound` guard,
verified). The dedup match itself is O(bounded-legacy × bounded-cap003) —
worst case 15×20 or 100×100 — never proportional to total notification
volume for the account or the platform.

## 13. Testing

`tests/notification-realtime-legacy-cutover-frontend.test.js` (Playwright
headless harness, same convention as `tests/task-relationships-frontend.
test.js`): 34 scenarios against the *real* `notifications-api.js`/`shell.js`
source, covering dedup correctness (matched/unmatched/window/superset/
consume-once), template rendering (all four keys, unknown-key fallback,
missing-param fallback, no leaked extra fields), routing (`CAP003_ROUTES`
correctness and absence of a fallback branch), the merged feed (own-list
display, migrated-event shown-once, non-migrated legacy always shown,
dedup-aware badge, badge hidden-at-zero/9+-cap), XSS escaping, bounded
pagination (asserting the exact bounded args every query is called with),
mark-read routing to the correct backend per source, deep-link params for
Task/Meeting, legacy routing unaffected, reconnect (full-replace, never
stale-merge), Realtime-triggers-refresh with an untrusted payload, and
duplicate-subscription prevention.

`supabase/validate-notification-realtime-legacy-cutover.sql`: the DB-side
structural validator (§10 above).

Existing suites this milestone deliberately reuses rather than duplicates:
`test-notification-outbox-persistence-foundation-rls.sql` (cross-user
`user_notifications` denial), `validate-task-meeting-notification-events.sql`
(legacy dual-write presence, re-asserted independently here too).

## 14. Rollback

`supabase/rollback-notification-realtime-legacy-cutover.sql` removes
`user_notifications` from the `supabase_realtime` publication (a no-op if it
was never a member). Nothing else needs reversing on the DB side — the patch
touched exactly that one thing, and none of the four legacy dual-writes were
ever modified. `supabase/validate-notification-realtime-legacy-cutover-
rollback.sql` confirms the publication membership is gone and every Phase
1.1–1.4B object, policy, and legacy dual-write remains fully intact.

The frontend rollback is a plain file-level revert of `js/data/
notifications-api.js` and `js/views/shell.js` to their pre-1.5 state (this
repository has no frontend migration/versioning system) — independent of
whether the SQL rollback above is also applied. All CAP-003 backend data
(`user_notifications`, `platform_outbox_events`, `notification_intents`) is
preserved regardless; no historical row is ever deleted by either rollback.

## 15. What this milestone does NOT do

- No legacy dual-write removed (all four retain a genuine, evidenced gap).
- No historical legacy row migrated or backfilled into `user_notifications`.
- No new module producer (Requests/Entry/Internal Collaboration/Prisoner
  Letters remain entirely legacy).
- No CAP-002/SLA notification producer.
- No email, push, SMS, notification preferences, quiet hours, or digest —
  external delivery is CAP-003 Phase 2.
- No dedicated mark-read/mark-unread RPC — the existing direct RLS-protected
  `UPDATE` boundary is used, matching how legacy `markRead()` already works.
- No visual redesign of the notification bell/dropdown.
- No scheduler/deployment change.
