# CAP-002 Phase 2B.2 — Workflow Instance Activation

## Scope

This milestone implements transactional activation of a pending instance
using a published executable-v1 (`schema_version = 1`) workflow definition,
on top of the inert Phase 1 foundation (`docs/61-workflow-backend-
foundation.md`), the Phase 2 instance lifecycle (`docs/62-workflow-
runtime.md`), and the Phase 2B.1 executable definition validator
(`docs/64-workflow-definition-validation.md`), following the contract in
`docs/63-workflow-executable-definition-contract.md`.

It pins the instance's own immutable version reference, re-verifies
publication integrity, creates one initial token, creates and completes the
Start-node step run, follows the sole `started` outbound edge, and enters
exactly one first executable node — Approval or End. For Approval, it
resolves candidates and creates the round, positions, and the initial work
items required to represent entry. For End, it completes that node and the
instance atomically (an explicit, bounded, docs/63-authorized special case,
not generic graph advancement). Activation stops immediately after the
first executable node is entered.

**Phase 2C graph advancement is explicitly deferred.** This milestone does
not record an approval decision, calculate an approval outcome, complete an
approval node, advance beyond the first executable node, traverse a second
executable node, or enter `End` automatically from anywhere except the
Start→End special case. Routing, gateways, split/join, conditions, timers,
notifications, delegation, substitution, adapters, module integrations, the
frontend, and the workflow designer remain out of scope, exactly as in every
prior phase of this engine.

## Compatibility and regression

Activation extends the SHARED `workflow_transition_instance()`'s `'start'`
command only, gated strictly on the instance's own pinned version payload
carrying a top-level `schema_version` key. A legacy inert instance (pinned
to a version whose payload has no `schema_version` key) falls straight
through the `IF v_is_executable THEN ... END IF` block untouched and
receives byte-for-byte the exact single-event `instance_started` behavior
Phase 2 already gave it. `suspend`/`resume`/`complete` are completely
unmodified. `cancel` gained one small, additive extension (see
"Concurrency and cancellation" below) that only ever touches rows this
milestone's own tables can contain — a legacy instance has none, so its
`cancel` behavior is also unaffected.

All ten pre-existing Phase 1/2/2B.1 suites were re-run against a disposable
local Postgres both immediately before and immediately after applying this
patch — `validate-workflow-backend-foundation.sql`,
`validate-workflow-runtime.sql`,
`validate-workflow-executable-definition-validation.sql`,
`test-workflow-backend-foundation.sql` (24/24),
`test-workflow-backend-foundation-rls.sql` (12/12),
`test-workflow-runtime.sql` (22/22),
`test-workflow-runtime-transitions.sql` (40/40),
`test-workflow-runtime-rls.sql` (12/12),
`test-workflow-executable-definition-validation.sql` (28/28),
`test-workflow-executable-definition-validation-rls.sql` (4/4) — plus the
full concurrency and performance suite for every phase
(`test-workflow-backend-foundation-concurrency.sql` 5/5,
`test-workflow-runtime-concurrency.sql` 5/5,
`test-workflow-executable-definition-validation-concurrency.sql` 3/3,
and the three corresponding performance probes) — identical pass results
both times.

## Executable instance eligibility

An instance is eligible for executable activation if, and only if, at the
moment `start_workflow_instance` is called:

- the instance's own `definition_version_id` (set once at instance
  creation, never rewritten) resolves to a `workflow_definition_versions`
  row whose `definition_payload` contains a `schema_version` key;
- that version's `status` is `published` (never `draft` or `retired` —
  checked explicitly and independently of the generic `pending → active`
  instance-state check that already gates the `start` command);
- re-running `canonicalize_workflow_definition_payload()` (the exact
  Phase 2B.1 function, not a reimplementation) against the stored payload
  reproduces both the stored payload byte-for-byte and the stored
  `content_hash`.

Any failure of these checks raises before any row is written; a legacy
instance simply never enters this block at all.

## Transaction sequence

