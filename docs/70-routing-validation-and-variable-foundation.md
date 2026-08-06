# CAP-002 Phase 4.1 — Routing Validation and Variable Foundation

## Scope

This milestone implements the reusable backend foundation `docs/69-workflow-routing-gateway-contract.md`'s capability version 2 requires before executable routing can exist: canonicalization and publication validation for `schema_version = 2` payloads containing `gateway_exclusive` nodes and condition-bearing edges, capability-version gating consistent with the existing `schema_version = 1` discipline, and the one missing piece docs/69 itself flagged as a load-bearing open dependency — a write path for `workflow_variables`.

It implements no condition evaluation, no gateway execution, no branch traversal, no merge behavior, and no routing event. `workflow_enter_downstream_node` — the single shared graph-advancement authority — is untouched. A `schema_version = 2` definition can be created, canonicalized, and published by this milestone, but an instance activated against one that reaches a `gateway_exclusive` node will still fail at that unmodified function's existing defensive node-type check, exactly as it already does for any node type outside `start`/`approval`/`end`. That failure is the correct, expected behavior for this milestone — execution is Phase 4.2's job, not this one's.

## Version 2 validation

`canonicalize_workflow_definition_payload` gained a `gateway_exclusive` branch, reached only when the payload's `schema_version` is `2`. Every `schema_version = 1` payload takes byte-for-byte the same code paths it already did — the function's schema_version check now accepts `1` or `2`, but the node-type allowlist, edge-field allowlist, and all other rules remain exactly as strict for `1` as before.

### Node contract

- `gateway_exclusive` requires `config = {}` — all routing-relevant configuration lives on the node's outbound edges, matching docs/69's own placement rationale.
- Exactly one inbound edge is required, reusing the exact rule already enforced for `approval` nodes (`gateway_inbound_edges_invalid`) — not merely the same rule *name*, but the identical validator logic, applied to a second node type. This is stricter than docs/69's own prose ("one or more... structurally permitted") suggested; the already-shipped `approval`-node validator enforces exactly one, and docs/69 explicitly said gateway nodes should "reuse exactly the same rule already applied to approval nodes" — so this milestone honors the rule as it actually exists in code, not as a looser reading of the architecture prose might imply. See "Limitations" below.
- 2 to 16 outbound edges, mirroring the existing candidate-selector-count precedent rather than a newly invented bound.
- Exactly one outbound edge must have `default = true`; a default edge must carry no `condition`; every non-default edge must carry exactly one.

### Edge contract

A `gateway_exclusive`-sourced edge uses a distinct field-set and rule-set from every other edge:

- `outcome` must be the single fixed value `'routed'` — used only for bookkeeping/uniqueness, never for branch selection.
- `priority` is a free integer 0–1000 (not fixed at `0` as in Version 1), and must be pairwise unique among one gateway node's own outbound edges (`gateway_duplicate_priority`) — giving the future execution phase a deterministic, tie-free evaluation order without any additional tiebreaker.
- `default` may be `true` or `false` (not fixed at `false`).
- `condition` is a new, sixth edge field, permitted only on gateway-sourced edges and validated in full (see below).

Every non-gateway-sourced edge (`start`/`approval`/`end`) keeps the exact `schema_version = 1` field-set and rule-set — `priority` fixed at `0`, `default` fixed at `false`, `condition` absent — unconditionally, regardless of the payload's `schema_version`.

### Condition validation

Each non-default gateway edge's `condition` object is validated against the exact closed allowlist docs/69 specifies:

- `source` must be `'instance_variable'` — `module_variable` and any other source is rejected (`gateway_condition_source_unsupported`); no module adapter exists to supply anything else.
- `variable_name` must match the existing `^[a-z][a-z0-9_]{0,62}$` pattern — the same constraint `workflow_variables.variable_name` itself already enforces, reused rather than duplicated.
- `operator` is one of `equals`, `not_equals`, `in`, `not_in`, `greater_than`, `greater_than_or_equal`, `less_than`, `less_than_or_equal`, `is_null`, `is_not_null` — anything else is `gateway_condition_operator_unsupported`.
- `value_type` (required for every operator except the two unary ones) is one of `boolean`, `number`, `string`, `date`, `timestamp`, `uuid`.
- Operator/type compatibility is enforced: `in`/`not_in` require `number`/`string`/`uuid`; the four comparison operators require `number`/`date`/`timestamp` (`gateway_condition_operator_type_mismatch`).
- The literal `value` (or each element of an `in`/`not_in` array, bounded to 1–20 elements) must match its declared `value_type`, checked by the new shared helper `wf_condition_literal_matches_type()` — the same function the new variable-write command reuses for its own type check, so the two surfaces can never disagree about what a "valid `string`" or "valid `uuid`" looks like.

