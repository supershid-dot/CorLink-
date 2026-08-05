# CAP-002 Phase 2B.1 — Executable Workflow Definition Validation

## Scope

This milestone implements executable (`schema_version = 1`) workflow-definition
validation on top of the inert Phase 1 foundation
(`docs/61-workflow-backend-foundation.md`) and the Phase 2 instance lifecycle
(`docs/62-workflow-runtime.md`), following the contract in
`docs/63-workflow-executable-definition-contract.md`.

It implements the executable definition validator, canonical JSON
normalization, canonical hash generation, publication validation, executable
publication rules, and executable version compatibility checks. It does
**not** implement activation, token creation, step runs, approval rounds,
work items, events, or graph traversal — those remain exactly as Phase 1/2
left them, deferred to a future Phase 2B.2 (activation) and beyond.

## Compatibility and regression

Every new check is gated strictly on the payload's own top-level
`schema_version` key being present — never on whether `nodes`/`edges` happen
to be empty. A payload without that key is untouched "legacy inert" input
and receives byte-for-byte the same treatment Phase 1/2 already gave it.

This matters because Phase 1's own behavioral test
(`test-workflow-backend-foundation.sql`) deliberately exercises a
non-empty, non-`schema_version` payload (`{"nodes":[{"key":"x"}],"edges":[]}`)
that succeeds at *create* time and is only rejected at *publish* time by the
original inert-only check. Gating on emptiness instead of on `schema_version`
presence would have made that exact scenario fail differently (rejected at
create instead of publish), a real regression. Gating on `schema_version`
presence instead means that scenario — and every other Phase 1/2 behavioral,
RLS, transition, concurrency, and performance scenario — is completely
unaffected: none of them ever submit a payload containing `schema_version`.

All nine pre-existing Phase 1/2 suites were re-run against a disposable local
Postgres both immediately before and immediately after applying this patch:
`validate-workflow-backend-foundation.sql`, `validate-workflow-runtime.sql`,
`test-workflow-backend-foundation.sql` (24/24), `test-workflow-backend-
foundation-rls.sql` (12/12), `test-workflow-runtime.sql` (22/22),
`test-workflow-runtime-transitions.sql` (40/40), `test-workflow-runtime-
rls.sql` (12/12), `test-workflow-backend-foundation-concurrency.sql` (5/5),
`test-workflow-backend-foundation-performance.sql`, `test-workflow-runtime-
concurrency.sql` (5/5), `test-workflow-runtime-performance.sql` — identical
pass results both times.

## Executable publication

A `workflow_definition_versions` row now falls into exactly one of two
compatibility classes, determined solely by whether its `definition_payload`
contains a `schema_version` key:

- **Legacy inert** — no `schema_version` key. `create_workflow_definition`/
  `create_workflow_definition_version` store it exactly as submitted;
  `publish_workflow_definition_version` still enforces only the original
  Phase 1 rule (`nodes` and `edges` must both be present, empty arrays).
- **Executable v1** — `schema_version` present and equal to the integer `1`.
  The payload is canonicalized and fully structurally- and graph-validated
  at *draft-creation* time (not only at publish), and re-verified (hash
  recomputed and compared, never rewritten) at publish time before the
  version may transition to `published`.

No existing row is rewritten merely to look executable, and no third payload
shape is silently accepted: a payload with `schema_version` absent but
non-empty `nodes`/`edges` remains exactly Phase 1's existing behavior
(accepted at create, rejected at publish) — not a new validation path.

## Validation rules

`canonicalize_workflow_definition_payload(payload, organization_id)` is the
single internal function implementing every rule from docs/63 §"Publication
validation" that is checkable from the payload plus the owning definition's
organization scope alone (the one rule requiring a live table lookup —
`section_role`'s section must exist, be active, and belong to that
organization — is included in the same function, since it needed no
additional context beyond the `organization_id` parameter already being
threaded through).

Checked, in order (fail-fast: the first violation raises immediately with a
stable `wf_def_validation: rule=<code> node=<key|NULL>` message):

- top-level shape: exactly the four required keys, `schema_version = 1`,
  valid `entry_node` format, `nodes` array sized 2–200, `edges` array sized
  1–400 — checked **before** any recursive/graph algorithm runs, per docs/63
  rule 14;
