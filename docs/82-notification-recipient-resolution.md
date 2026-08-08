# CAP-003 Phase 1.2 — Notification Recipient Resolution & Authorization-Safe Intent Creation

## Status

This is CAP-003's second implementation milestone, per docs/78 §25's own phasing. It implements
docs/78 §6–§8's recipient-targeting-and-resolution layer, narrowed to the six generic target
kinds whose membership/authorization semantics are already unambiguous in this repository (see
"Deviations" below). No worker, no module integration, no legacy cutover — Phase 1.1's
"inert foundation" mandate continues here: this milestone adds the resolution *primitive*, not
anything that calls it in production yet.

## Scope

Implements docs/78 §25's Phase 1.2 line item: recipient targeting/resolution (§7) and
processing-time authorization revalidation (§8), reusing existing visibility helpers rather than
inventing a parallel permission system. Phase 1.1's `platform_outbox_events`/`user_notifications`
(docs/81), CAP-003 1.0A/1.0B's legacy `notifications` fixes (docs/79, docs/80), and every CAP-002
object are completely untouched — this milestone is purely additive.

## Notification intents — a deliberate reconsideration of docs/78 §6

docs/78 §6 originally deferred persisting notification intent as its own table, reasoning that
the outbox event row and the resulting `user_notification` rows already carry everything the
intent represents, "unless a genuine need for standalone intent auditing... emerges." This
milestone found that need and persists `notification_intents` as a real table:

- **Idempotent resolution requires a lockable row.** `resolve_notification_intent()` takes
  `FOR UPDATE` on the intent row so a concurrent resolver blocks and then observes the
  already-recorded terminal `status` rather than double-processing (verified directly —
  concurrency suite scenario 1). Neither `platform_outbox_events` nor `user_notifications` can
  serve as that lock target: the outbox event has no per-target-descriptor status field, and
  `user_notifications` rows don't exist yet until resolution actually succeeds.
