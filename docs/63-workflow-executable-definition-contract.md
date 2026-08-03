# CAP-002 Phase 2A — Executable Workflow Definition and Graph Contract

## Status and scope

This document resolves the sequencing gap between the inert workflow foundation and the future approval engine. It is an architecture and executable-contract specification only. It adds no SQL, migration, function, RPC, runtime behavior, module adapter, notification, timer, frontend, or business-module integration.

The authoritative inputs are `docs/60-workflow-engine-architecture.md`, `docs/61-workflow-backend-foundation.md`, `docs/62-workflow-runtime.md`, and the workflow tables, constraints, functions, validators, and tests at commit `23a02d5a710e2b34c402cc77cd9af333b7e54e12`.

## Identified sequencing gap

The existing checkpoints deliberately cannot execute approvals:

- Phase 1 publishes only definitions whose `nodes` and `edges` arrays are empty.
- Phase 1 creates a pending instance, owner participant, and `instance_created` event, but no token, step run, work item, approval round, or decision.
- Phase 2 changes only instance lifecycle state. Starting an instance creates no graph state.
- Phase 2 explicitly requires definition validation and graph execution before approval commands.
- Existing tables can store steps, tokens, work items, and decisions, but no approved contract defines executable node JSON, candidate snapshots, round policy, quorum, token advancement, or graph completion.
- `workflow_decisions` prevents command reuse but does not by itself define one accepted vote per voter position.

Implementing approvals directly would therefore invent security and lifecycle semantics. This contract closes that gap and establishes separate implementation boundaries for executable definition validation, graph advancement, and approval decisions.

## Design decisions

1. Immutable JSONB in `workflow_definition_versions.definition_payload` remains the authoritative process definition. Definition graphs are loaded by primary key, not searched as operational data, so normalization would add synchronization risk without improving the hot paths.
2. Mutable runtime state remains normalized. Approval rounds and their voter-position snapshots require dedicated runtime persistence because quorum, concurrency, queues, and RLS must not depend on JSON scans.
3. Contract version 1 supports only `start`, `approval`, and `end` nodes. These are sufficient for sequential approval chains and parallel voting within a round.
4. Graph cycles, token splits, joins, routing, FYI, gateways, conditions, and system actions are prohibited in version 1. Later capability versions may add them without changing version-1 semantics.
5. Parallel approval means multiple voting work items in one approval round. It does not require parallel graph tokens.
6. Candidate resolution is snapshotted when an approval node is entered. The denominator never changes after the round opens.
7. Engine state remains separate from every module state. No definition may contain module SQL, table names, HTTP calls, JavaScript, or arbitrary expressions.

## Terminology

- **Contract version:** The `schema_version` governing the exact definition payload shape. Version 1 is specified here.
- **Definition node:** An immutable declarative node in a published definition version.
- **Definition edge:** An immutable outcome-to-node mapping in a published definition version.
- **Runtime token:** The current execution cursor for one path. Version 1 permits exactly one active token.
- **Step run:** One runtime entry into one definition node. Cycles are prohibited in version 1, so `run_number` is always 1, while the existing field remains future-compatible.
- **Approval round:** The normalized runtime aggregation state for one approval step run.
- **Voter position:** One immutable electorate slot with a resolved user and authority source. A user may occupy multiple positions only when the definition explicitly permits multi-capacity voting.
- **Decision:** One immutable accepted response for one voter position and work item.
- **Command root event:** The single event carrying the caller's idempotency key and replay result. Derived events use engine-generated keys and reference the root through `causation_id`.

## Executable definition schema

### Top-level payload

An executable version-1 payload has exactly these fields:

```json
{
  "schema_version": 1,
  "entry_node": "start",
  "nodes": [],
  "edges": []
}
```

Rules:

- Unknown top-level fields are rejected.
- `schema_version` is the integer `1`.
- `entry_node` is a node key and must identify the sole `start` node.
- `nodes` contains between 2 and 200 nodes, sorted by `key` in ascending bytewise order.
- `edges` contains between 1 and 400 edges in canonical order.
- The canonical payload is the JSONB representation with canonical node, selector, user-ID, and edge array ordering.
- The SHA-256 `content_hash` is computed from the canonical JSONB text representation and verified again at publication.
- The definition version's existing `capability_version` must be `1` for this contract.

### Common node fields

Every node has exactly:

```json
{
  "key": "legal_review",
  "type": "approval",
  "label": "Legal review",
  "config": {}
}
```

- `key` is required, unique within the version, and matches `^[a-z][a-z0-9_]{0,62}$`.
- `type` is required and is one of `start`, `approval`, or `end`.
- `label` is optional, plain text, trimmed, and 1–120 characters when present. It is display metadata, never an authorization input.
- `config` is required. Its exact allowed fields depend on the node type; unknown fields are rejected.

### Example version-1 definition

