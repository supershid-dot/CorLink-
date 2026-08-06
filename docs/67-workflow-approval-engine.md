# CAP-002 Phase 3.1 — Generic Approval Decision Engine

## Scope

This milestone implements docs/63's "Decision immutability and replay",
"Outcome calculation", "Sequential delivery", "Parallel delivery", and
"Work-item contract" sections for executable-v1 instances on top of the
inert Phase 1 foundation (`docs/61-workflow-backend-foundation.md`), the
Phase 2 instance lifecycle (`docs/62-workflow-runtime.md`), the Phase 2B.1
executable definition validator (`docs/64-workflow-definition-validation.md`),
the Phase 2B.2 instance activation checkpoint
(`docs/65-workflow-instance-activation.md`), the Phase 2B.2A event-
sequencing correction, and the Phase 2C.1 graph advancement foundation
(`docs/66-workflow-graph-advancement-foundation.md`).

It implements exactly one new command, `decide_workflow_work_item()`,
recording an immutable approve/reject/abstain decision against one
assigned, actionable work item; recalculating the round's unanimous or
majority outcome from the immutable per-round `approval_threshold` Phase
2B.2/2C.1 already compute and store at round-open time; progressing
sequential delivery to the next pending position when the round remains
open; and, when the round reaches a terminal outcome, completing the
approval step and invoking the exact same shared graph-advancement helper
(`workflow_enter_downstream_node`, Phase 2C.1) that activation and generic
advancement already use — never a second copy of that logic. It implements
no routing, gateways, conditional branching, timers, notifications,
delegation, escalation, module adapters, or frontend.

## Approval lifecycle

A round opens (Phase 2B.2/2C.1, unchanged by this milestone) with all
positions snapshotted and an immutable `approval_threshold` computed. From
there, this milestone's own contribution is entirely decision-driven:

1. An assigned voter calls `decide_workflow_work_item()` against their own
   offered work item with `approve`, `reject`, or `abstain`.
2. The decision is recorded immutably, the work item is completed, and the
   voter's position moves to `decided`.
3. The round's outcome is recalculated from every position's linked
   decision. If the round is still open, delivery-mode-specific progression
   happens (see below) and nothing else changes.
4. If the round reaches a terminal outcome (`approved` or `rejected`), the
   round is closed, every remaining offered work item and unoffered
   position in that round is cancelled atomically, the approval step is
   completed with that outcome as its `result_code`, and the shared
   downstream-entry helper is invoked to advance the graph — exactly the
   same helper Phase 2C.1's `workflow_advance_graph_step` and Phase 2B.2's
   activation path already use.

## Delivery models

- **Parallel**: every position's work item is already offered at round-open
  (Phase 2B.2/2C.1, unchanged). A nonterminal parallel decision creates
  nothing further — every other position simply remains `offered` until its
  own decision lands or the round closes.
- **Sequential**: only the ordinal-1 position's work item is offered at
  round-open. After a nonterminal accepted decision, this milestone
  atomically creates the next lowest-ordinal `pending` position's work item
  (`state = 'offered'`), updates that position, inserts its
  `workflow_participants` candidate row, and emits `work_item_created` — one
  new offer per nonterminal decision, never more than one position open at
  a time. When the round reaches a terminal outcome, any still-`pending`
  (never-offered) positions are cancelled without a work item to cancel and
  without their own event, matching docs/63's "cancellation records reason
  codes in events rather than adding a superseded work-item state."

## Decision models

`N` is the round's immutable `electorate_count`. `A`/`R`/`B` are the
approve/reject/abstain counts recomputed from every position's linked
decision on each call; `U = N - A - R - B` is undecided. The immutable
`approval_threshold` (`T`) was already computed and stored at round-open
time by Phase 2B.2/2C.1's shared helper — unanimous rounds store `T = N`,
majority rounds store `T = max(floor(N/2)+1, minimum_approvals)` (or
`floor(N/2)+1` alone if unconfigured) — so this milestone reads `T`
directly rather than recomputing it, avoiding a second copy of that
arithmetic.

Evaluation order on every decision:

1. **Immediate rejection**: `reject_behavior = 'immediate' AND R >= 1` →
   `rejected`, terminal.
2. **Approved**: `A >= T` → `approved`, terminal.
3. **Approval impossible**: `A + U < T` → `rejected`, terminal (this also
   resolves any remaining non-immediate rejection case, per docs/63).
4. Otherwise the round stays open.

Abstention never counts toward approval and never reduces `N`, but does
reduce `U` (an abstained position is no longer undecided). This is verified
against docs/63's own worked example: `N=4, A=2, B=2, R=0` → `U=0`,
`T=3` → `A >= T` is false, `A+U < T` → `2 < 3` is true → **rejected** —
"two approvals and two abstentions reject it," exercised as a dedicated
behavioral scenario.

