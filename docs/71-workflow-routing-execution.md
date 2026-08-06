# CAP-002 Phase 4.2 — Exclusive Gateway Condition Evaluation & Routing Execution

## Scope

This milestone implements execution of `gateway_exclusive` routing, closing the gap Phase 4.1 deliberately left open: a `schema_version = 2` definition could be authored, validated, and published, and a `workflow_variables` row could be written, but no instance could actually advance through a `gateway_exclusive` node — `workflow_enter_downstream_node` rejected it with "Unsupported graph node type: gateway_exclusive," exactly as designed. This milestone adds condition evaluation, deterministic branch selection, and graph advancement through gateway nodes. It adds no new node type, no new workflow feature, no split/join/merge behavior, and no new permission model.

## Execution flow

`gateway_exclusive` execution is a new branch inside the existing bounded synchronous loop already present in `workflow_enter_downstream_node` and `workflow_peek_final_graph_target` — the same structural pattern Phase 3.2 established for the zero-candidate approval-skip case. A gateway node is never a stopping point: on entry, its outbound edges are evaluated in ascending priority order, exactly one target is selected, a single `route_selected` event closes the gateway's own step, and the loop `CONTINUE`s into the selected target — synchronously, in the same command, with no additional round trip. A chain of consecutive gateway nodes resolves entirely within one command, exactly like a chain of skipped optional approval nodes already does.

Two new shared helper functions carry the actual logic, reused identically by both passes so they can never disagree:

- `workflow_evaluate_gateway_condition(p_instance_id, p_condition) RETURNS BOOLEAN` — the closed condition-operator registry.
- `workflow_resolve_gateway_target(p_instance_id, p_canonical, p_node_key) RETURNS TABLE(target_node_key, target_node, used_default, evaluated_conditions)` — deterministic branch selection, built on top of the condition evaluator.

