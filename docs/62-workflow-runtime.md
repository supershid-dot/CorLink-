# CAP-002 Phase 2 — Workflow Runtime and State Machine

## Scope

This milestone adds the generic instance lifecycle defined by `docs/60-workflow-engine-architecture.md` on top of the inert persistence and security boundary in `docs/61-workflow-backend-foundation.md`.

The runtime changes only generic workflow-instance state and its own step/token/work-item rows during cancellation. It does not execute definition graphs, approvals, routing, branches, delegation, substitution, timers, SLA behavior, notifications, compliance audit, module adapters, module projections, or frontend behavior.

## Runtime architecture

Five authenticated RPCs call one ungranted internal transition function. The internal boundary:

1. authenticates an active CorLink user;
2. reuses `can_manage_workflow_instance()`;
3. validates command input and safe codes;
4. takes a caller/instance/idempotency advisory lock;
5. locks the workflow instance row;
6. resolves an exact idempotent replay or validates the expected lock version;
7. validates the legal source state and completion preconditions;
8. mutates the instance and, for cancellation, closes open generic runtime rows;
9. appends one immutable, sequential event;
10. returns a stable non-sensitive result.

No generic runtime query dereferences `subject_type` or `subject_id`. No command reads or writes a module table.

## State machine

The foundation retains all architecture-defined instance states: `pending`, `active`, `suspended`, `completed`, `rejected`, `cancelled`, `withdrawn`, and `failed`. Phase 2 exposes only transitions justified without approvals, adapters, or fault-processing workers.

| Command | Legal source | Target | Terminal |
|---|---|---|---|
| Start | `pending` | `active` | No |
| Suspend | `active` | `suspended` | No |
| Resume | `suspended` | `active` | No |
| Cancel | `pending`, `active`, `suspended` | `cancelled` | Yes |
| Complete | `active` | `completed` | Yes |

All other combinations fail with SQLSTATE `55000`. Optimistic-version conflicts fail with `40001`; malformed inputs or idempotency mismatches use `22023`; unavailable or unauthorized instances fail without distinguishing existence using `42501`.

`rejected` and `withdrawn` remain architecture states but have no public command because they require approval or initiator/adapter policy. `failed` remains reserved for a future technical/configuration-fault path. Reopen is excluded because no approved definition-level reopen policy, restart node, or adapter permission exists. A terminal instance therefore remains immutable in this phase.

## Completion and cancellation

Completion requires an active instance with no open generic runtime state:

- no step run in `pending`, `ready`, `active`, `waiting`, or `failed`;
- no token in `active`, `waiting`, or `failed`;
- no work item in `offered`, `claimed`, or `failed`.

The caller supplies an allowlisted outcome code. Completion never closes or updates the opaque subject.

Cancellation requires an allowlisted reason code. It atomically marks open generic steps, tokens, and work items cancelled before terminating the instance. It never deletes their history and does not touch module data.

## RPCs

- `start_workflow_instance(instance_id, expected_lock_version, idempotency_key)`
- `suspend_workflow_instance(instance_id, expected_lock_version, idempotency_key, reason_code)`
- `resume_workflow_instance(instance_id, expected_lock_version, idempotency_key, reason_code)`
- `cancel_workflow_instance(instance_id, expected_lock_version, idempotency_key, reason_code)`
- `complete_workflow_instance(instance_id, expected_lock_version, idempotency_key, outcome_code)`

Each returns instance ID, resulting state, terminal outcome, resulting lock version, event ID, event sequence, and an idempotent-replay flag. The shared `workflow_transition_instance` function is deliberately not executable by `authenticated`, `anon`, or `PUBLIC`, preventing clients from selecting arbitrary target states.

## Authorization and RLS

Runtime authority adds no new permission model. The caller must be active and satisfy the existing `can_manage_workflow_instance()` helper: an active owner/manager participant or explicitly recognized super administrator.