Everything below runs inside the single existing `workflow_transition_
instance()` invocation — one transaction, one lock acquisition, no
sub-transactions:

1. The existing shared prelude runs unchanged: active-caller/authorization
   check, advisory lock on `(actor, instance, idempotency_key)`, `FOR
   UPDATE` lock on the instance row, idempotency-replay check, lock-version
   check, and the generic `pending → active` legality check for `start`.
2. **Eligibility gate**: load the pinned version; if its payload carries
   `schema_version`, enter the activation block.
3. **Publication integrity re-verification**: version must be `published`;
   canonical re-verification of payload and hash (see "Executable instance
   eligibility").
4. **Start step**: one `workflow_instance_steps` row for the entry node,
   inserted directly in `state = 'completed'`, `result_code = 'started'`.
5. **Initial token**: one `workflow_tokens` row created at the Start step
   (`token_key = 'epoch_<execution_epoch>_token_1'`), `state = 'active'`.
6. **Sole `started` edge**: derived (not re-validated — already structurally
   guaranteed by the Phase 2B.1 validator) from the canonical payload.
7. **First executable node's step run**: one `workflow_instance_steps` row
   for the target node — `state = 'completed'` immediately if it is an
   `end` node, else `state = 'waiting'`.
8. Token is moved to the new step (`UPDATE workflow_tokens SET step_id =
   ...`).
9. Branch on the target node's type — End or Approval (see below); any
   other type raises `Unsupported first executable node type`.
10. Events are appended in causal order (see "Events").
11. `RETURN QUERY` with the final `status`.

Any failure anywhere in this sequence — including inside the branch —
propagates as a PL/pgSQL exception, which rolls back the entire function
invocation; no partial token, step, round, position, work item, or event
can remain. Proven directly, not just by inspection: behavioral scenario 5
(tampered hash) and scenario 35 (undersized required electorate) each
assert zero rows in every runtime table and exactly the pre-existing
`instance_created` event afterward.

## Version pinning

`workflow_instances.definition_version_id` is an existing, immutable-in-
practice column — set once by `create_workflow_instance` and never
rewritten by anything in Phase 1, 2, 2B.1, or this milestone. Activation
loads `v_version` by this exact column (`SELECT * INTO v_version FROM
workflow_definition_versions WHERE id = v_instance.definition_version_id`)
and never reads or substitutes `workflow_definitions.active_version_id`,
the family's currently-active pointer. No new column or mechanism was
introduced; this satisfies docs/63's "never substitute the family's
current active version" using the mechanism that already existed.
Behavioral scenario 25 proves this directly: publishing a v2 of the family
(which retires v1 and updates `active_version_id` to point at v2) does not
change what an instance still pinned to v1 activates against — and since
v1 is now `retired`, activation against it correctly fails the
`status <> 'published'` check.

## Start-node and initial-token behavior

The Start step is entered and completed in the same statement — there is
no intermediate "Start is waiting" state, matching how Start nodes have no
decision content. The token is created at the Start step first (so
`token_created` always has a valid `step_id` to reference), then moved to
the target step by a single `UPDATE`. `token_key` encodes the instance's
`execution_epoch` (`epoch_<n>_token_1`) so a future re-execution epoch
(cancellation/retry semantics, out of this milestone's scope) would not
collide with a prior epoch's token key.

## First executable node — End (the Start→End special case)

Authorized directly by docs/63's own text ("If it is end, complete it and
the instance") as a bounded, single-hop, terminal exception to "no graph
advancement" — there is nowhere further to go from a terminal node, so
completing it is not advancement through the graph, it is the graph's own
designated stopping point. Implemented as one atomic block: the target
step is completed with the node's configured `outcome_code` as its
`result_code`, the token is marked `consumed`, and the instance itself
transitions straight to `status = 'completed'` (not `'active'`) with that
same `outcome_code` as `terminal_outcome` — never landing in an
intermediate `'active'` state that the caller would need a second command
to close out.

## First executable node — Approval

**Candidate resolution** is a private, server-side-only computation —
clients never submit resolved candidates. A single `UNION ALL` CTE
resolves all four docs/63 selector types (`explicit_user`,
`organization_role`, `section_role`, `instance_participant_role`) by
joining `user_assignments` directly against the existing generic scope
helpers `scope_org_id(scope_type, scope_id)` and `scope_section_ids(scope_
type, scope_id)` — not the caller-scoped `has_role_in_section()`, which is
hard-locked to `auth.uid()` and cannot resolve arbitrary candidate users.
Results are ordered by `(selector order, selector key, authority source,
user id)` per docs/63, computed via a `row_number() OVER (...)` in its own
CTE (a window function cannot nest inside `jsonb_agg(...)` directly) before
being aggregated into the final candidate array.

- `allow_self_approval = false` excludes `workflow_instances.created_by`
  from the resolved set.
- `allow_multi_capacity = false` rejects (fails the entire activation
  atomically) if the same user resolves through more than one selector —
  checked before any row is written, via the same resolution logic
  re-evaluated for duplicate detection.
- **Electorate sizing**: `required` with too few resolved candidates fails
  closed. `optional` with zero candidates fails closed with a distinct
  error naming Phase 2C explicitly (see "A deliberate, bounded limitation"
  below) rather than either silently advancing past the node or leaving an
  ambiguous half-entered one. `optional` with a nonzero but still
  undersized electorate is treated as a configuration error, not a skip,
  and also fails closed.
- **Threshold**: `unanimous` requires the full electorate; `majority`
  requires `GREATEST(floor(N/2)+1, minimum_approvals)`.
- **Delivery mode**: `parallel` creates a `workflow_work_items` row (and a
  corresponding `workflow_participants` candidate row) for every resolved
  position immediately. `sequential` creates a work item only for ordinal
  1; later positions are persisted as `workflow_approval_positions` rows in
  `state = 'pending'` with no work item, until a future (Phase 2C-or-later)
  decision advances the round — out of this milestone's scope.

## Work-item creation boundary

Work items are created only where the first-node contract requires them to
represent *entry* into the node — i.e. exactly the positions that are
immediately actionable under the node's own `delivery_mode` (all of them
for `parallel`, only ordinal 1 for `sequential`). No decision is recorded
against any work item, and no work item is ever completed by this
milestone; that is Phase 2C/3 territory.

## Events

Every event uses docs/63's exact, already-existing, unprefixed naming —
`instance_started`, `token_created`, `step_entered`, `step_completed`,
`token_moved`, `approval_round_opened`, `work_item_created`,
`instance_completed` — not a new `workflow_instance_activated`-style event.
docs/63 states explicitly that "the existing `instance_started` event
remains the canonical activation event; no synonymous `instance_activated`
event is added," and that rule controls over any illustrative event-name
list appearing outside docs/60-64.

Events are chained by `causation_id` back to the root `instance_started`
event (`v_root_event_id`), and `event_sequence` numbers are reserved
starting from the instance's own `next_event_sequence` at the moment of
this call (2, for a freshly created instance — sequence 1 is always
`create_workflow_instance`'s own `instance_created` event) — never
hardcoded to start at 1. The instance row's `next_event_sequence` is
advanced by the exact count of events the branch taken actually emits (8
for Start→End; `7 + offered_count` for Approval — 7 fixed events from
`instance_started` through `approval_round_opened`, plus one
`work_item_created` per offered position) in the same `UPDATE` that
also advances `lock_version`, keeping both counters consistent with
what is actually inserted.

> **Erratum (CAP-002 Phase 2B.2A, `supabase/patch-workflow-activation-
> event-sequence-correction.sql`)**: the Approval branch originally
> shipped with `5 + electorate_count + offered_count`, which only
> equals the correct `7 + offered_count` when `electorate_count = 2`
> — the exact candidate count every Phase 2B.1/2B.2 test fixture used,
> so the defect passed all existing tests undetected. Any real
> electorate size other than 2 left `next_event_sequence` incorrect:
> too low for `electorate_count < 2` (the next event-writing command
> on that instance collided with an already-used sequence number and
> crashed), too high for `electorate_count > 2` (a silent, permanent
> gap in the event ledger). Corrected to `7 + offered_count`; verified
> for electorate sizes 0 (still correctly rejected, unaffected), 1, 2,
> 3, and 5, under both parallel and sequential delivery, including
> idempotent replay and a later lifecycle command succeeding
> afterward — see `supabase/test-workflow-activation-event-sequence-
> correction.sql`.

**The one metadata subtlety**: the shared, unmodified idempotency-replay
code (used by every command, including legacy `start`) reads `new_status`/
`terminal_outcome` back out of the *first* event inserted under a given
idempotency key — always `instance_started` for `start`. For the Start→End
branch, the transaction's true final status is `'completed'`, not the
intermediate `'active'` a naive read of the old `start` logic might
suggest — so that event's own metadata stores `new_status: 'completed'`
and `terminal_outcome: <outcome_code>` to match the branch's real outcome.
A replayed Start→End activation therefore correctly reports `'completed'`
on retry, not a stale `'active'`.

## Idempotency

No new idempotency mechanism. Activation runs entirely inside the existing
shared prelude's idempotency-replay check (same `(instance_id,
idempotency_key)` lookup on `workflow_events`, same "same key + same input
→ same result; same key + different input → error" contract) — it never
adds a second idempotency key or a separate replay path. Behavioral
scenarios 16-20 (five idempotent-replay sub-checks: identical replay
returns the identical result; a Start→End replay after completion reports
`'completed'`, not a stale intermediate value; an Approval replay reports
the same round/position snapshot; a different-input replay under the same
key is rejected; a stale-lock-version retry is rejected) all pass.

## Authorization

No new permission model. `workflow_transition_instance()` reuses its exact
existing Phase 2 authorization check — `workflow_actor_is_active()` and
`can_manage_workflow_instance(p_instance_id)` — unchanged; activation logic
is inserted as an additional branch inside the existing authorization
boundary, never a replacement for it. The function remains `SECURITY
DEFINER` with `search_path = public, pg_temp` pinned, and remains revoked
from `PUBLIC`/`anon`/`authenticated` directly — reachable only through the
five narrow public wrapper RPCs (unchanged, not re-touched by this patch;
`CREATE OR REPLACE` preserves their existing grants without a re-grant
statement).

## RLS

Two new tables, both SELECT-only for `authenticated`, no direct write grant
for any role — mutation happens exclusively through
`workflow_transition_instance()`'s `SECURITY DEFINER` context:

- `workflow_approval_rounds` — one policy, `USING
  (can_view_workflow_instance(instance_id))`.
- `workflow_approval_positions` — one policy, `USING
  (can_view_workflow_instance(instance_id))`.

Both reuse the existing `can_view_workflow_instance()` helper unchanged —
no new visibility rule was written. `test-workflow-executable-instance-
activation-rls.sql` confirms: a resolved candidate can see the round and
their own position; a same-organization outsider with no participant row
sees neither the round, the position, the instance, the tokens, nor the
steps (no existence leakage); a cross-organization actor sees nothing;
neither new table has any direct write grant; each new table has exactly
one policy, and it is SELECT-only; `can_manage_workflow_instance()` (the
existing authorization gate) is reused by activation, not duplicated.

## Locking and concurrency

No new locking primitive and no change to lock order. Activation runs
entirely inside the existing Phase 2 lock scope — the same per-caller
advisory lock (`workflow_runtime:<actor>:<instance>:<idempotency_key>`)
followed by the same `FOR UPDATE` on the instance row — and acquires no
lock of its own; the documented order (idempotency/advisory lock →
instance row → token/step/work-item rows → event sequence) is unchanged
because activation's new writes (rounds, positions, work items, steps,
tokens) all happen strictly after the instance row is already locked, in
the same order relative to each other every time.

`test-workflow-executable-instance-activation-concurrency.sql` (6
independent-`dblink`-session scenarios) confirms this introduces no new
race window:

1. Two simultaneous activations of the same instance with different
   idempotency keys — exactly one wins, exactly one token/round, no
   duplicated work items.
2. A duplicate-key replay issued concurrently with itself converges on the
   identical result.
3. Activation racing a cancellation of the same instance — no partial or
   inconsistent state.
4. Activation racing a second, distinct `start` command — one wins, the
   other gets a stale-version/illegal-transition error; no duplicated step
   or token rows.
5. Activation of two unrelated organizations' instances proceeds in
   parallel without unnecessary blocking.
6. No deadlock observed across all of the above (a deadlock would have
   surfaced as an error from a checked `dblink_get_result` call in any
   scenario).

**Cancellation** gained one small, additive extension inside the existing
`cancel` branch: open `workflow_approval_rounds` rows move to `'cancelled'`
and open `workflow_approval_positions` rows move to `'cancelled'`,
alongside the pre-existing step/token/work-item cancellation this branch
already did. This only ever touches rows this milestone's tables can
contain, so it is a pure addition with no effect on a legacy instance.
Verified by behavioral scenario 36.

## Performance

`test-workflow-executable-instance-activation-performance.sql` measures
five dimensions against a disposable local Postgres, each wrapped in
`BEGIN; ... ROLLBACK;`:

1. Minimal Start→Approval→End with 100 potential supervisors resolvable —
   ~70-90 ms.
2. Maximum candidate snapshot (100 resolved positions, 100 work items,
   asserted exactly) — ~55-80 ms.
3. Fiftieth published version of one definition family, activated against
   that exact pinned version — ~4-6 ms.
4. The hundredth of 100+ workflow definitions in one organization — ~3-4
   ms.
5. Activation against an instance whose `workflow_events` table already
   has 100,000 pre-existing rows — ~2-20 ms; `EXPLAIN (ANALYZE, BUFFERS)`
   on the instance's own recent-event query confirms the existing
   `idx_workflow_events_instance_sequence` index is used (an index scan,
   not a sequential scan), with all-cache-hit buffer usage.

All five are well under generous regression bounds chosen to catch an
accidental quadratic blow-up, not to assert a tight production SLA. **No
speculative index was added** — dimension 5's `EXPLAIN` output was the
measured evidence gate for that decision, and it showed the existing index
already being used correctly.

## A deliberate, bounded limitation: optional approval with zero candidates

docs/63 describes a zero-candidate `optional` approval round as being
"skipped," with the token following the round's `skipped` edge. Doing that
would be graph advancement past the first executable node — explicitly out
of Phase 2B.2's scope, which stops immediately after the first node is
entered. Rather than either implementing the forbidden advancement or
leaving an ambiguous half-entered node, activation fails this specific case
closed with an error that names Phase 2C explicitly: `Optional approval
node <key> resolved zero candidates; skip-and-advance requires Phase 2C
graph advancement, not implemented in Phase 2B.2`. This is a narrow,
transparent, and — per the milestone's own explicit authorization to make
exactly this kind of bounded judgment call — deliberately conservative
resolution, not a silent gap. A caller hitting this today must wait for
Phase 2C.

## Rollback

`rollback-workflow-executable-instance-activation.sql`:

1. **Refuses unconditionally** if any `workflow_approval_rounds` or
   `workflow_approval_positions` row exists — rolling back while any
   instance has ever been activated through an approval node would
   irreversibly destroy that round/position history, and docs/60-64 define
   no compatibility path for it. The check runs before any mutation, so a
   refusal leaves the database completely untouched.
2. Restores `workflow_transition_instance()` to its exact pre-2B.2 body —
   copied verbatim from `supabase/patch-workflow-runtime.sql` (a file this
   patch never edited, so it remains the authoritative pre-patch source),
   not hand-transcribed.
3. Drops `workflow_approval_rounds` and `workflow_approval_positions`
   (no `CASCADE`).

It touches no other table, row, RLS policy, grant, or index — every Phase
1/2/2B.1 object, and every `workflow_instances`/`workflow_instance_steps`/
`workflow_tokens`/`workflow_work_items`/`workflow_events` row already
written, is preserved exactly.

**Verification performed for this document**, against a disposable local
Postgres (never staging/production):

1. Built a true pre-2B.2 baseline (Phase 1+2+2B.1 chain, this patch never
   applied) and captured `pg_get_functiondef('workflow_transition_
   instance(...)')` and its grants.
2. Applied this patch, activated one instance through an approval node,
   attempted rollback — confirmed it refused with the expected message and
   left both the new tables and the function definition completely
   unchanged (zero partial effect).
3. Rebuilt a fresh 2B.2 chain with no activation history and ran rollback
   — succeeded.
4. Compared the restored function definition and its grants against the
   true pre-2B.2 baseline — **byte-for-byte identical**, and
   **grant-identical** (only `postgres:EXECUTE`; neither `authenticated`
   nor `anon` has direct execute).
5. Ran `validate-workflow-executable-instance-activation-rollback.sql` —
   PASSED.
6. Reapplied `patch-workflow-executable-instance-activation.sql`; re-ran
   the structural validator, all 40 behavioral scenarios, and all 6 RLS
   scenarios — all PASSED, confirming clean reapplication.

## Testing

All suites run against a disposable local Postgres (stub `auth` schema,
real `schema.sql`/`rls.sql`, the real Phase 1/2/2B.1 workflow patches, this
patch) — never staging or production, per this environment's standing
constraints.

- `validate-workflow-executable-instance-activation.sql` — structural: the
  two new tables exist, are SELECT-only, have no direct write grant;
  `workflow_transition_instance`'s signature/security/no-execute-leak are
  unchanged; the five wrapper RPCs' grants are unchanged; activation-logic
  markers are present and version-pinning uses the instance's own pinned
  column (never the family's active pointer); no out-of-scope RPCs
  (`advance_workflow_instance`, `decide_workflow_work_item`, `record_
  workflow_decision`, `route_workflow_instance`) exist; the legacy start
  path and the Phase 2B.1 canonicalizer are both still present intact.
- `test-workflow-executable-instance-activation.sql` — **40/40** behavioral
  scenarios: activation success (Start→Approval and Start→End); version
  pinning against a retired non-active version; hash reverification
  (positive and a deliberately-tampered negative); token/step/work-item
  lifecycle; no-decision/no-advancement guarantees; five idempotent-replay
  sub-checks; reactivation prevention; invalid-graph/draft/retired-version
  rejection; legacy-instance behavior unchanged; four authorization
  negative cases; direct-insert denial on all four relevant tables; zero
  partial rows on failure; cancellation/suspend/resume unaffected; three
  explicit acknowledgements that the full existing suites still pass.
- `test-workflow-executable-instance-activation-rls.sql` — **6/6**
  scenarios (see "RLS" above).
- `test-workflow-executable-instance-activation-concurrency.sql` —
  **6/6** scenarios (see "Locking and concurrency" above).
- `test-workflow-executable-instance-activation-performance.sql` — 5
  dimensions (see "Performance" above).
- Full repository regression: every applicable Phase 1/2/2B.1 validator,
  behavioral suite, RLS suite, concurrency suite, and performance probe
  re-run against the final chain including this patch — zero failures
  (see "Compatibility and regression" above).

## Limitations

- **No graph advancement beyond the first executable node.** Exactly as
  scoped: Phase 2C (graph advancement — decisions, routing, gateways,
  multi-node traversal) and Phase 3 (approval decision recording) remain
  separate, future, separately-approved milestones.
- **Optional approval with zero resolved candidates fails closed** rather
  than skipping and advancing (see "A deliberate, bounded limitation"
  above) — a narrow, transparent, deliberately conservative choice, not an
  oversight.
- **Sequential-delivery positions beyond ordinal 1 have no work item and
  no path to get one** until a future (Phase 2C-or-later) decision
  mechanism advances the round — by design; this milestone only
  represents entry, not decision handling or round advancement.
- **No frontend, designer, or module adapter.** Unchanged from every prior
  workflow-engine phase — none has been approved yet.