`workflow_peek_final_graph_target` (used to compute the *eventual* `new_status`/`terminal_outcome` recorded on a command's own root event, without itself entering any node) now walks through gateway hops using the same `workflow_resolve_gateway_target` call, so its replay metadata is always correct for any command whose advancement passes through one or more gateways — including the very first node after Start, or the very next node after an approval decision.

Only two pre-existing immediate-target-type guard checks needed widening — from `('approval','end')` to `('approval','end','gateway_exclusive')` — in `workflow_transition_instance`'s `start` branch and in `workflow_advance_graph_step`'s own glue. Both because a graph's first node, or the node immediately following an approval decision, can itself be a gateway. No signature of any of the three outer command functions (`workflow_transition_instance`, `workflow_advance_graph_step`, `decide_workflow_work_item`) changed. `decide_workflow_work_item` needed zero changes — it already routes exclusively through the peek and shared-entry helpers with no inline node-type check of its own.

## Condition evaluation

`workflow_evaluate_gateway_condition` supports only the ten operators docs/69 approves: `equals`, `not_equals`, `in`, `not_in`, `greater_than`, `greater_than_or_equal`, `less_than`, `less_than_or_equal`, `is_null`, `is_not_null`. It is a closed `CASE` over the six approved value types (`boolean`, `number`, `string`, `date`, `timestamp`, `uuid`) with no dynamic SQL, no `EXECUTE`/`format()` escape hatch, no user-defined functions, and no adapters — verified structurally.

**Type-mismatch and missing-variable handling.** For every binary/comparison operator, if the named variable is missing entirely, has `value_type = 'null'`, or its stored `value_type` does not match the condition's own declared `value_type`, the condition evaluates deterministically to `FALSE` — never an exception, never three-valued NULL propagation. This matches docs/69's literal text and this engine's established discipline around avoiding SQL's three-valued logic.

**The `is_null`/`is_not_null` carve-out.** These two operators are unary and exist specifically to test for absence, so they are deliberately exempted from the blanket "missing variable → false" rule: `is_null` returns `TRUE` when the variable is missing, has `value_type = 'null'`, or its `variable_value` is JSON `null`; `is_not_null` returns the negation. This resolves an apparent internal tension in docs/69's own text — its "load-bearing open dependency" section describes exercising the undefined-variable path precisely via `is_null`, which would be unreachable if `is_null` also unconditionally returned `false` per the blanket rule for every other operator.

**Comparison semantics per value type**: `boolean` compares via direct JSONB equality/inequality only (no ordering operators); `number` casts the stored scalar to `NUMERIC`; `string`/`uuid` compare as `TEXT`; `date` casts to `DATE`; `timestamp` casts to `TIMESTAMPTZ`. `in`/`not_in` are implemented via `EXISTS`/`NOT EXISTS` over the condition's literal array, matching element-by-element against the variable's value under the same type rules.

## Variable sources

Only `workflow_variables` (via `workflow_evaluate_gateway_condition`'s read) and the condition's own embedded static literal are used. No module variable, adapter variable, or computed variable exists — `module_variable` remains rejected at Phase 4.1's validation layer and this milestone adds no runtime support for it either.

## Branch selection

`workflow_resolve_gateway_target` loops the gateway's non-default outbound edges strictly in ascending `priority` order (unique per node, enforced at publication by Phase 4.1), evaluating each edge's condition via the shared evaluator and stopping at the first match. If no non-default edge matches, the sole `default = true` edge (guaranteed to exist by publication) is used. The function accumulates an `evaluated_conditions` array of `{priority, matched}` entries, in evaluation order, stopping at the first `true` — this is deterministic and free of any random or unspecified ordering.

## Graph execution

No graph-entry or approval-entry logic is duplicated. The gateway branch sits inside the same loop, between the existing `end` branch and the existing `approval` branch, and reuses every mechanism already established for step/token bookkeeping (`workflow_instance_steps`, `workflow_tokens`) unchanged.

## Events

Exactly one new event type, already reserved by docs/69: `route_selected`, carrying `node_key`, `target_node_key`, `used_default`, and `evaluated_conditions`. It is the sole event closing the gateway's own step — occupying the same structural position `step_skipped` already occupies for the skip branch — and is deliberately *not* paired with a redundant generic `step_completed` for the same step. `evaluated_conditions` records only `{priority, matched}` booleans, never the raw variable or condition literal values, so a `restricted`-classified variable's value can never leak into the broader-visibility event ledger through routing metadata (verified by a dedicated behavioral scenario). Event sequencing remains contiguous, events remain immutable (the existing immutability trigger applies unchanged), and the causation chain (`causation_id` pointing at the command's root event) is preserved exactly as every other synchronous-loop event already does.

## Token model

Exactly one active token per instance throughout gateway execution, moved via the same `workflow_tokens` update every other node transition already uses. No split, merge, join, or parallel execution exists or is introduced.

## Authorization

No new permission model. Gateway execution runs entirely inside the existing `workflow_enter_downstream_node`/`workflow_peek_final_graph_target` helpers, which are only ever reached from the three outer command functions after their existing `can_manage_workflow_instance()` checks have already passed.

## Concurrency

No new lock tier. Gateway condition evaluation reads `workflow_variables` under the instance-row lock every mutating command already acquires first (`SELECT ... FOR UPDATE` on `workflow_instances`), so two concurrent commands touching the same instance — whether both attempting to advance through a gateway, or one advancing while another writes a variable via `set_workflow_instance_variable` — fully serialize through that pre-existing lock. Idempotency-key replay for both `workflow_advance_graph_step`/`workflow_transition_instance` (event-ledger-based) and `decide_workflow_work_item` continues to work unchanged through a gateway hop, verified under genuine concurrent races.

## Performance

Benchmarked, no speculative indexes added: a minimal single gateway hop (~12ms); a maximal 16-branch gateway evaluating 15 conditions before falling to the default (~8ms); a 25-hop consecutive gateway chain resolved synchronously in one command (~20ms); a gateway hop against an instance carrying 100,000 pre-existing events (~7ms), confirmed via `EXPLAIN (ANALYZE, BUFFERS)` to use the existing `workflow_events_sequence_unique` index rather than a sequential scan.

## Validation

- `validate-workflow-gateway-routing-execution.sql` — structural: `workflow_enter_downstream_node` (signature unchanged, still 14 args) executes gateway routing and emits `route_selected`; `workflow_peek_final_graph_target` walks gateway hops; the two new helpers exist, are private, `workflow_evaluate_gateway_condition` is `STABLE` with no dynamic-SQL escape hatch and references every approved operator; `workflow_resolve_gateway_target` reuses the condition evaluator and orders by priority; both immediate-target-type glue checks widened; `decide_workflow_work_item` present and untouched; no out-of-scope RPC; table count unchanged at 12; no direct write grant; prior-phase baseline intact.
- `test-workflow-gateway-routing-execution.sql` — **23/23** behavioral scenarios: first-node gateway routing on a matching condition; undefined-variable fallback to default; ascending-priority evaluation stopping at first match; `is_null`/`is_not_null` against both missing and defined variables; every approved operator across every approved value type (`not_equals`, `in`, `not_in`, boundary `less_than_or_equal`, `date`, `timestamp`, `uuid`, `boolean`); type-mismatched and explicit-null variables never matching; `route_selected` metadata leaking no raw literal values; a 3-hop consecutive gateway chain resolving synchronously; gateway routing into a real approval round correctly stopping and later resuming through `decide_workflow_work_item`; reconvergence with distinct upstream hop counts reaching the same downstream outcome; activation-idempotency-key and decision-idempotency-key replay through a gateway both converging identically with no duplicate event.
- `test-workflow-gateway-routing-execution-rls.sql` — **6/6** scenarios: instance manager can see `route_selected`; same-org non-manager and cross-org actors cannot; a non-manager outsider cannot activate a gateway-containing instance (reuses the existing `can_manage_workflow_instance` boundary, no new permission model); `workflow_variables` visibility unaffected by gateway evaluation; table/policy counts unchanged.
- `test-workflow-gateway-routing-execution-concurrency.sql` — **6/6** scenarios, verified robust across 3 repeated runs: concurrent racing advancement through the same gateway; same-idempotency-key concurrent replay; concurrent variable write vs. gateway read fully serializing with a deterministic outcome; advance-through-gateway vs. cancel race; independent organizations proceeding independently; no deadlock observed.
- `test-workflow-gateway-routing-execution-performance.sql` — 4 dimensions (see Performance above).
- Full repository regression: every applicable validator, behavioral suite, RLS suite, concurrency suite, and performance probe from Phase 1 through 4.1A re-run against the final chain including this patch — zero failures.

## Rollback

`rollback-workflow-gateway-routing-execution.sql`:

1. Drops `workflow_evaluate_gateway_condition()` and `workflow_resolve_gateway_target()` outright — both wholly new.
2. Restores `workflow_peek_final_graph_target()`, `workflow_enter_downstream_node()`, `workflow_transition_instance()`, and `workflow_advance_graph_step()` to their exact pre-4.2 (Phase 4.1A) bodies, extracted byte-for-byte via `sed` line ranges from the already-approved `patch-workflow-approval-round-lifecycle.sql`. No table, column, or constraint is touched — this milestone added none.

**Refuses** if any `workflow_events` row has `event_type = 'route_selected'` — mirroring the "protect real activated work" precedent (Phase 2B, and Phase 4.1's `capability_version = 2` guard) rather than the "nothing at risk" precedent (Phase 2C.1). A `route_selected` event means a real instance genuinely executed gateway routing; rolling back while such an instance still has future graph advancement ahead of it — for example, a gateway already routed it into a still-open approval round whose eventual decision might itself need to traverse another gateway — would leave the rolled-back code rejecting with "Unsupported graph node type: gateway_exclusive," permanently orphaning that instance until this milestone is reapplied. No event or any other row is ever deleted by the refusal; it is a hard stop, not a partial rollback.

**Verification performed for this document**, against a disposable local Postgres:

1. Applied this patch to a fresh chain; ran the structural validator and the full 23-scenario behavioral suite — both PASSED.
2. Applied the rollback with no `route_selected` events present — succeeded cleanly; confirmed both new helpers dropped, gateway-execution logic absent from all four restored functions, and the workflow table count unchanged at 12.
3. Ran `validate-workflow-gateway-routing-execution-rollback.sql` — PASSED.
4. Separately, on a fresh Phase-4.2-patched database, created and started a real gateway-routed instance (producing exactly one `route_selected` event), then attempted rollback — **refused**, exactly as designed, with the full Phase 4.2 schema left completely intact.
5. Built a **true independent pre-4.2 baseline** (Phase 1 through 4.1A chain only, this patch never applied) and byte-compared `pg_get_functiondef` and `pg_proc.proacl` for all four restored functions against it — **identical** in every case.
6. Reapplied the patch to the first (no-`route_selected`) rolled-back database; re-ran the structural validator and full 23-scenario behavioral suite — both PASSED, confirming clean reapplication.

## Testing

All suites run against a disposable local Postgres — never staging or production. See "Validation" above for exact scenario counts and coverage.

## Limitations

- **No boolean condition composition (`AND`/`OR`/`NOT`).** One atomic condition per edge, unchanged from Phase 4.1's validation-time decision.
- **`module_variable` condition sources remain unimplemented.** No module adapter contract exists; only `instance_variable` and static literals are usable.
- **Split, join, and multi-token execution remain fully deferred.** Reconvergence onto a `gateway_exclusive` or `end` node is ordinary graph convergence under the single-token model — no synchronizing merge, no token identity or join-arrival tracking exists or is introduced by this milestone.
- **No delegation, escalation, timers, notifications, adapters, or frontend.** Unchanged from every prior workflow-engine phase.
- **No new indexes.** Performance was verified sufficient against the existing index set at every benchmarked scale; none were added speculatively.
