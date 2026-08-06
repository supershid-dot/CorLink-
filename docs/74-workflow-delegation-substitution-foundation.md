# CAP-002 Phase 5.1 — Delegation and Substitution Persistence Foundation

## Scope

This milestone implements the generic backend persistence, validation, authorization, lifecycle, and evidence foundation for workflow delegation and substitution, per `docs/73-workflow-delegation-escalation-architecture.md`. It creates four new tables, ten public RPCs, and the private helpers/triggers they need — all as a self-contained addition that reuses existing authorization primitives and touches no existing function body.

**It does not make delegation or substitution effective in live workflow processing.** `workflow_work_items.assigned_to`, candidate resolution, approval decision authorization, `workflow_enter_downstream_node()`, `decide_workflow_work_item()`, approval-round creation, graph execution, and routing execution are all untouched, byte-for-byte, by this patch — confirmed structurally (see "Validation" below) by asserting neither function's body references `workflow_delegations` or `workflow_substitutions` at all. Wiring delegation/substitution into live candidate resolution and work-item authorization is explicitly deferred to a future, separately approved integration milestone, per docs/73's own two-seam design (candidate resolution for substitution, work-item authorization for delegation).

No SLA clocks, escalation execution, timers, background workers, notifications, or module adapters are implemented — this milestone is persistence and lifecycle only.

## Policy limits (Version 1 initial constants)

docs/73 deliberately left exact numeric bounds open pending implementation. This milestone applies the conservative initial limits the governing instruction specifies, documented here as **initial policy constants, not permanent business policy**:

| Limit | Value | Enforced |
|---|---|---|
| Maximum duration for a temporary delegation | 365 days | `create_workflow_delegation` |
| Permanent delegation | administrator-created only, explicit `starts_at` required | `create_workflow_delegation` |
| Re-delegation depth | 0 (structurally impossible, not merely bounded — see "Single-hop enforcement") | schema + `create_workflow_delegation` |
| Maximum duration for a substitution | 365 days | `create_workflow_substitution` |
| Overlapping active/scheduled substitutions for the same represented position/scope | 0 (hard-rejected) | `workflow_substitutions_no_overlap` EXCLUDE constraint |

All numeric validation lives in exactly one place per entity (the `create_*` RPC), matching the "one authoritative validation layer" instruction — no limit is duplicated or re-checked with a different value anywhere else.

## Database objects

- **`workflow_delegations`** — one row per delegation. Carries `organization_id`, `delegator_id`, `delegate_id`, a closed `scope_type` (`work_item` / `definition_step` / `organization_role` / `section_role`) with exactly the scope-type-appropriate fields populated (enforced by a `CHECK` constraint), `kind` (`temporary`/`permanent`), `activation_mode` (`manual`/`automatic`), `starts_at`/`ends_at`, `status`, and full acceptance/rejection/revocation metadata. A generated `scope_fingerprint` column canonicalizes the scope into one comparable string; a generated `pair_key` column canonicalizes the delegator/delegate pair order-independently — both feed the overlap `EXCLUDE` constraint (see below).
- **`workflow_delegation_events`** — append-only lifecycle evidence, one row per state transition (`created`/`accepted`/`rejected`/`activated`/`revoked`/`expired`), each carrying `actor_id`, `previous_status`/`new_status`, `reason`, an `idempotency_key`, and a `metadata` JSONB used for idempotent-replay comparison.
- **`workflow_substitutions`** — one row per substitution, structurally parallel to `workflow_delegations`: `organization_id`, a closed `represented_type` (`user`/`organization_role`/`section_role`) with type-appropriate fields, `substitute_id`, `kind` (`planned_leave`/`acting_appointment`, `CHECK`-constrained to match `represented_type`), `starts_at`/`ends_at` (both mandatory — no permanent substitution exists), `status`, and revocation metadata. A generated `represented_fingerprint` column feeds its own overlap `EXCLUDE` constraint.
- **`workflow_substitution_events`** — append-only lifecycle evidence, structurally parallel to `workflow_delegation_events` (`created`/`activated`/`revoked`/`cancelled`/`expired`).

Total workflow table count is now 16 (the Phase 1 through 4.3 baseline of 12 plus these four) — every earlier phase's own structural validator and RLS suite asserted exactly 12 as part of its own scope boundary; this milestone updates each of those six count assertions to 16 with an explanatory comment, following the established "superseded, not defective" pattern used repeatedly across this project's history.

## Delegation lifecycle

