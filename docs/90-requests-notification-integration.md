# CAP-003 Phase 1.6B — Requests Notification Integration

## Status

Implemented and locally verified against a disposable PostgreSQL harness (full
CAP-002 + CAP-003 1.0A–1.5 + Requests 1.6A migration chain applied). Not yet
pushed — pending a separate push-approval checkpoint.

## Scope, precisely

Phase 1.6A gave Requests a server-authoritative mutation boundary (19
SECURITY DEFINER RPCs) but produced zero CAP-003 events. Phase 1.6B wires
exactly **five** real business events, each atomically enqueued inside its
own already-existing Phase 1.6A mutation RPC:

| Event | Producer RPC | Target |
|---|---|---|
| `requests.sent.v1` | `approve_request()` | `org_admins(to_org_id)` |
| `requests.returned.v1` | `return_request()` | `specific_users([created_by])` |
| `requests.routed.v1` | `route_request()` | `section(to_section_id)` |
| `requests.assigned.v1` | `assign_request()`, conditional on a real assignee | `specific_users([assigned_to])` |
| `requests.response_sent.v1` | `approve_response()` | `specific_users([request.created_by])`, sourced from the **parent request** |

No new target-descriptor kind, no new mutation RPC, no `response`
source-record type, and — the smallest-footprint CAP-003 producer milestone
to date — zero changes to `process_platform_outbox_batch()` at all (every
target kind used already existed since Phase 1.2).

## Candidate inventory (all 19 Phase 1.6A commands evaluated)

| Command | Outcome | Reason |
|---|---|---|
| `create_request` / `update_request_draft` | Deferred | Draft-only, `requests_select` grants nobody but the creator visibility yet; no recipient exists. No legacy notification fires either. |
| `submit_request` | Deferred | Legacy recipient is either a single named `approverId` (informational routing only, not an authorization boundary — docs/89) or `sectionUserIds(from_section_id, [...])` — an internal, same-org, pre-send step. Lower value than the five implemented events; not required to prove any of this milestone's architecture points. The `section_leadership` target kind already exists for a future milestone to wire it. |
| `approve_request` | **Implemented** — `requests.sent.v1` | Sole RPC that reaches `status='sent'` with a `reference_number` — the actual "sent" event, matching the `requests.status` enum's own vocabulary (deliberately not named after `submit_request`, which only reaches the internal `'pending_approval'` state). |
| `return_request` | **Implemented** — `requests.returned.v1` | Sole RPC for returning a submitted draft. Legacy recipient: `[created_by]`. |
| `mark_request_received` | Deferred | No legacy notification fires at all (confirmed by direct inspection of `js/data/requests-api.js` — `markRequestReceived()` only returns `data`). Implementing one here would invent new recipient policy. |
| `route_request` | **Implemented** — `requests.routed.v1` | Legacy recipient: `sectionUserIds(toSectionId)` — verified to be the *exact same SQL function* (`section_user_ids(section_id, NULL)`) the existing `section` target kind already calls. |
| `return_request_to_previous_section` | Deferred | Same `section`-target shape as `requests.routed.v1` but a distinct RPC/lifecycle occurrence (a rejection hand-back, not a forward route). Deferred purely for the ~3–5 event budget — the `intent_user_can_view_request()` adapter this milestone ships already covers what a future `requests.returned_to_sender.v1` would need. |
| `assign_request` | **Implemented** — `requests.assigned.v1` | Legacy recipient: `[userId]`, conditional on a non-null assignee — mirrored exactly. |
| `receive_and_route_request` | Not directly wired | Composed RPC; nested `PERFORM route_request()`/`assign_request()` calls automatically propagate their own atomic enqueue in the same transaction — see §"Composed commands" below for the resulting fan-out and its one documented limitation. |
| `close_request` | Deferred | Legacy recipient (`sectionUserIds(from_section_id)` **union** `created_by`) needs the `task.completed.v1` multi-descriptor pattern; deferred together with `acknowledge_and_close` for the ~3–5 event budget, not an architecture gap. |
| `cancel_request` | Deferred | Legacy recipient is conditional on whether the request was ever routed (`section` vs `org_admins`) **and** on `reference_number` having ever been set. Both target kinds are already proven safe by `requests.routed.v1`/`requests.sent.v1`; deferred purely for scope. |
| `create_response` / `update_response_draft` | Deferred | Same reasoning as the request-side drafts. |
| `submit_response` | Deferred | Same reasoning as `submit_request`. |
| `approve_response` | **Implemented** — `requests.response_sent.v1` | Sole RPC that transitions a response to `'sent'` **and** the parent request to `'responded'` — the symmetric "sent" event on the response side, completing the bidirectional pair with `requests.sent.v1`. Legacy recipient: `[reqRow.created_by]`. |
| `return_response` | Deferred | Same `specific_users`shape as `requests.returned.v1`; deferred purely for the event budget. |
| `mark_response_received` | Deferred | No legacy notification fires at all. |
| `acknowledge_and_close` | Deferred | See `close_request` above. |

