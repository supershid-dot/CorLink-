# CAP-002 Phase 5.3 — SLA & Escalation Persistence / Runtime Foundation

## Scope

This phase implements the generic persistence and synchronous runtime foundation for SLA
clocks and escalation policies: clock creation and lifecycle (pause/resume/restart/
complete/cancel), warning-threshold and breach recording, business-calendar-aware deadline
calculation, ordered escalation policies, manual (caller-invoked) escalation, immutable
evidence for every fact, and a deterministic "what is due" query foundation.

It explicitly does **not** implement: a background timer worker that periodically finds and
executes due timers, any notification delivery mechanism (email/SMS/push/webhook), module
adapters or module-specific integrations, any frontend or visual designer, or new gateway/
approval semantics. Docs/73 names escalation as a third, orthogonal seam alongside
delegation and substitution — read-only observation plus a closed set of bounded exception
actions, never a new source of authorization and never a decision-maker. This phase builds
the storage and synchronous command surface that seam needs; the seam's automatic, time-
driven half is deliberately left for a later milestone.

## Database objects

Eight new tables, in two groups:

**Administrative configuration** (admin-only visibility, create-once/immutable, mutated
only by their own create RPC):
- `workflow_business_calendars` + `workflow_business_calendar_versions` — a calendar
  identity with an append-only version history; each version is a content-addressed,
  wholly immutable snapshot of timezone/working-days/working-hours/holidays.
- `workflow_escalation_policies` + `workflow_escalation_levels` — a named policy with an
  ordered, contiguous 1..N sequence of levels, each carrying an offset, an action from the
  closed seven-action allowlist, and optional `action_config`.
- `workflow_sla_policies` — a reusable, named, duration-based SLA template referencing an
  optional calendar and an optional escalation policy.

**Instance-scoped runtime data** (visible to any participant via the existing
`can_view_workflow_instance` boundary, mutated only through the RPCs below):
- `workflow_sla_clocks` — one row per running or historical SLA clock.
- `workflow_sla_clock_events` — append-only lifecycle evidence (started, paused, resumed,
  restarted, warning_fired, breached, completed, cancelled).
- `workflow_escalation_events` — append-only escalation evidence, one row per level fired.

RLS, grant posture (SELECT-only for `authenticated`, RPC-owned mutation, nothing granted to
`anon`), immutability triggers, and SECURITY DEFINER/pinned-`search_path` discipline all
follow the exact pattern established since Phase 1.

## Clock lifecycle

States are deliberately the smallest set that satisfies the requirements: `running`,
`paused`, `completed`, `cancelled`. There is no separate "scheduled" or "pending" state —
`create_workflow_sla_clock` creates and starts a clock in the same call, since an SLA
clock's whole reason to exist is "the start event has already occurred, begin timing."
`breached` is deliberately **not** a state; it is evidence (`breached_at` plus a
`workflow_sla_clock_events` row) layered on top of `running`, because a breach must never
by itself change what the underlying work item can do.

Every mutating RPC follows the same discipline used since Phase 3.1: an advisory
transaction lock keyed by `(actor, clock_id, idempotency_key)`, a `FOR UPDATE` row lock,
an idempotency-key replay check that compares every semantic input recorded in the prior
event's metadata (not just the event's existence — the Phase 4.3 defect this phase does
not repeat), an `expected_lock_version` optimistic-concurrency check, then the mutation and
its evidence row in the same transaction.

## Pause and resume

Pausing and resuming never replace the clock or touch its deadline's semantic source. The
clock carries `effective_deadline` (the original, calendar-resolved deadline — never
rewritten by pause/resume), `accumulated_paused_duration` (the running total of every pause
interval), and `effective_deadline_adjusted` (`effective_deadline + accumulated_paused_
duration`, recomputed and stored by every RPC that changes either input). Resuming adds
exactly the just-elapsed pause interval to the accumulated total; repeated pause/resume
cycles remain mathematically correct because each cycle only ever adds its own interval,
never rewrites the total from scratch.

