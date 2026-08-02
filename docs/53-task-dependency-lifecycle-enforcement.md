# Task Dependency Lifecycle Enforcement

## Scope

T3F.2 adds server-authoritative dependency checks to the existing Task start and completion paths. It does not add a Task status, stored blocked flag, automatic propagation, dependency-management UI, waiver mutation, dependency notifications, dashboard widgets, reports, or changes to business-module workflows.

The authoritative architecture remains `docs/51-task-dependency-architecture.md` and `docs/52-task-dependency-backend-foundation.md`.

## Enforcement points

Repository inspection confirmed there is no `start_task()` RPC. The only path into `in_progress` is `update_task(..., p_status := 'in_progress')`; the only path into `completed` is `complete_task()`. `valid_task_status_transition()` remains unchanged as defense in depth. `cancel_task()` remains unchanged and blocked Tasks may still be cancelled under its existing authorization.

T3F.2 replaces only these affected definitions:

- `update_task(...)`: applies a dependency precondition only when the requested status is `in_progress`;
- `complete_task(uuid, text)`: applies the dependency precondition before completion;
- `create_task_dependency(uuid, uuid)`: refreshes and revalidates endpoint Task rows after graph serialization, closing a creation/start race found by the executable concurrency suite;
- `get_task_dependency_lifecycle_state(uuid)`: a new read-only Task Detail wrapper.

Signatures, return types, ownership, volatility, SECURITY DEFINER posture, pinned search paths, existing grants, authorization, audit, notifications, and transition vocabulary are preserved.

## Dependency-state helper reuse and blocked semantics

Both lifecycle mutation paths call the existing private `get_task_dependency_state(uuid)` helper from T3F.1. No recursive graph or blocked-count logic is copied into the lifecycle RPCs.

An active prerequisite is unresolved until its Task is completed. Cancelled remains unresolved. Multiple prerequisites use AND semantics. Removed edges do not participate. No authenticated waiver mutation is introduced, so ordinary T3F.2 application behavior resolves prerequisites only through Task completion. The helper retains the architecture-approved reserved interpretation of an explicitly persisted waiver from `docs/51` sections **Resolution and blocked state** and **Supervisor override**, but this milestone creates no path to write such a waiver.

Blocked state remains a projection. No `blocked` status or Task column exists, and resolving/removing an edge does not start, complete, assign, or otherwise mutate a dependent.

## Validation order and authorization

Lifecycle validation is deliberately ordered:

1. derive the actor from `auth.uid()`;
2. load the Task and enforce the existing neutral not-found/authorization behavior;
3. validate the requested transition;
4. take the organization dependency-graph lock;
5. lock and refresh the Task row, then repeat authorization and transition validation after any wait;
6. call `get_task_dependency_state()`;
7. perform the existing mutation, audit, and notification behavior.

Dependency enforcement is only an additional precondition. It does not grant authority or introduce a new role predicate. Existing creator, active-assignee, scoped-supervisor, administrator, and super-administrator behavior is unchanged.

## Error contract

Blocked transitions raise SQLSTATE `P0001`, matching the repository's established `RAISE EXCEPTION` pattern, with stable messages:

```text
Task cannot be started because one or more prerequisites are unresolved.
Task cannot be completed because one or more prerequisites are unresolved.
```

Errors include no prerequisite ID, number, title, linked-record content, count, or role reasoning. Failed attempts create no success audit or notification row.

## State exposure and minimal UI

`get_task_dependency_lifecycle_state(uuid)` returns active count, unresolved count, blocked, can-start, and can-complete only when the actor can view the Task. It delegates state calculation to the private helper. If any active prerequisite is hidden, both counts are `NULL`; booleans remain fail-closed and no endpoint identity is returned.

Task Detail already had Complete and Cancel controls but no Start control. T3F.2 therefore adds no Start UI. The Actions panel loads server state independently, hides Complete while blocked or unverifiable, preserves Cancel, displays only a generic blocked explanation when counts are withheld, supports retry, and displays the stable server error if a race changes state after rendering. No dependency editing UI is added.

## Concurrency and locking order

All dependency graph changes and start/completion attempts take the exact organization key:

```sql
hashtextextended('task_dependencies:' || organization_id::text, 0)
```

The universal order is:

1. organization graph advisory transaction lock;
2. Task row locks (one dependent row for lifecycle; both dependency endpoints in ascending UUID order for create);
3. prerequisite reads through the state helper;
4. dependency or Task write.

Removal takes the graph lock and then updates only the dependency row. No path takes a Task row and then waits for the graph lock, so there is no lock inversion. Same-organization operations serialize; different organizations use different keys. Five `dblink` races verify completion/start, creation/start, removal/start, same-organization deadlock freedom, and unrelated-organization independence.

## Audit and notifications

Successful start continues to produce the existing Task `edited` audit row. Successful completion continues to produce the existing Task `completed` audit and `task_completed` stakeholder notifications. Blocked attempts produce neither success audit nor notification.

No dependency audit event or dependency notification is added. Completing a prerequisite performs no dependent fan-out and does not notify dependents. Dependency-specific event/outbox and notification work remains deferred.

## Performance

Disposable PostgreSQL 17 tests measured the authoritative state helper with 0, 1, 10, 100, and 1,000 unresolved prerequisites. Warm single-call observations on this host were approximately 0.5-0.9 ms, while repeated `EXPLAIN (ANALYZE, BUFFERS)` runs for the cold 1,000-edge helper call were approximately 4.5-6.9 ms. The hot lookup used the existing T3F.1 active-pair index; no index gap justified another index.

These are local observations, not production guarantees. Organization graph-lock wait time and high-fan-out state checks should be measured with staging-like data before production.

## Validation, rollback, and deployment

Deploy after `patch-task-dependencies.sql`:

1. apply `patch-task-dependency-lifecycle-enforcement.sql`;
2. run `validate-task-dependency-lifecycle-enforcement.sql`;
3. run the 30-scenario authenticated lifecycle suite;
4. run the five-scenario concurrency suite and performance probes in a disposable database;
5. run every existing Task, module, attachment, relationship, dependency, security, and frontend regression.

Rollback is `rollback-task-dependency-lifecycle-enforcement.sql`; see `docs/rollback/015-task-dependency-lifecycle-enforcement.md`. It preserves all T3F.1 data and restores normalized function definitions, grants, and schema exactly. Clean reapplication and validation are required after rollback testing.

## Deferred work

Waiver mutation/authorization, waiver UI, dependency notifications, automatic fan-out, dependency create/remove UI, dashboard/reporting surfaces, and production-scale staging verification remain separate reviewed work. T3F.3 is the future dependency-management Task Detail experience; it must not weaken server-authoritative lifecycle enforcement or two-sided visibility.