### Reconvergence

Multiple gateway (and/or approval) outbound edges may target the same downstream `end` node — ordinary graph convergence, requiring no new validation concept, verified as a dedicated behavioral scenario. A downstream node that is itself `approval` or `gateway_exclusive`, however, still requires exactly one inbound edge (see above), so reconvergence onto a second decision point is not supported by this milestone — only onto `end`.

## Capability version gating

`workflow_definition_versions.capability_version` (an existing Phase 1 column) is now computed from the payload's own `schema_version` at draft-creation time in both `create_workflow_definition` and `create_workflow_definition_version`, rather than left at the column `DEFAULT 1` for every payload. A `schema_version = 2` payload is stored with `capability_version = 2`; a `schema_version = 1` payload (or a legacy inert payload with no `schema_version` key at all) is stored with `capability_version = 1`, unchanged from before.

`publish_workflow_definition_version`'s existing capability-version check is generalized from a hardcoded `capability_version <> 1` to `capability_version <> (definition_payload ->> 'schema_version')::INTEGER`, so it validates `1`-with-`1` and `2`-with-`2` alike using one code path. `workflow_definition_versions`'s existing immutability trigger makes `capability_version` unchangeable after insertion — this milestone's structural validator confirms the mismatch check still actually fires by deliberately disabling that trigger for one test-only `UPDATE`, corrupting a stored row, and confirming `publish` rejects it, then re-enabling the trigger — the only way to exercise that defensive branch at all, since normal operation can never produce a mismatch.

## Variable contract

`docs/69` named a genuine open dependency: routing conditions need a value to read, but no approved contract anywhere wrote a `workflow_variables` row. This milestone closes it with one new command:

`set_workflow_instance_variable(p_instance_id, p_variable_name, p_value_type, p_variable_value, p_classification, p_idempotency_key)`:

1. Authenticates (`workflow_actor_is_active()`) and validates `variable_name` format, `value_type` (the full existing `workflow_variables.value_type` enum — `null`/`boolean`/`number`/`string`/`date`/`timestamp`/`uuid`/`json`), `classification` (`public`/`restricted`), and that the value matches its declared type (reusing `wf_condition_literal_matches_type()`; `json` accepts any well-formed JSON and is deliberately never usable as a condition operand per docs/69).
2. Takes the caller/idempotency advisory lock, then locks the instance row — reusing the existing global lock order's first two positions unmodified — then locks the variable row if one already exists, immediately after the instance lock and before any step/token/round/position/work-item lock, since a variable has no relationship to graph-execution rows.
3. Requires the instance to be `pending` or `active` — the same posture every other mutating command already requires.
4. Reuses `can_manage_workflow_instance()` — the exact existing manager/owner boundary, no new permission model.
5. Upserts by `(instance_id, variable_name)` (the existing Phase 1 unique constraint), incrementing a new `lock_version` column on every accepted change.

### Idempotent replay without an event

Every other command in this engine replays by reading its own root event's metadata back from the append-only `workflow_events` ledger — but this milestone is explicitly barred from adding an execution event ("no execution events... only variable persistence where required"). `set_workflow_instance_variable` instead stores the most recent write's idempotency key directly on the variable row itself (a new `write_idempotency_key` column) and compares against it: the same key with identical input is a no-op returning the unchanged `lock_version`; the same key with different input fails with the standard `22023` "idempotency key was already used with different input" contract every other command already uses. This gives full command-contract parity without an event, verified under concurrent replay (see Concurrency).

### Approved sources only

Only `instance_variable`, backed by this new write path, and static literals embedded directly in a condition are usable. `module_variable` is explicitly rejected at validation time — no module adapter contract exists, and this milestone invents no module-variable source, per docs/69's own scope boundary.

## Authorization

No new permission model anywhere in this milestone. `set_workflow_instance_variable` reuses `can_manage_workflow_instance()`; the definition-side changes reuse the exact same authorization `create_workflow_definition`/`create_workflow_definition_version`/`publish_workflow_definition_version` already had.

## Events