`effective_deadline_adjusted` is a plain column maintained explicitly by `create_workflow_
sla_clock`/`resume_workflow_sla_clock`/`restart_workflow_sla_clock`, not a `GENERATED
ALWAYS AS` column — Postgres' `timestamptz + interval` operator is `STABLE`, not
`IMMUTABLE` (interval day/month components are not statically resolvable across timezones),
so it cannot appear in a generation expression. This was discovered during implementation
(the migration failed to apply with `GENERATED`) and fixed by having every RPC that touches
either input set the derived column explicitly in the same statement, so it can never drift
out of sync with its inputs.

## Restart

Restart is **not** resume. It discards the clock's entire prior elapsed-time contribution
and begins a genuinely new timing epoch: a fresh `effective_deadline` recomputed from the
restart instant (re-resolving the calendar's currently-active version, since a restart is a
new window with its own "why was this deadline this timestamp" story), `accumulated_paused_
duration` reset to zero, `current_escalation_level`/`breached_at`/`warned_up_to_index` reset
for the new epoch, and `restart_epoch` incremented. The complete pre-restart snapshot
(prior deadline, accumulated pause, escalation level, breach state) is captured in the
`restarted` evidence event's metadata before being reset, so history is never silently
overwritten — a query against `workflow_sla_clock_events` still shows every earlier epoch's
full lifecycle exactly as it happened.

Docs/73 approves clock restart only as something a future "Reopen" workflow-level command
would trigger, stating "no other trigger is approved by this document." Investigation found
`workflow_instances.execution_epoch` already exists as a column (default 1) but has never
been incremented anywhere in the codebase — no Reopen RPC exists yet. This is resolved as a
narrow, documented interpretation, not an architecture decision: `restart_workflow_sla_
clock` is implemented as an explicitly authorized, manually-invoked administrative command,
never auto-wired to anything, documented here as the SLA-clock-level primitive a future
Reopen RPC would call once it exists. It is never triggered automatically by this phase.

## Business calendar semantics

A calendar version is an immutable snapshot: IANA timezone, `working_days` (ISO weekday
integers, 1=Monday..7=Sunday), a single daily `working_hours_start`/`working_hours_end`
window, and a `holidays DATE[]` exclusion list. `workflow_calculate_calendar_deadline`
computes a deadline by iterative day-stepping in calendar-local time (converting to/from
UTC only at the loop boundaries), skipping non-working weekdays and holidays, bounded at
3660 iterations — mirroring the graph engine's own existing 32-hop defensive bound
precedent, so a calendar with a pathological or empty working-day configuration fails
loudly instead of looping. Plain (non-calendar) `hours`/`days` durations bypass this
entirely and are simple wall-clock addition.

A clock created against a calendar-aware duration pins both `calendar_id` and the specific
`calendar_version_id` active at creation time. Publishing a new calendar version later never
retroactively changes an already-computed deadline — behavioral scenario 40 verifies this
directly. This is the calendar-version-stability guarantee the governing instruction
requires: a clock is always explainable against the exact calendar and version it was
computed from.

## Deadline calculation and warning offsets

A clock's deadline comes from exactly one of two sources, recorded on the row so the
"why was this deadline this timestamp" story is never lost: a duration-based `workflow_sla_
policies` reference (amount + unit + optional calendar), or a one-off `absolute_deadline`
supplied directly at creation (which therefore requires its own explicit timezone
parameter, since there is no policy to source one from). Exactly one of `policy_id`/
`absolute_deadline` may be supplied — never both, never neither.

Warning offsets (`[{"amount": N, "unit": "..."}]`, JSONB on the policy and copied onto the
clock at creation) describe how long before the deadline a warning becomes due. **Narrow,
documented simplification**: unlike the deadline itself, which is fully calendar-aware, a
warning offset's `business_hours`/`business_days` units are treated identically to plain
`hours`/`days` when computing "how far before the deadline." Rationale: an offset measures
a lead time relative to an already-calendar-resolved deadline, not an independent calendar
traversal — the deadline's own calendar-awareness is preserved completely; only the
lead-time arithmetic is simplified. `record_workflow_sla_warning` requires each offset to be
recorded strictly in order (never skipping index N-1) and only once its due time has been
reached; it never changes `clock.state`.