- unique node keys, valid key/type/label/config per node, exactly the
  allowed config keys for `start`/`approval`/`end` (unknown fields rejected);
- full approval-config validation: `delivery_mode`, `decision_rule`,
  `minimum_approvals` (only for `majority`, else must be null),
  `requirement`/`optional_policy` alignment, `allow_abstain`,
  `reject_behavior`, `allow_self_approval`, `allow_multi_capacity`,
  `minimum_candidates`, `comment_policy` (including the `allow_abstain =
  false ⟹ abstain forbidden` cross-field rule);
- 1–16 candidate selectors, unique `order`/`key`, exactly the allowed fields
  per selector type (`explicit_user`, `organization_role`, `section_role`,
  `instance_participant_role`), platform-definition restriction (an
  `organization_id IS NULL` definition may use neither `explicit_user` nor
  `section_role`), and the `section_role` DB lookup described above;
- edge shape: exactly the five allowed fields (a `condition` field is an
  unknown-field rejection, not a distinct check — version 1 has no
  condition concept at all), no self-loops, valid `outcome` format,
  `priority = 0`, `default = false`, no duplicate `(source, outcome,
  priority, target)` tuples, both endpoints reference real nodes;
- exactly one `start` node matching `entry_node`, zero inbound / exactly one
  `started`-outcome outbound edge; at least one `end` node, each with zero
  outbound / at least one inbound; each `approval` node with exactly one
  inbound edge and exactly the required outbound edges for its
  `requirement` (`approved`+`rejected`, plus `skipped` only when optional) —
  this is how "every producible outcome has exactly one edge" is enforced,
  by exact per-outcome and total-count checks rather than a separate
  per-edge "producible" pass;
- every node reachable from `start` (forward recursive CTE);
- every node can reach an end node (backward recursive CTE, seeded from the
  full end-node set);
- acyclic (iterative Kahn's-algorithm topological sort, bounded by the
  200-node/400-edge caps).

**A discovered structural property, not a separate design choice:** given
the "approval has exactly one inbound edge" and "every node reachable from
start" rules together, a genuine cycle can only ever exist as a disconnected
component with no path back to `start` — which the reachability check always
catches first (a cycle needs every node in it to receive its one inbound
edge from another node *in the cycle*, meaning nothing outside the cycle
points into it, meaning it is unreachable from start by construction). The
acyclic check therefore is genuine defense-in-depth exactly as docs/63 rule
9 requires it to be, not dead code — `supabase/test-workflow-executable-
definition-validation.sql` scenario 27 proves this directly with a
self-contained, internally-valid, disconnected two-node approval cycle: it
is rejected as `unreachable_node`, not `cycle_detected`, confirming the
check ordering and the underlying reachability proof.

Two rules are structural but currently unreachable to violate through the
public RPCs, and are therefore verified by direct code inspection rather
than a runtime negative-test scenario (both documented in the test file's
own comments):

- `capability_version` must equal `1` for a `schema_version = 1` payload —
  `capability_version` has no settable parameter anywhere in the API surface
  (it always defaults to `1`), so this is a real, permanent, structural
  guarantee, not a false claim.
- Stored-content-hash re-verification at publish time can only fail if the
  stored `definition_payload` were tampered with outside the RPC layer —
  which the existing Phase 1 immutability trigger
  (`workflow_guard_definition_version_mutation`) already unconditionally
  blocks for any `UPDATE`. It remains a real, independent defense-in-depth
  layer (a second, cheaper check that would also catch a hypothetical
  future bug in the trigger itself), not a claim that this specific attack
  is otherwise reachable today.

"No executable code" (docs/63 rule 13) is satisfied by construction, not by
scanning: every field in the schema is a fixed, typed, allowlisted value —
`label` is a plain length-capped display string never used in any
authorization or execution path, node/edge/selector `type` fields are closed
enums, and no field anywhere accepts a raw expression, SQL fragment, table
name, function name, or URL. There is nothing in the schema *capable* of
carrying code, so no denylist/pattern-scanning check was added.

## Canonicalization

Postgres `jsonb` storage already normalizes **object key order**
independent of input order — casting an equivalent object to `::text`
always produces the same key ordering regardless of how it was
constructed or in what order its keys were supplied. Canonicalization
therefore only needs to explicitly control **array order**, which `jsonb`
does preserve as submitted:

- `nodes` sorted by `key` ascending (`COLLATE "C"`, matching docs/63's
  "ascending bytewise order" requirement exactly);
- `edges` sorted by `(source, outcome, priority, target)` ascending;
- each approval node's `candidate_selectors` sorted by `(order, key)`
  ascending;
- each `explicit_user` selector's `user_ids` deduplicated and sorted
  ascending (`jsonb_agg(DISTINCT ... ORDER BY ...)`) — a duplicate
  `user_ids` entry is silently reduced to one position, per docs/63's own
  selector-specific "adds sorted, unique user_ids" wording, distinct from
  the general "reject rather than silently deduplicate" policy that applies
  to node keys, edge tuples, and selector `order`/`key` values (all of
  which are hard rejections on duplication, never silently resolved).

`test-workflow-executable-definition-validation.sql` scenario 3 proves this
concretely: two definitions with identical logical content but differently
ordered `nodes`/`edges` arrays and JSON key order produce byte-identical
canonical payloads and therefore identical `content_hash` values. Scenario
18 proves the `user_ids` deduplication specifically (a selector submitted
with the same user ID twice canonicalizes to exactly one entry).

Canonicalization is naturally idempotent — re-running it on an already-
canonical payload reproduces it exactly (sorting a sorted array is a no-op;
deduplicating a deduplicated set is a no-op) — which is what lets publication
re-run the identical function on the already-stored payload as a pure
integrity check without ever needing to mutate the row.

## Canonical hashing

`content_hash` (an existing Phase 1 column, `CHECK` constrained to a 64-hex-
character SHA-256) is computed as
`encode(digest(convert_to(canonical_payload::text, 'UTF8'), 'sha256'), 'hex')`
at draft-creation time, from the *canonical* form — not the raw submitted
form — so the hash is stable across equivalent-but-differently-ordered
inputs from the moment the row is first inserted.

At publish time, `publish_workflow_definition_version` recomputes the
canonical form of the *already-stored* payload and compares both the
resulting JSONB (must be byte-identical to what's stored — provable given
canonicalization's idempotency) and its recomputed hash (must match the
stored `content_hash`) before allowing the status transition. It never
rewrites the payload; the existing immutability trigger already forbids
that on any `UPDATE`. This is the "publication recomputes and compares the
hash before graph validation" step docs/63 requires, plus running the graph
validation itself as the very same function call (since canonicalization and
graph validation are one inseparable pass in this implementation — see
"Validation rules" above).

## Publication flow

```
create_workflow_definition / create_workflow_definition_version
  → payload has 'schema_version' key?
      yes → canonicalize_workflow_definition_payload(payload, org_id)
             (raises on any violation; nothing is inserted on failure)
            → store the CANONICAL payload + its hash
      no  → store the payload exactly as submitted (Phase 1, unchanged)

publish_workflow_definition_version
  → lock definition family row (unchanged Phase 1 locking)
  → idempotent-replay / draft-status / lock-version checks (unchanged)
  → stored payload has 'schema_version' key?
      yes → capability_version must be 1
            → re-run canonicalize_workflow_definition_payload on the
              STORED payload; compare result + hash to what's stored
      no  → original Phase 1 inert-only check (nodes/edges both empty),
            byte-for-byte unchanged
  → retire prior published version, publish this one (unchanged)
```

Because full validation already runs at *draft-creation* time, an
executable-v1 draft that exists in the database is already provably valid
before publication is ever attempted — publication's own re-validation is a
integrity re-confirmation, not the first time the payload is checked. This
is also why this milestone did not need to implement the `discarded`-state
draft-replacement/cloning mechanism docs/63 describes under "Draft editing
and cloning clarification": that mechanism exists to let a caller recover
from a draft that turned out to be unpublishable, but under this design a
structurally- or graph-invalid executable payload is rejected **before any
row is ever inserted** — there is no unpublishable draft to recover from.
It remains a real, separate gap only for a caller who wants to revise an
already-*valid* draft's content before publishing it (see "Limitations").

## Authorization

