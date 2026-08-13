# CAP-003 Phase 1.7B — Entry Notification Integration

## Status

Implemented and locally verified against a disposable PostgreSQL harness
(full CAP-002 + CAP-003 1.0A–1.7A + Requests 1.6A/1.6B migration chain
applied). Not yet pushed — pending a separate push-approval checkpoint.

## Scope, precisely

Phase 1.7A gave Entry / External Correspondence a server-authoritative
mutation boundary (12 SECURITY DEFINER RPCs) but produced zero CAP-003
events. Phase 1.7B wires exactly **four** real business events, each
atomically enqueued inside its own already-existing Phase 1.7A mutation RPC:

| Event | Producer RPC | Target |
|---|---|---|
| `entry.routed.v1` | `route_entry()`, when `p_assigned_to IS NULL` | `section(to_section_id)` |
| `entry.assigned.v1` | `route_entry()`, when `p_assigned_to IS NOT NULL`, **and** `assign_entry()`, conditional on a real assignee | `specific_users([assigned_to])` |
| `entry.reply_sent.v1` | `approve_entry_reply()` | `specific_users([entry.entered_by])`, sourced from the **parent entry** |
| `entry.reply_returned.v1` | `return_entry_reply()` | `specific_users([reply.created_by])`, sourced from the **parent entry** |