## Escalation policy model and ordered levels

An escalation policy is a named, ordered, 1..N contiguous sequence of levels (no gaps, no
duplicates, validated atomically before any row is inserted). Each level carries an
`offset_from` (`breach` or `previous_level`), an offset amount/unit, and an `action_code`
from the closed seven-action allowlist docs/60 and docs/73 both enumerate verbatim: `remind_
actor`, `notify_supervisor`, `add_replace_candidates`, `route_higher_scope`, `create_
exception_work_item`, `mark_breached`, `follow_branch`. No eighth action exists, and the
CHECK constraint enforces this as defense-in-depth behind the RPC's own validation.

## Manual escalation

`trigger_workflow_sla_escalation` is the only escalation-firing path this phase implements.
It always advances to exactly `current_escalation_level + 1` — never skips a level, never
fires the same level twice (enforced both by the RPC's own lookup and by a hard
`UNIQUE(clock_id, escalation_level_id)` database backstop independent of the RPC), and is
rejected outright on a paused or terminal clock.

**Narrow, documented resolution — evidence-only vs. real effect**: of the seven actions,
only `mark_breached` performs a real, self-contained effect (it sets the firing clock's own
`breached_at`, exactly the same field `record_workflow_sla_breach` sets, idempotently). The
other six are recorded purely as evidence in `workflow_escalation_events` — the action
itself is not performed. This is not a simplification of the action's meaning; it is a
scope boundary. `remind_actor`/`notify_supervisor`/`add_replace_candidates`/`route_higher_
scope`/`create_exception_work_item`/`follow_branch` would each require either notification
delivery (out of scope for this milestone by explicit instruction) or mutating the
protected graph/candidate-resolution/work-item machinery this patch must not touch (the
same constraint that kept delegation and substitution from ever writing directly into
`workflow_events`). The recorded evidence — level, action code, action config, timestamp,
triggering actor — is exactly what a later milestone needs to actually perform the action;
this phase deliberately stops at "recording that it is due/was manually invoked," never
"performing the external effect."

Manual escalation never grants visibility, never advances the graph, never records a
business decision, and never mutates any of the six action codes' underlying work-item or
approval state — behavioral scenarios 41 and 42 verify both the visibility and the
no-automatic-decision invariants directly.

## Due-detection foundation (not a worker)

