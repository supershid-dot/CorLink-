# CAP-002 Phase 2C.1 — Generic Graph Advancement Foundation

## Scope

This milestone implements docs/63's "Generic graph-advancement contract" for
executable-v1 instances on top of the inert Phase 1 foundation
(`docs/61-workflow-backend-foundation.md`), the Phase 2 instance lifecycle
(`docs/62-workflow-runtime.md`), the Phase 2B.1 executable definition
validator (`docs/64-workflow-definition-validation.md`), the Phase 2B.2
instance activation checkpoint (`docs/65-workflow-instance-activation.md`),
and the Phase 2B.2A event-sequencing correction.

It implements the private, generic "outcome-to-edge" routine: given the
instance's current token already sitting at a step that already carries
exactly one terminal result (a `result_code` set by some other,
already-authorized process), select the one matching outbound edge,
complete the source step, move the token, create the target step run, and
execute only that target node's allowlisted entry behavior — Approval:
resolve candidates and open a round, exactly like Phase 2B.2's first-node
entry; End: complete the node and the instance atomically. It records no
decision, calculates no approval outcome, and advances nothing beyond the
one resolved downstream node.

## What determines a step's terminal result

This milestone deliberately does **not** implement anything that can put an
Approval step into a `completed` state with a `result_code` — that
mechanism is Phase 3's decision RPCs, explicitly out of scope here. In the
current system, the only way a step reaches that precondition is Phase
2B.2's own Start-step handling (unchanged) or a future Phase 3 decision.
This means `workflow_advance_graph_step()`'s Approval-sourced path has no
live, production-reachable trigger yet — it is a complete, tested,
ready-to-use primitive with no caller until Phase 3 exists to record a
decision and invoke it. This is not an oversight: docs/63's own phase
breakdown describes exactly this staged split ("Add bounded graph
advancement and internal executable completion" as its own step, "Add
approval decision RPCs only after activation and advancement validators
pass" as the next). The milestone's own test suite manufactures the
precondition directly via a `SECURITY DEFINER` test-only helper
(`wfga_simulate_decision`), the same technique Phase 2B.2's own tamper test
used to exercise an otherwise-unreachable condition.

## A shared helper, not a second implementation

Phase 2B.2's activation code already proved the "enter a downstream node"
mechanics correct (Approval: candidate resolution, round/position/work-item
creation; End: atomic node-and-instance completion). Rather than write a
second copy of that logic for advancement, this milestone extracts it into
one new private function, `workflow_enter_downstream_node()`, and
**activation itself now calls it** — `workflow_transition_instance()`'s
`'start'` branch was refactored (via `CREATE OR REPLACE`, the same pattern
every prior phase used to extend this function) to call the shared helper
instead of carrying its own inline copy. This is a pure extraction, not a
redesign: the refactored activation path's externally observable behavior
(every event, its exact sequence number and metadata, every return value)
is byte-for-byte identical to the approved Phase 2B.2/2B.2A baseline —
verified by re-running all 40 Phase 2B.2 behavioral scenarios, all 6 RLS
scenarios, and all 11 Phase 2B.2A sequencing-correction scenarios unchanged
against the refactored code, with zero failures. `workflow_advance_graph_step()`
(this milestone's new command) calls the exact same shared helper, so
Approval-node entry mechanics are implemented and tested in exactly one
place.

## Advancement flow

`workflow_advance_graph_step(p_instance_id, p_expected_lock_version, p_idempotency_key)`:

1. Authenticate and authorize (`workflow_actor_is_active()`,
   `can_manage_workflow_instance()` — reused unchanged, no new permission
   model).
2. Acquire the caller/instance/idempotency advisory lock (a distinct
   `'workflow_advance:'` namespace from `workflow_transition_instance`'s
   own `'workflow_runtime:'` prefix, so the two commands' advisory-lock key
   spaces can never collide), then lock the instance row.
3. Idempotency-replay check — identical semantics to
   `workflow_transition_instance`: same key + same input replays the
   original result; same key + different input is rejected.
4. Verify `expected_lock_version` and that the instance is `active`.
5. Re-verify the pinned executable version's publication integrity
   (re-run `canonicalize_workflow_definition_payload()` against the stored
   payload, compare both the canonical JSONB and recomputed hash to what's
   stored) — the exact same defense-in-depth check activation performs.
6. Discover the current step through the instance's sole active token
   (never a client-selected target node — docs/63's own requirement).
7. Verify that step already carries exactly one terminal result
   (`state = 'completed'` and `result_code IS NOT NULL`).
8. Select the edge selection and downstream entry (below).

## Edge selection

Exactly one outbound edge is selected whose `source` matches the current
step's `definition_node_key` and whose `outcome` matches the step's
`result_code` — already structurally guaranteed to exist and be unique by
the Phase 2B.1 validator ("every producible outcome has exactly one
edge"), so this is a re-derivation, not a re-validation. The routine never
accepts a client-supplied edge, table name, function name, or SQL fragment
— it is a private, bounded routine exactly as docs/63 requires.

Version-1's node universe is `start`/`approval`/`end`. `start` can never be
a legal advancement target — zero inbound edges is enforced at
publication — so it is structurally unreachable through the public
surface; the shared helper rejects it defensively (`Unsupported graph node
type`) purely as defense-in-depth, verified by inspection rather than a
reachable negative test, matching the precedent Phase 2B.1 set for its own
structurally-unreachable rules.

## Token movement and downstream entry

The shared helper (`workflow_enter_downstream_node`) performs, in order:
create the target step run (`run_number` computed generically via
`COALESCE(MAX(run_number),0)+1`, which evaluates to `1` for both callers'
real usage today), move the token (`UPDATE workflow_tokens SET step_id =
...`), emit `token_moved` then `step_entered` for the target, then branch
on the target node's type.

## Terminal completion

If the target is `End`: the step's `result_code` is set to the node's own
static `outcome_code`, the step is marked completed, the token is marked
`consumed`, and the instance transitions straight to `status = 'completed'`
with that outcome as `terminal_outcome` — the exact same bounded,
docs/63-authorized Start→End special case Phase 2B.2 already established,
now reachable from any source node, not only Start. `step_completed` and
`instance_completed` events close out the transaction. Nothing further is
attempted — End has no outbound edges, so there is nowhere further to go.

## Approval-node entry

If the target is `Approval`: candidates are resolved via the identical
selector logic Phase 2B.2 already established (all four selector types,
`allow_self_approval`/`allow_multi_capacity` rules, ordering by `(selector
order, selector key, authority source, user id)`), a new
`workflow_approval_rounds` row is opened, and initial work items are
created for whichever positions the node's `delivery_mode` makes
immediately actionable (all of them for `parallel`, only ordinal 1 for
`sequential`) — no decision is recorded and nothing is completed. The
electorate-sizing rules (required-undersized rejection, optional-zero-
candidate fail-closed, optional-nonzero-undersized rejection) are the exact
same conservative resolution Phase 2B.2 already established for the first
node, now applied identically to every subsequent Approval node a future
decision might advance into. The optional-zero-candidate case in
particular is documented there as a deliberate, bounded limitation: the
docs/63-described "skip and follow the `skipped` edge" behavior is itself
a second graph-advancement hop within one command, which this milestone's
bounded single-hop-per-command design does not perform — it fails closed
with a distinct error naming the future extension, exactly as Phase 2B.2
did.

## Events

No new event type was introduced. Events follow docs/63's existing minimum
graph-event set: `step_completed` (source step, this command's root/
canonical event), `token_moved`, `step_entered` (target), then either
`step_completed` + `instance_completed` (End) or `approval_round_opened` +
`work_item_created` × offered-count (Approval). `event_sequence` numbers
are reserved starting from the instance's own live `next_event_sequence`
at the moment of the call, in the same `UPDATE` that also advances
`lock_version` — keeping both counters consistent with what is actually
inserted, exactly matching the Phase 2B.2A-corrected pattern (the
increment used here, `7 + offered_count` on the Approval path via the
shared helper's internal accounting, is verified by dedicated regression
scenarios at electorate sizes 1, 2, 3, and 5 under both delivery modes,
confirming the Phase 2B.2A sequencing defect class cannot reappear on this
new path).

**The same metadata subtlety Phase 2B.2A fixed applies here too**: the
shared, unmodified idempotency-replay code reads `new_status`/
`terminal_outcome` back out of this command's own root event
(`step_completed` on the source step) on retry. Since `workflow_events` is
append-only and can never be revised after insertion, the caller computes
the transaction's true final status/outcome (`'completed'`+outcome for an
End target, `'active'`+`NULL` for an Approval target) *before* inserting
that root event, from the already-resolved target node's own type/config —
never from a later `UPDATE`.

## Authorization

No new permission model. `workflow_advance_graph_step()` reuses
`workflow_actor_is_active()` and `can_manage_workflow_instance()`
unchanged — the exact same authorization boundary every other lifecycle
command already uses. It is `SECURITY DEFINER` with `search_path = public,
pg_temp` pinned, granted to `authenticated` (not `anon`), matching the
5 existing wrapper RPCs' posture. `workflow_enter_downstream_node()` is
fully private — revoked from `PUBLIC`, `anon`, and `authenticated` — since
it performs no independent authorization check of its own and trusts the
caller's already-established boundary, matching the precedent
`canonicalize_workflow_definition_payload()` set in Phase 2B.1.

## RLS

Zero new tables, zero new policies. This milestone reuses Phase 2B.2's
storage shape unchanged (still exactly 12 `workflow_*` tables).
`test-workflow-graph-advancement-foundation-rls.sql` (6 scenarios)
confirms: the instance owner/manager can call `workflow_advance_graph_step`
successfully; a same-organization non-manager outsider cannot, with a
non-disclosing error; a cross-organization actor cannot; the shared helper
has no direct execute grant to `authenticated` or `anon`; no new table or
policy exists; `can_manage_workflow_instance()` is reused, not duplicated.

## Concurrency

No new locking primitive and no change to lock order. Advancement acquires
its own advisory lock (a distinct namespace from the 5 lifecycle commands'
own), then the instance row, then the current step row, then the token row
— step-before-token, matching docs/63's documented global order.
`test-workflow-graph-advancement-foundation-concurrency.sql` (6
independent-`dblink`-session scenarios) confirms: two simultaneous
advancements converge on exactly one successful runtime state; a
duplicate-key replay issued concurrently converges safely; advancement
racing cancellation produces exactly one valid serialized final state with
no dangling open work; advancement racing a second, distinct advance
command does not duplicate runtime rows; unrelated organizations' 
advancements proceed independently with no unnecessary blocking; no
deadlock was observed across all scenarios.

**Duplicate node completion is prevented structurally**, not by a new
check: the "current step" is always freshly re-derived from the token's
own live position, never cached or client-supplied. Once a token has moved
past a step, that step is no longer what any subsequent discovery query
finds, so a stale or repeated advancement attempt naturally targets
whatever the token's *current* position actually is — which will either
lack a terminal result (rejected) or, if somehow already advanced past,
simply be unreachable as "the current step" at all.

## Performance

`test-workflow-graph-advancement-foundation-performance.sql` measures three
dimensions new to this milestone (the version-lookup/canonicalization
scaling Phase 2B.2 already proved is reused unchanged, not re-measured):

1. Minimal single-hop advancement (Approval[1 candidate] → End) — ~6-8 ms.
2. Maximal 100-candidate second-hop snapshot — ~50-55 ms, asserting exactly
   100 resolved positions.
3. Advancement against an instance whose event table already has 100,000
   rows — ~6 ms; `EXPLAIN (ANALYZE, BUFFERS)` on the instance's own
   recent-event query confirms the existing `workflow_events_sequence_unique`
   index is used via an efficient backward index scan (0.06 ms), not a
   sequential or bitmap-heap scan.

All three are well under generous regression bounds. **No speculative
index was added** — the measured `EXPLAIN` evidence showed an existing
index already being used correctly.

## Rollback

`rollback-workflow-graph-advancement-foundation.sql`:

1. Drops `workflow_advance_graph_step()`.
2. Restores `workflow_transition_instance()` to its exact pre-2C.1 (Phase
   2B.2A-corrected) body — copied verbatim from
   `supabase/patch-workflow-activation-event-sequence-correction.sql` (a
   file this patch never edited).
3. Drops `workflow_enter_downstream_node()`.

**Never refuses**, unlike the definition/activation rollbacks earlier in
this chain: this milestone adds no table and deletes no row. Any instance
already advanced via `workflow_advance_graph_step` has its state fully
represented in the unchanged, pre-existing Phase 2B.2 tables — rollback
only removes the ability to advance further until reapplied; there is
nothing for a preflight check to protect.

**Verification performed for this document**, against a disposable local
Postgres:

1. Built a true pre-2C.1 baseline (Phase 1+2+2B.1+2B.2+2B.2A chain, this
   patch never applied) and captured `pg_get_functiondef('workflow_
   transition_instance(...)')` and its grants.
2. Applied this patch, ran rollback, re-captured the same function
   definition and grants — **byte-for-byte identical** and **grant-
   identical** to the true baseline.
3. Ran `validate-workflow-graph-advancement-foundation-rollback.sql` —
   PASSED.
4. Reapplied `patch-workflow-graph-advancement-foundation.sql`; re-ran the
   structural validator, all 21 behavioral scenarios, and all 6 RLS
   scenarios — all PASSED, confirming clean reapplication.

## Testing

All suites run against a disposable local Postgres — never staging or
production.

- `validate-workflow-graph-advancement-foundation.sql` — structural: the
  shared helper is private and pinned; `workflow_advance_graph_step` is
  authenticated-only and reuses existing authorization; activation's
  `workflow_transition_instance` now calls the shared helper with no
  duplicated candidate-resolution logic remaining inline; the 5 wrapper
  RPCs and Phase 1/2/2B.1/2B.2 baseline are intact; no out-of-scope RPCs
  exist.
- `test-workflow-graph-advancement-foundation.sql` — **21/21** behavioral
  scenarios: advancing a completed Approval into a second Approval (round/
  positions/work items created, nothing decided); a second advancement
  from that round into End (atomic completion); idempotent replay; a
  fresh-key stale-version rejection; no-active-token rejection; suspended-
  instance rejection; no-terminal-result rejection; legacy-instance
  rejection; tampered-payload atomic failure; retired-version rejection;
  sequential delivery still offering exactly 1 work item; optional-second-
  hop zero-candidate fail-closed; required-second-hop undersized-
  electorate atomic failure; cancellation after a second-hop entry closing
  that round too; later suspend/resume succeeding; and 5 dedicated odd-
  electorate-size (1,2,3,4,5) regression scenarios each confirming
  contiguous sequencing and a successful later cancel — directly
  regression-testing that the Phase 2B.2A sequencing defect class cannot
  reappear on this new path.
- `test-workflow-graph-advancement-foundation-rls.sql` — **6/6** scenarios
  (see "RLS" above).
- `test-workflow-graph-advancement-foundation-concurrency.sql` — **6/6**
  scenarios (see "Concurrency" above).
- `test-workflow-graph-advancement-foundation-performance.sql` — 3
  dimensions (see "Performance" above).
- Full repository regression: every applicable Phase 1/2/2B.1/2B.2/2B.2A
  validator, behavioral suite, RLS suite, concurrency suite, and
  performance probe re-run against the final chain including this patch —
  zero failures, including all 40 Phase 2B.2 behavioral scenarios and all
  11 Phase 2B.2A sequencing-correction scenarios passing byte-for-byte
  unchanged against the refactored activation code.

## Limitations

- **No approval decisions, outcome calculation, or voting.** Exactly as
  scoped: Phase 3 (the Approval Engine) remains a separate, future,
  separately-approved milestone. This milestone's Approval-sourced
  advancement path has no live production trigger until Phase 3 ships and
  records a decision.
- **Optional approval with zero resolved candidates fails closed** rather
  than skipping and advancing a second hop — a narrow, transparent,
  deliberately conservative choice, not an oversight, matching Phase
  2B.2's own established resolution for the identical tension at the
  first node.
- **No routing, gateways, conditions, timers, notifications, delegation,
  module adapters, or frontend.** Unchanged from every prior workflow-
  engine phase — none has been approved yet.