```json
{
  "schema_version": 1,
  "entry_node": "start",
  "nodes": [
    {
      "key": "approved_end",
      "type": "end",
      "config": { "outcome_code": "approved" }
    },
    {
      "key": "rejected_end",
      "type": "end",
      "config": { "outcome_code": "rejected" }
    },
    {
      "key": "review",
      "type": "approval",
      "config": {
        "delivery_mode": "parallel",
        "decision_rule": "majority",
        "minimum_approvals": null,
        "requirement": "required",
        "optional_policy": null,
        "allow_abstain": true,
        "reject_behavior": "when_approval_impossible",
        "allow_self_approval": false,
        "allow_multi_capacity": false,
        "minimum_candidates": 1,
        "candidate_selectors": [
          {
            "key": "home_supervisors",
            "order": 1,
            "type": "organization_role",
            "organization": "home",
            "role": "supervisor"
          }
        ],
        "comment_policy": {
          "approve": "optional",
          "reject": "required",
          "abstain": "optional"
        }
      }
    },
    {
      "key": "start",
      "type": "start",
      "config": {}
    }
  ],
  "edges": [
    {
      "source": "review",
      "target": "approved_end",
      "outcome": "approved",
      "priority": 0,
      "default": false
    },
    {
      "source": "review",
      "target": "rejected_end",
      "outcome": "rejected",
      "priority": 0,
      "default": false
    },
    {
      "source": "start",
      "target": "review",
      "outcome": "started",
      "priority": 0,
      "default": false
    }
  ]
}
```

## Node contract

### `start`

- Required configuration: empty object.
- Optional configuration: none.
- Cardinality: exactly one per definition and it must equal `entry_node`.
- Inbound edges: exactly zero.
- Outbound edges: exactly one with outcome `started`.
- Runtime: activation creates the initial token at this node, creates and completes one start step run, then moves the token through the `started` edge in the same transaction.
- Token creation: yes, exactly one initial token.
- Step run: yes; entered and completed atomically.
- Work items: none.
- Completion: immediate after the initial token exists.
- Failure: invalid graph/version, duplicate activation, or failure to enter the downstream node rolls back activation entirely.

### `approval`

- Required configuration: every field shown in the example, including explicit `null` where specified.
- Optional configuration: none in schema version 1.
- Inbound edges: one or more are structurally permitted, but because cycles and splits are prohibited, validation must prove exactly one reachable predecessor path.
- Outbound edges: exactly one `approved` edge and one `rejected` edge. An optional node additionally requires exactly one `skipped` edge.
- Runtime: entering creates a waiting step run, one open approval round, an immutable voter-position snapshot, and bounded approval work items.
- Token creation: no; it retains the existing token at the approval step.
- Step run: yes, state `waiting` while the round is open.
- Work items: parallel rounds create one offered item per position; sequential rounds create only the currently actionable position's offered item. Later sequential positions remain solely in the electorate snapshot until their turn.
- Completion: the round reaches `approved`, `rejected`, or `skipped`, the step records the same result, and the token follows the matching edge.
- Failure: invalid or unauthorized candidate resolution, an electorate below `minimum_candidates`, a threshold larger than the snapshot, or an unresolvable downstream entry fails the command atomically.

### `end`

- Required configuration: `outcome_code`, matching `^[a-z][a-z0-9_]{0,62}$`.
- Optional configuration: none.
- Inbound edges: at least one.
- Outbound edges: zero.
- Runtime: creates and completes an end step, consumes the arriving token, and evaluates instance completion.
- Token creation: no.
- Step run: yes; entered and completed atomically.
- Work items: none.
- Completion: when no active/waiting/failed tokens, open step runs, or open work items remain, the engine sets the instance to `completed` and copies the end node's safe `outcome_code` to `terminal_outcome`.
- Failure: conflicting terminal outcomes or remaining open runtime state fail closed. Version 1's single-token rule prevents conflicting end outcomes by construction.

### Evaluated but deferred node types

| Type | Decision | Reason |
|---|---|---|
| `routing` | Deferred to Phase 4 | Requires destination resolution, route ledger, and adapter authority not needed for approvals. |
| `fyi` | Deferred | Requires non-voting delivery/acknowledgement semantics and later notification/inbox decisions. |
| `gateway` / `condition` | Deferred to Phase 4 | Requires an allowlisted condition registry and deterministic default handling. Arbitrary expressions remain prohibited. |
| `parallel_split` | Deferred | Parallel voting occurs within an approval round; graph-token fan-out is not needed to unlock Phase 3. |
| `join` | Deferred | No version-1 node can split graph tokens, so a join would be unreachable or misleading. |
| `system_action` | Deferred | No adapter or allowlisted action registry exists. A placeholder that silently succeeds would be unsafe. |

Adding a deferred node type requires a higher schema/capability version and cannot change version-1 behavior.

## Edge contract

Each edge has exactly `source`, `target`, `outcome`, `priority`, and `default`.

- `source` and `target` are existing node keys.
- Self-edges are prohibited.
- Duplicate `(source, outcome, priority, target)` tuples are prohibited.
- `outcome` matches `^[a-z][a-z0-9_]{0,62}$` and must be producible by the source type.
- `priority` is an integer from 0 through 1000. Version 1 requires `0` because conditions are not supported.
- `default` is a boolean. Version 1 requires `false`; default edges become meaningful only with a future gateway contract.
- `condition` is deliberately absent in version 1. Supplying a condition field or expression is an unknown-field validation error.
- Canonical ordering is `(source, outcome, priority, target)` ascending.
- For every outcome a version-1 node can produce, publication requires exactly one matching edge. More than one is nondeterministic and zero is a dead end.
- End nodes have no outgoing edges.

## Definition-version lifecycle

### Authority and immutability