Three private, read-only, ungranted functions — `workflow_sla_clocks_due_for_warning`,
`workflow_sla_clocks_due_for_breach`, `workflow_sla_clocks_due_for_escalation` — return the
deterministic set of candidates a future dispatcher would need. They are `STABLE`, take a
`p_limit`, and are shaped so a future dispatcher can safely wrap each candidate's `clock_id`
in its own `FOR UPDATE SKIP LOCKED`-based batch processing loop calling the existing
`record_workflow_sla_warning`/`record_workflow_sla_breach`/`trigger_workflow_sla_
escalation` RPCs (which already lock per-row). **Nothing in this patch calls them on a
schedule** — no cron, no `pg_cron`, no background process, no trigger. The escalation
due-time calculation anchors `offset_from = 'breach'` to `breached_at` and `offset_from =
'previous_level'` to the immediately preceding level's `workflow_escalation_events.occurred_
at`; for level 1 (which has no possible previous level), `previous_level` is treated as
`breach` — the same narrow lead-time-simplification precedent as warning offsets, applied
consistently rather than inventing new semantics for an edge case docs/73 does not address.

## Authorization and visibility

Two new authorization predicates reuse existing primitives rather than inventing a parallel
permission system: `can_manage_workflow_sla_config(organization_id)` mirrors `can_manage_
workflow_definition` exactly (super-admin or an org admin acting within their own org);
`can_manage_workflow_sla_clock(clock_id)` reuses `can_manage_workflow_instance` (owner/
manager) plus a direct work-item-assignee check, so the current holder of a clock's work
item can manage that one clock without needing instance-owner/manager standing — behavioral
scenario 44 exercises this path directly. Both predicates are `GRANT`ed to `authenticated`
(not just revoked from `anon`) because — unlike a function called only from inside another
`SECURITY DEFINER` function's body, where the privilege check runs as that outer function's
owner — an RLS policy expression is evaluated under the querying role's own privileges, so
`authenticated` genuinely needs `EXECUTE` to use them as `USING`-clause predicates. This
was discovered during RLS testing (the initial `REVOKE ALL ... FROM authenticated` broke
every SELECT policy referencing `can_manage_workflow_sla_config`) and fixed to match `can_
manage_workflow_definition`'s and `can_manage_workflow_instance`'s own established grant
shape exactly.

**The governing safety rule** (docs/60, restated verbatim in docs/73 as "the single most
important constraint"): escalation must never grant subject visibility, and must never
automatically approve, reject, cancel, complete, or close a workflow business decision
merely because a deadline elapsed. Concretely: `workflow_sla_clocks`/`workflow_sla_clock_
events`/`workflow_escalation_events` are visible only via the existing `can_view_workflow_
instance` boundary; a user named only inside an escalation level's `action_config` (e.g. a
`notify_supervisor` target) gains zero visibility from that alone — they see nothing unless
independently a `workflow_participants` row grants it. RLS scenario 5 and behavioral
scenario 41 both verify this directly.

## Immutable evidence

Every fact is append-only. `workflow_sla_clock_events` and `workflow_escalation_events`
share a single generic `workflow_reject_evidence_mutation()` trigger (`RAISE EXCEPTION '%
is append-only'`) rejecting UPDATE/DELETE unconditionally. The four administrative
configuration tables (calendars, calendar versions, escalation policies + levels, SLA
policies) are create-once/immutable via `workflow_reject_escalation_config_mutation()` /
`workflow_reject_calendar_version_mutation()` — there is no update RPC for any of them; a
correction is a new policy/version, never a rewrite of an existing one. `workflow_sla_
clocks` itself is mutable only until it reaches `completed`/`cancelled`, at which point
`workflow_reject_terminal_sla_clock_mutation()` (mirroring the exact Phase 3.2 terminal-
position/-round precedent) blocks any further UPDATE or DELETE, enforced at the database
level independent of the RPC layer — behavioral scenario 20 verifies this by attempting a
raw UPDATE against an already-terminal clock directly.

## Idempotency

Every mutating RPC accepts an idempotency key and compares **every semantic input** stored
in the prior matching event's metadata before treating a repeat call as a safe replay —
including `expected_lock_version`, not merely the event's existence — the exact discipline
the Phase 4.3 defect violated and which this phase applies correctly from the first RPC
written. A replayed call returns the identical prior result with `replayed = true`; reusing
the same key with genuinely different input (a different event type, a different expected
lock version) is rejected rather than silently returning a mismatched result.

## Concurrency and lock order

Every clock-lifecycle RPC acquires exactly one advisory transaction lock keyed by
`(actor, clock_id, idempotency_key)`, then a single `FOR UPDATE` row lock on its own
`workflow_sla_clocks` row, then (manual escalation only) a plain non-locking `SELECT` on
`workflow_escalation_levels` before its own `INSERT`. No RPC ever locks two clock rows, and
none locks any table outside this phase's own eight — deadlock with the existing graph/
approval engine (which locks `workflow_instances`/`workflow_instance_steps`/`workflow_
approval_rounds`/`workflow_approval_positions`/`workflow_work_items`, never `workflow_sla_
clocks`) is structurally impossible. The concurrency suite verifies six race scenarios
(concurrent pause vs. pause, concurrent escalation vs. escalation for the same level,
escalation vs. completion, restart vs. escalation, a duplicate idempotent command issued
twice concurrently, and two unrelated clocks proceeding independently) and confirms five
invariants directly: no duplicate escalation level, no duplicate evidence, no event-
sequence collision, no lost updates, and no deadlocks.

## Performance