`pending_acceptance` (manual, awaiting the delegate) → `active`/`scheduled` (accepted, or automatic from creation) → terminal (`revoked`, `expired`, or `rejected`). `scheduled` vs. `active` is computed once at creation/acceptance time by comparing `starts_at` to the current instant — no background worker exists to transition a `scheduled` row to `active` later; a future automatic-activation milestone would add that (see "Deferred: automatic activation and expiry" below).

- **Manual acceptance**: the default. A `pending_acceptance` delegation authorizes nothing; only `accept_workflow_delegation`, called by the named delegate, activates it.
- **Automatic delegation**: administrator-created only (`activation_mode = 'automatic'`), skips acceptance entirely, active immediately (or `scheduled` if `starts_at` is future).
- **Revocation**: by the original delegator, or an administrator with authority over the delegation's organization — always the terminal `revoked` state, from any non-terminal status (including `pending_acceptance` — revoking an offer before it's ever accepted is legitimate).
- **Rejection**: only the named delegate, only from `pending_acceptance`.

## Substitution lifecycle

`scheduled` (future `starts_at`) or `active` (immediate), both set once at creation with no acceptance step — substitution is always administrator-configured, never self-initiated. Terminal: `revoked` (was `active`) or `cancelled` (was still `scheduled`, never became effective) — one `revoke_workflow_substitution` RPC produces whichever terminal state is correct for the record's own current status at the moment of revocation, rather than two near-identical commands.

## Scope model

Four delegation scope types, each requiring the delegator to hold genuine, pre-existing standing in that exact scope — checked against existing, unmodified tables (`workflow_work_items.assigned_to` for `work_item`; `user_assignments` for `organization_role`/`section_role`), never against another delegation:

- `work_item` — one named, currently-assigned work item.
- `definition_step` — every future work item at a named step key within a named definition.
- `organization_role` — every future work item a named organization-role selector would resolve the delegator into.
- `section_role` — the same, narrowed to a named section.

Three substitution `represented` types (`user`, `organization_role`, `section_role`), gated to the two named `kind`s exactly as docs/73 specifies (`planned_leave` ⇒ `user`; `acting_appointment` ⇒ `organization_role`/`section_role`). Cross-organization substitution is out of scope for this milestone (the substitute must belong to the same organization) — docs/73 permits it only through an adapter-established boundary, which this persistence-only milestone has no adapter context to check against; deferred to the live-integration phase.

## Overlap prevention

Both `workflow_delegations` and `workflow_substitutions` carry a native PostgreSQL `EXCLUDE USING gist` constraint (requiring `btree_gist`) — the exact same mechanism and style already established in this repository by `patch-rooms-booking-foundation.sql`'s `meeting_room_bookings_no_overlap` constraint, not reinvented here. This is immune to any application bug or direct-API bypass, and is backed by an advisory lock acquired *before* each `INSERT` (see "Concurrency") so the constraint is a defense-in-depth backstop, not the primary serialization mechanism.

- **Delegation**: `workflow_delegations_no_overlap` excludes on `(pair_key, scope_fingerprint, tstzrange(starts_at, effective_ends_at, '[)'))` for non-terminal statuses. Because `pair_key` is order-independent (`LEAST`/`GREATEST` of the two UUIDs), this one constraint catches both an ordinary same-direction duplicate *and* a reciprocal A→B / B→A delegation of the identical scope with an overlapping window — the latter is a deliberate, documented elevation of docs/73's "flag as a warning" guidance to a hard rejection, per this milestone's own explicit instruction.
- **Substitution**: `workflow_substitutions_no_overlap` excludes on `(represented_fingerprint, tstzrange(starts_at, ends_at, '[)'))` for `scheduled`/`active` statuses — always a hard rejection, never a warning, matching docs/73's "Substitution limits" exactly (no reciprocal case exists for substitution, since a represented party has no symmetric "other side").
- **"Overlap" is exact-match only in Version 1**: two records overlap only when every scope/represented-identifying field is identical for the same type — not fuzzy hierarchical containment across granularities (e.g., an organization-wide role delegation is never treated as "overlapping" a narrower section-scoped one). Comparisons this milestone cannot decide (different scope/represented types) are never attempted as overlapping at all — documented explicitly per the "fail closed on ambiguous scope overlap" instruction, interpreted as: attempt only the comparisons that are genuinely decidable, and treat differently-typed scopes as different resources rather than an ambiguous version of the same one.

## Single-hop enforcement

Structural, not a runtime traversal check: every `create_workflow_delegation` call verifies the *delegator* holds real, pre-existing standing in the named scope by querying `workflow_work_items`/`user_assignments` directly — never `workflow_delegations` itself. A user whose only claim to a scope is a delegation they received therefore always fails this check when named as a delegator, so no chain can ever be constructed regardless of how many delegations exist. Self-delegation is rejected by a `CHECK` constraint (`delegator_id <> delegate_id`). Reciprocal overlapping delegation is rejected by the `EXCLUDE` constraint above.