No new permission model. `create_workflow_definition`, `create_workflow_
definition_version`, and `publish_workflow_definition_version` reuse their
exact existing Phase 1 authorization checks (`workflow_actor_is_active()`,
`is_admin()`/`is_super_admin()`/`get_my_org_id()`, `can_manage_workflow_
definition()`) unchanged — canonicalization is inserted as an additional
step inside the existing authorization boundary, never a replacement for it.
The one new function, `canonicalize_workflow_definition_payload`, is
`SECURITY DEFINER` with `search_path = public, pg_temp` pinned (matching
every other internal workflow helper) and is revoked from `PUBLIC`, `anon`,
and `authenticated` — it is reachable only from the three RPCs above, never
directly.

## RLS

Zero new tables, zero new policies, zero grant changes. The ten existing
`workflow_*` tables keep their exact Phase 1 SELECT-only RLS posture;
`supabase/validate-workflow-executable-definition-validation.sql` asserts
the table count is still exactly 10 and that no `anon`/`authenticated`
direct-write grant exists, in addition to confirming the new function's own
execute grants are absent for both roles.

## Concurrency

No new locking primitive. Canonicalization and validation run *inside* the
existing Phase 1 lock scope (`FOR UPDATE` on the definition family row, plus
the existing per-caller advisory-lock/idempotency-key pattern) — they never
acquire a lock of their own, so the existing global lock ordering is
unaffected.

`test-workflow-executable-definition-validation-concurrency.sql` (3
independent-`dblink`-session scenarios) confirms adding validation inside
that existing scope introduced no new race window:

1. Two concurrent `publish_workflow_definition_version` calls on the same
   schema-version-1 draft, with **different** idempotency keys (a genuine
   race, not a replay) — exactly one wins, the definition ends up published
   exactly once.
2. Two concurrent `create_workflow_definition_version` calls attempting a
   second draft under the same now-published family, both submitting valid
   schema-version-1 payloads — exactly one succeeds; the family ends up
   with exactly one draft (the pre-existing "one draft per definition" rule,
   unaffected by canonicalization now running earlier in the same call).
3. The *same* publish command (identical idempotency key and actor) issued
   concurrently — both sessions converge on the identical result, and the
   version is published exactly once, proving idempotent replay holds under
   real concurrency, not only when called sequentially.

## Performance

Bounded by construction: every check operates over the payload's own node/
edge arrays (capped at 200/400 by rule, checked before any recursive
algorithm runs), using iterative or `WITH RECURSIVE`-bounded SQL, never
unbounded recursion or per-row table scans beyond the single `section_role`
lookup.

`test-workflow-executable-definition-validation-performance.sql` builds the
maximal version-1 shape allowed — a 200-node, 395-edge sequential approval
chain (`start → a1 → a2 → … → a197 →` two shared end nodes) — and times
`create_workflow_definition` (canonicalize + validate + insert) and
`publish_workflow_definition_version` (re-canonicalize + re-validate)
against it once. Measured on this disposable local instance: ~188 ms create,
~182 ms publish — both well under the probe's own generous 5-second
regression bound (a bound chosen to catch an accidental quadratic blow-up,
not to assert a tight production SLA).

## Rollback

`rollback-workflow-executable-definition-validation.sql`:

1. **Refuses unconditionally** if any `workflow_definition_versions` row
   has a `schema_version` key in its payload — rolling back while an
   executable-v1 definition exists would strip the only validator that
   ever checked it, per docs/63's own rollback contract. The check runs
   before any mutation, inside the same transaction, so a refusal leaves
   the database completely untouched.
2. Restores `create_workflow_definition`, `create_workflow_definition_
   version`, and `publish_workflow_definition_version` to their exact
   Phase 1 bodies — copied verbatim from `supabase/patch-workflow-backend-
   foundation.sql` (a file this patch never edited, so it remains the
   authoritative pre-patch source), not hand-transcribed.
3. Drops `canonicalize_workflow_definition_payload`.

It touches no table, row, RLS policy, grant, or index — every Phase 1/2
object is preserved exactly.

**Verification performed for this document**, against a disposable local
Postgres (never staging/production):

1. Captured `pg_get_functiondef()` for the three modified RPCs immediately
   after applying the Phase 1/2 baseline, before this patch.
2. Applied this patch, then the rollback SQL above; re-captured the same
   three function definitions — **byte-for-byte identical** to step 1.
3. Confirmed the refusal path directly: created a real executable-v1
   definition, attempted rollback, confirmed it raised
   `Refusing rollback: 1 executable-v1 workflow_definition_versions row(s)
   exist...` and left `canonicalize_workflow_definition_payload` still
   present (the refusing transaction aborted cleanly with zero partial
   effect).
