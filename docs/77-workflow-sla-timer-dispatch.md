# CAP-002 Phase 5.4 — SLA Timer Dispatch & Worker Foundation

## Scope

This phase implements the bounded, concurrency-safe, idempotent automatic worker/
dispatcher mechanism docs/60's "Timer execution" and docs/73's "Queue model" sections
anticipate but explicitly defer: "A future dispatcher should claim due timers in bounded
batches, use skip-locked semantics, write a unique timer-fired event... Repeated dispatch
is safe because the causal key is unique." Phase 5.3/5.3A already built every synchronous
persistence primitive and three private due-detection functions
(`workflow_sla_clocks_due_for_warning`/`_breach`/`_escalation`) for exactly this future
milestone to consume. Nothing in Phase 5.3/5.3A ever called them on a schedule. This phase
adds the batch-claiming loop that does, and nothing else.

It explicitly does **not** implement: notification delivery of any kind, module adapters,
frontend, new workflow node types, automatic workflow business decisions, pg_cron or any
other scheduler wiring, or outbox/queue infrastructure (none exists anywhere in this
codebase yet — see "Deferred: outbox integration" below).

## Why this phase does not call the existing manual RPCs

`record_workflow_sla_warning`, `record_workflow_sla_breach`, and
`trigger_workflow_sla_escalation` each require `workflow_actor_is_active()` (`auth.uid()`
must resolve to a real, active human user) and `can_manage_workflow_sla_clock()` (instance
owner/manager, or the work item's own assignee). Both checks are correct and load-bearing
for a *human*-initiated action — exactly docs/73's "Manual escalation... An authorized
actor... may trigger the next configured escalation level early." A system dispatcher has
no such actor: it is not the current work item's holder, not a supervisor, not an
administrator "with authority over the instance" in the human sense docs/73 means.

Routing dispatcher calls through the manual RPCs would require either inventing a
synthetic "system user" identity (a new, unapproved identity/permission concept the
governing instruction forbids: "Do not create a new business permission model") or
weakening those RPCs' actor checks to also accept no-actor calls — which would silently
loosen the exact authorization boundary that protects every *human*-invoked manual
escalation, an unacceptable risk to already-verified, already-pushed Phase 5.3A protected
code.

This phase instead adds four new, small, narrowly-scoped functions
(`workflow_sla_process_due_warnings`/`_breaches`/`_escalations` plus the top-level
`process_workflow_sla_due_batch`) that perform **exactly** the same state transition, the
same evidence shape, and the same ordering/terminal/pause guards as their manual
counterparts — reusing docs/73's own due-detection helpers and the exact calendar-aware
offset functions Phase 5.3A already built (`workflow_calculate_calendar_offset_backward`,
`workflow_calculate_calendar_deadline`) unchanged — but gated by the row's own claimed `FOR
UPDATE SKIP LOCKED` lock and re-derived business state instead of a human actor check, and
recording `actor_id = NULL` / `triggered_by = 'automatic'` (a value
`workflow_escalation_events`'s own `CHECK` constraint already anticipated in Phase 5.3,
unused until now). This is "reuse the Phase 5.3 warning/breach/escalation primitive's
semantics" in the sense the governing instruction means — same rules, same evidence
contract, same idempotent-replay guarantee — without either inventing a system identity or
touching the protected human-actor RPCs.

## Database objects

Five new functions, all purely additive — **zero new tables, zero modifications to any
existing function, grant, comment, or table from Phase 1 through 5.3A**:

- `workflow_sla_automatic_idempotency_key(clock_id, discriminator)` — a pure, deterministic
  UUID derivation (`md5('wf_sla_auto_dispatch:' || clock_id || ':' || discriminator)::uuid`)
  used only for forensic traceability on automatically-fired evidence rows. Uses pgcrypto's
  `md5()::uuid` idiom, the same deterministic-UUID pattern this codebase's own performance
  fixtures already use — no new extension dependency.
- `workflow_sla_process_due_warnings(p_limit)` — automatic counterpart of
  `record_workflow_sla_warning`.
- `workflow_sla_process_due_breaches(p_limit)` — automatic counterpart of
  `record_workflow_sla_breach`.
- `workflow_sla_process_due_escalations(p_limit)` — automatic counterpart of
  `trigger_workflow_sla_escalation`.
- `process_workflow_sla_due_batch(p_limit DEFAULT 25)` — the single worker-facing entry
  point, running all three processors in one call and returning one evidence row per
  candidate examined (processed, skipped, or failed).

## Due-work model

Warning, breach, and escalation-level due-ness are recognized **independently**, exactly
as the governing instruction requires: a single clock can legitimately have more than one
kind of due action pending, and one `process_workflow_sla_due_batch` call processes all
three categories together. Each category reuses its own Phase 5.3/5.3A due-detection
function (`workflow_sla_clocks_due_for_warning`/`_breach`/`_escalation`) as the candidate
source — this phase introduces no new "what is due" query shape of its own.

## Bounded batching

`p_limit` (default 25) is clamped to `[1, 200]` per category inside
`process_workflow_sla_due_batch`, **regardless of what the caller requests** — worst case
600 items across all three categories in a single call. Docs/60/73 approve "bounded
batches" but fix no numeric value ("A future dispatcher should claim due timers in bounded
batches"). This patch's operational constant — 25 default, 200 hard ceiling per category —
is documented here as an operational tuning limit, not a business rule, and may be
revisited by a future milestone without any architecture change. The dispatcher can never
be driven into an unbounded scan/process loop regardless of caller input.

## Safe claiming

Each processor claims exactly one row at a time: given a candidate `clock_id` from the
non-locking due-detection read, it issues `SELECT ... FROM workflow_sla_clocks WHERE id =
<candidate> FOR UPDATE SKIP LOCKED`. A row already locked by a concurrent worker (or by a
concurrent human pause/resume/complete/cancel/manual-escalation call) is reported
`skipped_locked` and left for the next batch — never blocked on, never retried within the
same call. This is exactly the pattern docs/76 documented as the intended future dispatcher
shape: "safely wrap each candidate's `clock_id` in its own `FOR UPDATE SKIP LOCKED`-based
batch processing loop calling the existing `record_/trigger_` RPCs." No dispatcher call
ever locks two clock rows, and none locks any table outside Phase 5.3/5.3A's own eight —
deadlock with the existing graph/approval engine (which never locks
`workflow_sla_clocks`) remains structurally impossible, unchanged from Phase 5.3's own
concurrency guarantee.

Under the lock, every processor **re-derives** state, ordering, and due-ness directly from
the just-locked row — it never trusts the earlier non-locking due-detection snapshot for
anything beyond "this candidate was worth attempting." A clock that was paused, completed,
cancelled, advanced past this offset/level, or already breached between the candidate read
and the lock acquisition is safely reported `skipped_not_running`, `already_processed`, or
`skipped_out_of_order` — never an error, never a corrupted mutation.

## Transaction boundaries and failure isolation

One due action against one clock is the atomic business unit, exactly as docs/60 requires.
Each candidate's claim-and-process sequence is wrapped in its own `BEGIN ... EXCEPTION WHEN
OTHERS ... END` block inside the processor's loop — plpgsql's implicit savepoint, so a
failure processing one item rolls back only that item's own effects (never a half-written
evidence row, never a partially-advanced escalation level) while every other item already
processed earlier in the same batch call remains intact. A single bad item never aborts or
corrupts the rest of the batch; `process_workflow_sla_due_batch`'s own result set reports
that item's outcome as `failed: <error message>` and moves on.

## Warning processing

Reuses `record_workflow_sla_warning`'s exact rules: warnings fire strictly in order
(`warning_offset_index` must equal `warned_up_to_index + 1`), never for a paused or
non-running clock (`workflow_sla_clocks_due_for_warning`'s own `state = 'running'` filter
excludes paused/terminal clocks from candidacy entirely), and due-ness is evaluated through
the identical calendar-aware backward walk (`workflow_calculate_calendar_offset_backward`,
calendar-version-pinned to the clock) Phase 5.3A already built. `idx_workflow_sla_clock_events_warning_once`
(the same hard database backstop the manual path already relies on) guarantees no duplicate
`warning_fired` evidence regardless of how many times a batch is retried.

## Breach processing

Reuses `record_workflow_sla_breach`'s exact rule: `breached_at` is set at most once,
`clock.state` is never changed by a breach (breach is evidence layered on `running`, never
its own lifecycle state, per Phase 5.3's smallest-state-machine discipline). An
already-breached clock is a safe no-op, mirroring `record_workflow_sla_breach`'s own "two
independent paths can legitimately reach the same breach fact" precedent.
`idx_workflow_sla_clock_events_breach_once` backstops duplicate prevention identically for
automatic and manual firing.

## Escalation-level processing

Reuses `trigger_workflow_sla_escalation`'s exact rules: advances at most one level per due
candidate (`current_escalation_level + 1`, re-verified under the row lock), never skips,
never re-fires an already-fired level
(`workflow_escalation_events_no_duplicate_level`'s `UNIQUE(clock_id, escalation_level_id)`
backstops this independently of the processor's own lookup). `mark_breached` is the sole
action with a real, self-contained effect (sets `breached_at` idempotently, exactly as the
manual path does); the other six of the closed seven-action allowlist
(`remind_actor`/`notify_supervisor`/`add_replace_candidates`/`route_higher_scope`/`create_exception_work_item`/`follow_branch`)
are recorded as evidence only — no notification is sent, no candidate is added to a live
round, no graph branch is followed, no external work item is created — per docs/60's
unconditional prohibition on automatic approval/rejection/cancellation/closure and Phase
5.3's own narrow evidence-only resolution of the same six actions, unchanged.

Records are attributed `triggered_by = 'automatic'`, `triggering_actor_id = NULL` — the
exact combination `workflow_escalation_events_manual_actor_check`'s own `CHECK` constraint
already allowed since Phase 5.3, unused until this phase.

## Idempotency and retry safety

Automatic processing does not rely on caller-supplied idempotency-key replay comparison
the way the manual RPCs must (that machinery exists specifically to protect against a
*client* reusing a key with different semantic input — irrelevant here, since every key is
server-derived from `clock_id` + a fixed discriminator). Instead, safety comes from two
independent layers: the `FOR UPDATE SKIP LOCKED` claim (only one transaction can hold a
given clock row's lock at a time, so no true race is possible for that specific clock while
locked) and an explicit business-state re-check before any mutation (`already_processed`
for a warning offset/level/breach already recorded). A retry — whether sequential or
genuinely concurrent — against an already-settled clock is therefore a deterministic,
side-effect-free no-op, verified directly under real concurrency by the concurrency suite's
scenario 9.

## Evidence and observability

`process_workflow_sla_due_batch` returns one row per candidate examined:
`due_category, clock_id, instance_id, sequence_index, action_code, outcome, evidence_id`.
This is sufficient observability without a redundant worker-log table — the real evidence
of record remains `workflow_sla_clock_events` / `workflow_escalation_events`, exactly as
before, and the batch result lets a future caller (an Edge Function, a scheduler) log or
alert on `failed`/`skipped_locked` outcomes without a second persistent store. Every
automatically-fired evidence row is unambiguously attributable to the dispatcher rather
than a human actor: `actor_id`/`triggering_actor_id` is `NULL`, and `metadata->>'source' =
'automatic_dispatch'` on clock-lifecycle evidence.

## Authorization and execution boundary

`process_workflow_sla_due_batch` is `REVOKE`d from `PUBLIC`, `anon`, and `authenticated`,
and `GRANT`ed `EXECUTE` **only** to `service_role`. The four internal processor/helper
functions are fully private — no grant to any role at all, callable only by their owner
(the same posture the existing due-detection functions already use). This is deliberately a
*stricter* posture than the codebase's older, pre-CAP-002 `check_deadlines()`/`pg_cron`
precedent in `notifications.sql` (which carries no explicit grant at all, relying on
Postgres' default `PUBLIC` `EXECUTE` and is invoked only via `cron.schedule`, itself running
as a privileged role) — that precedent is not touched or weakened by this phase; it simply
is not the pattern this stricter, security-review-driven milestone follows, consistent with
docs/60's own "Permissions and security" invariants ("service/internal-only execution where
appropriate", "narrowest approved execution boundary"). A real deployment would invoke this
function from a server-side context authenticating with the Supabase service-role key (an
Edge Function, a privileged scheduled job) — never from a client using an end-user's
session.

## RLS

No new table, no new RLS policy, no new direct table grant. `workflow_sla_clocks` /
`workflow_sla_clock_events` / `workflow_escalation_events` remain exactly as visible as
before (`can_view_workflow_instance`-gated `SELECT` for `authenticated`, nothing for
`anon`) — automatically-fired evidence is subject to the identical visibility boundary as
manually-fired evidence, verified directly by the RLS suite's cross-organization scenario.

## Concurrency

Nine race scenarios verified under genuinely independent database sessions (`dblink`):
two workers claiming the same due warning/breach/escalation level (exactly one wins, one
piece of evidence, no duplicate/double-escalation); worker vs. pause/resume/complete/cancel
(no deadlock, no partial state — a human RPC that legitimately loses its own
optimistic-concurrency race to a concurrently-committing dispatcher claim receives the
correct `40001 "changed concurrently"` rejection, exactly as it always has, and converges
on retry against the current `lock_version`, which this suite performs explicitly to
demonstrate retry-safety rather than asserting a specific race winner); multiple workers on
unrelated clocks (no contention); and retry after an already-recorded action under real
concurrency (zero new evidence). All nine confirm: no duplicate evidence, no lost state, no
double escalation, no event-sequence collision, no deadlock, and unrelated clocks progress
concurrently.

## Performance

Measured at 10,000 active clocks (a mix of not-yet-due, breach-due, and
escalation-due-with-a-4-level-policy clocks), 10,000 completed/cancelled historical clocks,
and 100,000 `workflow_sla_clock_events` rows — the same scale Phase 5.3's own performance
suite established. `process_workflow_sla_due_batch` at the default limit (25/category)
completed in single-digit-to-low-double-digit milliseconds; at the hard ceiling
(200/category) in well under 100ms; twenty consecutive warm-cache calls averaged ~34ms
each. `EXPLAIN (ANALYZE, BUFFERS)` confirms both the per-candidate `FOR UPDATE SKIP LOCKED`
claim (an index/primary-key scan) and the breach-due discovery access path
(`idx_workflow_sla_clocks_breach_due`) never perform a sequential scan at this scale.
Growing the historical (terminal) tail by another 5,000 rows (to 15,000 terminal / 25,000
total clocks) left batch latency essentially unchanged (~37ms vs. ~36ms) — confirming
latency is bounded by due-candidate volume, not historical volume, exactly as the partial
indexes are designed to guarantee. No additional index was added — the two partial indexes
Phase 5.3 already created proved sufficient at the tested scale.

## Rollback

Purely additive: this phase creates five functions and touches zero existing tables,
functions, grants, or comments. It stores no data of its own — every row the dispatcher
writes lands in Phase 5.3's own `workflow_sla_clock_events` / `workflow_escalation_events`
tables, using exactly the same evidence shape a manual RPC call would have produced.
`rollback-workflow-sla-timer-dispatch.sql` simply drops the five functions; **no refusal
path is needed or implemented**, mirroring Phase 5.3A's own correction rollback precedent
("a function body only affects future calls, never already-stored rows"). Verified
directly: `pg_dump --schema-only` and the full `public`-schema function list are
byte-identical before Phase 5.4 was ever applied and after rollback (differing only in
`pg_dump`'s own random per-invocation `\restrict`/`\unrestrict` security tokens, not
schema content); the rollback validator passes; the patch reapplies cleanly afterward with
the structural validator passing again.

## Testing

Structural validator; a 20-scenario behavioral suite (empty batch, warning
becomes-due/not-yet-due/already-processed/paused, breach
becomes-due/already-processed, terminal-clock exclusion, escalation level 1/level 2/strict
ordering, repeated batch execution, batch-size bound, mixed due actions in one call,
calendar-aware due times, historical calendar-version pinning, evidence semantics, no
notification delivery, no automatic workflow decision, no-escalation-policy exclusion); a
6-scenario RLS suite (authenticated denied, anon denied, service_role permitted, no new
direct write grants, existing user read/manage behavior unchanged, no cross-organization
leakage); a 9-scenario concurrency suite (5 invariants: no duplicate evidence, no lost
state, no double escalation, no event-sequence collision, no deadlock, unrelated clocks
progress concurrently); and a 7-dimension performance suite. The full CAP-002 regression
sweep (Phase 1 through 5.4) passes with zero failures.

## Limitations and explicitly deferred functionality

The following are deliberately out of scope for this phase and are not implemented in any
form, per the governing instruction:

- **No notification delivery.** `remind_actor`, `notify_supervisor`,
  `create_exception_work_item`, `route_higher_scope`, `add_replace_candidates`, and
  `follow_branch` remain evidence-only in the automatic path exactly as they were in the
  manual path — none of them sends an email, SMS, push notification, or otherwise delivers
  anything outside the database.
- **No scheduler deployment.** `process_workflow_sla_due_batch` exists as a callable,
  correctly-secured worker-facing command; nothing in this patch schedules it. No
  `pg_cron` job, no `cron.schedule` call, no Supabase Edge Function, no external cron
  trigger is created. A future, separately approved milestone would wire an actual
  recurring invocation (Supabase Cron calling an Edge Function that authenticates with the
  service-role key and calls this RPC, or an equivalent mechanism) — this phase
  deliberately stops at "the function a scheduler would call," never "the scheduler
  itself," per the governing instruction's explicit exclusion of scheduler deployment.
- **Deferred: outbox integration.** Docs/60's "Timer execution" section anticipates a
  future dispatcher enqueuing outbox work "in one transaction" alongside a timer-fired
  event. No outbox table or infrastructure exists anywhere in this codebase yet (verified
  by inspection — the concept appears only in architecture documents, never in any applied
  patch). This phase does not invent one; it is the next dependency a future notification-delivery
  milestone would need to introduce before automatic evidence could drive an actual
  email/SMS/push consumer.
- **No module adapters, frontend, admin UI, or visual designer.**
- **No new gateway or approval semantics, no new workflow node types.** Automatic dispatch
  never advances the graph, never records a decision, never mutates any existing
  `workflow_events` event type, and never touches `decide_workflow_work_item`,
  `workflow_enter_downstream_node`, or `workflow_resolve_approval_candidates` — verified
  both by the structural validator's direct source inspection and the behavioral suite's
  explicit "no automatic workflow decision" scenario.

Two narrow implementation decisions this phase makes as documented concretizations of
details docs/60/73 leave open:

- **The automatic path is a new, small function family rather than a nullable-actor mode
  on the existing manual RPCs.** Reusing the manual RPCs directly would have required
  either a synthetic system-user identity (a new permission concept) or weakening their
  human-actor authorization checks — both rejected as unacceptable risk to already-approved
  Phase 5.3A code; see "Why this phase does not call the existing manual RPCs" above.
- **The operational batch-size constant (25 default, 200 hard ceiling per category).**
  Docs/60/73 approve "bounded batches" but fix no numeric value; this phase's choice is
  documented explicitly as an operational tuning limit, not a business rule, revisable by a
  future milestone without any architecture change.
