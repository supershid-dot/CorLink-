# CAP-003 Phase 1.6A — Requests Server-Authoritative Mutation Foundation

## Status

Implemented. Every business mutation in the Requests & Responses lifecycle now
goes through a focused, SECURITY DEFINER RPC that independently enforces
authorization, validates state transitions, and — where the previous
client-side composition was genuinely non-atomic — commits multiple related
writes as one transaction. Direct client `INSERT`/`UPDATE` on `requests` and
`responses` is revoked from `authenticated`. RLS on both tables is completely
unchanged. No Requests CAP-003 event is enqueued and no legacy notification
recipient/behavior changed — this is the mutation-boundary migration only.

## 1. Existing mutation inventory, before any change

A repository-wide search (`.insert(`/`.update(`/`.delete(`/`.upsert(` against
`requests`-family tables) confirmed every direct write against `requests`,
`responses`, and `approvals` was confined to `js/data/requests-api.js` — no
view file wrote to these tables directly. 19 distinct business commands were
found:

| Command | Table(s) | Notes |
|---|---|---|
| `createRequest` | `requests` INSERT | |
| `updateRequestDraft` | `requests` UPDATE | **arbitrary JSON patch** — see §2 |
| `submitRequest` | `requests` UPDATE | |
| `approveRequest` | `requests` UPDATE + `approvals` INSERT | two separate calls |
| `returnRequest` | `requests` UPDATE + `approvals` INSERT | two separate calls |
| `markRequestReceived` | `requests` UPDATE | |
| `routeRequest` | `requests` UPDATE | |
| `returnToPreviousSection` | `requests` UPDATE | client-supplied target section |
| `assignRequest` | `requests` UPDATE | |
| `receiveAndRoute` | composed (2–3 calls) | **non-atomic** — see §2 |
| `closeRequest` | `requests` UPDATE | |
| `cancelRequest` | `requests` UPDATE | |
| `createResponse` | `responses` INSERT | |
| `updateResponseDraft` | `responses` UPDATE | **arbitrary JSON patch** |
| `submitResponse` | `responses` UPDATE | |
| `approveResponse` | `responses` UPDATE + `approvals` INSERT + `requests` UPDATE | **three separate calls, non-atomic** |
| `returnResponse` | `responses` UPDATE + `approvals` INSERT | two separate calls |
| `markResponseReceived` | `responses` UPDATE | |
| `acknowledgeAndClose` | composed (2 calls) | **non-atomic** |

`cc_recipients` (CC/loop-in) and `review_comments` (supervisor draft
feedback) have their own dedicated, already-RLS-gated APIs
(`js/data/cc-recipients-api.js`, `js/data/review-comments-api.js`) — auxiliary
collaboration/annotation features layered onto the core lifecycle, not
lifecycle state transitions themselves, and never named in this milestone's
own command examples. **Deferred, not migrated** (see §15).

`attachments` uses a shared, generic, already-abstracted API used across many
modules (Requests, Tasks, Prisoner Letters, …), not a Requests-specific
mutation. **Deferred, not migrated** per the explicit instruction not to
redesign attachment storage in this milestone.

`deadline_extensions` has a real table (`schema.sql`) and a real
`audit_logs.action` vocabulary (`extension_requested`/`extension_approved`/
`extension_denied`), but **zero frontend implementation anywhere** — no
`.insert()`/`.update()`, no UI. There is nothing to migrate. **Deferred**, not
invented.

No "Further Information Request" table or dedicated mutation exists —
follow-up rounds are modeled as a new `requests` row chained via
`parent_request_id`, walked by the existing `conversation_request_ids()` RPC.
`createRequest` already carries this; no separate command was needed.

## 2. Two genuine architecture gaps found, and used as the justification for atomic RPCs

- **`updateRequestDraft`/`updateResponseDraft` accepted an arbitrary JSON
  patch object**, restricted only by RLS's row-level `WITH CHECK` (creator,
  unlocked, draft/pending_approval) — RLS does not restrict *which columns*
  change, so a client could in principle set `from_org_id`, `created_by`,
  `status`, `is_locked`, or `reference_number` directly as long as the
  post-update row still satisfied the row-level check. `update_request_draft`/
  `update_response_draft` now take **explicit, named parameters only**
  (subject/subject_language/body/language/deadline; body/language) — never a
  generic `update_request(any_json)` — closing this gap.