Measured at ~10,000 active clocks, ~10,000 completed/cancelled clocks (large historical
tail), 100,000 `workflow_sla_clock_events` rows, a 4-level escalation policy attached to
2,000 clocks, and a realistic 26-holiday business calendar. All six measured operations
(clock creation, a pause+resume cycle, warning recording, breach recording, manual
escalation against a 4-level policy, and the three due-detection queries) completed in
single-digit-to-low-double-digit milliseconds. `EXPLAIN` confirms the breach-due access
path (`state = 'running' AND breached_at IS NULL`, ordered by `effective_deadline_
adjusted`) uses the partial index `idx_workflow_sla_clocks_breach_due`, never a sequential
scan, at this scale. No additional index was added beyond the two partial indexes already
present in the schema (`idx_workflow_sla_clocks_active_deadline`, `idx_workflow_sla_clocks_
breach_due`) — none proved necessary at the tested scale.

## Rollback

Every one of the eight tables this phase creates is wholly new — no prior data was ever
possible in any of them — so the rollback follows the Phase 5.1 "refuse if any row exists"
precedent exactly, not the "protect real activated work" precedent used elsewhere: any row
present at rollback time, including administrative configuration (a published calendar
version or escalation policy is itself immutable business evidence once created, not draft
state), is necessarily real work a permissive rollback would silently destroy. The rollback
refuses outright if any of the eight tables is non-empty. Verified: a clean rollback against
an empty (pre-fixture) baseline reproduces a `pg_dump --schema-only` and public-function-
list output byte-identical to a true independent pre-5.3 baseline; the rollback validator
passes; the patch reapplies cleanly afterward with the structural and behavioral suites
passing again; the refusal path correctly blocks rollback when real data exists, with zero
partial rollback (the refusing check runs before any `DROP` inside the same transaction).

## Testing

Structural validator, a 47-scenario behavioral suite (clock creation/idempotency/
authorization, pause/resume/repeated cycles, restart including history preservation,
completion/cancellation and terminal immutability at both the RPC and database level,
warning/breach threshold recording and due-detection reflection, ordered/idempotent/
rejected manual escalation across all the boundary conditions, calendar business-hours/
holiday/timezone/version-stability behavior, no-visibility-grant and no-automatic-decision
verification, delegation coexistence, work-item-assignee authorization, cross-organization
rejection, and config-validation negative cases), an 8-scenario RLS suite, a 6-scenario/
5-invariant concurrency suite, and a 6-dimension performance suite. The full CAP-002
regression sweep (63 structural/behavioral/RLS/concurrency/performance files, Phase 1
through 5.3) passes with zero failures.

Eleven earlier phases' structural/RLS validators hardcode an exact `workflow_%` table
count as a schema-drift detector; each was updated from 16 to 24 to reflect this phase's 8
new tables, exactly mirroring how Phase 5.1 itself updated the same assertions from 12 to
16 when it added its own 4 tables. This is a superseding update to a numeric drift-detector
constant, not a change to any of those phases' approved architecture or behavior — every
other assertion in every one of those files is untouched, and the regression sweep confirms
each phase's actual functional behavior is unaffected.

## Limitations and explicitly deferred functionality

The following are deliberately out of scope for this phase and are not implemented in any
form, per the governing instruction:

- **No automatic worker.** Nothing in this patch periodically scans for due warnings,
  breaches, or escalation levels and executes them. The due-detection functions exist so a
  future milestone can build that dispatcher; this phase never invokes them on a schedule.
- **No notification delivery.** `remind_actor`, `notify_supervisor`, `create_exception_
  work_item`, `route_higher_scope`, `add_replace_candidates`, and `follow_branch` are
  recorded as evidence only — none of them sends an email, SMS, push notification, or
  otherwise delivers anything outside the database.
- **No module adapters or module-specific integrations.**
- **No frontend, admin UI, or visual designer** for calendars, SLA policies, or escalation
  policies — configuration is created exclusively via the RPCs in this patch.
- **No new gateway or approval semantics.** Escalation never advances the graph, never
  records a decision, and never mutates any existing `workflow_events` event type.

Four narrow, explicitly resolved implementation decisions (restart's trigger mechanism,
manual-escalation's evidence-only vs. real-effect split, the warning/escalation-offset
lead-time simplification, and the RLS-predicate grant fix) are documented inline above,
each concretizing a detail docs/73 left open rather than changing anything docs/73
actually specifies.
