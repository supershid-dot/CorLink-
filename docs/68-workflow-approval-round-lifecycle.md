# CAP-002 Phase 3.2 — Approval Round Lifecycle

## Scope

This milestone completes the generic approval-round lifecycle defined by
docs/63, on top of the Phase 2C.1 graph-advancement foundation
(`docs/66-workflow-graph-advancement-foundation.md`) and the Phase 3.1
approval decision engine (`docs/67-workflow-approval-engine.md`). It
implements: optional-approval empty-electorate skip-and-continue; skipped-
voter handling; a manager-gated unavailable/blocked-voter count; late-
decision rejection; database-enforced immutable round completion and round
history; safe round replacement; replay-safe and concurrency-safe round
closure. It implements no routing, gateways, delegation, escalation,
timers, notifications, adapters, frontend, or workflow designer, and no new
decision model beyond docs/63's existing required/optional and
sequential/parallel/unanimous/majority rules.

## The gap this milestone closes

Phase 2C.1 and Phase 3.1 both documented the same known, deliberately
deferred limitation: a zero-candidate optional Approval node caused
`workflow_enter_downstream_node` to fail closed, because "skip-and-advance
requires a future graph-advancement extension, not implemented in Phase
2C.1." This contradicted docs/63's own "Optional approval" contract:
"Zero resolved positions creates a skipped round/step history, creates no
work item, emits the skip events, and follows `skipped`." This milestone
implements that contract exactly as written, and no more.

## Skip-and-continue mechanics

`workflow_enter_downstream_node` is rewritten from a single-entry function
to a loop bounded at 32 iterations — the same defensive maximum docs/63
itself uses for the generic graph-advancement contract. On a zero-candidate
optional node the loop:

1. Creates an immutable skipped round: `state = 'completed'`,
   `outcome_code = 'skipped'`, `electorate_count = 0`,
   `approval_threshold = 0` — exactly the value docs/63's own field
   contract reserves for this case ("zero only for a zero-electorate
   skipped round").
2. Creates no work item and no position.
3. Emits `approval_round_opened` → `approval_round_completed` →
   `step_skipped` — a distinct event type from `step_completed`, per
   docs/63's event vocabulary, so a skipped step's history is
   unambiguously distinguishable from a decided one on replay.
4. Resolves the node's own `skipped` edge and `CONTINUE`s the loop into
   the next node.

The loop stops only at a real End node (the instance completes) or a real
open Approval round (the instance waits). A node with one or more resolved
candidates is never skipped and behaves exactly as Phase 2B.2/2C.1/3.1
already specify — "if two candidates resolve, the node is not silently
skipped; it follows its normal decision rule," per docs/63.

A **chain** of consecutive zero-candidate optional nodes is fully
supported: each hop opens and immediately completes its own skipped round
before the loop continues, all inside the same transaction that started
or advanced the graph.

### Signature change

`workflow_enter_downstream_node` gained a 14th parameter, `p_canonical
JSONB` (the already-canonicalized definition payload), so the loop can
resolve `skipped` edges itself without re-fetching or re-canonicalizing.
All three existing callers — `workflow_transition_instance`,
`workflow_advance_graph_step`, `decide_workflow_work_item` — now pass their
already-computed `v_canonical` through. The old 13-argument signature is
dropped, not overloaded, so no call site can silently keep invoking stale
fail-closed behavior.

## Replay-correctness for skip chains: the peek pattern

`workflow_events` is append-only. Every caller of the downstream-entry
helper pre-computes its own root event's `new_status`/`terminal_outcome`
metadata *before* inserting that root event, because a later replay of the
same command reads those fields back out of the already-recorded event
rather than recomputing them. Before this milestone, each caller did this
with a naive `CASE WHEN target_type = 'end' ...` check against the single,
immediately-resolved target node — correct when advancement is exactly one
hop, but wrong whenever a skip chain moves the true final status or
outcome past that immediate target.

This is solved with a peek-before-write pattern, factored into three new
shared, pure (non-mutating) functions:

- `workflow_resolve_approval_candidates(p_instance_id, p_home_organization_id, p_created_by, p_config)` —
  the exact candidate-resolution query (all four selector types, dedup
  check, ordering) extracted verbatim from the existing inline logic, so
  the real entry pass and the peek pass share one implementation and can
  never disagree.
- `workflow_classify_approval_electorate(p_requirement, p_electorate_count, p_minimum_candidates)` —
  returns `insufficient`/`skip`/`proceed`, likewise shared by both passes.
- `workflow_peek_final_graph_target(p_canonical, p_instance_id, p_home_organization_id, p_created_by, p_start_node_key, p_start_node)` —
  walks the same bounded 32-hop loop, read-only, using the two helpers
  above, and returns the true final node/type/status/outcome.

All three outer commands now call `workflow_peek_final_graph_target`
*before* inserting their own root event, and use its result for that
event's metadata — guaranteeing the metadata recorded at write time always
matches what the loop actually does moments later, and what a replay reads
back.

### A robustness side effect

The prior approval-branch code pre-computed
`next_event_sequence` with an arithmetic formula
(`v_seq + 1 + LEAST(...)`) — the same pattern that caused the Phase 2B.2A
defect. This milestone replaces that formula with a single final
`workflow_instances` update performed once after the loop concludes,
using the actual accumulated `v_seq` from the real event inserts that just
happened. This is structurally immune to arithmetic/reality mismatches
regardless of whether the loop takes one hop or many.

## Unavailable-voter handling

Re-reading docs63's "Candidate unavailability after snapshot" against the
already-approved engine found that most of it is already satisfied:
`workflow_actor_is_active()` already blocks a decision from an inactive
actor, a position is never reassigned or removed, other voters are
unaffected, and the round simply stays blocked with no automatic recovery
— "the round remains blocked... until a later approved recovery mechanism
operates" implies no version-1 auto-transition, so none was added.

The one genuinely new deliverable is docs/63's explicit requirement that
"the engine exposes a safe blocked/unavailable count only to authorized
workflow managers; it does not reveal hidden identity details":
`get_workflow_approval_round_blocked_count(p_round_id UUID) RETURNS
INTEGER`, `SECURITY DEFINER`, reusing `can_manage_workflow_instance()` for
authorization, granted to `authenticated` only. Its return type is a bare
`INTEGER` — structurally incapable of leaking identity regardless of what
its body queries.

## Safe round replacement

A new round opened for a subsequent node naturally supersedes the prior,
already-closed round — no new engine code was needed. A vote cast against
an old round's now-closed position is already rejected by the existing
preconditions (`round.state <> 'open'` / `position.state <> 'offered'`).
This milestone adds only test coverage confirming that behavior; see
Testing.

## Immutable round completion and round history

Docs/63's "database-enforced, not only private-function checks"
philosophy — already used elsewhere in this engine for the composite
`instance_id` invariant — is extended here with two new triggers,
defense-in-depth beneath the existing private-function preconditions:

- `workflow_reject_terminal_round_mutation()` on
  `workflow_approval_rounds`: unconditionally rejects `DELETE`, and
  rejects `UPDATE` when `OLD.state` is already `completed`, `cancelled`,
  or `failed`.
- `workflow_reject_terminal_position_mutation()` on
  `workflow_approval_positions`: the same shape, checking `OLD.state IN
  ('decided','cancelled','unavailable')`.

Both check `OLD.state`, not `NEW.state`, so the one legitimate transition
*into* a terminal state is unaffected — only mutation of an *already*
terminal row is rejected. Wired via `BEFORE UPDATE OR DELETE` triggers
`workflow_approval_rounds_immutable_after_terminal` and
`workflow_approval_positions_immutable_after_terminal`.

## Late decisions

Prevented deterministically and idempotently in every case docs/63 names:

- **After closure**: `round.state <> 'open'` fails the existing
  precondition in `decide_workflow_work_item`.
- **After replacement**: the old round is already closed by the time a new
  one opens, so the same precondition applies.
- **After cancellation**: an instance-level cancel leaves no `open` round
  to vote against.
- **After completion**: the instance is no longer `active`, failing the
  existing instance-status precondition before the round is even
  inspected.

None of these insert a row into the immutable decision ledger — a late
command fails before any telemetry is written, per docs/63's "fails
without inserting telemetry into the immutable decision ledger."

## Graph advancement and authorization reuse

No new graph-advancement logic exists outside `workflow_enter_downstream_node`
— the skip loop is an extension of the one existing shared helper, not a
second copy. No new authorization model was introduced:
`get_workflow_approval_round_blocked_count` reuses
`can_manage_workflow_instance()` exactly as every other manager-facing
workflow function does; nothing about voting authorization
(`work_item.assigned_to = auth.uid()`, Phase 3.1) changed.

## Events

No new event *types* beyond `step_skipped` (already present in docs/63's
vocabulary, simply unused until now). A skip hop emits
`approval_round_opened` → `approval_round_completed` → `step_skipped`,
then either `token_moved`/`step_entered` into the next node or the
terminal End-completion path — contiguous, gap-free sequencing verified by
the same assertion helper pattern used in every prior phase's suites, for
both single-hop and multi-hop skip chains, and confirmed replay-consistent.

## Concurrency

No new locking primitive and no change to the existing lock order (caller/
instance/command advisory lock → instance row → step → round → position →
work item). A skip hop is fully internal to the same transaction that
already holds these locks, so it introduces no new race window.
`test-workflow-approval-round-lifecycle-concurrency.sql` (6 independent-
`dblink`-session scenarios) confirms: two concurrent advancement calls
racing into and through a skip converge to exactly one winner and the
correct total round count; same-idempotency-key concurrent replay through
a skip converges; same-command-id concurrent decisions whose closure
advances through a skip converge to exactly one decision row; an
advance-through-skip race against a cancellation resolves to one valid
final state; unrelated organizations proceed independently; no deadlock
was observed.

## Validation

- `validate-workflow-approval-round-lifecycle.sql` — structural: the old
  13-arg `workflow_enter_downstream_node` is absent; the new 14-arg
  version exists, is private (revoked from all client roles),
  `SECURITY DEFINER`, and its body references the shared candidate-
  resolution/classification helpers and `step_skipped`; the three shared
  helpers exist and are private; `workflow_peek_final_graph_target`'s body
  reuses the other two; all three callers' bodies reference the peek
  helper; both immutability triggers and trigger functions exist;
  `get_workflow_approval_round_blocked_count` exists, is
  `authenticated`-only (not `anon`), reuses `can_manage_workflow_instance`,
  and returns a bare `INTEGER`; no out-of-scope RPCs; table count
  unchanged (12); prior-phase baseline intact.
- `test-workflow-approval-round-lifecycle.sql` — **15/15** behavioral
  scenarios: required approval; optional approval with a nonzero
  electorate (behaves normally, not skipped); a single zero-candidate
  optional node skipping directly to End; a two-hop chain where the first
  node is skipped and the second is a real round; skipped-voter/no-work-
  item verification; the manager-gated blocked-count function against an
  unavailable voter; a late decision after round closure rejected without
  ledger telemetry; a decision against a replaced (superseded) round
  rejected; sequential delivery through a skip; parallel delivery through
  a skip; replay of a command that advances through a skip; a decision
  immediately followed by a downstream skip to End; and further
  combinations of the above exercising docs/63's worked examples.
- `test-workflow-approval-round-lifecycle-rls.sql` — **6/6** scenarios: the
  instance manager can read the blocked count; a same-org non-manager is
  rejected with a non-disclosing error; a cross-org actor is rejected the
  same way; a nonexistent round id is rejected identically (no existence
  leakage); table count unchanged; `can_manage_workflow_instance` is
  reused, not duplicated.
- `test-workflow-approval-round-lifecycle-concurrency.sql` — **6/6**
  scenarios (see Concurrency above), verified robust across 3 repeated
  runs.
- `test-workflow-approval-round-lifecycle-performance.sql` — 3 dimensions:
  a minimal single skip hop (~21 ms); a programmatically generated 25-hop
  consecutive skip chain resolved synchronously in one
  `start_workflow_instance` call (~50 ms, exactly 25 skipped rounds
  asserted); a skip hop against an instance whose event table already has
  100,000 rows (~8 ms), with `EXPLAIN (ANALYZE, BUFFERS)` confirming the
  existing `workflow_events_sequence_unique` index is used.
- Full repository regression: every applicable validator, behavioral
  suite, RLS suite, concurrency suite, and performance probe from Phase 1
  through 3.1 re-run against the final chain including this patch — zero
  failures, including Phase 2C.1's own behavioral scenario 13 (updated in
  this milestone to assert skip-and-continue rather than the superseded
  fail-closed behavior it originally asserted) and Phase 3.1's concurrency
  scenarios 3/4 (a latent, unrelated `dblink_get_result` test bug fixed
  during this milestone's own concurrency work, described below).

### Two pre-existing test bugs found and fixed along the way

Neither is an engine defect; both are corrected in already-approved test
files as part of this milestone's own verification work:

- `dblink_get_result(conn, false)` does not raise a catchable exception on
  a remote error — it emits a NOTICE and returns zero rows. Two existing
  concurrency scenarios in `test-workflow-approval-decision-engine-concurrency.sql`
  relied on a `err` column populated via `EXCEPTION WHEN OTHERS` around
  such a call to pick the losing side of a race; since `err` was always
  `NULL`, the retry target was always the same regardless of which side
  actually lost. Fixed by querying actual database state (`state =
  'offered'`) instead.
- A scalar-subquery comparison (`(SELECT v FROM tmp) <> 'x'`) silently
  evaluates to `NULL`, not `TRUE`, when the subquery returns zero rows —
  masking a real fixture bug (a missing `supervisor` role holder in one
  test organization) instead of failing loudly. Hardened with an explicit
  row-count check plus `IS DISTINCT FROM`.

## Rollback

`rollback-workflow-approval-round-lifecycle.sql`:

1. Drops `get_workflow_approval_round_blocked_count`.
2. Drops both immutability triggers and their trigger functions.
3. Drops the 14-arg `workflow_enter_downstream_node`,
   `workflow_peek_final_graph_target`,
   `workflow_resolve_approval_candidates`, and
   `workflow_classify_approval_electorate`.
4. Restores `workflow_enter_downstream_node` (13-arg), `workflow_transition_instance`,
   `workflow_advance_graph_step`, and `decide_workflow_work_item` to their
   exact pre-3.2 bodies, extracted byte-for-byte via `sed` line ranges
   from the already-approved patch files rather than hand-transcribed.

**Never refuses**, matching Phase 2C.1's rollback precedent rather than
Phase 3.1's: this milestone drops no column and removes no `NOT NULL`
constraint that could destroy evidence. A skipped round already recorded
under this milestone's behavior remains fully intact in the unchanged,
pre-existing `workflow_approval_rounds` table after rollback — its
`outcome_code = 'skipped'` value sits in an ordinary, untyped `TEXT`
column the restored code has no awareness of but does not choke on.
Rollback only removes the *ability* to create new skipped rounds until
this patch is reapplied; it does not delete any row.

**Verification performed for this document**, against a disposable local
Postgres:

1. Extracted the four restored function bodies via exact `sed` line-range
   extraction from the still-unedited-in-that-respect approved source
   files and diffed them against the rollback script's embedded copies —
   byte-identical.
2. Applied this milestone's patch to a disposable database, ran the
   rollback — applied cleanly with no errors.
3. Ran `validate-workflow-approval-round-lifecycle-rollback.sql` —
   PASSED: the 14-arg signature and all four new functions/triggers
   absent; the pre-3.2 13-arg signature and all three callers restored;
   none of the restored callers reference the removed peek helper;
   prior-phase baseline intact.
4. Built a **true independent pre-3.2 baseline** (Phase 1 through 3.1
   chain only, this patch never applied) and byte-compared
   `pg_get_functiondef` and `pg_proc.proacl` for all four restored
   functions against it — **identical** in both body and grants.
5. Reapplied this milestone's patch on top of the rolled-back database;
   re-ran its structural validator and full 15-scenario behavioral suite
   — both PASSED, confirming clean reapplication.

## Limitations

- **No routing, gateways, conditional branching, timers, notifications,
  delegation, escalation, module adapters, frontend, or workflow
  designer.** Unchanged from every prior workflow-engine phase — none has
  been approved yet.
- **No automatic recovery from an unavailable voter.** Docs/63 describes
  the round remaining blocked "until the instance is cancelled or a later
  approved recovery mechanism operates" — no such recovery mechanism
  (delegation, substitution, escalation, timer) is implied or implemented
  by this milestone; only the manager-gated read of the blocked count is
  new.
- **Only the `skip_if_no_candidates` optional rule exists.** Manual skip,
  deadline skip, conditional skip, and manager override remain explicitly
  out of scope, per docs/63's own "Optional approval" section.
- **The 32-hop bound on graph advancement is shared, not new.** A
  pathological definition with more than 32 consecutive zero-candidate
  optional nodes fails the same way generic advancement already would;
  this milestone does not raise or lower that bound.
- **Rollback removes the ability to create new skipped rounds, but not
  history.** By design, matching the "never refuses" precedent — see
  Rollback above.