- JSONB remains authoritative and is never copied into mutable node/edge definition tables.
- Published and retired payloads, capability versions, hashes, creators, and version numbers are immutable.
- Running instances remain pinned to `definition_version_id`; activating a newer family version never changes an existing instance.
- Definition retirement affects only new instance creation. It does not invalidate or rewrite pinned instances.

### Canonicalization and hashing

Before a draft snapshot is inserted, the server:

1. rejects unknown or invalid fields;
2. normalizes optional absent display fields without adding semantic defaults;
3. sorts node, edge, selector, and explicit-user arrays canonically;
4. rejects duplicate keys and values rather than silently deduplicating them;
5. stores the canonical JSONB payload;
6. computes SHA-256 from canonical JSONB text.

Publication recomputes and compares the hash before graph validation. It never rewrites the payload.

### Draft editing and cloning clarification

The existing foundation calls all version payloads immutable and allows at most one draft. Therefore “editing” cannot mean mutating a draft row in place.

- A draft is an immutable saved snapshot.
- Editing creates a replacement draft version with a new monotonically increasing version number.
- The prior draft is retained and transitioned to a new `discarded` state in the same transaction before the replacement is inserted.
- Definition-version state validation must permit `draft → discarded` while retaining payload immutability. A discarded version keeps null publication fields, can never publish, and is distinct from a formerly published `retired` version.
- Cloning copies a selected version's canonical payload into a new draft snapshot under the same definition family, with a new creator, idempotency key, version number, and identical initial hash.
- Only the one current draft may publish. Discarded snapshots can never publish.

This resolves the current conflict between immutable snapshots and usable draft revision without deleting history.

## Publication validation

Publication is one transaction under a definition-family row lock and expected family `lock_version`. It hard-fails unless all checks pass:

1. The payload and capability version are supported and the stored hash matches canonical content.
2. All objects contain only known keys and valid scalar/array types.
3. Node and selector keys are unique and valid; configured limits are respected.
4. Exactly one start node exists, matches `entry_node`, has no inbound edge, and has one `started` edge.
5. At least one end node exists; every end has inbound reachability and no outbound edge.
6. Every edge endpoint exists and every edge outcome is valid for its source node.
7. Every node is reachable from start and every reachable nonterminal node can reach an end.
8. Every producible outcome has exactly one edge; no unsupported outcome edge exists.
9. The graph is acyclic. All loops, including correction/resubmission loops, are prohibited in schema version 1.
10. There are no split or join nodes, and no path can create more than one active token.
11. Every approval configuration passes the approval-policy and candidate-selector rules below.
12. Platform definitions contain no organization-specific explicit-user or section selector.
13. No string is interpreted as SQL, code, table name, function name, URL, or arbitrary expression.
14. Maximum payload and graph limits are enforced before recursive validation.

Validation returns stable, location-aware administration errors such as a node key and rule code. It must not disclose hidden users or organizational structures to an unauthorized publisher.

## Instance activation contract

The existing `start_workflow_instance` signature and grants should be preserved and its executable-version behavior extended in Phase 2B.

For a schema-version-1 instance, starting performs one transaction:

1. Authenticate an active actor and reuse `can_manage_workflow_instance()`.
2. Take the caller/instance/idempotency transaction advisory lock.
3. Lock the instance row and resolve exact replay from the command-root event.
4. Verify `pending` status and expected instance `lock_version`.
5. Load the instance's pinned published version by `definition_version_id`, verify its hash, and never substitute the family's current active version.
6. Create one token with a deterministic unique key such as `epoch_1_token_1`, state `active`, and ownership by this instance.
7. Enter and complete the start step run.
8. Move the token through the sole `started` edge and synchronously enter the target node.
9. If the target is approval, create its round, positions, participants, and work items. If it is end, complete it and the instance.
10. Set `started_at`, advance instance state and version exactly once, allocate all event sequences from the locked instance, and append events.
11. Commit only if every graph and candidate operation succeeds.

Any error leaves the instance pending with no token, step, round, work item, participant addition, or activation event. An identical retry returns the original result and event identities. Reusing the key with different input fails.

The existing `instance_started` event remains the canonical activation event; no synonymous `instance_activated` event is added.

## Token semantics

- A token belongs to exactly one instance and references its current step run.
- Version 1 creates one token during activation and never creates a second token.
- Movement updates the same active token's `step_id` after the prior step completes and emits `token_moved`.
- Entering an end node consumes the token and sets `consumed_at`.
- Cancellation sets active/waiting/failed tokens to `cancelled`, preserving history.
- Suspension does not introduce a token state. Tokens retain their current state, while all mutating commands require instance state `active` and therefore freeze advancement.
- Resume does not recreate or move tokens; it merely permits the existing cursor to continue.
- Duplicate-token prevention uses the existing `(instance_id, token_key)` uniqueness and the instance row as the allocation boundary.
- Parallel graph fan-out and join behavior are prohibited in schema version 1. A future split/join contract must add parent/lineage and join-arrival invariants under a new capability version.

## Step-run semantics

- Entering every node creates one `workflow_instance_steps` row before node behavior occurs.
- Identity is `(instance_id, definition_node_key, run_number)`. Version 1 is acyclic, so `run_number = 1`.
- `start` and `end` steps move through `active → completed` in one transaction.
- An approval step enters `waiting` while its round is open, then `completed` with result `approved`, `rejected`, or `skipped`.
- `activated_at` is set once when entered. `ended_at` is set once on a terminal step state.
- `result_code` is a safe allowlisted outcome, not free text.
- Cancellation changes open steps to `cancelled`; suspension leaves them unchanged.
- A step cannot have more than one open approval round or more than one terminal result.