`allow_abstain=false` on a round rejects an `abstain` decision outright.
`comment_policy` (`required`/`optional`/`forbidden`, already validated at
definition-publish time by Phase 2B.1) is enforced at decision time per
decision code: a `required` comment missing, or a `forbidden` comment
present, is rejected before any row is written.

## Vote recording

`decide_workflow_work_item(p_work_item_id, p_decision_code,
p_expected_instance_lock_version, p_expected_work_item_lock_version,
p_command_id, p_comment DEFAULT NULL)`:

1. Authenticate (`workflow_actor_is_active()`, reused unchanged).
2. Acquire the caller/instance/command advisory lock (a distinct
   `'workflow_decision:'` namespace), then lock the instance row.
3. Idempotency-replay check on `(instance_id, command_id)` — identical
   semantics to every other command in this codebase: same key + same
   input replays the original result (read back from this command's own
   root event's metadata); same key + different input is rejected.
4. Verify `expected_instance_lock_version` and that the instance is
   `active`.
5. Lock order: step → round (must be `open`) → position (must belong to
   that round and be `offered`) → work item (must be `offered`). The
   caller must be the position's exact assigned voter
   (`work_item.assigned_to = auth.uid()`) — see Authorization below.
6. Verify `expected_work_item_lock_version`, abstention eligibility, and
   comment policy.
7. Insert the immutable decision row, complete the work item, mark the
   position `decided` — no events yet.
8. Recompute `A/R/B/U` and the terminal/nonterminal outcome. If terminal,
   **also** resolve the downstream edge/target-node/target-type and
   compute the transaction's true final `instance_status`/
   `terminal_outcome` at this point — mirroring exactly how
   `workflow_advance_graph_step` pre-computes its own final status before
   its root event, because `workflow_events` is append-only and the shared
   replay path reads these exact fields back from this command's own root
   event on retry (see "A shared replay-metadata discipline" below).
9. Insert `decision_recorded` (this command's root/canonical event, sequence
   number captured before any further insert), then `work_item_completed`.
10. If nonterminal: sequential delivery offers the next pending position
    (see above); update the round's `lock_version` and the instance's
    `lock_version`/`next_event_sequence` directly.
11. If terminal: close the round (`approval_round_completed`), cancel every
    remaining offered work item and position
    (`work_item_cancelled` × actually-offered count), cancel any never-
    offered pending positions without an event, complete the approval step
    (`step_completed`), then call `workflow_enter_downstream_node` directly
    — not the public `workflow_advance_graph_step` RPC, which would require
    inventing a second, synthetic idempotency key and would emit a
    confusing extra root event from within an already-locked transaction.
    The shared helper performs the transaction's own final, authoritative
    `workflow_instances` update.

### A shared replay-metadata discipline

Every command's idempotency-replay path in this codebase reads its own
final-outcome fields back out of its own root event's metadata on retry,
because `workflow_events` is append-only. `decide_workflow_work_item`
follows the exact same discipline `workflow_advance_graph_step` established:
the value returned as `event_sequence` is the root `decision_recorded`
event's own sequence number, captured once at insert time
(`v_root_seq := v_seq`) — never derived from `v_seq` after later inserts or
the downstream-helper call have advanced it further. An early draft of this
function initially returned the sequence of whichever event happened to be
inserted last (which, for a terminal decision, is several events and one
downstream-helper call past the root event), which would have made a fresh
call's return value diverge from what a replay of the same command returns.
This was caught and fixed before this milestone's suites were written; the
now-committed function returns the root event's own sequence number
consistently in both the original call and every replay.

## Graph advancement integration

"Do not duplicate graph advancement logic" is satisfied by reusing
`workflow_enter_downstream_node` (Phase 2C.1) for the entirety of
downstream-entry mechanics (candidate resolution, round-opening,
atomic End-completion) — the same helper `workflow_transition_instance`
(activation) and `workflow_advance_graph_step` (generic advancement)
already call. The small (~15-line) edge-selection glue query — re-verify
publication integrity, select the one edge matching
`(step.definition_node_key, outcome)`, resolve the target node/type — is
written a third time here, matching the same precedent already established
between `workflow_transition_instance` and `workflow_advance_graph_step`:
this is trivial, bounded lookup code, not the substantial mechanics, which
remain centralized in exactly one place.

Phase 2C.1's own documentation noted its Approval-sourced advancement path
"has no live production trigger until Phase 3 exists" — this milestone is
that trigger. `workflow_advance_graph_step` itself remains fully usable and
unchanged for any future non-approval terminal-result source; this
milestone does not call it and does not modify it.

## Events

No new event types beyond `decision_recorded` (new, this command's root
event), `work_item_completed`, `work_item_created` (sequential progression
only), `approval_round_completed`, `work_item_cancelled`, and
`step_completed` — all names already used or anticipated elsewhere in
docs/63's event vocabulary. Event ordering for a terminal decision:
`decision_recorded` → `work_item_completed` → `approval_round_completed` →
`work_item_cancelled` × N (one per actually-offered cancelled item; none
for never-offered pending positions) → `step_completed` (the approval step)
→ whatever `workflow_enter_downstream_node` itself emits (`token_moved`,
`step_entered`, then either End-completion or Approval-round-opening
events). Sequencing is contiguous and gap-free, verified by a dedicated
assertion helper after every behavioral scenario.

## Authorization

**A deliberately different boundary from lifecycle commands.** Every prior
workflow command (`start`/`suspend`/`resume`/`cancel`/`complete`,
`workflow_advance_graph_step`) reuses `can_manage_workflow_instance()` —
the instance owner/manager boundary. Casting a decision is not a lifecycle
action: per docs/63, "managers and super administrators cannot cast another
person's vote unless they themselves hold that position." This milestone
therefore reuses a different existing primitive —
`work_item.assigned_to = auth.uid()` — rather than
`can_manage_workflow_instance()`, satisfying "reuse existing authorization
helpers; do not create a new permission model" by reusing the pre-existing
`assigned_to` column/pattern instead of inventing new state.
`decide_workflow_work_item()` is `SECURITY DEFINER` with `search_path =
public, pg_temp` pinned, granted to `authenticated` only (not `anon`),
matching every other command's posture.

## Concurrency

No new locking primitive. Lock order: caller/instance/command advisory lock
→ instance row → step → round → position → work item (the token itself
needs no lock at this layer — only the shared downstream-entry helper,
invoked on a terminal outcome, touches it). Every decision, terminal or
not, advances the instance's `lock_version`, so — exactly like every other
mutating workflow command — two truly concurrent decisions on the same
instance are serialized by instance-level optimistic concurrency: exactly
one succeeds immediately, the other receives a stale-version conflict and
must retry with the current lock version.
`test-workflow-approval-decision-engine-concurrency.sql` (7 independent-
`dblink`-session scenarios) confirms: duplicate votes on the same work item
converge to exactly one decision row; a duplicate command id issued
concurrently replays safely to an identical result; a majority round's
threshold-crossing race and a unanimous round's final-vote race are each
serialized to exactly one winner, with the loser's retry (at the current
lock version) completing the round exactly once; a sequential round's
next-position offer is created exactly once even under a replayed
concurrent decision; unrelated organizations' decisions proceed
independently with no unnecessary blocking; no deadlock was observed across
all scenarios.