4. Ran `validate-workflow-executable-definition-validation-rollback.sql`
   after a clean rollback — PASSED.
5. Re-ran `validate-workflow-backend-foundation.sql` and the full Phase 1
   behavioral suite (24/24) after rollback — unaffected.
6. Reapplied `patch-workflow-executable-definition-validation.sql`; re-ran
   the structural validator, all 28 behavioral scenarios, and all 4 RLS
   scenarios — all PASSED, confirming clean reapplication.

## Testing

All suites run against a disposable local Postgres (stub `auth` schema,
real `schema.sql`/`rls.sql`, the real Phase 1/2 workflow patches, this
patch) — never staging or production, per this environment's standing
constraints.

- `validate-workflow-executable-definition-validation.sql` — structural:
  the new function exists, is `SECURITY DEFINER` with pinned `search_path`,
  has no direct execute grant; the three modified RPCs still exist, retain
  their exact grants, and contain both the dual legacy/executable branches
  and the unchanged literal Phase 1 inert-check text; zero new tables/
  grants; no runtime/activation RPCs were added.
- `test-workflow-executable-definition-validation.sql` — 28 behavioral
  scenarios: a fully valid definition creates/canonicalizes/publishes;
  idempotent publish replay; order-independent canonical hashing; legacy
  payloads fully unaffected; one negative scenario per major rule category
  (unknown fields, bad `schema_version`, node/edge count bounds, duplicate
  keys/tuples, invalid types, approval-config field/value violations,
  selector platform-scope and section-role violations, edge shape
  violations, start/end/approval edge-cardinality violations, unreachable
  nodes); a positive `explicit_user` + `user_ids` deduplication scenario.
- `test-workflow-executable-definition-validation-rls.sql` — 4 scenarios:
  the internal canonicalizer has no direct grant; the existing
  authorization boundary (org admin / non-admin staff / cross-organization
  admin) gates schema-version-1 input exactly as it already gated inert
  input.
- `test-workflow-executable-definition-validation-concurrency.sql` — 3
  independent-`dblink`-session scenarios (see "Concurrency" above).
- `test-workflow-executable-definition-validation-performance.sql` — the
  maximal 200-node/395-edge probe (see "Performance" above).
- Full repository regression: all nine pre-existing Phase 1/2 validators/
  test suites re-run both immediately before and immediately after this
  patch, with identical pass results both times (see "Compatibility and
  regression" above).

## Limitations

- **No draft-replacement/discarded-state mechanism.** Docs/63's "Draft
  editing and cloning clarification" describes a `draft → discarded`
  transition so a caller can revise an already-*valid* draft's content
  before publishing. This milestone does not implement it — deliberately
  out of the narrowed "validation only" scope for Phase 2B.1, and not
  required for the validator itself to be fully exercisable (see
  "Publication flow" above for why). A caller who wants to iterate on a
  definition family today creates a fresh family per attempt, or (once a
  version is published) creates the next version number normally. Adding
  `discarded` support is a distinct, separately-scoped future editing-
  workflow feature.
- **`minimum_approvals`'s "may raise, never lower, the strict-majority
  threshold" rule is not checked here.** That comparison requires the
  resolved electorate count `N`, which does not exist until activation
  (candidate resolution). This is a genuine, correctly-deferred limitation,
  not an oversight — publication validates selector *structure*; activation
  resolves *candidates* (docs/63's own stated boundary).
- **No cloning RPC.** Docs/63 mentions cloning a published version's
  payload into a new draft; not implemented here, for the same reason as
  draft-replacement above.
- **Two rules are currently unreachable to violate** through the public
  RPCs (`capability_version` mismatch, stored-content-hash tampering) and
  were verified by direct inspection rather than a runtime negative test —
  documented explicitly under "Validation rules" above, not silently
  assumed.
- **No activation, token creation, step runs, approval rounds, work items,
  or events.** Exactly as scoped: this is Phase 2B.1 (validation only).
  Phase 2B.2 (activation) and Phase 2C (graph advancement) remain separate,
  future, separately-approved milestones per docs/63's own phase breakdown.
- **No frontend, designer, or module adapter.** Unchanged from every prior
  workflow-engine phase — none has been approved yet.