## `source_record_type`: `'request'` added, `'response'` deliberately NOT added

`requests.response_sent.v1` is produced by `approve_response()` — a
`responses`-table mutation — but its outbox event uses
`source_record_type='request'` / `source_record_id=<the PARENT request's id>`,
never a new `'response'` source type. This is deliberate, not an oversight:

1. `request-detail.js` already renders a response inline within its parent
   request's own page — there is no separate response detail route to
   deep-link to.
2. The only candidate for this event's target (`request.created_by`) is
   unconditionally covered by `intent_user_can_view_request()`'s own
   `r.created_by = p_user` branch — a second adapter would duplicate
   authorization the request adapter already provides for exactly this
   candidate, which the governing instruction explicitly discourages
   ("prefer reuse of existing request/response visibility helper logic; do
   not duplicate authorization unnecessarily").

No `'response'` source type is added to the closed dispatcher.

## `intent_user_can_view_request()`: generalization source and scope

A candidate-parameterized mirror of `requests_select`'s own `USING` clause
(`supabase/rls.sql`) — the exact same generalization pattern Phase
1.2/1.4/1.4A already used three times (`intent_user_can_view_workflow_instance`/
`_task`/`_meeting`). Requests visibility is spread across **four** additive
`SELECT` policies (`requests_select`, `requests_select_via_internal_collab`,
`requests_select_assigned_receiver`, `requests_select_cc`) — this adapter
mirrors only the first, core policy: the org-party check plus
`is_admin()`/`from_section_id`/`to_section_id`/`previous_section_id`/
`created_by`/`received_by`.

This narrower scope is **not a new decision invented for this milestone** —
it is the exact same scope decision the codebase's own pre-existing
`can_view_request_or_response()` helper (`supabase/rls.sql`, used by
`cc_recipients`' RLS policies) already makes: that function also mirrors
only the core policy, not the three additive ones.

**Known, evidenced, documented limitation**: every one of this milestone's
five events' target candidates (`org_admins(to_org_id)`, `section(to/
previous_section_id)`, `specific_users(assigned_to/created_by)`) is a subset
of what the core policy already authorizes in the ordinary case, but a
candidate visible ONLY via `requests_select_assigned_receiver`'s
default-receiving-section carve-out — e.g. a plain org supervisor on a
still-**unrouted** request — fails **closed** at CAP-003 resolution
(filtered from the new `user_notifications` channel), while the untouched
legacy `notifications` dual-write still reaches them exactly as it does
today. Proven directly (behavioral scenario 4): a plain Beta supervisor with
no section relationship to a still-unrouted request is legitimately resolved
as an `org_admins(to_org_id)` candidate but is correctly skipped
(`skipped_count=1`), while an `mcs_admin` in the same org is correctly
resolved and notified. This is fail-closed, safe behavior — never a security
issue — and is exactly why legacy coexistence (below) retains every legacy
write unconditionally.

## Bidirectionality

`requests.sent.v1` targets `org_admins(v_row.to_org_id)` — the request row's
own `to_org_id`, never a hard-coded "always org A"/"always org B"
assumption. `requests.response_sent.v1` targets
`specific_users(v_req.created_by)` — the parent request's own creator, who
by `requests_insert`'s own `WITH CHECK` always belongs to
`v_req.from_org_id`. Proven directly (behavioral scenario 21): the identical
`requests.sent.v1`/`requests.response_sent.v1` flow run with Organization
Beta as the sender and Organization Alpha as the receiver (reversed from
every other scenario) produces correct, symmetric events and recipients —
both events read `from_org_id`/`to_org_id`/`created_by` live off the actual
request row, never a fixed organization role, in either `approve_request()`
or `approve_response()`.

## Target mapping (no new target kinds)

- `requests.sent.v1`: `org_admins(to_org_id)`.
- `requests.returned.v1`: `specific_users(created_by)`.
- `requests.routed.v1`: `section(to_section_id)` — the just-routed-to
  section.
- `requests.assigned.v1`: `specific_users(assigned_to)`, conditional on a
  non-null assignee.
- `requests.response_sent.v1`: `specific_users(request.created_by)`.

All five reuse target kinds and their existing resolution SQL
(`org_supervisor_user_ids`/`section_user_ids`, both already called
unchanged by `resolve_notification_intent()` since Phase 1.2) verbatim.
`resolve_notification_intent()` gains exactly one new source-authorization
dispatch branch (`'request'` → `intent_user_can_view_request()`), following
the identical pattern Phase 1.4A added for `'meeting'`.
`create_notification_intent()` gains exactly one new allowed value in its
own independent `source_record_type` guard — a genuine, non-obvious finding
surfaced only by direct end-to-end testing against the local harness (see
§"Known non-obvious finding" below), not by static inspection alone.

## Idempotency

Each event's `idempotency_key` is the fresh `audit_logs.id` captured via
`RETURNING id INTO v_audit_id` at the exact moment of the real mutation —
never a timestamp, never invented. None of the five events needs a
multi-descriptor fan-out (unlike `task.completed.v1`), so no
deterministic-derivation (`md5(...)`) key is needed — the raw
`audit_logs.id` is used directly, exactly like `task.assigned.v1`/
`meetings.rescheduled.v1`/`meetings.cancelled.v1`'s own single-descriptor
precedent. Legitimate repeated occurrences (e.g. `assign_request()` called
again to reassign) each produce their own fresh `audit_logs` row and are
therefore their own legitimate, distinguishable occurrence — proven directly
(behavioral scenario 16 / concurrency scenario 2): two concurrent
`assign_request()` calls with different assignees both succeed serially,
producing two distinct, independently-idempotency-keyed occurrences, never
collapsed into one.

## Correlation/causation

Each mutation generates one fresh `gen_random_uuid()` `correlation_id` for
its own single enqueue call. `causation_id` is `NULL` for all five events,
identical to every prior CAP-003 producer's own precedent — no upstream
CAP-003 event caused these.

## Safe payload

`template_params` carries only structural identifiers: `request_id`,
`reference_number` (explicitly whitelisted by the governing instruction as
safe — "request ID, request number/reference"), from/to organization ids,
from/to section ids, assigned/actor user ids, `response_id`. **`subject` is
deliberately excluded from every payload** — docs/89 (the Phase 1.6A
source-of-truth for this table's own confidentiality posture) never
affirmatively confirms `subject` as non-confidential, so per the governing
instruction's own explicit fallback ("if even the subject/title may be
confidential, use a generic template without it"), this milestone treats it
conservatively as potentially sensitive and never copies it into
`notification_intents`/`user_notifications`. `body`, response `body`, and
every free-text comment parameter (`p_comment` on `approve_request`/
`return_request`/`approve_response`) are never read by any of the five new
enqueue call sites — proven directly (behavioral scenarios 1, 8, 18, each
passing a distinctive marker string through the free-text parameter and
asserting it never appears in the outbox payload). Frontend templates
(`js/data/notifications-api.js`) render generic text using only
`reference_number`, never a fetched subject/body.

## Legacy coexistence

No legacy `NotificationsAPI.notify()` call site in `js/data/requests-api.js`
is removed, altered, or suppressed by this milestone (the SQL patch is
pure-SQL; the JS frontend change is dedup/routing/templates only, described
below). For `requests.sent.v1`/`requests.routed.v1`, the CAP-003 target's
own resolution SQL is *the same function* the legacy call site already uses
(`org_supervisor_user_ids`/`section_user_ids`) — but
`intent_user_can_view_request()`'s own narrower late-authorization (see
above) means the two channels' recipient sets are not proven byte-for-byte
identical in every case, so per the governing instruction ("if exact
equivalence is NOT proven, retain the legacy write") every legacy write is
retained unconditionally for all five events.

### Frontend dedup extension (`js/data/notifications-api.js`)

`MIGRATED_EVENT_MAP` gained three new entries:

```js
new_request:    { cap003Type: ['requests.sent.v1', 'requests.routed.v1', 'requests.assigned.v1'], recordType: 'request' },
draft_returned: { cap003Type: 'requests.returned.v1',      recordType: 'request' },
new_response:   { cap003Type: 'requests.response_sent.v1', recordType: 'request' },
```

`new_request` is the first entry whose `cap003Type` is an **array** —
`js/data/requests-api.js` reuses the single legacy type `'new_request'` for
three structurally different transitions (`approveRequest`, `routeRequest`/
`receiveAndRoute`'s section branch, `assignRequest`/`receiveAndRoute`'s
assignee branch). `dedupeLegacyAgainstCap003()` was generalized to accept
either a string or an array for `cap003Type`; the existing `(record_id,
time-window)` matching still disambiguates correctly, since only ONE of the
three possible CAP-003 events is ever actually enqueued near a given legacy
row's own timestamp for a given request — proven directly (frontend
scenario "three legacy `new_request` rows on the SAME request each consume
their own distinct CAP-003 counterpart").

`draft_returned` and `new_response` are similarly reused by additional,
**not-migrated** call sites (`returnResponse`; `closeRequest`/
`acknowledgeAndClose`) — those legacy rows simply never find a
`requests.returned.v1`/`requests.response_sent.v1` match (since no such
CAP-003 event was ever enqueued for that request near that time) and
survive undeduped, exactly the same "no match, no suppression" safety the
pre-existing `meeting_updated` entry already relies on. Proven directly
(frontend scenarios covering `returnResponse`, `closeRequest`, and
`cancelRequest`'s own never-migrated `request_cancelled` type).

`NOTIFICATION_TEMPLATES` gained five new keys (`requests.sent`,
`requests.returned`, `requests.routed`, `requests.assigned`,
`requests.response_sent`) — all render generic text, `requests.sent`/
`requests.response_sent` additionally interpolating `reference_number`
only.

## Realtime/UI behavior

No new Realtime channel. Phase 1.5 already exposes CAP-003 notifications
generically through `user_notifications`; Requests events flow through the
existing subscription unchanged.

## Deep links

`CAP003_ROUTES` gained one new entry:

```js
request: recordId => ({ route: 'request-detail', params: { id: recordId } }),
```

`requests.response_sent.v1` also routes here (its `source_record_id` is
always the **parent request**, never a separate response id — see
§"`source_record_type`" above) — there is no `CAP003_ROUTES.response` entry,
by design. `RequestDetailView`'s own `getConversation()` call resolves to an
empty conversation when `requests_select` denies the row (the recursive walk
in `conversation_request_ids()`, `supabase/rls.sql`, runs under the
caller's own privileges and yields nothing past a step it cannot see) — so
the notification only ever supplies an id to navigate to, never a
substitute for Requests' own RLS.

## Late authorization / dynamic recipient resolution

Where a target is section-based (`requests.routed.v1`), current section
membership at **processing time** is used, never an enqueue-time snapshot —
proven directly (behavioral scenario 11 / concurrency scenario 5): a section
member deactivated between enqueue and worker processing receives nothing;
a genuine concurrent deactivation racing the worker's own resolution
produces 0 or 1 notifications, never a duplicate, both documented as
legitimate serial outcomes per docs/78 §7.2.

## Assignment events

`requests.assigned.v1` targets the specific assigned user alone
(`specific_users`), never the receiving section as a whole — matching the
legacy notification's own recipient set exactly (`assignRequest()` in
`js/data/requests-api.js` notifies only `[userId]`). No "also notify section
leadership" behavior was invented.

## Composed commands (`receive_and_route_request`) and the one documented limitation

`receive_and_route_request()` is not itself modified — it reaches its
effect entirely through nested `PERFORM mark_request_received()`/
`route_request()`/`assign_request()` calls inside the same transaction, so
each nested call's own atomic enqueue (if any) fires automatically. Two
proven behaviors:

- **No assignee** (behavioral scenario 13): only `requests.routed.v1`
  fires, via the nested `route_request()` call.
- **With an assignee** (behavioral scenario 17): **both**
  `requests.routed.v1` (to the whole section, via `route_request()`) and
  `requests.assigned.v1` (to the assignee, via `assign_request()`) fire.

This is a **documented, evidenced divergence** from legacy: `receiveAndRoute()`
in `js/data/requests-api.js` deliberately suppresses the section-wide legacy
broadcast when an assignee is chosen in the same step (`notifySection:
false`), notifying only the assignee. CAP-003, by construction (each RPC's
own enqueue is independent and has no visibility into a caller's later
steps), notifies both the whole section AND the assignee in this exact
composed case — a safe **over-notification**, never a dropped event, and the
same category of documented limitation Phase 1.4B's own
task_watchers/meeting_participants self-notification finding already
established as acceptable for this codebase's CAP-003 architecture. Not
worked around; reopening either RPC to suppress this would require the
producer to know about a *later* step in the same composed call, which none
of Phase 1.6A's 19 RPCs do today.

## Return-to-sender events

`requests.returned_to_sender.v1` (for `return_request_to_previous_section`)
was evaluated and **deferred**, purely for the ~3–5 event budget — see the
candidate inventory table. Its target shape (`section`) and authorization
adapter (`intent_user_can_view_request()`) are already fully proven safe by
`requests.routed.v1`; a future milestone could wire it the same way with no
further architecture work.

## Response events

`requests.response_sent.v1` is the only response-sourced event implemented.
It preserves the response's own approval cycle (fires once per genuine
`approve_response()` call, each with its own fresh `audit_logs.id`), never
treats the response body as payload, and targets the request's current
`created_by` — the actual repository relationship, not an invented one.

## Further Information

Unchanged from Phase 1.6A's own finding: no frontend implementation exists
for deadline extensions/Further Information commands. No new FI notification
producer was invented here.

## Worker genericity

`process_platform_outbox_batch()` is **not modified at all** by this
milestone — no new `NULLIF(...)` payload passthrough was needed (unlike
Phase 1.4A), since every target kind this milestone uses (`specific_users`,
`org_admins`, `section`) already existed since Phase 1.2. All five event
types are registered exactly like `task.assigned.v1`
(`uses_generic_notification_envelope = TRUE`), routing through the same
registry-driven generic passthrough path with zero worker code changes —
proven directly (performance dimension 7, draining 300 real Phase 1.6B
events through the unmodified worker entry point).

## Known non-obvious finding: `create_notification_intent()`'s own independent `source_record_type` guard

`create_notification_intent()` carries its own hardcoded
`source_record_type` allowlist, entirely separate from the table's own
`notification_intents_source_record_type_check` CHECK constraint. Adding
`'request'` to the CHECK constraint alone is **not sufficient** —
`create_notification_intent()`'s own guard also rejects any
`source_record_type` not in its literal list, independent of the table
constraint. This was found only by direct end-to-end testing against the
local harness (a real `approve_request()` → worker → `retry_scheduled`
outcome with `last_error = 'source_record_type request has no generic
authorization dispatch...'`), not by static inspection of the patch alone —
exactly the kind of gap the governing instruction's "do not reconstruct
function bodies from memory" / "prove it against the real code" discipline
exists to catch. Both the CHECK constraint and `create_notification_intent()`'s
own guard were updated together; the rollback restores both to their exact
Phase 1.4A form.

## SECURITY DEFINER / search_path

Every modified/new function pins `search_path = public, pg_temp`,
`intent_user_can_view_request()` is `REVOKE ALL ... FROM PUBLIC, anon,
authenticated` (internal-only, matching `intent_user_can_view_task()`/
`intent_user_can_view_meeting()`'s own posture — verified: `has_function_
privilege('authenticated', 'intent_user_can_view_request(uuid,uuid)',
'EXECUTE')` is `false`), and every actor is derived from `auth.uid()`, never
a client-supplied user id. The repository's 37 unrelated, pre-existing
SECURITY DEFINER `search_path` findings (reported in Phase 1.6A) are **not**
addressed here — out of scope, recorded only.

## RLS

No Requests, Responses, `user_notifications`, `notification_intents`, or
`platform_outbox_events` RLS policy was weakened. `requests`/`responses`
policy counts remain exactly 10/6 (Phase 1.6A's own byte-for-byte baseline).
No direct authenticated `INSERT` on `platform_outbox_events`/
`notification_intents` (RLS-enabled, zero policies — the real gate, not raw
table grants, per this repository's own established convention: the
disposable local harness's `01-grants.sql` blanket-grants
`INSERT`/`UPDATE`/`DELETE` to `authenticated` on all tables, mirroring real
Supabase's own default). No direct authenticated `EXECUTE` on
`process_platform_outbox_batch()`/`create_notification_intent()`/
`intent_user_can_view_request()`.

## Testing

- **Structural validator** (`validate-requests-notification-integration.sql`,
  12 checks): exactly the 5 approved event types registered
  (registry-driven); deferred candidates absent; `source_record_type` CHECK
  extended by exactly `'request'`; `create_notification_intent()`'s own
  independent guard also extended; `resolve_notification_intent()` gains
  exactly the one new dispatch branch, no event-type-specific/module-specific
  branch anywhere; `process_platform_outbox_batch()` completely untouched
  (textual scan for any `requests.*`/`'requests'` literal); exactly one new
  authorization adapter (`intent_user_can_view_request`, internal-only, no
  grant to `authenticated`/`anon`); each of the five producers' own
  `functiondef` contains the real atomic enqueue call, the correct
  event-type literal, an approved target type, no direct `user_notifications`
  write, and free-text fields excluded from the enqueue call site's own
  payload construction; `approve_response()` sourced from the parent request,
  never a `'response'` source type; Requests/Responses RLS policy counts and
  direct-write closure unchanged; no external-delivery/preferences objects;
  all 19 Phase 1.6A RPCs still present; Entry/Internal
  Collaboration/Prisoner Letters still not integrated; CAP-003 Phase 2 not
  started.
- **Behavioral** (21 scenarios, `test-requests-notification-integration.sql`):
  per-event outbox correctness (source identity, target descriptor, safe
  payload, subject/comment/body never leaked); domain-failure → zero outbox
  events (5 status-guard rejections tested); a forced
  `platform_enqueue_outbox_event()` failure (via a temporary function rename)
  rolls back the ENTIRE domain mutation (`requests.status`/`reference_number`/
  `is_locked`, the `approvals` row, and the `audit_logs` row) as one unit,
  with a normal call succeeding again once the dependency is restored; late
  authorization correctly skips a legitimate-but-unauthorized candidate
  while resolving an authorized one; cross-org (third-org) isolation; two
  full replay-idempotency proofs (intent-level and worker-level); the whole
  section is notified for `requests.routed.v1`; dynamic section-membership
  exclusion; the Phase 1.6A cross-org routing guard still rejects before
  reaching the enqueue; the composed `receive_and_route_request()` fan-out
  (with and without an assignee); unassignment fires no event; legitimate
  reassignment produces a second, distinguishable occurrence;
  `requests.response_sent.v1` sourced from the parent request with the
  response body/comment excluded; and the full bidirectional
  Alpha→Beta/Beta→Alpha proof.
- **RLS** (11 scenarios, `test-requests-notification-integration-rls.sql`):
  no direct `platform_outbox_events` insert bypassing `approve_request()`;
  no direct `create_notification_intent()`/`process_platform_outbox_batch()`/
  `intent_user_can_view_request()` invocation; `user_notifications` strictly
  recipient-scoped (positive and negative controls); a third-org user sees
  nothing; non-recipient cannot mark another user's notification read
  (positive control included); `requests_select` RLS completely unaffected
  (a third-org outsider still denied, a legitimate section member still
  allowed); Phase 1.6A's direct-write closure on `requests`/`responses`
  intact; `platform_event_type_registry` still admin-write-only despite 5
  new rows added via the migration itself.
- **Concurrency** (8 scenarios, genuine `dblink` multi-session,
  `test-requests-notification-integration-concurrency.sql`): two workers
  racing the same real `requests.sent.v1` event resolve exactly once; two
  concurrent `assign_request()` calls (two assignments) both succeed
  serially, each producing its own distinguishable occurrence;
  `approve_request()` vs `return_request()` racing the same
  `pending_approval` request are mutually exclusive via the pre-existing
  status guard (exactly one of the two events fires); two concurrent
  `approve_response()` calls (response submission race) — exactly one wins,
  exactly one event; a section-membership deactivation racing the worker's
  own resolution of a real `requests.routed.v1` event never duplicates (0 or
  1, both legitimate); a replayed `approve_request()` on an already-sent
  request is rejected by the pre-existing status guard, no duplicate event;
  an unrelated request proceeds independently throughout; no deadlock
  (explicit lock-table check after every dblink session cleanly
  disconnects).
- **Performance** (8 dimensions, 20,000+ historical Requests, 20,000+
  background outbox rows, 20,000+ background `user_notifications` rows,
  `test-requests-notification-integration-performance.sql`): `approve_request()`/
  `route_request()`/`assign_request()` atomic-enqueue overhead at scale (100
  calls each, well under bound); idempotency-key uniqueness lookup
  index-backed (`EXPLAIN ANALYZE BUFFERS`-verified — `Index Only Scan`, no
  sequential scan against 20,000+ rows); `intent_user_can_view_request()`
  authorization overhead measured directly (500 calls well under bound,
  `EXPLAIN`-verified); `section_user_ids()` target resolution remains
  index-backed; draining 300 real Phase 1.6B events via the unmodified
  worker entry point; the merged notification feed
  (`list_my_notifications()`) with 4,000+ Requests-sourced background rows
  for one recipient remains a fast, index-backed keyset page fetch. No
  speculative index added — every access path already had an adequate
  existing index.
- **Frontend** (21 scenarios, headless Chromium,
  `tests/requests-notification-integration-frontend.test.js`): the new
  `MIGRATED_EVENT_MAP` entries (including the array-valued `new_request`
  case); all three `new_request` sub-transitions each correctly matching
  their own distinct CAP-003 counterpart on the same request without
  cross-matching; non-migrated legacy rows (`returnToPreviousSection`,
  `returnResponse`, `closeRequest`, `cancelRequest`) never incorrectly
  suppressed; the five new render templates (safe text, `reference_number`
  interpolation only, no leaked extra payload fields); the new
  `CAP003_ROUTES.request` entry (and the explicit absence of a `.response`
  entry); Phase 1.4B/1.5's own task/meeting routes and dedup behavior
  unaffected; `js/data/requests-api.js` still has zero direct CAP-003/outbox
  references and every pre-existing legacy `NotificationsAPI.notify()` call
  site survives unchanged; zero page errors. All 35 pre-existing Phase 1.5
  frontend scenarios (`tests/notification-realtime-legacy-cutover-frontend.test.js`)
  re-verified passing unchanged against the modified `notifications-api.js`.

## Sibling structural-validator reconciliation

Extending the shared, closed `notification_intents_source_record_type_check`
CHECK constraint with `'request'` — and adding `intent_user_can_view_request()`
as a new authorization adapter — broke exact-literal pins in **eight** earlier
phases' own structural validators/tests, each of which had asserted (as of
its own completion) precisely which values/adapters existed and, in three
cases, used `'request'` itself as their own negative-control "still
genuinely unsupported" example literal. This is not a new pattern: several of
these same files already carried a near-identical carve-out comment from
Phase 1.4A's own earlier addition of `'meeting'` (e.g.
`test-notification-module-integration-foundation.sql`'s own scenario 18,
whose comment already documented swapping its example literal from
`'meeting'` to `'request'` for exactly this reason). Reconciling all eight,
each with a minimal, explained diff, was necessary to reach zero regression-sweep
failures and is part of this milestone's own change, not "unrelated code":

- `validate-notification-outbox-persistence-foundation.sql`,
  `validate-notification-outbox-worker.sql`,
  `validate-legacy-notification-search-path-hardening.sql`: each had a
  negative check hardcoding `'approve_request'`/`'route_request'` as
  placeholder examples of a hypothetical, not-yet-approved future module
  integration — updated to remove those two names from the negative list
  (their real, approved integration is now verified positively by this
  milestone's own validator instead).
- `validate-notification-module-integration-foundation.sql`,
  `validate-notification-target-expansion.sql`,
  `validate-task-meeting-notification-events.sql`: each pinned the
  `source_record_type` CHECK constraint's exact literal string — updated
  from an exact-equality assertion to a positive-membership assertion (each
  phase's own values must still be present), so a later phase's legitimate
  further extension no longer breaks an earlier phase's own pin.
  `validate-task-meeting-notification-events.sql` additionally pinned the
  exact set of authorization adapters that existed as of Phase 1.4B —
  extended to allow `intent_user_can_view_request` alongside its own three.
- `validate-requests-server-mutation-foundation.sql` (Phase 1.6A's own
  validator): asserted, as its own completion criterion, that **zero** of
  the 19 Requests RPCs integrated CAP-003 and that `platform_event_type_registry`
  had zero `owning_module='requests'` rows — both literally true at Phase
  1.6A's own completion, both now superseded by this milestone's own
  approved integration. Narrowed to assert only the 14 RPCs Phase 1.6B
  deliberately left alone still integrate nothing, and that the Requests
  event count is either 0 or exactly the 5 this milestone registers.
- `test-notification-module-integration-foundation.sql`,
  `test-notification-target-expansion.sql`,
  `test-notification-recipient-resolution.sql`: each used `'request'`
  (`source_record_type`) as its own negative-control example of a literal
  that "will never be supported," to prove the closed dispatcher rejects
  unknown types. Updated to use `'internal_collaboration_thread'` instead
  (Internal Collaboration CAP-003 integration remains genuinely deferred,
  per every CAP-003 phase's own explicit out-of-scope list) — the
  assertion itself (closed dispatch rejects every unsupported literal) is
  unchanged.

No test's actual security assertion was weakened by any of these eight
changes — each still proves exactly what it always proved (the closed
dispatcher rejects genuinely unsupported types; no undocumented module
integration exists), just against an example literal or a "known adapters"
list that correctly accounts for this milestone's own approved addition.

## Known, pre-existing, unrelated flaky test (not touched)

`test-workflow-sla-timer-dispatch-concurrency.sql` (CAP-002, Phase 5.4) was
observed to fail intermittently during the full regression sweep. This is
the **same test already documented as a pre-existing, timing-sensitive
flake** in an earlier phase of this project (see docs/87's own harness
notes) — confirmed again directly here: three consecutive isolated runs
against a freshly rebuilt baseline (no other suite's load in the same
process) produced pass/fail/pass, with the failure message itself a
dblink-timing race ("expected exactly one of two concurrent workers to
process the same due escalation level, got 2") entirely unrelated to
Requests, notifications, or any CAP-003 code this milestone touches. Per
the governing instruction's own "STOP and report separately, do not
silently repair unrelated code" directive, this was not modified. Every one
of this milestone's own four new suites (behavioral/RLS/concurrency/
performance) and every one of the eight reconciled sibling validators above
pass consistently and repeatedly across multiple full, freshly-rebuilt
regression sweeps.

## Rollback

`rollback-requests-notification-integration.sql` restores `approve_request()`/
`return_request()`/`route_request()`/`assign_request()`/`approve_response()`
to their **exact, byte-for-byte** pre-1.6B (Phase 1.6A) bodies, restores
`create_notification_intent()`/`resolve_notification_intent()` to their exact
Phase 1.4A bodies, drops `intent_user_can_view_request()`, restores the
`source_record_type` CHECK constraint to its exact Phase 1.4A form, and
removes the 5 event-type registry rows — refusing (raising, never silently
discarding evidence) if any `platform_outbox_events`/`notification_intents`/
`user_notifications` row still uses one of the 5 event types or
`source_record_type='request'`. `validate-requests-notification-integration-rollback.sql`
verifies all of the above plus that every Phase 1.0–1.5/1.6A object (all 19
Requests RPCs, direct-write closure, RLS policy counts, `task.assigned.v1`/
`task.completed.v1`/`meetings.rescheduled.v1`, both prior authorization
adapters) remains completely unaffected. Verified directly: rollback →
rollback-validator PASS → re-apply patch → structural-validator PASS, a full
round trip against the live local harness.

## Limitations

- Only five events, from two RPCs' worth of lifecycle stages (send, return,
  route, assign, respond-and-send), are wired. `requests.submitted.v1`,
  `requests.received.v1`, `requests.returned_to_sender.v1`,
  `requests.closed.v1`, `requests.cancelled.v1`,
  `requests.response_submitted.v1`, `requests.response_returned.v1`,
  `requests.response_received.v1` all remain deferred, each with a
  documented, specific reason (see the candidate inventory table) — none
  worked around.
- `intent_user_can_view_request()` mirrors only `requests_select`'s core
  policy, not the three additive ones (`requests_select_via_internal_collab`,
  `requests_select_assigned_receiver`, `requests_select_cc`) — a documented,
  evidenced, fail-closed gap covered by retained legacy coexistence (see
  above), matching the codebase's own pre-existing `can_view_request_or_
  response()` helper's identical scope decision.
- `receive_and_route_request()` with an assignee produces a documented
  over-notification (both `requests.routed.v1` to the whole section and
  `requests.assigned.v1` to the assignee) relative to legacy's own
  section-broadcast suppression in that exact composed case — never a
  dropped or duplicated event, not a security issue.
- Requests, Entry, Internal Collaboration, and Prisoner Letters modules
  besides Requests itself remain deferred — Entry/Internal
  Collaboration/Prisoner Letters CAP-003 integration is unchanged from
  every prior CAP-003 phase's own finding.
- Deadline extensions/Further Information: no new business commands were
  invented; Phase 1.6A's own finding (no frontend implementation exists)
  is unchanged.
- CAP-002/SLA notification producers, email/push/SMS delivery, notification
  preferences, historical legacy-notification migration, and a broader
  Requests UI redesign are all explicitly out of scope, matching every prior
  CAP-003 phase.
- The repository's 37 unrelated, pre-existing SECURITY DEFINER `search_path`
  findings (Phase 1.6A) are not addressed here.
- CAP-003 Phase 2 has not started.