- **Three composed client-side actions were genuinely non-atomic**:
  `receiveAndRoute` (up to 3 separate network calls), `approveResponse`
  (2 separate table updates across `responses` and `requests`), and
  `acknowledgeAndClose` (2 separate calls). A failure partway through any of
  these could leave a request received-but-unrouted, a response marked
  `sent` with its parent request never advancing, or similar partial states.
  `receive_and_route_request()` and `acknowledge_and_close()` are now single
  atomic RPCs; `approve_response()` folds all three of its writes (responses
  status/lock/reference-number, `approvals` row, `requests.status =
  'responded'`) into one transaction.

## 3. The real requests/responses state machine (discovered, not invented)

`schema.sql` already carries `check_request_status`/`check_response_status`
triggers (`valid_request_status_transition()`/`valid_response_status_
transition()`) that enforce the true transition graph on every `UPDATE OF
status`, regardless of caller — this predates the migration entirely and was
initially under-credited in one of this patch's own comments (`close_request`
originally said "no status-transition guard… preserved exactly," discovered
to be inaccurate while writing this milestone's own concurrency test: a race
that tried to close a request from `in_progress` correctly failed against
the trigger with `Invalid request status transition: in_progress -> closed`,
because only `('responded', 'closed')` is a legal edge). The comment was
corrected; no code changed — the trigger already governs every RPC exactly
as it already governed the direct client writes.

```
requests:  draft -> pending_approval -> sent -> received -> in_progress -> responded -> closed
                        |         \-> overdue (from any of the middle 4)
           pending_approval -> draft (returned)
           sent/received/in_progress/overdue -> cancelled
responses: draft -> pending_approval -> sent
           pending_approval -> draft (returned)
```

No conflicting/contradictory transition was found — the trigger's own
allow-list is closed and consistent. No STOP condition was reached.

## 4. Commands migrated (19)

`create_request`, `update_request_draft`, `submit_request`, `approve_request`,
`return_request`, `mark_request_received`, `route_request`,
`return_request_to_previous_section`, `assign_request`,
`receive_and_route_request`, `close_request`, `cancel_request`,
`create_response`, `update_response_draft`, `submit_response`,
`approve_response`, `return_response`, `mark_response_received`,
`acknowledge_and_close` — every evidenced mutation, no more, no fewer.

## 5. Commands deferred (and why)

- CC recipients / review comments — auxiliary collaboration features, own
  existing RLS-gated APIs, never named as core lifecycle commands.
- Attachments — shared generic API across modules, explicit instruction not
  to redesign storage.
- Deadline extensions — zero existing frontend implementation to migrate.
- Further Information — no dedicated data model exists; already served by
  `createRequest`'s `parentRequestId` chaining.

## 6. Authorization model

Every RPC restates its authorization check explicitly (SECURITY DEFINER
bypasses RLS, so nothing here relies on RLS firing underneath the function) —
transcribed directly from the corresponding `rls.sql` policy
(`requests_update`, `requests_update_supervisor`, `requests_update_cancel`,
`requests_update_assigned_receiver`, `requests_update_section_receiver`,
`responses_update`, `responses_update_supervisor`, `responses_update_
assigned_receiver`, `responses_insert`, `approvals_insert`), never a parallel
permission system. The actor is always `auth.uid()`, derived server-side —
never a client-supplied identity.

Two deliberate deviations, both narrowing (never loosening) the surface:

1. **`route_request`/`receive_and_route_request` now validate that
   `to_section_id` actually belongs to the request's own `to_org_id`.**
   Today's RLS checks the *actor's* org membership but never that the
   *target section* resolves to the same organization — a data-integrity
   gap (never a visibility leak, since `requests_select` independently
   requires org membership), closed as a natural byproduct of writing
   explicit server-side validation.
2. **`create_request` no longer accepts `from_org_id` as a parameter at
   all** (derived from `get_my_org_id()`), and **`approve_request`/
   `return_request_to_previous_section` no longer accept a client-supplied
   `from_section_id`/`previous_section_id`** — both are now read from the
   row itself. This removes the class of "client-provided organization/
   section identity" risk entirely rather than merely re-validating it.

## 7. Bidirectionality

No organization is hard-coded anywhere (asserted directly by the structural
validator: no literal UUID, no `MCS`/`HRCM` string in any of the 19 function
bodies). Every command derives its authorization/target from the request
row's own `from_org_id`/`to_org_id`/`from_section_id`/`to_section_id`, or
from the caller's own `get_my_org_id()`/`my_section_ids()`. The behavioral
suite proves the full lifecycle (create → submit → approve → receive → route
→ assign → respond → approve-response → acknowledge-and-close) end-to-end in
**both directions** with generic "Org Alpha"/"Org Beta" fixtures — neither
side is reply-only (TEST 13/14).

## 8. Routing / return-to-sender

