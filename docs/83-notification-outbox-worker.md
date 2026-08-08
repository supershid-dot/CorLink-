# CAP-003 Phase 1.3 — Notification Outbox Worker, Retry & Dead-Letter Processing

## Status

This is CAP-003's third implementation milestone, per docs/78 §25's own phasing. It implements
the asynchronous processing foundation that moves `platform_outbox_events` through intent
creation/lookup, recipient resolution, and durable `user_notifications` materialization — the
direct architectural sibling of CAP-002 Phase 5.4's SLA timer dispatcher. No module
integration, no legacy cutover, no Realtime delivery, no email/push. Follows docs/78 and the
Phase 5.4 precedent without redesigning either; no architecture defect or missing contract was
found during implementation (see "Deviations" below for the one within-discretion scoping
decision this milestone had to make on its own).

## Scope

Implements docs/78 §25's Phase 1.3 line item: "Outbox worker: bounded-batch `SKIP LOCKED`
claiming, retry/backoff, dead-letter handling." Phase 1.1's `platform_outbox_events`/
`user_notifications` (docs/81), Phase 1.2's `notification_intents`/`create_notification_intent`/
`resolve_notification_intent` (docs/82), and CAP-003 1.0A/1.0B's legacy `notifications` fixes are
completely untouched — this milestone is purely additive, adding only new functions plus one
`platform_event_type_registry` row.

## Worker entry point

`process_platform_outbox_batch(p_limit INTEGER DEFAULT 25, p_worker_id TEXT DEFAULT NULL)` — the
single worker-facing entry point, `SECURITY DEFINER`, pinned `search_path`, granted to
`service_role` only (revoked from `PUBLIC`/`anon`/`authenticated`) — the identical posture every
other CAP-002/CAP-003 dispatcher entry point in this codebase already establishes.
`p_worker_id` is an opaque, caller-supplied label recorded in `claimed_by` for observability
only (defaults to the backend pid) — never an authorization input. Returns one row per
candidate examined (`event_id, event_type, outcome, intent_id, attempt_count, next_attempt_at,
final_status`) — the real evidence stays on `platform_outbox_events`' own already-existing
processing-state columns and on `notification_intents`/`user_notifications` themselves; no new
worker-log table was created.

## Batch limits