None. No `route_selected` or any other new event type exists yet — that is explicitly Phase 4.2's responsibility. The structural validator asserts `workflow_enter_downstream_node`'s body contains neither `gateway_exclusive` nor `route_selected`, and that `set_workflow_instance_variable`'s body never references `workflow_events`.

## Concurrency

No new lock tier for definition validation (canonicalization and publication already ran under the existing definition-family lock). For the new variable-write command, no new lock tier either — the variable row is locked immediately after the already-held instance row lock, so two concurrent writers to the same instance fully serialize exactly as every other mutating command already does. `test-workflow-routing-validation-foundation-concurrency.sql` (5 independent-`dblink`-session scenarios, verified robust across 3 repeated runs) confirms: two concurrent writes to the same variable name serialize to exactly one final row with no unique-constraint race; a same-idempotency-key concurrent replay converges to exactly one row with no error on either side; concurrent writes to distinct variable names on the same instance both succeed with no deadlock; unrelated organizations' writes proceed independently; no deadlock was observed anywhere.

## Validation

- `validate-workflow-routing-validation-foundation.sql` — structural: `canonicalize_workflow_definition_payload` carries the new gateway validation logic while its `schema_version = 1` node-type allowlist is unchanged; `wf_condition_literal_matches_type` is private; `create_workflow_definition`/`create_workflow_definition_version` compute `capability_version`; `publish_workflow_definition_version`'s mismatch check is generalized; `workflow_variables` gained exactly the two new columns (still 12 workflow tables); `set_workflow_instance_variable` is authenticated-only, `SECURITY DEFINER`, pinned `search_path`, reuses `can_manage_workflow_instance`, and never references `workflow_events`; no out-of-scope execution RPC exists; `workflow_enter_downstream_node` carries no gateway-execution logic; prior-phase baseline intact.
- `test-workflow-routing-validation-foundation.sql` — **28/28** behavioral scenarios: a valid gateway definition creates (storing `capability_version = 2`) and publishes; `gateway_exclusive` rejected under `schema_version = 1`; non-empty gateway config rejected; too-few/too-many outbound edges rejected; zero/two default edges rejected; duplicate priority rejected; wrong edge outcome rejected; condition-on-default and missing-condition-on-non-default rejected; unsupported operator, operator/type mismatch, unsupported source, invalid variable name, and type-mismatched literal all rejected; a gateway reachable from two distinct gateway sources rejected; reconvergence onto a shared End node from two gateways publishes successfully; the capability-version mismatch defensive check verified to actually fire; instance-variable first write, exact-replay no-op, reused-key-different-input rejection, fresh-key update with `lock_version` increment, type-mismatch rejection, `json`/`null` type handling, outsider/cross-org rejection, and cancelled-instance rejection.
- `test-workflow-routing-validation-foundation-rls.sql` — **6/6** scenarios: manager can write; same-org non-manager and cross-org actors rejected; variable visibility remains governed by the unmodified Phase 1 `workflow_variables_select` policy; no direct write grant exists on `workflow_variables`; `can_manage_workflow_instance` reused, not duplicated.
- `test-workflow-routing-validation-foundation-concurrency.sql` — **5/5** scenarios (see Concurrency above).
- `test-workflow-routing-validation-foundation-performance.sql` — 3 dimensions: a maximal 200-node/395-edge `gateway_exclusive` chain (the exact node/edge counts of Phase 2B.1's own maximal-approval-chain probe, for direct comparison) — create+canonicalize ~120–170 ms, publish ~125–165 ms; a single variable write against a fresh instance ~1–2 ms; a variable write against an instance with 1,000 pre-existing variables ~1–2 ms, with `EXPLAIN (ANALYZE, BUFFERS)` confirming the existing `idx_workflow_variables_instance` index is used, not a sequential scan.
- Full repository regression: every applicable validator, behavioral suite, RLS suite, concurrency suite, and performance probe from Phase 1 through 3.2 re-run against the final chain including this patch — zero failures, after updating one now-superseded Phase 2B.1 scenario (see below).

### One pre-existing test scenario updated

`test-workflow-executable-definition-validation.sql`'s scenario 6 previously asserted that `schema_version: 2` is rejected as unsupported — true before this milestone, no longer true now that `2` is a supported capability version. Updated to assert rejection of `schema_version: 3` instead (still genuinely unsupported), following the exact "superseded, not defective" update pattern Phase 3.2 already established for Phase 2C.1's own scenario 13.

## Rollback

`rollback-workflow-routing-validation-foundation.sql`:

1. Drops `set_workflow_instance_variable()` and `wf_condition_literal_matches_type()` outright — both wholly new.
2. Restores `canonicalize_workflow_definition_payload()`, `create_workflow_definition()`, `create_workflow_definition_version()`, and `publish_workflow_definition_version()` to their exact pre-4.1 (Phase 2B.1) bodies, extracted byte-for-byte via `sed` line ranges from the already-approved patch file.
3. Drops the two purely-additive `workflow_variables` columns (`lock_version`, `write_idempotency_key`).

**Mixed refusal policy**, reasoned independently for each surface:

- **Refuses** if any `workflow_definition_versions` row has `capability_version = 2` — mirroring Phase 2B's own precedent ("refuse if any executable-v1 definition... exists") one capability version up: a `schema_version = 2` definition is real authored work product that would become permanently unsupported after rollback (canonicalization and publication would no longer recognize it). No `schema_version = 2` instance can ever have reached real runtime state regardless of rollback, since Phase 4.1 deliberately never touches `workflow_enter_downstream_node` — activating an instance against a `gateway_exclusive` node already fails today at that function's unmodified defensive node-type check — so there is no separate "gateway-activated instance" evidence category to guard, unlike Phase 2B's original concern.
- **Never refuses** on `workflow_variables` content. Dropping `lock_version`/`write_idempotency_key` destroys no substantive evidence — `variable_name`, `value_type`, `variable_value`, and `classification` are untouched, unrelated columns that remain byte-identical. The two dropped columns are pure write-retry bookkeeping for a command that no longer exists once rollback completes, so keeping them would only leave permanently dead columns behind. This matches Phase 2C.1's "changes only function bodies/schema, no meaningful data at risk" character, not Phase 3.1's evidence-protecting refusal.

**Verification performed for this document**, against a disposable local Postgres:

1. Applied this patch, confirmed all 4 restored-function targets and the two new columns; ran the structural validator — PASSED.
2. Applied the rollback with no `capability_version = 2` rows present — succeeded cleanly.
3. Ran `validate-workflow-routing-validation-foundation-rollback.sql` — PASSED.
4. Separately, created a real `schema_version = 2` definition, then attempted rollback — **refused**, exactly as designed, with the full Phase 4.1 schema left completely intact (re-verified via the structural validator) after the refusal.
5. Built a **true independent pre-4.1 baseline** (Phase 1 through 3.2 chain only, this patch never applied) and byte-compared `pg_get_functiondef` and `pg_proc.proacl` for all four restored functions, plus `workflow_variables`'s column shape, against it — **identical** in every case.
6. Reapplied the patch to the first (no-V2-definitions) database; re-ran the structural validator and full 28-scenario behavioral suite — both PASSED, confirming clean reapplication.

## Testing

All suites run against a disposable local Postgres — never staging or production. See "Validation" above for exact scenario counts and coverage.

## Limitations

- **No condition evaluation, gateway execution, branch traversal, or merge behavior.** This milestone is validation and variable persistence only — see docs/69's own Phase 4.2/4.3 split.
- **A `schema_version = 2` definition containing a `gateway_exclusive` node cannot be safely activated yet.** Publication succeeds, but `workflow_enter_downstream_node` still rejects any node type outside `start`/`approval`/`end` — this is expected, not a defect, and is exactly why the rollback above needs no "graph-activated instance" refusal guard.
- **Gateway reconvergence is available only onto `end` nodes, not onto a second `approval`/`gateway_exclusive` node.** This milestone implements the exactly-one-inbound-edge rule for gateway nodes literally as it already exists for approval nodes in shipped code, which is stricter than docs/69's own "one or more... structurally permitted" prose suggested. Loosening this — if ever wanted — is a validator change for a future milestone to propose and justify on its own, not something this document silently redefines.
- **No boolean condition composition (`AND`/`OR`/`NOT`).** One atomic condition per edge, per docs/69's own deliberate minimality decision.
- **`module_variable` condition sources remain unimplemented** — no module adapter contract exists.
- **`set_workflow_instance_variable`'s idempotency guarantee is narrower than the rest of the engine's.** It replays safely against its own most recent write, stored on the row itself, rather than against the full append-only event ledger every other command uses — a deliberate, documented scope decision (see "Variable contract" above), not an oversight.
- **No routing, gateways execution, delegation, escalation, timers, notifications, adapters, or frontend.** Unchanged from every prior workflow-engine phase.