## Approval-node contract

### Orthogonal policy dimensions

The architecture's approval terms are made deterministic through three orthogonal fields:

- `delivery_mode`: `sequential` or `parallel` controls when voter work items become actionable.
- `decision_rule`: `unanimous` or `majority` controls the approval threshold.
- `requirement`: `required` or `optional` controls empty-electorate behavior.

This supports sequential, parallel, unanimous, majority, and optional approvals without treating incompatible concepts as one enum.

### Approval configuration validation

- `minimum_candidates` is an integer from 1 through 100.
- `minimum_approvals` is `null` or an integer from 1 through 100. It is permitted only for `majority` and may raise, never lower, the strict-majority threshold.
- `optional_policy` must be `null` for required nodes and exactly `skip_if_no_candidates` for optional nodes.
- `allow_abstain`, `allow_self_approval`, and `allow_multi_capacity` are explicit booleans; there are no implicit true values.
- `reject_behavior` is `immediate` or `when_approval_impossible`.
- `comment_policy` has exactly `approve`, `reject`, and `abstain`, each `required`, `optional`, or `forbidden`. `abstain` must be forbidden when `allow_abstain` is false.
- One through 16 candidate selectors are required and canonically ordered by `(order, key)`; `order` values are unique integers from 1 through 16.

### Electorate snapshot

- Candidates resolve when the approval step is entered, inside the same instance-locked transaction.
- Only active users satisfying the selector and allowed-organization boundary may enter the snapshot. Before adapters exist, this generic engine cannot assert module-subject visibility; the approved bootstrap boundary is the organization-scoped definition plus explicit workflow participation. A future adapter must add subject visibility as an additional check, never replace these checks.
- The snapshot contains one immutable voter position per capacity: round ID, stable position key, ordinal, user ID, authority source, organization ID, optional section ID, selector key, and activation timestamp.
- With `allow_multi_capacity = false`, the resolver rejects a duplicate user across selectors instead of silently choosing one authority source.
- With `allow_multi_capacity = true`, the same user may hold multiple positions only through distinct selector/authority pairs; each position gets its own work item and decision.
- The denominator is the final voter-position count and never shrinks.
- Required nodes fail entry if the count is below `minimum_candidates`.
- Optional nodes skip only when the count is exactly zero. A nonzero count below `minimum_candidates` is a configuration/availability error, not a skip.
- No later user deactivation, assignment change, organization change, or participant removal rewrites the snapshot or threshold.

### Round state and persistence

Phase 2B requires normalized `workflow_approval_rounds` and `workflow_approval_positions` runtime objects. Their exact physical DDL is deferred to that implementation, but their contract is fixed:

- A round is uniquely bound to one approval step run and has `open`, `completed`, `cancelled`, or `failed` state.
- Immutable round policy includes delivery mode, decision rule, requirement, optional policy, electorate count, approval threshold, rejection behavior, abstention policy, and execution epoch.
- Mutable round fields are state, outcome, lock version, completion timestamp, and causal event.
- A voter position is immutable except for its progress state and linked work item/decision identifiers.
- Position states are `pending`, `offered`, `decided`, `cancelled`, and `unavailable`. A pending sequential position has no work item yet.
- One accepted decision per position and one decision per work item are enforced by database uniqueness, not application counting.
- Database-enforced composite references must prove that every round, position, work item, decision, step, and token in one chain carries the same `instance_id`; private-function checks alone are insufficient for this invariant.

The approval-round persisted field contract is:

| Field | Type | Contract |
|---|---|---|
| `id` | UUID | Primary identity. |
| `instance_id` | UUID | Required instance; part of every composite consistency reference. |
| `step_id` | UUID | Required approval step; unique because one round belongs to one version-1 step run. |
| `token_id` | UUID | Required retained token at the approval step. |
| `execution_epoch` | integer | Required positive snapshot from the instance. |
| `delivery_mode` | text | Immutable `sequential` or `parallel`. |
| `decision_rule` | text | Immutable `unanimous` or `majority`. |
| `requirement` | text | Immutable `required` or `optional`. |
| `optional_policy` | text/null | Immutable null or `skip_if_no_candidates`. |
| `minimum_candidates` | integer | Immutable configured minimum, 1–100. |
| `electorate_count` | integer | Immutable resolved denominator, 0–100. |
| `approval_threshold` | integer | Immutable computed threshold; zero only for a zero-electorate skipped round. |
| `reject_behavior` | text | Immutable `immediate` or `when_approval_impossible`. |
| `allow_abstain` | boolean | Immutable decision allowlist input. |
| `comment_policy` | JSONB | Immutable three-key validated policy; never free-form configuration. |
| `state` | text | `open`, `completed`, `cancelled`, or `failed`. |
| `outcome_code` | text/null | Null while open; otherwise `approved`, `rejected`, `skipped`, `cancelled`, or `failed` aligned to state. |
| `lock_version` | bigint | Nonnegative optimistic version, incremented once per accepted round mutation. |
| `opened_by` | UUID | Actor whose command entered the node. |
| `causation_event_id` | UUID | Command-root event that opened the round. |
| `opened_at` | timestamptz | Immutable activation time. |
| `completed_at` | timestamptz/null | Set once for any terminal round state. |
| `created_at`, `updated_at` | timestamptz | Standard persistence timestamps. |