docs/78 §5.7/§13/§26 explicitly leaves the exact numeric bound to "the implementation phase."
This milestone reuses CAP-002 Phase 5.4's own already-established constant for consistency
across this codebase's two `SKIP LOCKED` dispatchers: **default 25, hard-clamped to `[1, 200]`
regardless of caller input** (`LEAST(GREATEST(...), 200)`, identical shape to
`process_workflow_sla_due_batch`'s own clamp). These are operational tuning constants, not
business rules.

## Claim model — `FOR UPDATE SKIP LOCKED`, no persisted lease

Candidate discovery (`platform_outbox_events_due_for_processing(p_limit)`, private/read-only,
`STABLE SQL`) is a plain, unlocked pre-filter using Phase 1.1's own partial index
(`idx_platform_outbox_events_pending`). Claiming happens per-candidate inside the processing
loop: `SELECT * FROM platform_outbox_events WHERE id = <candidate> FOR UPDATE SKIP LOCKED` —
never blocks; a row another in-flight batch already holds is simply skipped
(`skipped_locked`). Eligibility is **re-derived from the locked row**, never trusted from the
earlier non-locking candidate snapshot — a concurrent batch, or an operator replay/dead-letter
transition, may have changed the row's state since discovery.

`platform_outbox_events.status` already allows `'claimed'`/`'processing'` (Phase 1.1's own
`CHECK` constraint), but this milestone **never leaves a row durably in either state**. Every
candidate is claimed, processed to a terminal outcome, and written back to a terminal value
(`'pending'` again with incremented `attempt_count`/pushed-out `next_attempt_at`, `'completed'`,
or `'dead_letter'`) within the same per-item `BEGIN...EXCEPTION` block, inside the same outer
transaction that holds the row's lock. A row is therefore never visible to any other transaction
in a `'claimed'`/`'processing'` state at all — there is no persistent claim/lease to go stale, so
no stale-claim recovery machinery is needed. This is the simplest crash-safe design available
given transaction-scoped locking already provides the safety property lease machinery would
otherwise exist to provide. `claimed_by`/`claimed_at` are still written on every terminal
outcome, purely as operational telemetry (who/when last touched this row), never as a durable
ownership token anything reads to decide eligibility.

## Processing pipeline

For each claimed, eligible candidate:

1. Verify the event's `event_type` is the one shape this worker recognizes (see "Supported
   event shape" below) — otherwise raise a deterministic, safely-classified exception.
2. `create_notification_intent(...)` — **reused verbatim from Phase 1.2**, never duplicated.
   `organization_id`/`source_module`/`source_record_type`/`source_record_id` are derived from
   the outbox event row itself (Phase 1.2's own design); the notification-shape/target-
   descriptor fields (`notification_type`, `title_template_key`, `template_params`, `priority`,
   `target_type`, and the matching `target_*` field) are extracted from `payload`. Every field
   is validated by `create_notification_intent`'s own existing required-field checks and by
   `notification_intents`' own `CHECK` constraints — nothing here duplicates that validation.
3. `resolve_notification_intent(intent_id)` — **reused verbatim from Phase 1.2**. Candidate
   resolution + per-candidate authorization revalidation, idempotent (`FOR UPDATE` on the intent
   row).
4. Mark the outbox event `'completed'`, set `processed_at`, clear `last_error` — **regardless of
   `resolved_count`** (see "Zero-recipient outcome" below).

## Supported event shape (narrowed, within docs/78's own discretion)

docs/78 §25 explicitly defers real per-module event-type mappings to Phase 1.4 ("module
integration foundation... adopted by one pilot module"). Since no production module enqueues
real business events yet, this worker recognizes exactly **one** generic, worker-processable
`event_type` — **`platform.generic_notification_request.v1`** — whose `payload` directly carries
the exact parameters `create_notification_intent()` needs, narrowed to Phase 1.2's own six
supported target kinds. This is registered as one `platform_event_type_registry` row
(`owning_module='platform'`, `is_mandatory=FALSE`, `requires_acknowledgement=FALSE`) — a generic
passthrough envelope, not a module-specific business-event mapping. It invents no new
business-event vocabulary and duplicates no validation. Any other `event_type` is "not yet
supported" by this worker and is rejected deterministically through the same bounded
retry/dead-letter machinery described below — Phase 1.4's own module adapters will each register
their own concrete `event_type` and extend this worker's dispatch, not broadened here merely to
look more useful.

## Processing states

Uses exactly the state model Phase 1.1 already established (`pending`, `claimed`, `processing`,
`completed`, `failed`, `dead_letter`) — no second worker-state system was invented. This
milestone exercises `pending`, `completed`, and `dead_letter`; `claimed`/`processing` remain
reserved/unused (see "Claim model" above — this milestone's transaction-scoped design has no
need for a durably-visible intermediate state); `failed` (Phase 1.1's own enum value) is likewise
unused by this milestone's design, since every failure this worker can classify is retryable up
to the bound, then `dead_letter` — never a separate terminal `'failed'` resting state distinct
from `dead_letter`.

## Retry model

**Uniform, not two-tier.** Every failure — an unsupported event type, a malformed/out-of-range
payload, a target reference not yet available, a genuine resolver exception — is routed through
the *same* bounded retry/dead-letter mechanism: `attempt_count` increments by 1, `next_attempt_at`
advances by the deterministic backoff below, and once `attempt_count` reaches the terminal
threshold the event transitions to `dead_letter`. This is a deliberate simplification within
docs/78's own discretion (§5.8/§15 leave exact policy open): inventing a second "immediately
terminal vs. genuinely retryable" state axis would be a second worker-state system the governing
instruction warns against, and "do not retry forever on deterministic invalid data" is already
satisfied by the shared attempt cap applying uniformly — a permanently-unsupported event type
simply exhausts its bounded attempts and dead-letters exactly as a poison event would. The
distinguishing signal for operators is the stored `last_error` classification text (e.g.
`unsupported_event_type: ...`), not a different state-transition path.

- **Terminal attempt threshold**: 5 attempts (operational constant — a conservative default
  matching common bounded-retry convention).
- **Backoff**: deterministic exponential, `1 minute * 2^(attempt_count-1)`, capped at 30 minutes
  — **no randomness/jitter** (governing instruction: "Never use random client-controlled retry
  values"; jitter is explicitly optional per docs/78 §15's own "for example" phrasing and is
  left as a documented future refinement, not a blocker at this scale).
- **No busy-loop retry**: `next_attempt_at` is the sole re-eligibility gate, backed by Phase
  1.1's own partial index.

## Dead-letter behavior

A poison event exhausts its bounded attempts (5) and transitions to `status = 'dead_letter'` —
never deleted, never silently retried again. `replay_dead_lettered_outbox_event(p_event_id)`
implements docs/78 §5.8's own explicit requirement ("administrator-visible and explicitly
re-playable... itself an audited administrative act, not an automatic retry"): resets
`status='pending'`, `attempt_count=0`, `next_attempt_at=NULL`, `last_error=NULL`, but **only**
if the row's current status is genuinely `dead_letter` — it can never be used to bypass the
retry machinery for a still-in-flight (`pending`) event. `service_role`-only, same posture as
every other CAP-003 internal primitive; no new application permission was invented.

## Zero-recipient outcome

docs/78 §8 is explicit: a candidate failing authorization revalidation "receives nothing —
silently, not as a batch failure." Phase 1.2's own `resolve_notification_intent()` already
returns `status='failed'` for zero `resolved_count` (whether zero candidates existed at all, or
every candidate was legitimately skipped) — that is **intent-level** vocabulary for "zero
recipients," never **worker-level** vocabulary for "processing malfunctioned." This worker
therefore marks the outbox event `'completed'` whenever `resolve_notification_intent()` returns
without raising, **regardless of `resolved_count`** — a correctly-reached zero-recipient
decision is a successful completion of CAP-003's own job, never a retryable/dead-letterable
failure. Retrying it would never change a today's-zero-recipients-are-correct outcome, and
treating it as an error would violate §8's own "never a batch failure" rule. The returned
`outcome` distinguishes this case textually (`processed_zero_recipients` vs. `processed`) for
observability, without a separate state-machine branch.

## Crash recovery

Because the whole batch call is one transaction, a crash at any point — before claim, after
claim, during intent creation, after intent creation but before resolution, after notification
materialization but before marking the outbox event terminal — simply rolls back that item's
writes (implicit `plpgsql` savepoint on exception) or, in the catastrophic whole-connection-dies
case, the entire in-flight batch. Either way this is **safe, not merely tolerated**: redoing an
already-safely-completed item on the next run produces zero duplicate intents or notifications,
because `create_notification_intent`'s own `ON CONFLICT` (Phase 1.2) and
`platform_create_user_notification`'s own `ON CONFLICT` (Phase 1.1) both dedupe by durable
business identity — convergence is guaranteed by those two independent uniqueness constraints,
not by this worker's own bookkeeping.

## Idempotency

At-least-once processing; exactly-once is never claimed. Every layer is independently safe to
repeat: enqueue-level (Phase 1.1's own `idempotency_key` uniqueness), intent-level (Phase 1.2's
own `UNIQUE (outbox_event_id, target_type, target_key)`), and notification-level (Phase 1.1's
own `UNIQUE (outbox_event_id, recipient_user_id)`). Worker crash/retry, an operator replay of a
dead-lettered event, or a duplicate claim from a stale candidate list all converge to the same
durable state with zero duplicates — verified directly (behavioral scenarios 13-14, concurrency
scenarios 6-7).

## Failure isolation

Each candidate is processed inside its own `BEGIN...EXCEPTION WHEN OTHERS` block — a single
poison event's failure never aborts or rolls back a different, already-processed event earlier
in the same batch call (verified directly, behavioral scenario 15, mirroring CAP-002 Phase 5.4's
own per-item exception-isolation precedent).

## Observability / traceability

Operators can determine event ID, current processing state, attempt count, next retry,
`processed_at`, dead-letter state, and last safe error classification directly from
`platform_outbox_events`' own columns — no new log table. Intent traceability is preserved via
`notification_intents.outbox_event_id` (Phase 1.2's own index-backed column); the worker's own
batch-result rows additionally surface `intent_id` per event for immediate visibility without a
follow-up query. `last_error` is always bounded (`LEFT(SQLERRM, 500)`) and safe — self-authored
exception messages reference only IDs/enum values, never raw payload content; the defensive
truncation bounds even a pathological Postgres-generated cast-error message that might otherwise
echo a malformed input value.

## Security boundary

`process_platform_outbox_batch`, `replay_dead_lettered_outbox_event`,
`platform_outbox_worker_backoff_interval`, and `platform_outbox_events_due_for_processing` are
all `SECURITY DEFINER`, pinned `search_path`, revoked from `PUBLIC`/`anon`/`authenticated`; the
two caller-facing ones (`process_platform_outbox_batch`, `replay_dead_lettered_outbox_event`)
are granted to `service_role` only, the two internal helpers are granted to nobody. No new
application permission was introduced. `validate-security-definer-search-path.sql` (repository-
wide) confirms every `SECURITY DEFINER` function in `public`, including this milestone's four,
pins an explicit `search_path`.

## RLS

No RLS policy was added or changed by this milestone. `platform_outbox_events`,
`notification_intents`, and `user_notifications` all keep exactly the posture Phase 1.1/1.2
established: zero policies for `authenticated`/`anon` on the first two (worker-side writes go
exclusively through the `SECURITY DEFINER` primitives, never a direct table grant), recipient-
scoped `SELECT`/`UPDATE` on the third. Verified directly that the worker's own processing-state
writes (`status`/`attempt_count`/`next_attempt_at`/`last_error`/`claimed_*`) do not weaken any
of this.

## Indexing

Evaluated Phase 1.1's existing indexes first, per the governing instruction. The claim/discovery
access path (`status = 'pending' AND next_attempt_at`) is already served by
`idx_platform_outbox_events_pending` — no new index was needed for pending-work discovery or the
retryable subset (both measured, both index-scan-backed at 100,900-row scale). The dead-letter
subset lookup was measured directly rather than assumed: a plain `WHERE status = 'dead_letter'`
query resolves via a sequential scan at ~14.5ms against 100,900 rows (200 of them `dead_letter`)
— well within bound, and dead-letter rows are expected to remain a small, self-limiting,
operator-visible subset (they require explicit operator replay to clear), so no dedicated
partial index was added. Per the governing instruction ("add indexes only if measurements
demonstrate need"), the measured evidence does not demonstrate a need; a future milestone can
revisit this if dead-letter volume ever grows materially.

## Performance (measured, 100,900 outbox events / 100,000 notification_intents / 100,000
user_notifications)

| Dimension | Result |
|---|---|
| Pending-work discovery (500 due-now of 100,900) | 0.54 ms, `Function Scan` over the partial-index-backed helper |
| SKIP LOCKED claim + full single-event pipeline | 6.75 ms |
| Full pipeline, 25-event batch | 17.26 ms total (0.69 ms/event) |
| Retryable-subset lookup (200 of 100,900) | 0.24 ms, `Bitmap Index Scan` on `idx_platform_outbox_events_pending` |
| Dead-letter-subset lookup (200 of 100,900) | 14.5 ms, measured sequential scan (see "Indexing") |
| Draining the remaining 474-event pending subset amid the 100,000-row historical tail | 242.8 ms total |

## Testing

- **Structural validator**: hard-fails unless the worker entry point exists, is `SECURITY
  DEFINER`/pinned/`service_role`-only, hard-clamps its batch limit to `[1,200]`, uses `FOR
  UPDATE SKIP LOCKED` with post-lock status revalidation, reuses `create_notification_intent`/
  `resolve_notification_intent` (textually confirmed, not merely claimed), implements attempt
  increment/backoff/dead-letter transition, never touches immutable outbox envelope fields, the
  replay primitive is scoped to `dead_letter` rows only, zero new tables/columns beyond Phase
  1.1's own processing-state columns exist, and zero delivery/Realtime/module-integration
  objects exist yet. **PASSED.**
- **Behavioral suite** (20/20): valid-event processing, no-reprocessing of completed events,
  empty-batch safety, batch-limit enforcement, unsupported-event handling, legitimate
  zero-recipient completion, retry attempt/backoff progression, not-yet-due skip, successful
  retry after a transient dependency becomes available, poison-event dead-lettering, no
  automatic retry of a dead-lettered event, replay-safe duplicate intent/notification
  prevention, mixed-batch failure isolation, correlation/causation preservation, bounded error
  metadata, no delivery-state implication, legacy-table non-interference, Phase 1.2 direct
  call-site behavior unchanged.
- **RLS suite** (9/9): authenticated/anon denied the worker entry point, `service_role` succeeds,
  outbox/intent tables remain unreadable to ordinary users even after worker writes, recipient-
  scoped `user_notifications` visibility holds regardless of caller (worker vs. direct call), no
  new direct write reaches any Phase 1.1/1.2 table, legacy and prior-phase postures all intact
  together.
- **Concurrency suite** (9/9, real `dblink` sessions): same-event race (exactly one winner),
  different-event parallel progress, retry race (exactly one increment), an actively-locked row
  correctly reported `skipped_locked` while an unrelated event in the same caller's batch still
  completes, dead-letter-threshold race (exactly one terminal transition), zero duplicate
  intents/notifications across every race, cross-organization independent progress, zero
  deadlocks.
- **Performance suite**: see table above.
- **Full regression sweep**: all CAP-002 phases, CAP-003 1.0A, 1.0B, 1.1, 1.2, plus this
  milestone's own five new suites, plus the repository-wide `SECURITY DEFINER` search-path
  validator — zero failures.

## Rollback

`rollback-notification-outbox-worker.sql` drops all four new functions and deletes the one
`platform_event_type_registry` row this milestone registered, in dependency order, no `CASCADE`.
**No refusal path is needed or implemented** — this milestone creates no new table and stores no
durable business evidence of its own (every intent/notification the worker creates lands in
Phase 1.1/1.2's own tables, using exactly the primitives a direct manual call already produces),
so there is nothing this rollback could destroy that Phase 1.1/1.2's own rollbacks do not already
own, exactly mirroring CAP-002 Phase 5.4's own rollback precedent. The registered
`platform_event_type_registry` row is configuration data, not business evidence — no `FK` ties
any `platform_outbox_events`/`user_notifications` row to it, and its removal is safe regardless
of how much real processing history already references that `event_type` string. Verified
directly: clean rollback, `validate-notification-outbox-worker-rollback.sql` passes confirming
every 1.3 object is gone while Phase 1.1/1.2/1.0A/1.0B/CAP-002 baselines are all unaffected, and
the patch reapplies cleanly with both the structural validator and the full behavioral suite
passing again.

## Limitations

- **No module integration.** Nothing in Requests/Meetings/Tasks/Entry/Prisoner Letters calls
  `platform_enqueue_outbox_event`, and this worker recognizes only the one generic passthrough
  event shape — Phase 1.4.
- **Eight target kinds remain deferred** (unchanged from Phase 1.2): `department_leadership`,
  `command_leadership`, `org_role`, `task_assignees`, `task_watchers`, `meeting_participants`,
  `record_owner`, `dynamic`.
- **No scheduler/cron deployment.** This patch adds only the worker-facing SQL entry point; how
  and how often it is invoked (existing `pg_cron`, an Edge Function on a timer, an external
  scheduler) remains an implementation-phase deployment decision docs/78 §13 explicitly leaves
  open, exactly as Phase 5.4 itself deferred it.
- **No Realtime cutover, no delivery-channel adapters, no legacy table migration or
  retirement.** The legacy `notifications` table keeps serving every existing module
  unchanged — Phase 1.5/2.
- **`claimed`/`processing` remain unused enum values** by design (see "Claim model") — a future
  milestone that moves to a longer-running, multi-phase claim model would need to introduce
  genuine stale-claim recovery at that point, not before.

**Module integration, the remaining eight target kinds, scheduler deployment, Realtime cutover,
and external delivery all remain deferred to their own later CAP-003 phases** — nothing in this
milestone begins any of them.

## Deviations / architecture clarifications

Two within-discretion scoping decisions, both explicitly anticipated by docs/78's own phasing
rather than departures from anything it fixes:

1. **The generic `platform.generic_notification_request.v1` event shape** (see "Supported event
   shape" above) — docs/78 §25 assigns real per-module event-type mappings to Phase 1.4;
   defining one generic, worker-recognized passthrough shape for this milestone's own
   validation is scoping within that phasing, not a redesign.
2. **Uniform retry/dead-letter handling instead of a two-tier "immediately terminal vs.
   retryable" state system** (see "Retry model" above) — docs/78 §5.8/§15 leave exact retry
   policy as an operational constant; collapsing to one mechanism is a simplification within
   that discretion, chosen specifically to avoid inventing a second worker-state system the
   governing instruction warns against.