All six functions are `SECURITY DEFINER` with `search_path = public, pg_temp`. Public and anonymous execution is revoked, and only the five narrow RPCs are granted to `authenticated`.

The Phase 1 SELECT-only RLS policies and table grants are unchanged. Participants retain read access; viewers cannot mutate; same-organization membership alone grants neither visibility nor transition authority; missing and inactive identities fail closed.

## Locking and concurrency

Lock order is deterministic:

1. caller + instance + idempotency advisory lock;
2. instance row lock (`FOR UPDATE`);
3. bounded open step/token/work-item updates for cancellation;
4. instance update;
5. event append.

The instance row is the aggregate serialization boundary. Every non-replay command must match `lock_version`; a successful transition increments it once. The locked row also owns `next_event_sequence`, so event allocation cannot race. The event ledger’s `(instance_id, idempotency_key)` uniqueness provides durable replay identity.

Identical concurrent commands converge on the same event and result. Distinct concurrent commands against one version produce one winner and one `40001` conflict. Unrelated instances use distinct row and advisory locks and do not block one another unnecessarily.

## Events

Successful commands append exactly one of:

- `instance_started`
- `instance_suspended`
- `instance_resumed`
- `instance_cancelled`
- `instance_completed`

Metadata contains only safe command/state/version/reason/outcome codes. It contains no subject title, reference, content, user role, section, recipient, or module data. Failed authorization, validation, transition, and version checks append no success event. Existing event immutability remains unchanged.

## Performance

Transition work is bounded to one aggregate row, an indexed idempotency probe, one instance update, and one event append. Completion uses instance-local indexed checks; cancellation updates only open rows for the selected instance.

The disposable performance suite exercised a single aggregate containing 100,000 events:

- first transition: approximately 9 ms;
- exact idempotent replay: approximately 0.6 ms;
- newest 100-event authorized page: approximately 19 ms.

The history query used the instance/sequence index. No new index was required because Phase 1 already supplied the aggregate event, idempotency, current-step/token, and work-item access paths. Event partitioning remains evidence-driven and deferred.

## Testing

- Structural validator: six pinned definer functions, five narrow grants, transition/locking/event contract, unchanged RLS and foundation schema, no forbidden integrations.
- Behavioral suite: 22 authenticated scenarios.
- Transition suite: all 40 combinations of five public commands and eight architecture states.
- RLS suite: 12 owner, manager, viewer, outsider, cross-organization, inactive, super-administrator, direct-write, and anonymous scenarios.
- Concurrency suite: five independent-session retry, double-transition, conflicting-command, lost-update, and unrelated-instance scenarios.
- Performance suite: transition, replay, and history page over a 100,000-event aggregate.
- Repository regression: all existing Phase 1, security-definer, module, attachment, audit, Task relationship/dependency, and Meeting validators.

## Rollback

`rollback-workflow-runtime.sql` transactionally drops only the five public RPCs and internal transition function. It preserves every Phase 1 table, row, RLS policy, grant, index, definition, instance, participant, and event. Runtime events already committed before rollback remain immutable history.

`validate-workflow-runtime-rollback.sql` confirms all Phase 2 functions are absent while the Phase 1 foundation, RLS, and approved module baseline remain intact. Clean reapplication restores the runtime commands.

## Limitations and future phases

- Definition publication remains inert; no nodes or edges execute.
- Starting makes the instance active but creates no step, token, or work item.
- Completion is a generic terminal command and never projects an outcome to a module.
- Rejection, withdrawal, failure recovery, and reopen have no public commands.
- No approval, routing, conditional, delegation, substitution, escalation, SLA, timer, notification, outbox, adapter, audit-projection, or frontend behavior exists.
- No module is integrated and no existing module API has changed.

Future work requires separate approval. Definition validation and graph execution should precede approval/routing commands; adapters must follow only after the generic engine is complete and independently verified.
