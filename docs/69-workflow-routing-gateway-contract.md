# CAP-002 Phase 4.0 — Workflow Routing and Gateway Contract

## Status and scope

This is an architecture and executable-contract specification only, in the exact spirit of `docs/63-workflow-executable-definition-contract.md`. It adds no SQL, migration, function, RPC, validator, test, runtime behavior, module adapter, notification, timer, frontend, or workflow designer. It defines the contract a future implementation phase must follow; it does not implement that phase.

The authoritative inputs are `docs/60-workflow-engine-architecture.md` through `docs/68-workflow-approval-round-lifecycle.md` and the approved baseline at commit `24543f36cd88b3bcb8c709713f799d56f24451a1`. This document does not redesign anything those documents already settled. Every rule below either extends an existing rule to a new node type or introduces a genuinely new, previously-deferred concept; where it does the latter, that is called out explicitly.

Docs/63 already named this exact milestone and scoped it precisely: **"CAP-002 Phase 4 — Routing and Conditional Branching: Define and implement routing nodes, allowlisted conditions/gateways, default-edge behavior, and any required token split/join capability under a higher contract version."** This document is the "define" half of that sentence.

## Design decisions

1. Version 1 (`docs/63`) is byte-for-byte unchanged by this document. Nothing here alters `start`, `approval`, or `end` node behavior, the existing outcome-keyed edge-selection algorithm, or any already-published `schema_version = 1` payload's execution.
2. A new capability version — Version 2 — is additive. It introduces exactly one new node type, `gateway_exclusive`, and exactly one new edge-selection algorithm that applies only to edges sourced from that node type.
3. Per docs/63's own deferred-node-type table, `gateway` / `condition` semantics require "an allowlisted condition registry and deterministic default handling." This document defines that registry and that handling — the two things that table said were still missing.
4. Consistent with docs/60's stated risk mitigation ("over-generalized engine... small allowlisted node vocabulary") and docs/63's design decision 4 ("later capability versions may add them without changing version-1 semantics"), Version 2 deliberately implements only the smallest useful slice: single-token, deterministic, condition-based branching. Parallel split, synchronizing merge/join, and boolean condition composition are evaluated below and explicitly deferred, each with its own stated reason — not silently dropped.
5. Docs/63's own single-token model, bounded 32-hop advancement ceiling, global lock order, append-only event ledger, and replay-metadata discipline (the peek-before-write pattern from `docs/68`) are reused without modification. Version 2 is designed to be a new `ELSIF` branch inside the existing bounded loop in `workflow_enter_downstream_node`, exactly the same shape as the empty-electorate skip branch Phase 3.2 already added — not a parallel execution path.

## A load-bearing open dependency: variable population

Before defining the condition system, this document must surface a real gap rather than paper over it. Every routing condition needs a left-hand value to compare. The only instance-scoped value storage that exists in the approved baseline is `workflow_variables` (`docs/61`, Phase 1) — and **no approved contract anywhere in docs/60–68 defines a command that writes a `workflow_variables` row.** `create_workflow_instance` does not accept or populate variables; no later phase added one either.

This means: condition evaluation against an `instance_variable` source is fully specified by this contract, but as of the approved baseline there is no populated data for it to evaluate against. This is a genuine open dependency, not an oversight, and this document does not resolve it — closing it requires a separately approved contract (most plausibly either a narrow manager-gated `set_workflow_instance_variable` command, or a future module-adapter contract that snapshots subject attributes into variables at instance-creation or node-entry time). Until it is closed, `gateway_exclusive` nodes remain fully specified and structurally valid, but can only be meaningfully exercised using the `is_null` / `is_not_null` operators against a deliberately-unset variable (see "Undefined variable handling" below) or against static-constant-only conditions. The implementation roadmap below returns to this explicitly under Phase 4.1.

## Terminology additions

- **Gateway node:** A definition node whose outbound edges are selected by evaluating conditions rather than by matching a step's outcome code.
- **Route:** The single outbound edge a gateway selects for one execution of one gateway step.
- **Condition:** One allowlisted, typed, atomic comparison between an instance variable and a static literal.
- **Condition registry:** The fixed, versioned enumeration of supported operators and data types a condition may use. There is no registry extension mechanism inside a definition; extending it requires a new capability version.
- **Default edge:** The single outbound edge of a gateway node that fires when no condition matches. Required on every gateway node in Version 2 (see "Default branches").
- **Capability version:** The existing `workflow_definition_versions.capability_version` column (`docs/61`), kept in lockstep with the payload's `schema_version` field exactly as docs/63 already requires for Version 1. Version 2 payloads declare `schema_version: 2` and must be stored with `capability_version = 2`.