No new target-descriptor kind, no new mutation RPC, no `external_
correspondence_reply` source-record type, and zero changes to
`process_platform_outbox_batch()` at all (every target kind used already
existed since Phase 1.2). `route_entry()` is the sole two-producer RPC in
this milestone: its own either/or shape (route with vs. without an
assignee) mirrors `entry-api.js`'s own pre-existing legacy `if
(assignedTo)/else` branch exactly, mutually exclusive within one call.

## Candidate inventory (all 12 Phase 1.7A commands evaluated)

| Command | Outcome | Reason |
|---|---|---|
| `create_entry` / `update_entry_draft` | Deferred | Draft-only; while unrouted, an entry is visible only to Entry staff/its own creator (`external_correspondence_select`), and no legacy notification fires for either (confirmed by direct inspection of `js/data/entry-api.js` — `create()`/`updateDraft()` never call `NotificationsAPI.notify()`). |
| `route_entry` | **Implemented**, conditionally, as `entry.routed.v1` OR `entry.assigned.v1` | `entry-api.js`'s own `route()` legacy behavior is itself an either/or: `if (assignedTo) notify([assignedTo], ...) else notify(sectionUserIds(toSectionId), ...)` — never both. Mirrored exactly inside the single RPC. |
| `mark_entry_received` | Deferred | No legacy notification fires at all (confirmed by direct inspection — `markReceived()` only returns `data`). Implementing one here would invent new recipient policy. Same finding, same reasoning, as Requests' own `mark_request_received` in Phase 1.6B. |
| `assign_entry` | **Implemented** — `entry.assigned.v1` (second producer of the same event type as `route_entry()`'s own assignee branch) | Legacy recipients: `[userId]`, conditional on `userId` being non-null (an unassignment fires no legacy notification) — mirrored exactly, same conditional-enqueue shape as Requests' own `assign_request()`. |
| `close_entry` | Deferred | No legacy notification fires at all (confirmed by direct inspection — `close()` only returns `data`). |
| `draft_entry_reply` / `update_entry_reply_draft` | Deferred | Draft-only; no legacy notification fires for either. |
| `submit_entry_reply` | Deferred | Legacy recipients (`approval_requested`) are either a single named `approverId` (informational routing only, not an authorization boundary, mirroring `submit_request`'s own `p_approver_id`) or `sectionUserIds(entry.to_section_id, ['mcs_admin','authority_admin','supervisor'])` — an internal, same-org, pre-approval step. Exact same reasoning Requests' own `submit_request` used to defer in Phase 1.6B: lower value, not required to prove any of this milestone's architecture points, and the `section_leadership` target kind already exists for a future milestone to wire it. |
| `approve_entry_reply` | **Implemented** — `entry.reply_sent.v1` | Sole RPC that transitions a reply to `status='sent'` **and** the parent entry to `status='responded'` — the real "sent" business event, matching Requests' own `requests.response_sent.v1` precedent (named after the sub-object's own transition, not the RPC name). Legacy recipients: `[entry.entered_by]`. Sourced from the PARENT ENTRY, never a new reply source type — see below. |
| `return_entry_reply` | **Implemented** — `entry.reply_returned.v1` | Sole RPC for returning a submitted reply draft. Legacy recipients: `[data.created_by]` (the reply's own drafter). Also sourced from the parent entry. |
| `mark_entry_reply_sent` | Deferred | No legacy notification fires at all (confirmed by direct inspection — `markReplySent()` only returns `data`); it is a delivery-recording bookkeeping action (how the already-approved reply physically reached the sender), not a notify-worthy business transition. |

## `source_record_type`: `'external_correspondence'` added, no separate reply source type

Every legacy Entry notification call site in `js/data/entry-api.js` uses
`recordType: 'external_correspondence'` (never `'entry'`) — confirmed by
direct grep of `entry-api.js`'s own `NotificationsAPI.notify()` calls, and
matching `audit_logs.record_type`'s own existing convention for this table
and `shell.js`'s own deep-link `routes = { external_correspondence:
'entry-detail' }` convention. Per the governing instruction ("use existing
routing/deep-link terminology... do not choose from preference"), this
milestone uses `source_record_type = 'external_correspondence'`, NOT
`'entry'` — `'entry'` is used only as the RPC-name/route-name/event-prefix
convention, never as the record-type string value anywhere in the current
schema/frontend.

`entry.reply_sent.v1`/`entry.reply_returned.v1` are both sourced from the
**parent entry** (`source_record_type='external_correspondence'`,
`source_record_id=<entry.id>`), never a new `external_correspondence_reply`
source type — because (a) `entry-detail.js` already renders every reply
inline within its parent entry's own page, there is no separate reply
detail route to deep-link to, and (b) both events' only target candidates
(`entry.entered_by`, `reply.created_by`) are already covered by
`intent_user_can_view_entry()`'s own core-policy branches (`entered_by`/
`to_section_id` membership respectively), so a second adapter would
duplicate authorization the entry adapter already provides — exactly the
same reasoning Requests' own `requests.response_sent.v1` used to avoid
adding a `'response'` source type in Phase 1.6B.

## `intent_user_can_view_entry()`: generalization source and a real, evidenced divergence from the Requests precedent

A candidate-parameterized mirror of `external_correspondence_select`'s own
core `USING` clause (`supabase/rls.sql`) — the same generalization pattern
Phase 1.2/1.4/1.4A/1.6B already used four times
(`intent_user_can_view_workflow_instance`/`_task`/`_meeting`/`_request`).
Entry visibility is spread across **two** SELECT policies
(`external_correspondence_select`, `external_correspondence_select_via_
internal_collab`) — this adapter mirrors only the first, core policy (org
match, `is_entry_staff()`-equivalent, `to_section_id` membership,
`assigned_to`, `entered_by`), deliberately excluding the additive Internal
Collaboration loop-in policy — the same "core policy only" scope decision
Requests' own `intent_user_can_view_request()` already made for its own
three additive policies.

Unlike `is_entry_staff()`/`my_section_ids()` (both session-bound, always
evaluating against `auth.uid()` — the WORKER's own identity when called from
inside `resolve_notification_intent()`, never the candidate being
authorized), this adapter re-implements the equivalent check fully
parameterized by `p_user`, directly against `user_assignments`/
`scope_section_ids()` — exactly matching `intent_user_can_view_request()`'s
own technique for the identical reason (`my_section_ids()` cannot safely be
called here at all; caught during design, before writing the adapter, by
reading `my_section_ids()`'s actual body — not assumed from memory).

**A genuine, evidenced divergence from the Requests precedent**: Entry
RLS's own `is_entry_staff()` has **NO admin/supervisor bypass** —
`schema.sql`'s own comment on `is_entry_staff()` explicitly documents that a
previous version DID have a blanket `is_supervisor_or_above()` bypass and
that this was REMOVED as a reported bug ("that let every supervisor/admin
org-wide see and manage every logged entry regardless of section ...
exactly the 'all entries visible to all supervisors' bug this was reported
as"). `intent_user_can_view_request()` includes an
`intent_user_is_super_admin()`/`mcs_admin`/`authority_admin` bypass branch
because `requests_select` itself grants org admins that visibility;
`intent_user_can_view_entry()` deliberately does **NOT** include any such
bypass, because `external_correspondence_select` itself grants none.
Copying the Requests adapter's admin-bypass branch here would silently
WIDEN Entry visibility beyond what its own real RLS grants — exactly the
class of mistake "prove it against the real code, don't reconstruct from
memory/a sibling precedent" exists to catch. Proven directly (RLS scenarios
12–13): an org `authority_admin` whose only section assignment is
deliberately NOT registered in `entry_sections` at all is correctly
authorized `FALSE`, while the same user, once given a genuine assignment to
the entry's own `to_section_id`, is correctly authorized `TRUE` — proving
the `FALSE` result reflects the deliberate absence of an admin-role-alone
bypass, not a broken adapter. Note also that `is_entry_staff()`'s own
"is entry staff org-wide" grant (membership in ANY entry-registered section
within the org, not just the entry's own `to_section_id`) is itself
faithfully mirrored — this is real, existing RLS behavior, not a bypass.

## Target mapping (no new target kinds)

- `entry.routed.v1`: `section(to_section_id)` — the just-routed-to section.
- `entry.assigned.v1`: `specific_users(assigned_to)`, conditional on
  `assigned_to` being non-null.
- `entry.reply_sent.v1`: `specific_users(entry.entered_by)`.
- `entry.reply_returned.v1`: `specific_users(reply.created_by)`.

All four reuse target kinds and their existing resolution SQL
(`section_user_ids()`, already called unchanged by
`resolve_notification_intent()` since Phase 1.2) verbatim — ZERO changes to
`resolve_notification_intent()`'s target-resolution CASE, the target-shape
CHECK constraint, or `process_platform_outbox_batch()`.
`create_notification_intent()` and `resolve_notification_intent()` each
gain exactly ONE new line: an `'external_correspondence'` entry added to
`create_notification_intent()`'s own `source_record_type` guard
(independent of the table CHECK constraint, same non-obvious finding Phase
1.6B already documented and re-verified here by direct end-to-end testing,
not assumed) and `resolve_notification_intent()`'s
`'external_correspondence'` → `intent_user_can_view_entry()` dispatch
branch, following the identical pattern Phase 1.4A/1.6B added for
`'meeting'`/`'request'`.

## Idempotency

Each event's `idempotency_key` is the fresh `audit_logs.id` captured via
`RETURNING id INTO v_audit_id` at the exact moment of the real mutation —
never a timestamp, never invented. Each of the three producer RPCs enqueues
at most one outbox event per real invocation (`route_entry()`'s own
either/or is mutually exclusive within one call, never both), so no
deterministic-derivation (`md5(...)`) idempotency key is needed; the raw
`audit_logs.id` is used directly for all four events, exactly as Phase
1.6B's own five events already do. Legitimate repeated occurrences (e.g.
`route_entry()` called again to reroute, or `assign_entry()` called again
to reassign) each produce their own fresh `audit_logs` row and are
therefore their own legitimate, distinguishable occurrence — proven
directly (behavioral scenario 7 / concurrency scenarios 2 and 5): two
concurrent `assign_entry()` calls with different assignees both succeed
serially, producing two distinct, independently-idempotency-keyed
occurrences; re-invoking `route_entry()` on an already-routed entry (a
legitimate reroute) produces its own second, distinct occurrence.

## Correlation/causation

Each mutation generates one fresh `gen_random_uuid()` `correlation_id` for
its own single enqueue call. `causation_id` is `NULL` for all four events,
identical to every prior CAP-003 producer's own precedent — no upstream
CAP-003 event caused these.

## Safe payload

`template_params` carries only structural identifiers: `entry_id`,
`reference_number` (explicitly whitelisted by the governing instruction as
safe, same category as Requests' own `reference_number`), `to_section_id`,
assigned/actor user ids, `reply_id`. **`subject` (the correspondence's own
title/summary line) is deliberately EXCLUDED from every payload** — docs/91
never affirmatively confirms `subject` as non-confidential (Entry logs
correspondence from the public, prisoners' families, and prisoner
complaints — materially more sensitive in kind than Requests' own internal
inter-organization subject line), so per the governing instruction's own
explicit fallback this milestone treats it conservatively as potentially
sensitive and never copies it into `notification_intents`/
`user_notifications`. `body`, reply `body`, `sender_name`, `sender_contact`,
`prisoner_name`, and every free-text/personal-data field are never read by
any of the four new enqueue call sites — proven directly (behavioral
scenarios 1, 8, 10, each passing a distinctive marker string through a
free-text field and asserting it never appears in the outbox payload).
Frontend templates render generic text using only `reference_number`, never
a fetched subject/body/sender identity.

## Legacy coexistence

No legacy `NotificationsAPI.notify()` call site in `js/data/entry-api.js`
is removed, altered, or suppressed by this milestone (this is a pure-SQL
patch; the JS frontend change is dedup/routing/templates only, described
below). For all four events, the CAP-003 target's own resolution SQL is
*the same function* the legacy call site already uses
(`section_user_ids`) or targets the exact same specific user id — but
`intent_user_can_view_entry()`'s own narrower late-authorization (no admin
bypass, core-policy-only scope) means the two channels' recipient sets are
not proven byte-for-byte identical in every case, so per the governing
instruction every legacy write is retained unconditionally for all four
events.

### Frontend dedup extension (`js/data/notifications-api.js`)

`MIGRATED_EVENT_MAP` gained three new entries, and its own value shape was
generalized from a single object per legacy type to an **array** of
candidate mapping objects:

```js
new_external_correspondence:     [{ cap003Type: ['entry.routed.v1', 'entry.assigned.v1'], recordType: 'external_correspondence' }],
external_correspondence_replied: [{ cap003Type: 'entry.reply_sent.v1', recordType: 'external_correspondence' }],
draft_returned: [
  { cap003Type: 'requests.returned.v1',    recordType: 'request' },
  { cap003Type: 'entry.reply_returned.v1', recordType: 'external_correspondence' },
],
```

This generalization was **required**, not optional: `entry-api.js`'s
`returnReply()` reuses the exact same legacy type string `'draft_returned'`
that Requests' own `returnRequest()` already used (Phase 1.6B) — but the two
are genuinely different events with different `recordType` values
(`'external_correspondence'` vs `'request'`) and different CAP-003
counterparts. A single-object value per key cannot represent two distinct
candidates sharing one key. `dedupeLegacyAgainstCap003()` was updated to
iterate each legacy type's candidate array, filtering by
`legacy.record_type === candidate.recordType` before ever considering a
CAP-003 match — so the two `draft_returned` candidates never cross-match
each other's rows, proven directly (frontend scenarios: an Entry
`draft_returned` row is unaffected by an unrelated Requests
`requests.returned.v1` row at nearly the same timestamp, and vice versa; two
simultaneous `draft_returned` rows of each kind each consume their own
distinct counterpart). Every pre-existing single-candidate entry
(`task_assigned`, `task_completed`, `meeting_cancelled`, `meeting_updated`,
`new_request`, `new_response`) was mechanically wrapped in a one-element
array — no behavioral change for any of them, re-verified by the full
pre-existing 23-scenario Requests frontend suite passing unchanged.

`new_external_correspondence` mirrors `new_request`'s own array-valued
`cap003Type` pattern exactly: `entry-api.js`'s `route()`/`assign()` reuse
the single legacy type `'new_external_correspondence'` for two structurally
different transitions (route with no assignee vs. route/assign with one) —
the `(record_id, time-window)` match still disambiguates correctly, since
only ONE of the two possible CAP-003 events is ever actually enqueued near
a given legacy row's own timestamp for a given entry.

`NOTIFICATION_TEMPLATES` gained four new keys (`entry.routed`,
`entry.assigned`, `entry.reply_sent`, `entry.reply_returned`) — all render
generic text, `entry.reply_sent` additionally interpolating
`reference_number` only.

## Realtime/UI behavior

No new Realtime channel. Phase 1.5 already exposes CAP-003 notifications
generically through `user_notifications`; Entry events flow through the
existing subscription unchanged.

## Deep links

`CAP003_ROUTES` gained one new entry:

```js
external_correspondence: recordId => ({ route: 'entry-detail', params: { id: recordId } }),
```

`entry.reply_sent.v1`/`entry.reply_returned.v1` also route here (their
`source_record_id` is always the **parent entry**, never a separate reply
id — see §"`source_record_type`" above) — there is no
`CAP003_ROUTES.external_correspondence_reply` entry, by design. Notification
presence never grants Entry access; destination Entry RLS
(`external_correspondence_select`) remains the sole authority on whether a
given user can actually open the entry the notification points to — a stale
or since-revoked notification can never be used as a substitute for that
check.

## Late authorization / dynamic recipient resolution

Where a target is section-based (`entry.routed.v1`), current section
membership at **processing time** is used, never an enqueue-time snapshot —
proven directly (behavioral scenario 12 / concurrency scenario 4): a
section member deactivated between enqueue and worker processing receives
nothing; a genuine concurrent deactivation racing the worker's own
resolution produces 0 or 1 notifications, never a duplicate, both
documented as legitimate serial outcomes per docs/78 §7.2.

## Internal-only semantics preserved

Entry remains internal-only throughout this milestone: no cross-organization
notification semantics were introduced. Every recipient candidate for all
four events comes only from the entry's own actual organization/section/
assignee/creator relationships (`to_section_id` membership, `assigned_to`,
`entered_by`, `reply.created_by`) — never from a merely shared platform
membership. Proven directly (behavioral scenario 13 / RLS scenario 6): a
user belonging to a genuinely unrelated, itself Entry-enabled organization
(Org Gamma, with its own real staff and supervisor) never becomes a
candidate for, and never receives, any `entry.*.v1` notification produced by
another organization's Entry activity.

## Composed commands

None of Phase 1.7A's 12 Entry RPCs are composed (unlike Requests'
`receive_and_route_request()`) — each of the four implemented events is
produced by exactly one direct RPC call, with no nested-`PERFORM` fan-out to
reason about.

## Prisoner transfer / facility reassignment

**Explicitly unresolved and not implemented here.** No prisoner-transfer or
facility-reassignment engine exists anywhere in the current Entry RPC
surface — Phase 1.7A's own documented finding, unchanged and reconfirmed by
this milestone's own structural validator (`transfer_entry`/
`reassign_entry_prison` asserted absent). No such event was invented for
this milestone; a future phase introducing that engine would need to design
its own notification integration from scratch, informed by but not
constrained by this milestone's own target/source-authorization choices.

## Worker genericity

`process_platform_outbox_batch()` is **not modified at all** by this
milestone — every target kind this milestone uses (`specific_users`,
`section`) already existed since Phase 1.2. All four event types are
registered exactly like `requests.sent.v1`
(`uses_generic_notification_envelope = TRUE`), routing through the same
registry-driven generic passthrough path with zero worker code changes —
proven directly (performance dimension 7, draining 300 real Phase 1.7B
events through the unmodified worker entry point in ~5.7 seconds).

## SECURITY DEFINER / search_path

Every modified/new function pins `search_path = public, pg_temp`,
`intent_user_can_view_entry()` is `REVOKE ALL ... FROM PUBLIC, anon,
authenticated` (internal-only, matching every other `intent_user_can_view_
*()` adapter's own posture — verified: `has_function_privilege
('authenticated', 'intent_user_can_view_entry(uuid,uuid)', 'EXECUTE')` is
`false`), and every actor is derived from `auth.uid()`, never a
client-supplied user id. The repository's previously-reported unrelated
SECURITY DEFINER `search_path` findings are **not** addressed here — out of
scope, recorded only.

## RLS

No Entry, Entry replies, `user_notifications`, `notification_intents`, or
`platform_outbox_events` RLS policy was weakened. `external_correspondence`/
`external_correspondence_replies` policy counts remain exactly 5/3 (Phase
1.7A's own byte-for-byte baseline). No direct authenticated `INSERT` on
`platform_outbox_events`/`notification_intents` (RLS-enabled, zero policies
— the real gate, not raw table grants, per this repository's own
established convention). No direct authenticated `EXECUTE` on
`process_platform_outbox_batch()`/`create_notification_intent()`/
`intent_user_can_view_entry()`. Phase 1.7A's direct-write closure on
`external_correspondence`/`external_correspondence_replies` (no
authenticated `INSERT`/`UPDATE` grant) remains intact.

## Testing

- **Structural validator** (`validate-entry-notification-integration.sql`,
  12 checks): exactly the 4 approved event types registered
  (registry-driven); deferred candidates absent; `source_record_type` CHECK
  extended by exactly `'external_correspondence'`; `create_notification_
  intent()`'s own independent guard also extended;
  `resolve_notification_intent()` gains exactly the one new dispatch
  branch, no event-type-specific/module-specific branch anywhere;
  `process_platform_outbox_batch()` completely untouched (textual scan for
  any `entry.*`/`'entry'` literal); exactly one new authorization adapter
  (`intent_user_can_view_entry`, internal-only, no grant to
  `authenticated`/`anon`, deliberately no admin-bypass branch, no
  session-bound-helper call); each of the four producers' own
  `functiondef` contains the real atomic enqueue call, the correct
  event-type literal(s), an approved target type, no direct
  `user_notifications` write, and free-text fields excluded from the
  enqueue call site's own payload construction;
  `approve_entry_reply()`/`return_entry_reply()` sourced from the parent
  entry, never a reply source type; Entry RLS policy counts and
  direct-write closure unchanged; no external-delivery/preferences
  objects; all 12 Phase 1.7A Entry RPCs still present; no
  prisoner-transfer engine introduced; Internal Collaboration/Prisoner
  Letters still not integrated; CAP-003 Phase 2 not started.
- **Behavioral** (17 scenarios, `test-entry-notification-integration.sql`):
  per-event outbox correctness (source identity, target descriptor, safe
  payload, subject/sender/body never leaked); domain-failure → zero outbox
  events (cross-org routing rejection, status-guard rejections for reply
  approve/return); a forced `platform_enqueue_outbox_event()` failure (via
  a temporary function rename) rolls back the ENTIRE domain mutation
  (`external_correspondence.status`/`to_section_id`, the `audit_logs` row)
  as one unit, with a normal call succeeding again once the dependency is
  restored; `route_entry()`'s mutually-exclusive either/or (routed vs.
  assigned) proven directly; `assign_entry()` as the second independent
  producer of `entry.assigned.v1`; unassignment fires no event; legitimate
  reassignment produces a second, distinguishable occurrence; dynamic
  section-membership exclusion; cross-org (unrelated, itself Entry-enabled
  org) isolation; two full replay-idempotency proofs (intent-level and
  worker-level); two independent entries never cross-contaminate
  idempotency keys; every deferred candidate RPC (`mark_entry_received`,
  `draft_entry_reply`, `update_entry_reply_draft`, `close_entry`) confirmed
  to enqueue zero CAP-003 events.
- **RLS** (13 scenarios, `test-entry-notification-integration-rls.sql`): no
  direct `platform_outbox_events` insert bypassing `route_entry()`/
  `assign_entry()`; no direct `create_notification_intent()`/
  `process_platform_outbox_batch()`/`intent_user_can_view_entry()`
  invocation; `user_notifications` strictly recipient-scoped (positive and
  negative controls); a genuinely unrelated org's user sees nothing;
  non-recipient cannot mark another user's notification read (positive
  control included); `external_correspondence_select` RLS completely
  unaffected (a third-org outsider still denied, the assignee still
  allowed); Phase 1.7A's direct-write closure intact;
  `platform_event_type_registry` still admin-write-only despite 4 new rows
  added via the migration itself; **the no-admin-bypass proof**:
  `intent_user_can_view_entry()` correctly returns `FALSE` for an org
  `authority_admin` with no genuine entry-section membership, with a
  positive control proving the same adapter correctly returns `TRUE` once
  that user is given a real section assignment matching the entry's own
  `to_section_id`.
- **Concurrency** (7 scenarios, genuine `dblink` multi-session,
  `test-entry-notification-integration-concurrency.sql`): two workers
  racing the same real `entry.routed.v1` event resolve exactly once; two
  concurrent `assign_entry()` calls (two assignments, both invoked by the
  SAME kind of authorized caller to avoid the authorization-depends-on-race-
  outcome confound already learned in Phase 1.7A's own concurrency suite)
  both succeed serially, each producing its own distinguishable occurrence;
  `approve_entry_reply()` vs `return_entry_reply()` racing the same
  `pending_approval` reply are mutually exclusive via the pre-existing
  status guard (exactly one of the two events fires); a section-membership
  deactivation racing the worker's own resolution of a real
  `entry.routed.v1` event never duplicates (0 or 1, both legitimate); a
  legitimate reroute (`route_entry()` invoked again) correctly produces its
  own second, distinct occurrence rather than a duplicate; an unrelated
  entry proceeds independently throughout; no deadlock (explicit lock-table
  check after every dblink session cleanly disconnects).
- **Performance** (8 dimensions, 10,000+ historical Entries, 10,000+
  background outbox rows, 20,000+ background `user_notifications` rows,
  `test-entry-notification-integration-performance.sql`): `route_entry()`/
  `assign_entry()`/`approve_entry_reply()` atomic-enqueue overhead at scale
  (100 calls each, well under bound); idempotency-key uniqueness lookup
  index-backed (`EXPLAIN ANALYZE BUFFERS`-verified — `Index Only Scan`, no
  sequential scan against 10,000+ rows); `intent_user_can_view_entry()`
  authorization overhead measured directly (500 calls well under bound,
  `EXPLAIN`-verified); `section_user_ids()` target resolution remains
  index-backed; draining 300 real Phase 1.7B events via the unmodified
  worker entry point (~5.7 seconds); the merged notification feed
  (`list_my_notifications()`) with 4,000+ Entry-sourced background rows for
  one recipient remains a fast, index-backed keyset page fetch. No
  speculative index added — every access path already had an adequate
  existing index. (The initial draft of this suite's own background
  fixture used a per-row correlated subquery to look up each
  `platform_outbox_events.id` — pathologically slow, ~6 minutes and still
  incomplete against only 20,000 rows; rewritten as a single set-based
  `JOIN`, the same fixture completed in under 1 second. This was a test-
  harness authoring mistake, not a finding about the production schema or
  RPCs, and is recorded here only for completeness.)
- **Frontend** (21 scenarios, headless Chromium,
  `tests/entry-notification-integration-frontend.test.js`): the new
  `MIGRATED_EVENT_MAP` entries; the `draft_returned` collision proven
  directly from three angles (an Entry row ignores an unrelated
  simultaneous Requests row and vice versa, and two simultaneous rows of
  each kind each consume their own distinct counterpart); the
  `new_external_correspondence` array-valued `cap003Type` case; the four
  new render templates (safe text, `reference_number` interpolation only,
  no leaked subject/body/sender-identity payload fields); the new
  `CAP003_ROUTES.external_correspondence` entry; Phase 1.4B/1.5/1.6B's own
  task/meeting/request routes and dedup behavior unaffected;
  `js/data/entry-api.js` still has zero direct CAP-003/outbox references
  and every pre-existing legacy `NotificationsAPI.notify()` call site
  survives unchanged; zero page errors. The pre-existing 23-scenario
  Requests frontend suite (`tests/requests-notification-integration-
  frontend.test.js`) was updated for the new array-of-candidates
  `MIGRATED_EVENT_MAP` shape (a structural, non-behavioral change — every
  existing assertion's actual behavior is unchanged) and re-verified
  passing. All 35 pre-existing Phase 1.5 frontend scenarios
  (`tests/notification-realtime-legacy-cutover-frontend.test.js`) and all
  11 Phase 1.7A Entry frontend scenarios
  (`tests/entry-server-mutation-foundation-frontend.test.js`) re-verified
  passing unchanged.

## Rollback

`rollback-entry-notification-integration.sql` restores `route_entry()`/
`assign_entry()`/`approve_entry_reply()`/`return_entry_reply()` to their
**exact, byte-for-byte** pre-1.7B (Phase 1.7A) bodies, restores
`create_notification_intent()`/`resolve_notification_intent()` to their
exact Phase 1.6B bodies (the `'request'` dispatch branch is legitimately
preserved — Requests 1.6B predates this milestone and is untouched by this
rollback — only the `'external_correspondence'` dispatch is removed), drops
`intent_user_can_view_entry()`, restores the `source_record_type` CHECK
constraint to its exact Phase 1.6B form, and removes the 4 event-type
registry rows — refusing (raising, never silently discarding evidence) if
any `platform_outbox_events`/`notification_intents`/`user_notifications`
row still uses one of the 4 event types or
`source_record_type='external_correspondence'`.
`validate-entry-notification-integration-rollback.sql` verifies all of the
above plus that every Phase 1.0–1.6B/1.7A object (all 12 Entry RPCs,
direct-write closure, RLS policy counts, Requests/Task/Meeting events, all
prior authorization adapters) remains completely unaffected. Verified
directly: apply → structural-validator PASS → behavioral/RLS/concurrency/
performance suites PASS → rollback → rollback-validator PASS → re-apply
patch → structural-validator PASS again → focused smoke re-test PASS, a
full round trip against the live local harness.

## Limitations

- Only four events, from three RPCs' worth of lifecycle stages (route,
  assign, reply-approve, reply-return), are wired. No cancel/return-to-
  previous-section event exists to defer (Phase 1.7A's own documented
  finding: neither command exists in the current Entry RPC surface).
- `intent_user_can_view_entry()` mirrors only `external_correspondence_
  select`'s core policy, not the additive Internal Collaboration loop-in
  policy (`external_correspondence_select_via_internal_collab`) — a
  documented, evidenced, fail-closed gap covered by retained legacy
  coexistence (see above).
- Prisoner transfer / facility reassignment remains entirely unresolved and
  unimplemented — no such engine exists anywhere in the Entry RPC surface,
  and none was invented for this milestone.
- Internal Collaboration and Prisoner Letters modules remain deferred —
  unchanged from every prior CAP-003 phase's own finding.
- CAP-002/SLA notification producers, email/push/SMS delivery, notification
  preferences, historical legacy-notification migration, and a broader
  Entry UI redesign are all explicitly out of scope, matching every prior
  CAP-003 phase.
- Previously-reported, unrelated SECURITY DEFINER `search_path` findings, a
  known CAP-002 SLA timer concurrency flake, and an unrelated Requests
  timing/performance flake are not addressed here.
- CAP-003 Phase 2 has not started.