The voter-position persisted field contract is:

| Field | Type | Contract |
|---|---|---|
| `id` | UUID | Primary identity. |
| `instance_id` | UUID | Required and equal to the round/step/work-item instance. |
| `round_id` | UUID | Required approval round. |
| `step_id` | UUID | Required approval step for composite enforcement. |
| `position_key` | text | Stable safe key unique within the round. |
| `ordinal` | integer | Required 1–100 order, unique within the round. |
| `user_id` | UUID | Immutable resolved voter. |
| `authority_source` | text | Immutable safe selector/assignment source code. |
| `organization_id` | UUID | Immutable allowed organization snapshot. |
| `section_id` | UUID/null | Immutable section scope when applicable. |
| `selector_key` | text | Immutable source selector key. |
| `state` | text | `pending`, `offered`, `decided`, `cancelled`, or `unavailable`. |
| `work_item_id` | UUID/null | Unique; set exactly once when the position becomes actionable. |
| `decision_id` | UUID/null | Unique; set exactly once with an accepted decision. |
| `offered_at`, `decided_at`, `unavailable_at`, `cancelled_at` | timestamptz/null | State-aligned timestamps set once. |
| `created_at` | timestamptz | Immutable snapshot time. |

Round policy and position identity/scope fields are immutable after insertion. Only the explicitly mutable state, linkage, version, and aligned timestamp fields may change through private engine functions.

`workflow_decisions` remains the immutable evidence table and must gain round/position linkage or equivalent enforced composite references in Phase 3. Existing decision rows and their immutable trigger remain intact.

### Outcome calculation

Let `N` be the immutable position count, `A` approvals, `R` explicit rejections, `B` abstentions, and `U = N - A - R - B` undecided positions.

- Unanimous threshold: `T = N`.
- Majority threshold: `T = max(floor(N / 2) + 1, minimum_approvals)` when an override is configured; otherwise `floor(N / 2) + 1`.
- Approved: `A >= T`.
- Rejected immediately: `reject_behavior = immediate` and `R >= 1`.
- Approval impossible: `A + U < T`. This rejects the round for `when_approval_impossible`, and also resolves any remaining non-immediate case.
- Abstention never counts as approval and never reduces `N`.
- A tie can never approve because majority is strictly more than half. When all positions decide and `A < T`, the round is rejected.
- Once an outcome is reached, remaining offered work items and unoffered positions are cancelled atomically and no late decision is accepted.

### Sequential delivery

- All positions are snapshotted when the round opens.
- Only the first ordered position receives an `offered` work item. Later positions have no work item and are excluded from queues.
- After a nonterminal accepted decision, the engine atomically creates the next pending position's offered work item and candidate participant.
- When the threshold is met or can no longer be met, all remaining unoffered positions and offered work items are cancelled.

### Parallel delivery

- All work items become `offered` in the round-opening transaction.
- Decisions may arrive in any order.
- Every vote transaction locks and recalculates the same round, so the final simultaneous votes cannot produce two outcomes.

### Optional approval

Version 1 supports exactly one explicit optional rule: `skip_if_no_candidates`.

- Zero resolved positions creates a skipped round/step history, creates no work item, emits the skip events, and follows `skipped`.
- One or more positions make the node behave exactly like a required node under its delivery and decision rule.
- Manual skip, deadline skip, conditional skip, and manager override are not implied and require later contracts.

### Candidate unavailability after snapshot

- An inactive or no-longer-authorized candidate cannot submit a decision.
- The position remains in the denominator and is not reassigned or removed.
- With delegation, substitution, escalation, and timers deferred, the round remains blocked until the instance is cancelled or a later approved recovery mechanism operates.
- Other eligible voters may still decide when their work items are open.
- The engine exposes a safe blocked/unavailable count only to authorized workflow managers; it does not reveal hidden identity details.

### Decision immutability and replay

- Decision codes are exactly `approve`, `reject`, and, when enabled, `abstain`.
- The actor must match the immutable voter position and actionable work item. Managers and super administrators cannot cast another person's vote unless they themselves hold that position.
- An accepted decision inserts one immutable row, completes the work item, updates position/round state, advances the graph when resolved, and emits events in one transaction.
- Exact replay with the same command ID and identical input returns the recorded result without another decision or event.
- Reuse with different input fails with stable invalid-input semantics.
- A second command for an already decided position, or a late command after round closure, fails without inserting telemetry into the immutable decision ledger.
- A correction or resubmission creates a new step run and round under a future loop contract; it never edits old decisions. Version 1 prohibits such loops.

### Worked examples

#### Sequential unanimous, three positions

`N = 3`, `T = 3`. Position 1 approves, then position 2 is offered. Position 2 approves, then position 3 is offered. The round approves only after position 3 approves. If any position rejects, approval becomes impossible and remaining work items are cancelled.

#### Parallel unanimous, three positions

All three work items are offered. Two approvals leave the round open. The third approval completes it as approved. One rejection completes it as rejected because `A + U` can no longer reach 3.

#### Parallel majority, four positions