## Gateway node architecture

### `gateway_exclusive`

A single new node type, deliberately more specific than the deferred placeholder name `gateway` in docs/63's table, to leave room for `gateway_parallel_split` / `gateway_merge` as distinct, separately-versioned node types if a future capability version adds them (see "Gateway types").

- **Required configuration:** empty object `{}`. All routing-relevant configuration lives on the node's outbound edges, not the node itself — the same placement docs/63 already uses for `outcome`/`priority`/`default`. A gateway node with per-node routing config would duplicate what edges already express and risk the two disagreeing.
- **Optional configuration:** none in Version 2.
- **Key/label rules:** unchanged — `^[a-z][a-z0-9_]{0,62}$`, optional 1–120 character label, identical to every existing node type.
- **Inbound edges:** one or more are structurally permitted, reusing exactly the same rule and the same proof obligation docs/63 already states for `approval` nodes ("validation must prove exactly one reachable predecessor path"). This proof continues to hold automatically in Version 2 because Version 2 preserves the single-token model (design decision 2) — with no split, at most one predecessor path can ever be live in one execution, whether the converging edges originate from `approval` nodes, `gateway_exclusive` nodes, or a mix.
- **Outbound edges:** 2 through 16 (a gateway with fewer than two real branches is not a gateway; 16 mirrors the existing candidate-selector-count precedent in docs/63 rather than inventing a new scale). Exactly one of them must be the default edge (see below).
- **Runtime:** entering a gateway node creates one `workflow_instance_steps` row (preserving docs/63's "entering every node creates one step run before node behavior occurs" invariant without exception), evaluates its outbound edges' conditions in deterministic order, selects exactly one edge, moves through `active → completed` in the same transaction — the identical synchronous shape `start` and `end` steps already use — with `result_code = 'routed'`.
- **Token creation:** no. A gateway node retains the existing token exactly like an `approval` node does; Version 2 does not introduce a second token.
- **Work items:** none. A gateway is a machine decision, never a human one.
- **Completion:** immediate, in the same transaction that entered the node — a gateway never waits.
- **Failure:** an unresolvable route (no condition matched and, structurally, no default edge exists — which publication validation must already have prevented) fails the command atomically and records a configuration-fault event, never silently completing. This is docs/60's own already-approved principle ("every branch has a deterministic default or fail-closed error route... the instance fails closed into an administrator-visible configuration fault") — Version 2 does not invent a new failure philosophy, it satisfies the one that was already written down and unimplemented.

## Gateway types

The task is to evaluate exclusive gateway, parallel split, and merge gateway, and state which belong to Version 2.

| Type | Version 2 decision | Reason |
|---|---|---|
| **Exclusive gateway** (`gateway_exclusive`) | **In Version 2.** | A deterministic, single-token, condition-driven branch is a minimal, additive extension of the existing outcome-keyed edge-selection algorithm. It needs no new runtime primitive beyond "evaluate conditions, pick one edge" — no token identity, no join accounting, no new lock tier. |
| **Parallel split** | **Deferred**, to a future higher capability version (tentatively "Version 3" below; not binding until separately approved). | Docs/63 is explicit that this needs its own contract: "Parallel graph fan-out and join behavior are prohibited in schema version 1. A future split/join contract must add parent/lineage and join-arrival invariants under a new capability version." That sentence describes real new runtime state (token identity, parent/child lineage, per-branch completion tracking) this document has not designed and should not smuggle in as a side effect of routing. |
| **Merge gateway** (synchronizing join) | **Deferred**, for the same reason and to the same future version. | A synchronizing join only has meaning once more than one token can be simultaneously in flight, which Version 2 does not introduce (see "Token model"). Building a join primitive with nothing to join would be speculative, unused surface area — directly against docs/60's own stated risk mitigation. |

Reconvergence *without* a synchronizing join is already possible in Version 2 at no additional cost: because `gateway_exclusive` branches are mutually exclusive and Version 2 preserves the single-token model, multiple gateway outbound edges — or a mix of gateway and approval outbound edges — may target the same downstream node key. This is ordinary graph convergence, not a new primitive, and is covered by the exact same "one or more inbound edges, prove exactly one reachable predecessor path" rule already applied to `approval` nodes above. See "Merge behavior" for the full statement of what is and is not supported.

## Routing conditions

Arbitrary SQL, arbitrary JavaScript, and arbitrary expressions are prohibited, exactly as docs/60 and docs/63 already require for the entire engine. Version 2 defines a closed, allowlisted condition system with no expression parser and no extensibility point inside a definition payload.

### Condition schema

Each non-default outbound edge of a `gateway_exclusive` node may carry exactly one `condition` object (edges omitting `condition` are a validation error unless they are the default edge, which must never carry one):

```json
{
  "source": "instance_variable",
  "variable_name": "priority_band",
  "operator": "equals",
  "value_type": "string",
  "value": "urgent"
}
```

- `source` is required and is one of the allowlisted variable sources below.
- `variable_name` is required when `source = "instance_variable"`, matches the existing `^[a-z][a-z0-9_]{0,62}$` pattern (`workflow_variables.variable_name`'s own constraint, reused verbatim, not a new pattern), and is not validated for existence at publish time — instance variables do not exist until runtime.
- `operator` is required and is one of the allowlisted operators below.
- `value_type` is required for every operator except `is_null`/`is_not_null`, and is one of `boolean`, `number`, `string`, `date`, `timestamp`, `uuid` — the existing `workflow_variables.value_type` enum, minus `null` (meaningless as a comparison operand type) and `json` (deep-equality/ordering over arbitrary JSON is unbounded complexity this document deliberately does not take on; a `json`-typed instance variable simply cannot be used as a condition operand in Version 2).
- `value` is required for every operator except `is_null`/`is_not_null`, is a static literal embedded in the definition payload at authoring time, and must match the declared `value_type`.
- Unknown fields on a condition object are rejected, matching every other object in this contract family.

### Supported operators

A single fixed, closed list — no registry extension mechanism inside a definition:

| Operator | Applies to | Arity |
|---|---|---|
| `equals`, `not_equals` | `boolean`, `number`, `string`, `date`, `timestamp`, `uuid` | binary |
| `in`, `not_in` | `number`, `string`, `uuid` | binary, `value` is an array of 1–20 literals of the declared type |
| `greater_than`, `greater_than_or_equal`, `less_than`, `less_than_or_equal` | `number`, `date`, `timestamp` | binary |
| `is_null`, `is_not_null` | any type | unary (no `value`/`value_type` field) |

Boolean composition (`AND`/`OR`/`NOT` across multiple conditions on one edge) is **deliberately not supported** in Version 2. One edge carries at most one atomic condition. A multi-clause requirement is expressed the same way an `if`/`elif`/`else` chain already expresses it: as multiple prioritized single-condition edges evaluated in order (see "Branch selection"). This is a real capability restriction, not an oversight — it keeps the condition system provably non-Turing-complete and keeps validation and auditing simple, at the cost of requiring several edges instead of one compound condition for genuinely multi-clause routing. A future capability version may add bounded composition if evidence justifies the added complexity.

### Undefined variable handling

An `instance_variable` reference to a variable that does not exist on the instance (because it was never written — see "A load-bearing open dependency" above) is **not** a validation error and **not** a runtime exception. It evaluates the condition as `false` — never `NULL`, never a silent pass, never a crash — and evaluation proceeds to the next edge in priority order. This is a deliberate, explicit design choice informed directly by this session's own prior debugging history: Phase 3.2's concurrency and rollback verification work repeatedly found that letting a three-valued (`true`/`false`/`NULL`) comparison silently fall through as neither `true` nor `false` (`dblink_get_result`'s `err` column; a scalar subquery `<>` comparison against a possibly-empty result) masked real bugs instead of failing loudly. Routing conditions must never repeat that class of defect: "the variable does not exist" is a fully defined, deterministic outcome (`false`), not an undefined one.

## Variable sources

| Source | Version 2 status | Notes |
|---|---|---|
| `instance_variable` | **Supported.** | Reads `workflow_variables` for the instance being routed, scoped to `(instance_id, variable_name)` — the exact existing index (`docs/61`). See the open dependency above: reading is fully specified; writing is not yet approved anywhere. |
| Static constant | **Supported, as the right-hand `value` only.** | A condition always compares one `instance_variable` against one embedded literal. Comparing two variables against each other, or two static constants against each other, is not supported — the former has no approved use case yet and the latter is a compile-time-constant result that adds no routing value while adding validation surface. |
| Module variable | **Explicitly prohibited / deferred.** | No module adapter contract exists (`docs/60`: adapters are a separately approved future layer; `docs/63`: "adapter-supplied candidates... deferred"). A condition source that read module data directly would bypass the adapter boundary docs/60 treats as load-bearing security architecture. Deferred until a module-adapter contract is separately approved, exactly like every other adapter-dependent capability in this engine. |
| Anything else (client-supplied RPC parameters, other instances' variables, direct table/column references, dynamic identifiers) | **Explicitly prohibited.** | A condition may only read `workflow_variables` rows already committed to the *same* instance before the routing command begins, under the same instance row lock every other engine read already uses. No condition may accept a value directly from the calling command's own parameters — that would let a caller choose their own route, which is exactly the "never a client-selected target-node RPC" principle docs/63 already establishes for graph advancement generally, extended here to gateway edges specifically. |

## Branch selection

Deterministic, single-winner selection — the routing counterpart to docs/63's existing outcome-keyed edge selection, which remains unchanged for `start`/`approval`/`end`. Gateway-sourced edges use a second, new algorithm instead:

1. **Evaluation order:** a gateway node's non-default outbound edges are evaluated in ascending `priority` order. `priority` reuses the existing edge field (docs/63: integer 0–1000), which Version 1 requires to be exactly `0` for every edge. Version 2 makes this field meaningful for gateway-sourced edges only: **priority values among one gateway node's outbound edges must be unique integers**, evaluated ascending, giving a total, deterministic order with no ties — the same "unique ordering integers" discipline docs/63 already uses for candidate-selector `order`.
2. **First-match wins:** the first edge (in that order) whose condition evaluates `true` is selected. Evaluation stops there — later edges are not evaluated, and their conditions have no side effects to worry about (conditions are pure reads).
3. **No match:** if no non-default edge's condition evaluates `true`, the sole default edge is selected.
4. **Ambiguity:** cannot occur at runtime by construction — priorities are validated unique at publish time, and evaluation always stops at the first match — but publication additionally rejects any gateway node whose outbound edges do not have pairwise-unique priorities, so ambiguous configurations are rejected before an instance can ever reach them, not merely tolerated at runtime.
5. **Invalid routing:** an edge whose `condition` references an operator/type/value combination the registry does not allow is a publish-time validation failure (see "Validation"), never a runtime discovery.
6. **No-match without a default:** cannot occur, because a default edge is required on every `gateway_exclusive` node (next section) and publication rejects a gateway node lacking one. The synchronous fail-closed fault path described under "Gateway node architecture → Runtime/Failure" exists purely as defense-in-depth beneath that publish-time guarantee — the same "belt and suspenders" relationship docs/63 already keeps between publish-time graph validation and the runtime's own defensive checks.

## Default branches

- **Required:** every `gateway_exclusive` node must have exactly one outbound edge with `default = true`. Version 2 makes no attempt to prove at publish time that a gateway's conditions are exhaustive (that would require a constraint-satisfiability check this document deliberately does not take on, consistent with the minimality decisions above) — instead, a default is simply always mandatory, closing the same gap by construction rather than by proof.
- **Prohibited elsewhere:** exactly as docs/63 already states, `default = true` remains prohibited on every non-gateway-sourced edge (`start`/`approval`/`end` outbound edges continue to require `default = false`, unchanged).
- **Validation:** a default edge must not carry a `condition` (the two are mutually exclusive — a default is definitionally the "otherwise" case); a gateway node with zero or more than one default edge is a publish-time validation failure; a gateway node whose default edge shares a `priority` value with a non-default edge is likewise rejected, keeping `priority` a clean total order over the non-default edges only.

## Merge behavior

- **Version 2 supports:** ordinary graph reconvergence. Multiple gateway (and/or approval) outbound edges may target the same downstream node key. No new runtime object, table, or state is required — this is exactly the "one or more inbound edges, exactly one reachable predecessor path" rule already stated for `approval` nodes, applied uniformly. Because Version 2 keeps the single-token model, "exactly one reachable predecessor path" continues to hold automatically: only one branch is ever actually taken per execution, so only one of the converging paths is ever actually live.
- **Version 2 does not support:** a synchronizing merge/join that waits for more than one token to arrive before proceeding. That primitive has no meaning without a preceding split, and split is deferred (see "Gateway types"). Building a join node in Version 2 would create a node type with no valid producer of the state it would need to synchronize.
- **Token behavior at a merge point:** unchanged from every existing node type. The single token simply continues into the shared downstream node the same way it would into any other node with more than one structural predecessor.
- **Replay:** unaffected. Because only one path is ever live, replay of a routing command through a reconvergence point reads back the exact same recorded route from the command's own root event (see "Replay semantics"), regardless of how many structural predecessors the target node has.

## Token model

**Version 2 preserves the single active-token-per-instance model unchanged.** `gateway_exclusive` selects among mutually exclusive outbound paths — it narrows the one live token's next step, it does not fan it out. No token identity, parent/lineage, or join-arrival tracking is introduced.

Parallel split (and therefore true merge/join) is deferred to a later, separately approved architecture milestone, for the reasons already stated under "Gateway types": it requires genuinely new runtime primitives — token identity, parent/child lineage, per-branch completion accounting, and join-arrival invariants — that docs/63 already flagged as needing "a new capability version" of their own, and that this document has not designed. Attempting to fold multi-token semantics into this same contract would violate design decision 4 (smallest useful slice) and would make this document responsible for two independent, separately-risky capabilities (conditional branching and parallel execution) instead of one.

## Capability version

| | Capability Version 1 | Capability Version 2 |
|---|---|---|
| `schema_version` payload field | `1` | `2` |
| Stored `capability_version` column | `1` | `2` |
| Node types | `start`, `approval`, `end` | `start`, `approval`, `end`, `gateway_exclusive` |
| Edge selection | outcome-keyed (exactly one edge per producible outcome) | outcome-keyed for `start`/`approval`/`end` (unchanged); condition-priority-default for `gateway_exclusive`-sourced edges (new) |
| `priority` / `default` / `condition` edge fields | `priority` must be `0`; `default` must be `false`; `condition` field prohibited entirely | unchanged for non-gateway-sourced edges; meaningful for gateway-sourced edges as specified above |
| New events | none | `route_selected` |

**Version compatibility:** an engine that supports capability version 2 must continue to execute every already-published capability-version-1 definition and every instance pinned to one with byte-identical behavior — this is the acceptance test for Phase 4.2's implementation, not merely an aspiration. Structurally guaranteed because the new gateway branch in the shared graph-advancement loop is additive (see "Migration"), and because `gateway_exclusive` cannot appear in any payload whose `schema_version` is `1` — publication already rejects unknown node types today, and will continue to reject `gateway_exclusive` under a `schema_version = 1` payload specifically.

**Migration rules:** unchanged from docs/63 — a published version is never rewritten in place; declaring `schema_version = 2` behavior against an existing family requires a new draft version under the existing draft/publish/version-increment discipline. There is no "upgrade a running instance's capability version" concept; instances remain pinned to the version they activated against, exactly as today.

**Validation rules:** `schema_version` values other than `1` or `2` are rejected as unknown/invalid input, not silently accepted or coerced. The `schema_version` (payload) / `capability_version` (column) equality check docs/63 already enforces for `1` is extended, unchanged in mechanism, to require `2`/`2` together.

**Backward compatibility:** guaranteed by construction, not by testing alone — though Phase 4.2's regression suite must still prove it empirically, following this session's established discipline of running the full prior-phase suite unmodified after every change.

## Routing execution model

Reuses `workflow_enter_downstream_node` (`docs/66`, extended in `docs/67`/`docs/68`) as the single graph-advancement authority — no second copy of graph-traversal logic, per the standing "do not duplicate graph advancement" rule this entire document is written to respect.

The bounded loop already established in Phase 3.2 for the empty-electorate skip gains one more branch, structurally identical in shape to the existing skip branch:

1. `start` → unchanged (creates the initial token, moves through its sole `started` edge, `CONTINUE`s).
2. `approval` with a nonzero electorate → unchanged (opens a round, creates work items, the loop stops — waiting).
3. `approval` with a zero-candidate optional electorate → unchanged from Phase 3.2 (skip-and-`CONTINUE`).
4. **`gateway_exclusive` (new):** creates the step row, evaluates the node's outbound edges per "Branch selection," emits `route_selected` then the existing `token_moved`/`step_entered` sequence for the selected target, and `CONTINUE`s the loop into that target — exactly the same "synchronous zero-work node, no waiting" shape the skip branch already established, generalized from "one deferred case" to "any node with no human decision to wait for."
5. `end` → unchanged (consumes the token, evaluates instance completion).

**Bound:** no new ceiling. The existing defensive maximum of 32 immediate node entries per command (docs/63, reused verbatim by Phase 3.2's own bounded loop) now also counts gateway hops, exactly as it already counts skip hops and `start`/`end` entries. A pathological chain of consecutive gateways fails the same bounded way a pathological chain of skips already would.

## Deterministic routing rules

- Routing must produce exactly one active execution path: guaranteed structurally, because branch selection (above) always yields exactly one selected edge — either the first true condition or the mandatory default — and the single-token model means there is only ever one path to produce.
- Routing must reject ambiguous routing: guaranteed at publish time by the unique-priority requirement (see "Branch selection" and "Validation") — ambiguity cannot reach an instance.
- Routing must reject invalid routing: guaranteed at publish time by the condition-registry allowlist — an edge referencing an unsupported operator, type, or malformed value is a publish-time validation failure, never a runtime discovery.
- Routing must support default branches: guaranteed by the mandatory-default rule.
- Routing must remain fully replay-safe: see next section.

## Replay semantics

Routing decisions are **recorded, not re-derived** — the same append-only replay discipline `docs/67`/`docs/68` already established for graph-advancement metadata (the peek-before-write pattern) is reused unmodified. The selected edge/target for a gateway evaluation is written into the routing command's own root event metadata at decision time (via the existing `workflow_peek_final_graph_target`-style pre-computation the three outer commands already perform before inserting their root event, extended to walk through gateway hops exactly as it already walks through skip hops). A replay of the same command — same idempotency key, same input — returns the originally recorded routing outcome. **It never re-evaluates conditions against possibly-different variable state on replay.**

This matters even though, as of this contract, no approved command can actually change a `workflow_variables` value after it is written (there is no write path yet at all, per the open dependency above) — the discipline is deliberately future-proof: if a variable-write contract is approved later, replay safety for routing decisions already taken will not need to be revisited, because replay was never designed to re-read live state in the first place.

## Concurrency model

**No new lock tier.** Gateway evaluation reads `workflow_variables` under the instance row lock the bounded loop already holds for the entire advancement command — the existing global lock order (docs/63, "Global lock order," 9 steps: advisory lock → instance row → steps → tokens → rounds → positions → work items → decision inserts → instance update/events) requires zero amendment, because a gateway hop touches only the instance, its step, and its token — all of which are already locked at that point in the existing order. This is the deliberate result of design decision 5, not a coincidence.

**Prevented, exactly as required, by mechanisms already in place and reused unmodified:**

- *Duplicate branch execution:* a hop, once taken and recorded (`route_selected` + `token_moved`), is exactly as idempotent as every other step in the bounded loop — a replay of the outer command returns the recorded root-event metadata (see "Replay semantics") and never re-runs the loop.
- *Replay races:* the existing idempotency-key + root-event-metadata replay discipline, unmodified.
- *Stale graph execution:* the existing instance `lock_version` optimistic-concurrency check, unmodified.
- *Concurrent branch evaluation:* two concurrent commands advancing the same instance already serialize at the instance row lock; the loser observes the incremented `lock_version` and fails with the existing stable `40001` retry contract, unmodified.

If a future variable-write contract is approved (see the open dependency), *that* contract — not this one — will be responsible for stating where in the lock order `workflow_variables` writes belong, since none of the mechanisms above currently need to lock that table for writes.

## Audit model

One new event type, added to docs/63's existing "minimum graph events" list under a new grouping, alongside the existing token/step/work-item/round/decision groupings:

- **Gateway routing:** `route_selected`

**Placement:** emitted immediately before the existing `token_moved`/`step_entered` sequence for the gateway's selected target — the same position the skip branch's `step_skipped` already occupies relative to its own continuation, generalized rather than duplicated.

**Payload contract** (bounded exactly like every other event, 16 KiB, safe codes only): gateway node key, selected edge's target node key, whether the default edge was used (boolean), and — bounded to `true`/`false` per evaluated condition slot, in the priority order they were evaluated — which conditions were checked and their boolean result. **Raw instance-variable values are never copied into event metadata, regardless of a variable's `classification`.** This is a deliberate hard rule, not an oversight: `workflow_variables.classification` already distinguishes `public` from `restricted` (docs/61), and event visibility (`can_view_workflow_instance()`) is broader than the manager-only visibility `workflow_variables` itself carries (`can_manage_workflow_instance()`, per the existing `workflow_variables_select` policy). Copying a restricted variable's value into an event would silently widen its visibility. Recording only the boolean outcome of each condition check gives full auditability of *why* a branch was taken without re-exposing the value that decided it.

## Security

- **Routing authorization:** no new permission model. Gateway evaluation happens entirely inside the same `SECURITY DEFINER`, pinned-`search_path` command path already used by `workflow_transition_instance` / `workflow_advance_graph_step` / `decide_workflow_work_item`, purely as an internal extension of the shared bounded loop. A route is never independently client-selectable — the existing "never a client-selected target-node RPC" principle (docs/63, "Generic graph-advancement contract") is extended, unchanged in spirit, to gateway edges specifically.
- **Condition safety:** the closed operator/type allowlist above is the entire surface. No expression parsing, no dynamic SQL, no code execution, no dynamic identifiers — the exact same "no string is interpreted as SQL, code, table name, function name, URL, or arbitrary expression" rule docs/63 already states for the whole engine, applied verbatim to condition values.
- **Expression safety:** there are no expressions in Version 2, only atomic typed comparisons — this is what makes the safety argument above tractable; a future bounded-composition extension (see "Routing conditions") would need to re-justify safety on its own terms rather than inherit this one automatically.
- **RLS expectations:** no new table, therefore no new RLS policy. `workflow_variables`'s existing `SELECT` policy (`can_manage_workflow_instance`) is unchanged and is not the mechanism by which the engine itself reads variables during gateway evaluation (that read happens server-side inside a `SECURITY DEFINER` function, not as a client SELECT). The new `route_selected` event is visible under the existing `workflow_events_select` policy (`can_view_workflow_instance`), exactly like every other event type — no new policy is required, matching how docs/67 and docs/68 each needed zero new RLS policies for their own new event types.
- **Deterministic execution:** guaranteed by the same instance-row-lock discipline that already guarantees deterministic outcome ordering for concurrent commands under docs/63's global lock order, reused unmodified (see "Concurrency model").

## Validation

A future validator must enforce, extending the existing publication-validation pipeline (docs/63, "Publication validation," 14 checks) rather than replacing it:

- **Gateway correctness:** `gateway_exclusive` node `config` is exactly `{}`; unknown fields rejected, matching every other node type.
- **Branch correctness:** every gateway outbound edge has `outcome = 'routed'` (a single fixed reserved value used only for bookkeeping/uniqueness, never for branch selection — branch selection uses conditions, not outcomes, for this node type); a non-default gateway edge has exactly one `condition` object conforming to the schema above; a default gateway edge has none.
- **Default branch rules:** exactly one `default = true` edge per gateway node (see "Default branches").
- **Unreachable branches:** reuses the existing global reachability validator unmodified — every node reachable from `start`, every reachable nonterminal node can reach an `end` — now applied uniformly across gateway-sourced edges too, with no algorithm change.
- **Cycles:** still fully prohibited, unchanged. A gateway edge pointing back upstream remains a publish-time validation failure exactly like any other node type's edge would.
- **Duplicate priorities:** rejected — priority values among one gateway node's outbound edges must be pairwise unique integers (see "Branch selection").
- **Invalid operators / types:** rejected against the closed allowlist above; no unknown operator or `value_type` may publish.
- **Invalid variable references:** `variable_name` must match the existing safe-key pattern; existence is not checked at publish time (variables are instance-scoped and do not exist yet), but malformed names are still rejected exactly like any other key-shaped field in this contract family.

## Scalability

- **Evaluation limits:** at most 16 outbound edges per gateway node (matching the existing candidate-selector-count precedent), so at most 16 condition evaluations per gateway hop.
- **Branching limits:** covered by the existing 200-node / 400-edge definition-wide budget (docs/63); no separate cap is introduced for gateway node count specifically.
- **Merge limits:** not applicable in Version 2 — no synchronizing merge primitive exists to bound.
- **Recursion / hop limits:** the existing 32-immediate-node-entries-per-command ceiling, unchanged, now also bounding gateway chains (see "Routing execution model").
- **Token limits:** 1 active token per instance, unchanged (see "Token model").
- **Performance expectations:** qualitative only, since nothing is implemented by this document — a gateway hop adds one bounded, indexed `(instance_id, variable_name)` read plus in-memory evaluation of at most 16 typed comparisons, the same order of magnitude of work the existing skip-branch hop already performs and already measured at single-digit-to-low-double-digit milliseconds even across a 25-hop chain (docs/68's own performance dimension 2). Exact numbers must come from Phase 4.3's own performance probes, not from this document.

## Migration

Version 1 → Version 2 is purely additive:

- Every already-published `schema_version = 1` definition and every instance pinned to one continues to execute through the unchanged `start`/`approval`/`end`/skip branches of the shared loop — byte-for-byte, per design decision 1.
- `gateway_exclusive` cannot appear in a `schema_version = 1` payload; publication already rejects unknown node types today and will continue to reject this one specifically under a `schema_version = 1` payload.
- A `schema_version = 2` payload requires `capability_version = 2` end-to-end, gated by the same equality-check discipline docs/63 already enforces for `1`/`1`. No definition can silently upgrade; a mismatch is a hard publish-time validation failure.
- **Rollback expectations** for the future implementation phase (Phase 4.2/4.3), stated now so that phase does not have to re-derive them: reuse the "never refuses" vs. "refuses if evidence exists" distinction this session has already applied consistently. A rollback of the Version 2 implementation must **refuse** if any `schema_version = 2` definition, gateway-activated instance, or `route_selected` event exists — a recorded routing decision is exactly the kind of immutable evidence Phase 2B's and Phase 3.1's rollback precedents already protect (docs/63: "Rollback must refuse if any executable-v1 definition, approval round, position, or graph-activated instance exists; it must never discard runtime history"). It may **never refuse** purely on the grounds that the new `gateway_exclusive` branch of the shared loop exists in code with no gateway-activated instances yet — that is the Phase 2C.1/3.2 "changes only function bodies, no data at risk" case, unchanged in spirit.

## Implementation roadmap

Each phase below requires its own separate approval, design, tests, rollback, documentation, and commit boundary, exactly as docs/60's "Implementation phases" section and every phase actually executed in this session have already required.

- **Phase 4.1 — Definition validation for capability version 2.** Extend canonicalization and the publication validator to accept `schema_version = 2` payloads containing `gateway_exclusive` nodes: condition-schema validation, branch/default/priority validation, reachability validation extended to gateway-sourced edges. No runtime/execution change — mirrors exactly how docs/63 → Phase 2B separated validation from execution. Phase 4.1 must also resolve, or explicitly re-scope around, the open variable-population dependency above: either define and implement a minimal variable-write command as part of this phase, or explicitly limit this phase's behavioral coverage to the `is_null`/undefined-variable paths and static-only conditions until a variable-write contract is separately approved. This document does not decide which; that is Phase 4.1's own scoping call to make and report.
- **Phase 4.2 — Gateway execution / graph advancement extension.** Add the new `gateway_exclusive` branch to `workflow_enter_downstream_node`'s bounded loop; extend the peek-before-write helpers (in the style of `workflow_peek_final_graph_target`) so gateway hops are correctly accounted for in the existing replay-metadata discipline; emit `route_selected`. Purely additive — the full Version 1 regression suite must pass completely unmodified, exactly like Phase 3.2's own regression discipline required for the skip branch.
- **Phase 4.3 — Verification and closeout.** Structural validator, behavioral tests (successful routing, default branch, invalid branch rejected at publish time, ambiguous branch rejected at publish time, replay, reconvergence, concurrent execution), RLS tests, concurrency tests, performance probes, rollback + rollback validator with byte-exact baseline comparison, full repository regression across every phase through 4.2, `docs/70-workflow-routing-execution.md`, single commit. Follows this session's established verification methodology exactly.
- **Phase 5 — Parallel split / synchronizing merge (a future, separately approved capability version).** Token identity and lineage, join-arrival invariants, parallel completion semantics. Requires its **own** architecture-only milestone before any implementation, for the same reason this document had to exist before Phase 4.1-4.3 could start — token fan-out is a large enough capability that folding it into this document would have violated design decision 4.
- **Phase 6 — Delegation, substitution, escalation, timers.** Already-deferred scope from docs/60/63, unchanged, now sequenced after routing because these are actor/time concerns orthogonal to graph shape, not a routing prerequisite.
- **Phase 7 — Module adapters, notifications/outbox, shared inbox/frontend, workflow designer.** The "adoption" stages docs/60 already describes as Stage 4 through 8 of its own migration strategy. Each requires its own separately approved architecture milestone, per docs/60's explicit statement that adoption is incremental and no module is yet selected for pilot or migration.

## Open questions / deferred items

Explicitly deferred, not ambiguous — each requires a new approved contract or capability version, exactly matching the discipline docs/63 closes with:

- Variable population (`workflow_variables` write path) — see "A load-bearing open dependency" above.
- Boolean condition composition (`AND`/`OR`/`NOT` across multiple conditions on one edge).
- Parallel split, synchronizing merge/join, and multi-token execution generally.
- Module-adapter-supplied condition variables.
- Manual/deadline/conditional route overrides by a workflow manager (routing here is purely condition-driven; no human override path is defined).
- Any condition operand type beyond `boolean`/`number`/`string`/`date`/`timestamp`/`uuid` (in particular, no `json` operand comparison).
- Reporting-line-based resolvers, delegation, substitution, escalation, timers, notifications, adapters, and frontend — all already deferred by prior documents and unchanged by this one.

There are no blocking semantic questions for Phase 4.1 through 4.3 as scoped above, beyond the one explicit scoping decision Phase 4.1 itself must make regarding variable population.