## Rollback

`rollback-workflow-approval-decision-engine.sql`:

1. Drops `decide_workflow_work_item()`.
2. Drops the composite `(round_id, instance_id)`, `(position_id,
   instance_id)`, `(work_item_id, instance_id)`, and `(step_id,
   instance_id)` foreign keys and the `round_id`/`position_id` columns this
   patch added to `workflow_decisions`.
3. Drops the four purely-additive `UNIQUE(id, instance_id)` constraints on
   `workflow_instance_steps`, `workflow_approval_rounds`,
   `workflow_approval_positions`, and `workflow_work_items`.

**Refuses outright if any `workflow_decisions` row exists.** Unlike Phase
2C.1's rollback (which changed only function bodies and therefore never
refuses), this milestone is the first to write real rows into
`workflow_decisions`, with `round_id`/`position_id` added as `NOT NULL`.
Dropping those columns once a real decision has been cast would destroy
immutable evidence already recorded in the decision ledger — there is no
partial or safe rollback path once that has happened, so the script raises
an exception naming the row count and performs no schema change at all.

**Verification performed for this document**, against a disposable local
Postgres:

1. Built a true pre-Phase-3.1 baseline (Phase 1+2+2B.1+2B.2+2B.2A+2C.1
   chain, this patch never applied) and captured
   `\d workflow_decisions`/`\d workflow_instance_steps`/`\d
   workflow_approval_rounds`/`\d workflow_approval_positions`/`\d
   workflow_work_items` and `to_regprocedure` for
   `decide_workflow_work_item`.
2. Applied this patch (no decisions cast), ran rollback, re-captured the
   same — **byte-for-byte identical** to the true baseline for every table,
   and `decide_workflow_work_item` absent in both.