`route_request` validates the target section's organization server-side
(§6.1). `return_request_to_previous_section` derives the target from the
request's own `previous_section_id` (trigger-maintained by
`trigger_track_previous_section`, unmodified) rather than a client-supplied
value — the same request row, never a new id (TEST 18).

## 9. Responses / conversation continuity

Multi-round-trip cases remain modeled as chained `requests` rows via
`parent_request_id` (unchanged); `responses` keeps its own table and ids.
No response cycle is collapsed into a single mutable field; each
`createResponse` call still produces a distinct row.

## 10. Deadlines / extensions

Unimplemented in the frontend today (§1) — deferred, not built here. No
automatic SLA behavior is added; CAP-002 SLA integration remains separate.

## 11. Audit / history

Every RPC writes to the pre-existing `audit_logs` table using the same
action vocabulary the legacy JS already used (`created`, `edited`,
`submitted`, `approved`, `returned`, `received`, `routed`, `assigned`,
`returned_to_sender`, `cancelled`) — no new history mechanism invented.
`js/data/requests-api.js`'s own `logAudit()` helper and every direct
`audit_logs`/`approvals` insert were removed from the frontend, since
duplicating them client-side would double-write history the RPC already
writes atomically.

## 12. Idempotency / concurrency

No new `lock_version` column or idempotency-key infrastructure. Every
transition's `UPDATE ... WHERE id = ... AND <expected prior state>` guard is
reused directly from this repository's existing Task/Workflow RPC
convention (guarded UPDATE, `RAISE` on zero rows) — a retried call after
success finds the row no longer in the expected state and is rejected, not
silently double-applied. Proven directly: 8 concurrency scenarios
(`test-requests-server-mutation-foundation-concurrency.sql`, dblink-based,
genuinely independent sessions) — concurrent `approve_request` (exactly one
wins), `route_request` vs `return_request_to_previous_section` (serialize,
self-consistent), concurrent `create_response` (independent, no
interference), concurrent `close_request` after `responded` (safe no-op
convergence), duplicate `submit_request` replay (rejected), concurrent
`assign_request` (no lost update), unrelated requests (no cross-contention),
and a crossed-lock-order two-row approval chain (no deadlock).

## 13. Transactional atomicity

`approve_request`, `approve_response`, `receive_and_route_request`, and
`acknowledge_and_close` each commit multiple related writes (domain state +
`approvals` + `audit_logs`, or a full receive→route→assign chain) as one
PL/pgSQL function body — one transaction. Forced-failure rollback is proven
directly: behavioral TEST 16 fires an invalid `receive_and_route_request`
call mid-chain and asserts the request's `to_section_id`/`status`/
`assigned_to` are byte-for-byte unchanged afterward (no partial state).

## 14. Frontend migration

`js/data/requests-api.js`'s entire mutation section now calls its RPC
instead of a direct table write. Two call sites in `js/views/request-detail.
js` were updated for the two intentionally-narrowed signatures
(`approveRequest(id, comment)`, `returnToPreviousSection(id, comment)`);
every other call site (`receiveAndRoute`, `acknowledgeAndClose`,
`createRequest`, etc.) needed no change — their existing argument shapes
already matched what the new RPC-backed functions still accept.
Legacy-notification calls (`NotificationsAPI.notify()`) are unchanged
everywhere.

## 15. Direct-write elimination

