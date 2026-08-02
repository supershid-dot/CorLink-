# Task Dependency Backend Foundation

## Implemented architecture

T3F.1 implements the database foundation approved in `docs/51-task-dependency-architecture.md`. Operational dependencies live in `task_dependencies`; informational `task_relationships`, module `task_links`, Task lifecycle RPCs, notifications, dashboards, and all frontend code are unchanged.

The canonical stored edge is:

```text
dependent_task_id depends_on prerequisite_task_id
prerequisite_task_id blocks dependent_task_id  (derived only)
```

There is no dependency type column and no inverse row. A dependent may have many active prerequisites; they use AND semantics. Blocked state is derived and is not a Task status.

## Data model and constraints

`task_dependencies` stores its UUID, both Task endpoints, organization, creator/time, and nullable soft-removal actor/time. Task, organization, and actor foreign keys use `ON DELETE RESTRICT`; Tasks are never cascade-deleted. A check rejects self-links and a paired-removal check prevents incomplete removal metadata. An endpoint trigger rejects an organization value that differs from either Task and prevents endpoint, organization, and creation-history mutation.

The active directed pair has a partial unique index. Removed history therefore remains intact while the same directed edge can be recreated. The create RPC separately rejects the reverse edge and every indirect cycle.

The architecture's Architecture, Resolution and blocked state, Supervisor override, and Implementation Plan sections require waiver state to be explicit and distinct from removal, while deferring waiver RPCs to lifecycle enforcement. T3F.1 therefore adds the minimum `task_dependency_waivers` structure: one explicit waiver record per dependency with actor, timestamp, and nonblank reason. It has SELECT-only RLS and no authenticated mutation surface. It does not affect `start_task()` or `complete_task()`; waiver creation, authority, notification, and lifecycle use remain T3F.2 work.

## RLS, authorization, and visibility

Both new tables have RLS enabled. Their only authenticated table policy is SELECT; authenticated direct INSERT, UPDATE, and DELETE are revoked. Public and anonymous access is revoked.

A dependency and its audit row are visible only when both of these are true:

```sql
can_view_task(dependent_task_id)
AND can_view_task(prerequisite_task_id)
```

Create and remove require `can_manage_task()` for both endpoints. Same-organization validation is server-side. These functions delegate to the existing Task helpers and add no role aliases or permission model. Private graph/state/trigger helpers are not executable by authenticated users. Every SECURITY DEFINER function pins `search_path = public, pg_temp`.

## Cycle prevention and locking

Every graph mutation takes one transaction-scoped advisory lock with the exact key:

```sql
hashtextextended('task_dependencies:' || organization_id::text, 0)
```

The scope is one organization. A transaction never acquires a second dependency-graph key, so this design has no multi-key ordering and cannot create a graph-lock deadlock. Concurrent mutations in one organization serialize; after obtaining the lock, create rechecks active uniqueness, the reverse pair, and recursive reachability on the committed graph. Concurrent inserts therefore cannot each validate against the same stale graph. Unrelated organizations use different keys and proceed independently. Removal uses the same lock so remove/recreate races remain consistent.

## RPCs

- `create_task_dependency(uuid, uuid)` validates both Tasks, status eligibility, organization, both-endpoint management, duplicate/reverse edges, and recursive cycles; then atomically inserts and audits.
- `remove_task_dependency(uuid)` takes the organization graph lock, requires management of both endpoints, soft-removes the edge only, and audits.
- `list_task_dependencies(uuid, integer, integer)` returns active `depends_on` and derived `blocks` rows in deterministic newest-first order, capped at 100 rows, with two-sided visibility.
- `get_task_dependency_capabilities(uuid)` returns only fail-closed view/add/remove booleans.
- `search_tasks_for_dependency(uuid, text, integer)` exists because `list_tasks()` has no number/title query. It performs a same-organization, two-sided-visible, prefix search capped at 50; excludes self, cross-organization, hidden, and already directly linked Tasks; and remains advisory because create performs final authorization and cycle validation.
- Private `get_task_dependency_state(uuid)` returns active count, unresolved count, and blocked boolean. Only `status='completed'` or a persisted waiver resolves an active prerequisite; cancelled remains unresolved. It is not connected to lifecycle RPCs.

## Audit and notifications

`audit_logs` gains record type `task_dependency` and actions `task_dependency_added`, `task_dependency_removed`, and the reserved `task_dependency_waived`. Add/remove audit notes contain only endpoint UUIDs; no Task title, description, or module content is copied. Audit SELECT checks both endpoints.

No notifications or event ledger are added. The approved plan places lifecycle events and waiver RPCs in T3F.2 and transactional notification/outbox work in a later milestone, avoiding premature or duplicate noise.

## Indexes and performance

Partial indexes support active unique pairs, dependent listings, prerequisite listings, and organization graph traversal. Waivers are indexed by dependency/time. Two organization-scoped prefix indexes support number/title picker search.

The disposable PostgreSQL 17 probe used 10,000 Tasks and 9,998 active edges: a 999-edge deep chain plus an 8,999-edge fan-out. `EXPLAIN (ANALYZE, BUFFERS)` selected the dependent and prerequisite partial indexes. On this host, the 100-row dependent probe completed in about 0.09 ms, the reverse probe in about 0.02 ms, the 1,000-node cycle check in about 2-3 ms, and the 8,999-prerequisite derived-state lookup in about 13-18 ms. These are local observations, not production-scale guarantees. Production should monitor deep recursive traversal, very wide fan-out, and organization-lock contention.

## Validation and testing

`validate-task-dependencies.sql` hard-fails on missing columns, defaults, restricted foreign keys, checks, trigger, indexes, active uniqueness, RLS, policy shape, RPC signatures/overloads, SECURITY DEFINER hardening, grants, private helpers, delegated authorization, audit registration, and all approved Task/module foundations.

The authenticated behavioral suite covers 31 scenarios, including both directions, self/duplicate/cycle rejection, long cycles, AND prerequisites, derived completion/cancellation behavior, both-endpoint permissions, hidden-data resistance, denied direct DML, soft removal/recreation, picker filtering, safe audit, and regressions. The repeatable `dblink` suite covers six duplicate/cycle/removal/organization-lock/deadlock races. The performance script creates and removes only disposable synthetic data.

## Rollback and deployment

Deploy after `patch-task-relationships-hardening.sql`:

1. apply `supabase/patch-task-dependencies.sql`;
2. run `supabase/validate-task-dependencies.sql`;
3. run behavioral and concurrency tests in a disposable database;
4. run the existing Task/module regression validators.

`rollback-task-dependencies.sql` refuses while any active or removed dependency row or dependency audit history exists. It deletes no business data. Once operators have explicitly exported and cleared such data, it removes only T3F.1 functions, policies, tables, triggers, indexes, and audit constraint additions. Clean rollback was schema/grant compared with the T3F checkpoint, then reapplication and validation were repeated. See `docs/rollback/014-task-dependencies.md`.

## Deferred work and limitations

T3F.2 must separately review and implement start/completion enforcement, waiver mutation and authority, cancellation exception workflows, and full lifecycle regression. Notifications, event/outbox history, Task Detail UI, dashboards, reporting, exports, workflow propagation, progress roll-up, and cross-organization dependencies remain out of scope. Candidate search is prefix-based and create remains the authoritative race-safe validator. Staging/UAT with real confidential-module roles is still required.