## Authorization

Every mutation reuses existing CorLink primitives (`is_admin()`, `is_super_admin()`, `get_my_org_id()`, `workflow_actor_is_active()`) through one new private helper, `can_manage_workflow_delegation_scope(p_organization_id)`, mirroring `can_manage_workflow_definition`'s exact shape — no duplicated permission logic.

| Action | Who |
|---|---|
| Create manual/temporary delegation | The delegator themself, or an org administrator on their behalf |
| Create automatic or permanent delegation | An org administrator only |
| Accept/reject a delegation | The named delegate only |
| Revoke a delegation | The delegator, or an org administrator |
| Create a substitution | An org administrator only (never self-service) |
| Revoke a substitution | An org administrator only |

## RLS and visibility

Strict SELECT-only RLS; every mutation is RPC-owned (`REVOKE ALL ... FROM PUBLIC, anon, authenticated` on all four tables, `GRANT SELECT` to `authenticated` only — matching the exact grant discipline every prior phase established, including the `authenticated` role in the initial `REVOKE` rather than omitting it, a mistake caught and fixed during this milestone's own implementation). Visibility predicates are defined once, in two shared functions (`workflow_delegation_visible_to_caller`, `workflow_substitution_visible_to_caller`), and reused identically by the RLS policy and by the `get_*`/`list_*` RPCs — one authoritative definition, not duplicated logic. A delegation is visible to its delegator, its delegate, or an administrator of its organization; a substitution is visible to its represented user (when `represented_type = 'user'`), its substitute, or an administrator. Lifecycle evidence visibility is derived by joining back to the parent record and applying the identical predicate.

**A deliberate grant subtlety, discovered and fixed during implementation**: `workflow_delegation_visible_to_caller`/`workflow_substitution_visible_to_caller` are referenced directly inside RLS `USING` clauses, which evaluate in the *querying* role's own context (`authenticated`), not as a nested call from within another `SECURITY DEFINER` function body. They therefore need `EXECUTE` granted to `authenticated` — exactly like the pre-existing `can_view_workflow_instance`/`can_manage_workflow_instance` precedent (`patch-workflow-backend-foundation.sql`) — while every other helper in this patch (`can_manage_workflow_delegation_scope`, all four trigger functions), which is only ever called from within an already-`SECURITY DEFINER` RPC body, stays fully ungranted.

## Immutable evidence

Every meaningful transition is its own immutable row in `workflow_delegation_events`/`workflow_substitution_events` — `created`, `accepted`/`rejected` (delegation only), `activated` (reserved for a future automatic-activation worker), `revoked`, `cancelled` (substitution only), `expired` (reserved). Both event tables carry a blanket `BEFORE UPDATE OR DELETE` trigger rejecting any mutation (`workflow_reject_delegation_event_mutation`, mirroring `workflow_events`' own trigger exactly). The parent tables (`workflow_delegations`/`workflow_substitutions`) are mutable up to their first terminal status, then immutable — mirroring `workflow_approval_rounds`/`workflow_approval_positions`'s exact terminal-state-immutability discipline, not a new pattern. Evidence contains only safe IDs, timestamps, and structural metadata (e.g., `expected_lock_version`, `kind`, `activation_mode`) — never confidential module content — and integrating this evidence into `workflow_events`' own decision-event metadata is explicitly deferred to the future live-integration milestone, per the governing instruction.

## Idempotency

Every mutating command follows the exact stabilized replay discipline this session's Phase 4.3 hardening established — applied here from day one, not added later as a fix:

- **`create_*` commands** (no pre-existing row to key against) store `create_idempotency_key` directly on the row and compare `(created_by, create_idempotency_key)`, mirroring `create_workflow_definition`'s own precedent exactly — full semantic comparison (organization, delegator/delegate or represented/substitute, every scope field, kind, activation mode, window, reason) on replay; any mismatch is rejected `22023`.
- **Lifecycle commands** (`accept`/`reject`/`revoke`) key off `(delegation_id, idempotency_key)` on the append-only evidence table, mirroring `decide_workflow_work_item`'s replay path — comparison always includes `expected_lock_version`, plus every other semantic input the command accepts (`reason`, event type). Same key + identical semantics replays the original result with zero new rows and zero double-incremented lock version; same key + different semantics is rejected deterministically.

## Concurrency and lock order

Documented explicitly, per the governing instruction:

1. Advisory lock keyed by `(command family, caller, idempotency key)` — serializes retries of the exact same caller/command/key, identical in shape to every other command in this engine.
2. **Create commands only**: a second advisory lock keyed by the logical overlap-check unit (the unordered delegator/delegate pair + scope fingerprint for delegation; the represented fingerprint for substitution) — serializes concurrent creates targeting the same overlap-sensitive unit *before* either `INSERT` is attempted, so the `EXCLUDE` constraint is a defense-in-depth backstop, not the primary serialization mechanism.
3. **Lifecycle commands**: a `SELECT ... FOR UPDATE` row lock on the target delegation/substitution row, acquired after the advisory lock — identical shape to `decide_workflow_work_item`'s own lock order.

This never acquires a lock on `workflow_instances`, `workflow_work_items`, or any other existing engine table (beyond a read-only existence/ownership check with no lock taken, for `work_item`-scoped delegation validation) — since no live integration exists yet, deadlock with the existing workflow engine is structurally impossible in this phase, not merely unobserved.

## Indexes and pagination

Composite indexes support the two access patterns this milestone actually needs: `(delegator_id, status, created_at DESC, id DESC)` and `(delegate_id, status, created_at DESC, id DESC)` and `(organization_id, status, created_at DESC, id DESC)` on `workflow_delegations`; the structurally identical set (by `represented_user_id`/`represented_role_organization_id`/`represented_section_id`/`substitute_id`/`organization_id`) on `workflow_substitutions`; `(delegation_id/substitution_id, occurred_at, id)` on each evidence table for history pagination. Both `create_idempotency_key` uniqueness constraints and both overlap `EXCLUDE` constraints create their own supporting indexes automatically. No index was added speculatively — every one directly supports a query this milestone's own RPCs or performance probes exercise. `list_workflow_delegations`/`list_workflow_substitutions` use the exact keyset-pagination shape `list_workflow_work_items` already established (`(created_at, id) < (cursor_created_at, cursor_id)`, `LIMIT LEAST(GREATEST(p_limit,1),100)`) — no unbounded list RPC exists.

## Performance

Measured against a disposable local Postgres at 10,000 pre-existing delegation rows, 10,000 pre-existing substitution rows, and 100,000 lifecycle evidence rows:

- `create_workflow_delegation` against a 10,000-row backdrop: ~5 ms. `create_workflow_substitution`: ~3 ms.
- A history read for one delegation against 100,000 total evidence rows: ~16 ms, confirmed via `EXPLAIN (ANALYZE, BUFFERS)` to use `idx_workflow_delegation_events_history`, not a sequential scan.
- `list_workflow_delegations`/`list_workflow_substitutions`, **self-scoped** (`p_role` supplied — the common case, an ordinary user listing their own delegations/substitutions): ~11–15 ms.
- `list_workflow_delegations`/`list_workflow_substitutions`, **admin-inclusive** (`p_role IS NULL` — an administrator listing everything visible in their organization) over 10,001 candidate rows: ~1.4–5 s.

**A genuine finding, investigated and partially resolved during this milestone**: the admin-inclusive path's cost comes from PostgreSQL never inlining `SECURITY DEFINER` functions (a language-level restriction, not a bug) — `workflow_delegation_visible_to_caller`/`workflow_substitution_visible_to_caller` each call three further `SECURITY DEFINER` helpers (`is_admin()`, `get_my_org_id()`, `is_super_admin()`), and none of that nested call chain can be inlined or hoisted out of a per-row filter by the planner, regardless of indexing — confirmed via `EXPLAIN (ANALYZE, BUFFERS)`, which showed the correct index-narrowed candidate set but a large per-row filter cost. Both `list_*` RPCs were restructured to accept a `p_role` parameter (`'delegator'`/`'delegate'` or `'represented'`/`'substitute'`) that short-circuits the expensive multi-function visibility check entirely for the self-scoped case — a caller-owned row is always visible regardless of admin status, so the check is redundant work when `p_role` already narrows to self-ownership. This is not a semantic change (self-scoped results were always a strict subset of what the full visibility check already allowed) and reduced the common-case query time roughly 100-fold (from ~1.5 s to ~11–15 ms). The remaining admin-inclusive cost is a known, understood characteristic shared by every `SECURITY DEFINER`-based authorization helper in this codebase (including the pre-existing `can_view_workflow_instance`/`can_manage_workflow_instance` pattern), not unique to this milestone, and is documented here rather than solved further within a persistence-foundation milestone's scope — see "Limitations."

No index was added speculatively in response to this finding; the fix was query-structure, not indexing, and is directly evidence-driven rather than anticipatory.

## Rollback

`rollback-workflow-delegation-substitution-foundation.sql` drops every object this milestone created — all four tables, all ten RPCs, all six private helpers — restoring nothing (there is no pre-5.1 body to restore; every object is wholly new). `btree_gist` is deliberately never dropped, since the already-approved, separate `patch-rooms-booking-foundation.sql` also depends on it.

The rollback unconditionally refuses if any row exists in any of the four new tables — mirroring the Phase 1 (`rollback-workflow-backend-foundation.sql`) "refuse if any row exists" precedent, since this milestone's tables have no possible prior history to protect via a softer policy.

Verified: clean apply with no data present; refusal — with schema and data left completely intact — when a real delegation exists; a true independent pre-5.1 baseline built (Phase 1 through 4.3 chain only) and diffed against the rolled-back database's complete `public`-schema function list (excluding only `btree_gist`/`dblink`-owned objects) — zero difference; clean reapplication with the structural validator and full 35-scenario behavioral suite both re-passing. Full detail in `docs/rollback/017-workflow-delegation-substitution-foundation.md`.

## Testing

- `validate-workflow-delegation-substitution-foundation.sql` — structural validator: tables/RLS/policies, `EXCLUDE` constraints, immutability triggers, private-helper grant boundaries (including the RLS-visibility-helper subtlety above), all ten RPCs' authentication/security/replay-discipline shape, no live-integration surface touched, prior-phase baseline intact, no out-of-scope RPC. **PASSED.**
- `test-workflow-delegation-substitution-foundation.sql` — **35/35** behavioral scenarios (see the file for the full list): manual/automatic delegation creation and lifecycle, accept/reject/revoke authorization boundaries, self-delegation and chain rejection, reciprocal and direct overlap rejection, window/duration/permanent-authority validation, scope validation, idempotent replay (both directions), late-accept-after-revocation, immutable evidence; the structurally parallel substitution set; and explicit confirmation that no live work-item ownership change occurs and ordinary approval behavior is unaffected.
- `test-workflow-delegation-substitution-foundation-rls.sql` — **12/12** scenarios: delegator/delegate/admin visibility, unrelated same-org and cross-org denial, substitution subject/substitute visibility with ordinary-staff denial, evidence-follows-parent visibility, direct INSERT/UPDATE/DELETE denial, anon denial (table and RPC), private-helper grant boundaries.
- `test-workflow-delegation-substitution-foundation-concurrency.sql` — **9/9** scenarios, verified robust across repeated runs: duplicate-key creation races (delegation and substitution), overlapping and reciprocal creation races, accept-vs-revoke and revoke-vs-revoke races, unrelated organizations proceeding independently, no deadlock.
- `test-workflow-delegation-substitution-foundation-performance.sql` — 4 dimensions at 10,000/10,000/100,000-row scale (see "Performance" above).
- Full repository regression: every applicable validator, behavioral suite, RLS suite, concurrency suite, and performance probe from Phase 1 through 4.3 re-run against the final chain including this patch — zero failures, after updating six pre-existing "exactly 12 workflow tables" assertions (in earlier phases' own structural validators and RLS suites) to 16, following the same "superseded, not defective" pattern this project has used at every prior milestone boundary.

## Limitations

- **Live work-item integration is fully deferred.** No delegation or substitution has any effect on `workflow_work_items.assigned_to`, candidate resolution, or decision authorization yet. A delegate cannot actually decide a delegated work item; a substitute is not actually considered during candidate resolution. This is the explicit, single-sentence charter of this milestone, not an oversight.
- **No automatic activation or expiry worker.** `scheduled`→`active` and any→`expired` transitions are never performed automatically; `status` reflects only what was true at creation/acceptance/revocation time. A future milestone would need a narrow, generic lifecycle-transition command plus a timer dispatcher, per docs/73's own "Scalability model."
- **Cross-organization substitution is unsupported.** The substitute must belong to the same organization as the represented position/user; docs/73's adapter-mediated cross-org boundary has no adapter context to check against at this persistence-only layer.
- **The admin-inclusive list path is measurably slower than the self-scoped path at scale**, due to `SECURITY DEFINER` non-inlining shared by the whole codebase's authorization-helper pattern — mitigated for the common case, documented rather than further engineered around for the administrative case (see "Performance").
- **No notification, email, SMS, or outbox integration.** Delegation acceptance requests and substitution activation are future consumers of the existing outbox contract, per docs/73 — none is wired up here.
- **No SLA clocks, escalation execution, timers, or background workers** — entirely out of scope for this milestone, per docs/73's own phase boundary and the explicit governing instruction.