- **One outbox event can fan out to more than one target descriptor.** A single event might
  need both a `workflow_participants` intent and a `section` intent (e.g. participants plus a
  supervising section). Deduplicating "this event already has an intent for this exact target
  descriptor" needs an identity distinct from the event itself — `UNIQUE (outbox_event_id,
  target_type, target_key)`.
- **Resolution outcome (`resolved_count`/`skipped_count`/`status`) is itself durable evidence**
  distinct from any individual `user_notification` row — it's the record of the *decision*, not
  any one recipient's outcome.

This is recorded here, in docs/82, exactly as docs/78 §6 anticipated ("a future phase may
reconsider this"), not as a silent departure. `validate-legacy-notification-record-authorization-
fix.sql` (1.0B's own validator) has been updated to stop asserting `notification_intents`' absence
now that this milestone has shipped, matching the carve-out it already had for Phase 1.1's tables.

## Target descriptor vocabulary — narrowed from docs/78 §7.1

docs/78 §7.1's full vocabulary has 14 target kinds, including several (`department_leadership`,
`command_leadership`, `org_role`, `task_assignees`, `task_watchers`, `meeting_participants`,
`record_owner`, `dynamic`) whose membership/authorization semantics depend on a specific source
module's own data model — Requests, Entry, Internal Collaboration, Prisoner Letters, Tasks, and
Meetings all remain deferred to their own Phase 1.4 module adapters (docs/78 §25). This milestone
implements exactly six target kinds, each generically resolvable today without a module-specific
adapter:

| `target_type` | Candidate resolution | Reuses |
|---|---|---|
| `specific_users` | The caller-supplied, bounded (≤50) user-id array itself | — |
| `org_admins` | Organization's admin users | `org_supervisor_user_ids()` |
| `section` | Section membership | `section_user_ids(section_id, NULL)` |
| `section_leadership` | Section supervisors/admins only | `section_user_ids(section_id, ARRAY['mcs_admin','authority_admin','supervisor'])` |
| `workflow_participants` | Active (`ended_at IS NULL`) participants of a CAP-002 workflow instance | `workflow_participants` directly |
| `work_item_assignee` | The single assignee of a CAP-002 work item | `workflow_work_items.assigned_to` |

`specific_user(user_id)` (singular) from docs/78 §7.1 is subsumed by `specific_users` (a
single-element array) rather than implemented as a separate branch — no informational gain from
a second code path for the same case. Every other omitted target kind is rejected structurally:
the `target_type` `CHECK` constraint is a closed allowlist, so an unsupported kind fails at
`create_notification_intent()` call time with a clear error, never silently accepted and later
producing zero recipients.

## Source-record authorization dispatch — closed, two source types

Structural, never dynamic SQL: exactly two `source_record_type` values are supported —
**`workflow_instance`** (CAP-002's own participant model, the only source module whose visibility
semantics are already unambiguous and generically resolvable — `can_view_workflow_instance()`
generalized to an explicit candidate user as `intent_user_can_view_workflow_instance(instance_id,
user_id)`) and **`platform`** (no confidential source record at all, e.g. a system-wide notice —
authorization reduces to "recipient is active"). Any other `source_record_type` is rejected at
intent **creation** time (`create_notification_intent()`), closed-allowlist, never faked at
resolution time — matching docs/78 §7.3/§8's "resolving candidates is never itself an
authorization decision" principle at the dispatch level too. Requests, Entry, Internal
Collaboration, Prisoner Letters, Tasks, and Meetings all remain deferred to Phase 1.4's own
module-specific authorization adapters.

## `notification_intents` schema

`id, outbox_event_id NOT NULL REFERENCES platform_outbox_events(id), organization_id,
notification_type` (same `<module>.<event>.v<n>` family as Phase 1.1), `title_template_key,
template_params` (bounded ≤4096 bytes, `jsonb_typeof = 'object'`), `source_module,
source_record_type` (closed 2-value `CHECK`), `source_record_id, priority` (same 4-value `CHECK`
as Phase 1.1), `target_type` (closed 6-value `CHECK`), one populated `target_*` column per
descriptor kind (`target_user_ids UUID[]`, `target_organization_id`, `target_section_id`,
`target_workflow_instance_id`, `target_work_item_id`), `target_key TEXT` (the deterministic
dedup identity — sorted comma-joined ids for `specific_users`, the bare id text for every
single-id kind), `status` (`pending`/`resolved`/`partially_resolved`/`failed`), `resolved_at,
resolved_count, skipped_count, created_at`.

Two structural `CHECK` constraints enforce shape, not convention:

- **`notification_intents_target_shape_check`** — exactly one `target_*` column populated,
  matching `target_type`. A `specific_users` intent can never also carry a
  `target_workflow_instance_id`, etc.
- **`notification_intents_target_user_ids_bounded`** — `array_length(target_user_ids,1) <= 50`
  for `specific_users`, closing the "user-controlled arbitrary recipient expansion" risk the
  governing instruction calls out — never an unlimited caller-supplied fan-out.

## Business-fact immutability

Same column-diff `BEFORE UPDATE` trigger pattern Phase 1.1 established: every business-fact and
target-descriptor column is write-once; only `status`/`resolved_at`/`resolved_count`/
`skipped_count` are legitimately mutable (outcome-recording fields, written exactly once by
`resolve_notification_intent()` itself when it transitions the row out of `pending`).

## RLS

Same posture as `platform_outbox_events` (docs/78 §17): RLS enabled, **zero policies** for
`authenticated`/`anon` — an internal platform object, never browsed directly by ordinary users.
`service_role` (`BYPASSRLS`) is the only role with real access.

## Internal creation and resolution boundaries

Two `SECURITY DEFINER`, pinned-`search_path` primitives, both granted to `service_role` only
(revoked from `PUBLIC`/`anon`/`authenticated`) — identical posture to Phase 1.1's own two
primitives:

- **`create_notification_intent(...)`** — every business-identity field (`organization_id`,
  `source_module`, `source_record_type`, `source_record_id`) is *derived* from the parent outbox
  event, never re-supplied and trusted from the caller, so the source reference is structurally
  valid by construction. Derives `target_key` deterministically per `target_type`, then inserts
  with `ON CONFLICT (outbox_event_id, target_type, target_key) DO NOTHING`, returning the
  existing id on a safe replay — identical idempotent-insert shape to Phase 1.1's two primitives.
- **`resolve_notification_intent(intent_id)`** — the synchronous primitive a future Phase 1.3
  worker will call, one intent at a time (**not** the worker itself — no claiming, no batching,
  no retry policy here). Locks the intent row (`FOR UPDATE`), no-ops idempotently if already
  non-`pending`, resolves the target descriptor to raw candidates (docs/78 §7.2 — candidates
  only, never itself an authorization decision), then for each candidate: checks
  `users.is_active`, revalidates current authorization via the closed source-type dispatcher
  (§8 above — late, against live state, never cached from intent-creation time), and on success
  calls Phase 1.1's own `platform_create_user_notification()` directly rather than duplicating
  its dedup/insert logic. Records `resolved`/`partially_resolved`/`failed` and the two counts,
  returns them. Never claims delivery — delivery is not a concept this function has any notion
  of.

## Testing

- **Structural validator**: hard-fails unless the closed target-type/source-type allowlists, the
  two structural shape/bound `CHECK` constraints, both dedup `UNIQUE` constraints (intent-level
  and Phase 1.1's own notification-level, confirmed still present), zero-policy RLS, the
  immutability trigger, both primitives' `SECURITY DEFINER`/pinned-`search_path`/
  `service_role`-only posture, genuine authorization-revalidation reuse (not merely claimed —
  scans the function body for the actual helper calls), and the Phase 1.1/1.0A/1.0B/CAP-002
  baselines are all still genuinely present. **PASSED.**
- **Behavioral suite** (20/20): intent creation across all six target types, enqueue-level dedup
  (repeat call returns the same id, no duplicate row), resolution producing the correct candidate
  set per target type, authorization revalidation correctly skipping an unauthorized/inactive
  candidate while still resolving the authorized rest (`partially_resolved`), a fully-unauthorized
  intent resolving to `failed`, idempotent re-resolution of an already-terminal intent, rejection
  of an unsupported `source_record_type` at creation time, rejection of a malformed/mismatched
  target descriptor, `user_notifications` rows created via the reused Phase 1.1 primitive with
  correct denormalized fields, `>50`-user `specific_users` rejected.
- **RLS suite** (9/9): `notification_intents` has zero policies and is unreadable/uninsertable by
  `authenticated`/`anon` directly, `service_role` path works, both primitives denied to ordinary
  roles, Phase 1.1's own `user_notifications`/`platform_outbox_events` RLS shapes unchanged,
  legacy `notifications` policies unchanged.
- **Concurrency suite** (8/8, real `dblink` sessions): two concurrent resolvers on the same intent
  (row lock forces sequential processing, second resolver observes the terminal status rather
  than re-resolving — no duplicate `user_notifications` rows), concurrent `create_notification_intent`
  calls for the same `(outbox_event_id, target_type, target_key)` racing safely to the same row,
  unrelated intents/organizations progressing independently, zero deadlocks.
- **Performance suite** (100,000 `notification_intents` / 200,000 `user_notifications` background
  volume, plus a realistic 501-candidate large-fan-out resolution): see table below.
- **Full regression sweep**: all CAP-002 phases, CAP-003 1.0A, 1.0B, and 1.1 suites, plus this
  milestone's own four new suites — zero failures.

### Performance (measured)

All dimensions use their intended index (verified via `EXPLAIN (ANALYZE, BUFFERS)`, zero
sequential scans) and complete well within bounds:

| Dimension | Result |
|---|---|
| Intent lookup by id (100,000-row table) | 0.40 ms |
| Intent dedup lookup (`UNIQUE`-backing index) | 0.18 ms, `Index Scan` |
| `resolve_notification_intent`, `section` target, 501 candidates, platform-sourced | 39.17 ms, 501 resolved / 0 skipped |
| `resolve_notification_intent`, `workflow_participants` target, 501 candidates, per-candidate `workflow_instance` revalidation | 50.51 ms, 501 resolved / 0 skipped |
| Per-candidate `workflow_participants` revalidation lookup (single candidate) | 0.018 ms, `Index Only Scan` on `idx_workflow_participants_user_active` |

## Rollback

`rollback-notification-recipient-resolution.sql` drops every object this patch created
(`resolve_notification_intent`, `create_notification_intent`, both authorization-revalidation
helpers, the immutability trigger and its function, `notification_intents` itself) in dependency
order, no `CASCADE`. It **refuses to run** if `notification_intents` already contains any row —
`DROP TABLE` would permanently destroy durable recipient-resolution evidence, and this rollback
exists for exact-rollback verification of the still-empty foundation, not as an operational
"undo" once real intents exist. Verified directly: the refusal path (populated table, real error,
rollback aborts with zero partial drops) and the clean path (empty table, rollback succeeds,
`validate-notification-recipient-resolution-rollback.sql` passes confirming every 1.2 object is
gone while Phase 1.1/1.0A/1.0B/CAP-002 baselines are all unaffected, and the patch reapplies
cleanly with the structural validator passing again).

## Limitations

- **No worker.** Nothing calls `resolve_notification_intent()` on a schedule or in response to a
  new outbox event yet — Phase 1.3.
- **No module integration.** Nothing in Requests/Meetings/Tasks/Entry/Prisoner Letters calls
  `create_notification_intent` — verified directly by the structural validator's own textual scan
  of every existing module RPC body — Phase 1.4.
- **Eight target kinds remain deferred**: `department_leadership`, `command_leadership`,
  `org_role`, `task_assignees`, `task_watchers`, `meeting_participants`, `record_owner`,
  `dynamic` — each needs its own module-specific authorization adapter (Phase 1.4).
- **No legacy cutover, no Realtime cutover, no delivery-channel adapters.** The legacy
  `notifications` table keeps serving every existing module unchanged — Phase 1.5/2.

**Worker processing, module integration, the remaining eight target kinds, and external delivery
all remain deferred to their own later CAP-003 phases** — nothing in this milestone begins any of
them.

## Deviations / architecture clarifications

The one substantive deviation from docs/78 as originally written is the `notification_intents`
table itself (§6, discussed above) — anticipated and pre-authorized by docs/78's own "a future
phase may reconsider this" language, not an undocumented departure. The target-descriptor
narrowing (six of docs/78 §7.1's fourteen kinds) and the two-value `source_record_type` dispatch
are both scoping decisions within docs/78's own explicit phasing (§25: module adapters are
Phase 1.4's concern), not redesigns of anything docs/78 fixes.