`T = floor(4 / 2) + 1 = 3`. Three approvals complete the round. Two approvals and two abstentions reject it; the 2–2 tie is not approval. With `reject_behavior = immediate`, the first explicit rejection rejects even though three approvals could otherwise remain possible.

#### Parallel majority, five positions with concurrent final votes

`T = 3`. If two approvals exist and two voters submit simultaneously, the instance/round locks serialize them. The first accepted vote updates the counts; the second sees the new state. Exactly one transaction closes the round, and the other either contributes before closure or receives the stable closed-round response.

#### Optional approval with no candidates

Resolution produces zero positions. The round and step are recorded as skipped, no work item is created, and the token follows `skipped`. If two candidates resolve, the node is not silently skipped; it follows its normal decision rule.

## Candidate-resolution contract

### Supported version-1 selectors

All selectors have required `key`, `order`, and `type` fields. Unknown fields are rejected per selector type.

1. `explicit_user`
   - Adds sorted, unique `user_ids`.
   - Permitted only on an organization-scoped definition.
   - Every user must be active and belong to the instance home organization at activation.
2. `organization_role`
   - Fields: `organization: "home"` and `role` from the existing `user_assignments.role` allowlist.
   - Resolves active users with an active assignment whose resolved scope organization is the home organization.
3. `section_role`
   - Fields: `section_id` and allowlisted `role`.
   - Permitted only on an organization-scoped definition; the section must be active and belong to that definition organization at publication and the instance home organization at activation.
   - Uses existing scope expansion so command/department/division/organization assignments covering the section qualify.
4. `instance_participant_role`
   - Field: `participant_role`, initially restricted to `owner` or `manager`.
   - Resolves active, non-ended instance participants already visible to the workflow.

`supervisor_chain` is deferred because CorLink has scoped supervisor assignments but no approved single-person reporting-chain object. `adapter_supplied_participant_role` is deferred until adapters exist. Neither may be emulated through client-supplied user IDs.

### Resolution invariants

- Resolution executes in a private server boundary; clients never submit resolved candidates.
- Users are ordered by selector order, selector key, authority source, then user UUID.
- Candidate authority sources are stable safe codes, not display names.
- Self-approval defaults to prohibited using `workflow_instances.created_by` as the generic initiator available before adapters. A future adapter may provide a stricter submitter identity but may not weaken an existing definition silently.
- Version 1 candidates must belong to the home organization. The instance organization must equal the candidate user organization, and work-item organization must be present in `participant_organization_ids`.
- Super-administrator visibility does not make a super administrator a voter.
- Publication validates selector structure; activation resolves current users and assignments.
- Empty and undersized results follow the approval-node rules, never a client fallback.

## Work-item contract

- Approval work items are created when a position becomes actionable: all positions at parallel-round opening, or one position at a time for sequential rounds.
- Each item binds one round position, step, token, instance, organization, and assigned user.
- A unique position-to-work-item binding prevents retry from creating a second item for the same position.
- Version 1 approval items are assigned, not claimable. `claimed_by` and `claimed_at` remain unused; claim behavior is deferred.
- Every created approval item starts `offered`; unoffered sequential responsibility exists only as a voter position.
- An offered item is actionable only by its assigned position holder while the instance is active and the round is open.
- An accepted decision changes exactly one item to `completed`, sets actor/time, and increments its lock version.
- Round closure cancels every remaining offered item and marks unoffered positions cancelled. Cancellation records reason codes in events rather than adding a `superseded` work-item state.
- Instance suspension leaves item states unchanged but decision RPCs reject while suspended. Resume reuses the same items.
- Instance cancellation uses the existing cancellation behavior to cancel open items and additionally closes open rounds/positions.
- Direct table writes remain prohibited; authenticated retains SELECT-only grants and RLS.
- Queue ordering remains `(created_at DESC, id DESC)` with a hard 100-row page and complete keyset cursor. Pending items are excluded.

## Generic graph-advancement contract

Graph advancement is a private bounded routine, never a client-selected target-node RPC.

For a completed node outcome:

1. Hold the instance row lock and verify the instance is active.
2. Lock the current step, token, and approval round/work items as applicable in global order.
3. Verify the step is current and has exactly one terminal result.
4. Select exactly one immutable outgoing edge matching that result.
5. Mark the source step completed if not already completed.
6. Move the token to the target and emit the movement event.
7. Create the target step run with the next valid run number.
8. Execute only the target node's allowlisted entry behavior.
9. Continue synchronously through immediate `start`/`end` behavior, stopping when approval waits or the instance completes.
10. Allocate events from `next_event_sequence`, increment the instance lock version once for the external command, and return a stable result.

The routine never accepts a table name, function name, SQL fragment, arbitrary condition, module record, or client-selected edge. Version 1 is acyclic and single-token, so advancement is bounded. A defensive maximum of 32 immediate node entries per command fails atomically even though publication also limits total graph depth.

### Instance completion

Reaching an end node consumes the sole token. Internal completion occurs only when:

- no token is active, waiting, or failed;
- no step is pending, ready, active, waiting, or failed;
- no work item is offered, claimed, or failed;
- no approval round is open or failed.