`patch-requests-server-mutation-foundation.sql`'s final statement:
`REVOKE INSERT, UPDATE ON TABLE requests, responses FROM authenticated`.
Confirmed structurally (`validate-requests-server-mutation-foundation.sql`)
and behaviorally (`test-requests-server-mutation-foundation-rls.sql`,
TESTs 3–6: a direct client `INSERT`/`UPDATE` against either table now fails
with `insufficient_privilege`, even from the row's own creator). `SELECT`
remains granted — every read (list/detail/timeline) is unmigrated by design.
`internal_requests` (Internal Collaboration) direct writes are proven
unaffected (RLS TEST 11).

## 16. Security / RLS

No RLS policy was created, altered, or dropped — `requests`/`responses`
retain their exact pre-1.6A policy count and text (asserted by both the
structural and rollback validators). `deadline_extensions`,
`internal_requests`, `external_correspondence`, `prisoner_letters` are
completely untouched. No new SECURITY DEFINER function skips search_path
pinning, PUBLIC/anon revocation, or `authenticated`-only granting (asserted
per-function by the structural validator). The repository-wide
`validate-security-definer-search-path.sql` was also run: **all 19 new
functions are correctly hardened**; it separately reported **37 pre-existing,
unrelated functions across other modules** (`get_my_org_id`, `is_admin`,
`has_role_in_section`, `generate_reference_number`, entry/prisoner-letters
helpers, module-enablement helpers, etc.) that predate this milestone and
were never in its scope — reported here as a discovered protected-baseline
finding, not silently fixed (see §20).

## 17. Performance

`test-requests-server-mutation-foundation-performance.sql`, 5,000 background
requests / 3,000 background responses / 200 organizations for realistic
selectivity: `create_request` 2.7–3.5ms, `approve_request` (the atomic
5-write command) 2.5–3.0ms, `receive_and_route_request` (the atomic 2-step
composed command) 3.2ms, a bounded 50-row inbox-style list ~60–65ms, an
unrouted-inbox-style status-filtered query confirmed via `EXPLAIN` to use a
`Bitmap Heap Scan` (not `Seq Scan`) at 5,000-row scale, and a case-timeline
`audit_logs` lookup well under its bound. No sequential scan, no N+1, no
speculative index added.

## 18. Rollback

`supabase/rollback-requests-server-mutation-foundation.sql` drops all 19
RPCs and restores direct `INSERT`/`UPDATE` grants on `requests`/`responses`
to `authenticated` — the complete DB-side reversal, since the patch never
touched RLS, added a column, or added a constraint (no CASCADE risk, no
refuse-case). `supabase/validate-requests-server-mutation-foundation-
rollback.sql` confirms function removal, grant restoration, exact
policy-count parity, and CAP-002/CAP-003 baseline integrity. Verified
end-to-end: rollback → rollback-validator → reapply-patch →
structural-validator, all clean. Frontend rollback
(`js/data/requests-api.js`, `js/views/request-detail.js`) is a plain
git-revert of this milestone's commit (no frontend versioning system exists
in this repository) — applied together with the SQL rollback, not
independently (a frontend-only revert without the SQL rollback would call
RPCs that no longer have grants; an SQL-only rollback without the frontend
revert would leave the frontend calling RPCs that no longer exist).

## 19. Testing

- `supabase/validate-requests-server-mutation-foundation.sql` — structural.
- `supabase/test-requests-server-mutation-foundation.sql` — 23 behavioral
  scenarios (full lifecycle both directions, atomicity, replay rejection,
  authorization denial, column-safety, return-to-sender, cancel/return/
  response cycles, cross-org rejection).
- `supabase/test-requests-server-mutation-foundation-rls.sql` — 11 scenarios
  (SELECT-side RLS unchanged, direct-write elimination, unauthenticated
  rejection, unrelated-module non-interference).
- `supabase/test-requests-server-mutation-foundation-concurrency.sql` — 8
  dblink-based genuine-race scenarios.
- `supabase/test-requests-server-mutation-foundation-performance.sql` — 6
  probes at 5,000+/3,000+ row scale.
- `tests/requests-server-mutation-foundation-frontend.test.js` — 14 source-
  marker checks proving the frontend migration itself (every command calls
  its RPC, no direct write verb remains, the two narrowed signatures are
  enforced at both the API layer and its call sites, composed commands call
  one RPC not several, legacy notifications untouched).
- `supabase/test-request-task-integration.sql` — TEST 9's raw
  `UPDATE requests SET status = 'cancelled'` (now rejected by the grant
  revocation) was updated to call `cancel_request()` instead, preserving the
  same test intent through the new authoritative path.

## 20. Known limitations / deferred items

- CC recipients, review comments, attachments, deadline extensions, and
  Further Information cycles remain on their existing paths (§1/§5) —
  none needed migration for the reasons given.
- `close_request` has no independent status guard in application code —
  correctly relies on the pre-existing `check_request_status` trigger,
  which already only permits `responded -> closed` (§3); documented here so
  a future reader doesn't rediscover this the hard way.
- **37 pre-existing SECURITY DEFINER functions across unrelated modules
  lack a pinned `search_path`** (§16) — a genuine, protected-baseline
  finding, entirely outside this milestone's scope (none of the 37 are
  Requests functions; none were touched or introduced by this patch).
  Reported here, not silently fixed.
- A user with more than 100 unread notifications across sources is
  unrelated to this milestone (CAP-003 Phase 1.5's own limitation) —
  restated here only because it's the same repository, not because
  Phase 1.6A touches it.

## 21. Explicitly out of scope (unchanged by this milestone)

No Requests CAP-003 event producer, no Requests Realtime/notification
changes, no legacy-notification cutover for Requests, no Entry mutation
migration, no Internal Collaboration mutation migration, no Prisoner Letters
mutation migration, no new CAP-002 workflow behavior, no digital signatures,
no email/push/SMS, no notification preferences, no broad Requests UI
redesign. Phase 1.6B (CAP-003 Requests event integration) remains a future
milestone, gated on this mutation boundary existing first.