3. Ran `validate-workflow-approval-decision-engine-rollback.sql` — PASSED.
4. Separately, applied this patch and cast one real decision, then attempted
   rollback — **refused**, exactly as designed, with the schema and
   function left fully intact (verified: `decide_workflow_work_item` still
   present, `round_id`/`position_id` still present) after the refusal.
5. Reapplied the patch to the first (no-decisions) database; re-ran the
   structural validator and the full behavioral suite — all PASSED,
   confirming clean reapplication.

## Testing

All suites run against a disposable local Postgres — never staging or
production.

- `validate-workflow-approval-decision-engine.sql` — structural:
  `decide_workflow_work_item` is authenticated-only, `SECURITY DEFINER`,
  pinned `search_path`; reuses `workflow_actor_is_active`,
  `workflow_enter_downstream_node`, assignment-based `assigned_to`
  authorization, `canonicalize_workflow_definition_payload`, and the
  immutable `approval_threshold`; carries no duplicated candidate-
  resolution or routing logic; `workflow_decisions` gained the enforced
  `round_id`/`position_id` composite linkage and all four
  `(id, instance_id)` unique constraints exist; no out-of-scope RPCs; table
  count unchanged (12); prior-phase baseline intact.
- `test-workflow-approval-decision-engine.sql` — **18/18** behavioral
  scenarios: unanimous approval; unanimous rejection (immediate);
  majority approval; majority rejection (approval-impossible); abstention
  (docs/63's own N=4/A=2/B=2 worked example); duplicate votes; unauthorized
  voting (including by the instance's own manager/admin); sequential
  approvals (offer progression, terminal cancellation of never-offered
  positions); parallel approvals (all offered up front, no extra offers on
  a nonterminal decision); replay (both nonterminal and terminal); graph
  advancement after completion (into a second approval round, then into
  End, token consumed); comment-policy enforcement; abstention disallowed
  by round configuration; stale instance/work-item lock version rejection;
  reused idempotency key with different input rejected; a late decision
  after round closure rejected without inserting ledger telemetry;
  cross-organization actor rejected.
- `test-workflow-approval-decision-engine-rls.sql` — **7/7** scenarios (see
  "Authorization" and "Concurrency" above): same-org non-assigned outsider
  rejected; the instance owner/admin (despite managing the lifecycle)
  still cannot decide another actor's work item; cross-org actor rejected;
  the exact assigned voter succeeds; `workflow_decisions` has no direct
  write grant; `workflow_decisions` SELECT visibility remains governed by
  the existing `can_view_workflow_instance()` policy; the function reuses
  `workflow_actor_is_active`/`assigned_to`, not a new permission model.
- `test-workflow-approval-decision-engine-concurrency.sql` — **7/7**
  scenarios (see "Concurrency" above).
- `test-workflow-approval-decision-engine-performance.sql` — 3 dimensions:
  a minimal single-elector terminal decision (~12-16 ms); a maximal
  100-candidate round's threshold-crossing (51st) decision, cancelling the
  49 remaining offered work items atomically (~23-26 ms); a decision
  against an instance whose event table already has 100,000 rows
  (~5-6 ms), with `EXPLAIN (ANALYZE, BUFFERS)` confirming the existing
  `workflow_events_sequence_unique` index is used via an efficient
  backward index scan, not a sequential or bitmap-heap scan.
- Full repository regression: every applicable Phase 1/2/2B.1/2B.2/2B.2A/
  2C.1 validator, behavioral suite, RLS suite, concurrency suite, and
  performance probe re-run against the final chain including this patch —
  zero failures, including Phase 2C.1's own 21 behavioral scenarios (which
  exercise its `wfga_simulate_decision` test-only fake-decision helper)
  passing unchanged now that a real decision path exists alongside it.

## Limitations

- **No routing, gateways, conditional branching, timers, notifications,
  delegation, escalation, module adapters, or frontend.** Unchanged from
  every prior workflow-engine phase — none has been approved yet.
- **Optional approval with zero resolved candidates still fails closed**,
  and the docs/63-described "skip and follow the `skipped` edge" behavior
  remains unimplemented — unchanged from Phase 2C.1's own documented
  limitation, since this milestone does not touch round-opening mechanics.
- **A rejected round always follows its single `rejected` edge** — there is
  no per-decision-code branching beyond the two outcomes (`approved`/
  `rejected`) the executable-v1 graph contract already defines; distinct
  routing on `reject` vs. an "approval impossible" rejection is out of
  scope, matching docs/63's own outcome model.
- **Rollback is one-way once a decision has been cast.** By design: the
  immutable decision ledger cannot be safely un-shaped once it holds real
  evidence, so the rollback script refuses rather than silently discarding
  data or leaving it orphaned by a dropped `NOT NULL` column.