For executable definitions, graph completion—not a manager-supplied outcome—is authoritative. Phase 2B/2C must reject direct external `complete_workflow_instance` for schema-version-1 instances while retaining Phase 2 behavior for legacy inert instances. Internal completion must reuse the existing transition/audit-safe state mutation rather than duplicate lifecycle logic.

## State and lifecycle interaction

| Instance state | Graph behavior |
|---|---|
| `pending` | No token or step exists. Start may activate once. |
| `active` | The current work item may accept a decision and graph advancement may run. |
| `suspended` | Tokens, steps, rounds, and work items are frozen in place. No decision or advancement is accepted. |
| `cancelled` | Existing lifecycle cancellation cancels open steps/tokens/work items; future extension also closes open rounds/positions. No resume or advancement. |
| `completed` | No active runtime work remains. The terminal outcome is immutable. |

Resume changes only instance state and does not recreate work. Completing a node never sends notifications or mutates a module. Cancellation never deletes graph history.

## Concurrency and idempotency

### Global lock order

Every future graph or approval command uses this order:

1. caller/instance/idempotency transaction advisory lock;
2. workflow instance row;
3. affected step rows ordered by UUID;
4. affected token rows ordered by UUID;
5. approval round rows ordered by UUID;
6. voter-position rows ordered by UUID;
7. work-item rows ordered by UUID;
8. decision inserts;
9. instance update and event appends.

This extends the existing Phase 2 instance-first cancellation order and prohibits helper functions from acquiring an earlier lock after a later lock.

### Command contract

- Every external command carries a UUID idempotency/command key and expected instance lock version.
- Work-item decisions additionally carry expected work-item lock version.
- The locked round version is validated internally.
- Stale expected versions return the existing retryable `40001` pattern.
- The command-root event alone stores the caller's key and replay result. Derived events get unique engine keys and reference the root event through `causation_id`.
- Identical replay returns the original decision, round outcome, instance version, and event identifiers.
- Input mismatch under an existing key returns stable `22023` semantics.

### Required race outcomes

- Two votes on different parallel work items serialize at the instance/round and both may commit only if the round remains open for each.
- The final two parallel votes cannot close the round twice; one transaction records the terminal outcome and the other observes closure or a stale version.
- A vote versus cancellation has one winner under the instance lock. If cancellation wins, no decision is inserted; if voting wins, cancellation sees the incremented instance version.
- Suspension versus graph advancement similarly has one valid winner and no partial decision.
- Duplicate activation converges on one token/start step/event for identical input; differing keys against one pending version produce one winner.
- Duplicate node completion is prevented by step state, round state, expected versions, and unique event/decision constraints.
- Unrelated instances take different advisory and row locks and do not block one another unnecessarily.

## Event contract

Existing event names remain authoritative. Version 1 adds only the following minimum graph events:

- `token_created`, `token_moved`, `token_consumed`
- `step_entered`, `step_completed`, `step_skipped`, `step_cancelled`
- `work_item_created`, `work_item_completed`, `work_item_cancelled`
- `approval_round_opened`, `approval_round_completed`
- `decision_recorded`

Existing `instance_created`, `instance_started`, `instance_suspended`, `instance_resumed`, `instance_cancelled`, and `instance_completed` continue unchanged. `instance_started` is the activation event.

Payloads may contain only internal UUIDs, definition/node keys, safe state/outcome/reason codes, counts, thresholds, sequence numbers, execution epoch, and lock versions. They must not contain subject titles, references, correspondence, prisoner information, comments, user names, emails, role display names, or hidden organization/section names. Decision comments remain in the RLS-protected decision row and are not copied into event metadata.

Each payload is limited to 16 KiB. Notifications are a later projection and no event delivery is implied.

## Authorization, security, and RLS

### Definitions

- Definition and version visibility continues through `can_manage_workflow_definition()`.
- Organization administrators may create/publish only their organization definitions. Super administrators retain explicit platform-definition authority.
- Platform definitions cannot embed tenant-specific users or sections.

### Instances and work

- Instance/history visibility continues through active `workflow_participants` or explicit super-administrator visibility.
- Entering an approval node adds candidate participants only after selector, active-user, definition-scope, and organization checks pass. Future adapters add module-subject visibility before this insertion.
- Work-item and decision reads remain participant-scoped. Version 1 does not introduce secret ballots; all viewers already authorized for the instance may see its decision history, subject to safe projections.
- Same-organization membership alone grants no workflow visibility.

### Decisions

- A decision requires an active authenticated user, active instance, open round, actionable assigned work item, matching voter position, current visibility, same allowed organization, and expected versions.
- Instance owners/managers may manage lifecycle but cannot vote for another position.
- Super administrators may inspect/manage under existing explicit rules but cannot cast another actor's decision.
- Errors for hidden/missing/unauthorized objects use one non-disclosing contract and never reveal candidate counts or identities.

### Database boundaries

- Runtime tables remain SELECT-only under RLS; mutation occurs only through narrow RPCs.
- Public RPCs are authenticated-only, explicitly validate `auth.uid()`, pin `search_path`, and reuse existing helpers.
- Internal graph, resolver, quorum, and event helpers have no execution grant to `PUBLIC`, `anon`, or `authenticated`.
- No helper accepts arbitrary identifiers or uses dynamic module SQL.
- Candidate resolution reads existing directory tables under a privileged boundary but returns only authorized workflow positions, never a general user directory.

## Scalability limits and access paths

Initial hard limits are deliberately finite:

| Resource | Version-1 limit |
|---|---:|
| Nodes per definition | 200 |
| Edges per definition | 400 |
| Immediate node entries per command | 32 |
| Graph-token fan-out | 1 |
| Active tokens per instance | 1 |
| Candidate selectors per approval node | 16 |
| Voter positions per approval round | 100 |
| Work items per approval node | 100 |
| Event metadata payload | 16 KiB |
| Definition payload | Existing 1 MiB limit |
| Queue page | Existing hard limit of 100 |

Expected later indexes:

- unique approval round per step run and `(instance_id, state, created_at, id)` for current rounds;
- unique `(round_id, position_key)` and ordered `(round_id, ordinal)` positions;
- partial `(user_id, state, round_id)` for actionable/unavailable positions if measured queries require it;
- unique accepted decision per position and work item;
- existing assigned work-item queue, instance/state work-item, participant, step/token, and event sequence indexes;
- keyset pagination for queues and histories, never deep `OFFSET`.

Definition JSON is loaded by pinned version ID and validated at publication; no broad JSONB operational index is required. Any new index requires `EXPLAIN (ANALYZE, BUFFERS)` evidence at representative fan-out.

## Migration from inert definitions

### Compatibility classes

- **Legacy inert:** existing payloads with empty `nodes`/`edges` and no `schema_version`. They remain valid and behave exactly as Phase 1/2.
- **Executable v1:** canonical payloads with `schema_version = 1` satisfying this contract.
- No existing row is rewritten merely to look executable.

### Deployment order

1. Add new approval-round/position persistence, constraints, indexes, SELECT-only RLS, and private helpers without changing legacy behavior.
2. Add the `discarded` version state and its publication-field alignment, then add canonicalization and executable validation while retaining the legacy inert publication rule as a separate compatibility branch.
3. Extend definition draft replacement/cloning and publication under existing authorization and locks.
4. Extend `start_workflow_instance` so only executable-v1 instances activate graph state; legacy inert starts retain Phase 2 behavior.
5. Add bounded graph advancement and internal executable completion.
6. Add approval decision RPCs only after activation and advancement validators pass.

Every step is additive/idempotent, preserves signatures where promised, pins search paths, and retains SELECT-only RLS. Existing published inert definitions, pending/active legacy instances, events, participants, and runtime RPC results remain valid.

### Rollback

- Phase 2B rollback restores the exact inert publication and Phase 2 lifecycle definitions.
- Rollback must refuse if any executable-v1 definition, approval round, position, or graph-activated instance exists; it must never discard runtime history.
- A preflight validator identifies blocking rows without exposing subject data.
- Empty/new objects may then be removed transactionally without `CASCADE`, preserving Phase 1/2 tables and data.
- Reapplication must accept the same canonical payload/hash and restore validators, grants, RLS, and function definitions exactly.

## Revised implementation phases

### CAP-002 Phase 2B — Executable Definition Validation and Activation

- Implement canonical schema-version-1 validation and safe publication.
- Add approval-round and voter-position persistence needed by activation, but no decision mutation.
- Resolve candidates and create initial token, steps, round, participants, and work items.
- Preserve inert definitions and legacy runtime behavior.
- Validate migration, rollback refusal, RLS, activation idempotency, and candidate confidentiality.

### CAP-002 Phase 2C — Generic Token and Graph Advancement

- Implement the private outcome-to-edge algorithm for version-1 start/approval/end nodes.
- Implement executable end/completion semantics and event ordering.
- Keep external approval decisions unavailable.
- Test bounded cascades, duplicate completion, lifecycle races, and rollback/reapplication.

### CAP-002 Phase 3 — Approval Engine

- Implement approve, reject, and enabled abstain decisions.
- Implement sequential offering, parallel voting, unanimous/majority calculation, optional empty-electorate skip, immutable decisions, replay, and decision history.
- Reuse 2B candidate snapshots and 2C graph advancement.
- Add no routing, conditions, delegation, notifications, timers, adapters, or frontend.

### CAP-002 Phase 4 — Routing and Conditional Branching

- Define and implement routing nodes, allowlisted conditions/gateways, default-edge behavior, and any required token split/join capability under a higher contract version.

### Later milestones

Delegation, substitution, escalation, timers, notifications/outbox, module adapters, shared inbox/frontend, graph visualization, and workflow designer remain separately approved work.

## Required implementation verification

Each implementation phase must provide structural validation, authenticated behavioral/RLS tests, independent-session concurrency tests, bounded performance probes, transactional rollback, exact definition/grant equality checks, clean reapplication, and full repository regression. Tests must include all race scenarios and worked approval examples defined here.

## Open questions

There are no blocking semantic questions for Phase 2B, Phase 2C, or the narrowed Phase 3 described above.

The following are explicitly deferred rather than ambiguous:

- reporting-line-based `supervisor_chain` resolution;
- adapter-supplied candidates and cross-organization approval positions;
- manual/deadline/conditional optional-step skipping;
- unavailable-voter substitution, delegation, or escalation;
- correction/resubmission loops and new approval rounds after return;
- graph token split/join semantics;
- claimable approval work items and secret-ballot visibility;
- production-limit tuning based on staging-scale evidence.

Each deferred item requires a new approved contract or capability version and cannot be inferred by Phase 2B, 2C, or 3 implementations.
