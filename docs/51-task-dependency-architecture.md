# 51 — Task Dependency Architecture (T3F)

## Executive Summary

T3F defines an enterprise dependency model for Tasks without implementing it. Dependencies are operational constraints and must remain separate from both approved link systems:

- `task_links` associates a Task with Requests, Meetings, Internal Collaboration, Entry, and Prisoner Letters.
- `task_relationships` stores informational `related`, `duplicate`, and `parent` relationships, with derived `child` display.
- A future `task_dependencies` surface will govern whether a Task may start or complete.

The canonical stored direction should be **dependent Task → prerequisite Task**, named `depends_on`. A Task may have many prerequisites and V1 applies AND semantics: every active prerequisite must be satisfied. OR groups are deferred because they introduce materially different authorization, explanation, notification, audit, and reporting behavior.

A Task with unresolved prerequisites may be created, opened, assigned, watched, commented on, edited, moved to `waiting`, or cancelled. It may not enter `in_progress` or `completed` unless every active prerequisite is completed or explicitly waived by an authorized supervisor. Dependency state is derived alongside the existing Task status; `blocked` must not become a seventh Task status or redefine `waiting`.

Dependencies are same-organization only. Creation, removal, and override require authorization on both Task endpoints. Reads require `can_view_task()` on both endpoints so a dependency never reveals a hidden Task. Module origin is irrelevant: any two same-organization Tasks may participate, including Request, Meeting, Internal Collaboration, Entry, Prisoner Letter, case-associated, and standalone Tasks. No module record changes status because a Task dependency changes.

## Goals

- Represent enforceable Task prerequisites without changing informational Task Relationships.
- Support one or many prerequisites with deterministic, explainable semantics.
- Prevent self-links, duplicate active edges, reverse contradictions, and directed cycles under concurrency.
- Preserve the existing Task lifecycle, visibility helpers, SELECT-only RLS posture, SECURITY DEFINER mutation convention, soft-history model, notifications table, and audit trail.
- Work uniformly for standalone Tasks and Tasks linked to every approved module.
- Provide actionable dashboard and reporting views without exposing hidden Task existence.
- Scale to large organizations and deep, but bounded, dependency graphs.

Non-goals are dependency-driven changes to Requests, Meetings, Internal Collaboration, Entry, Prisoner Letters, or Cases; cross-organization workflows; OR groups; automatic cancellation; hard deletion; scheduling engines; critical-path planning; and automatic reassignment.

## Architecture

### Separate operational graph

Dependencies should use a dedicated `task_dependencies` table in a future implementation. Reusing `task_relationships` would weaken both models: informational relationships permit concepts that do not control lifecycle, while dependencies need transition enforcement, override state, cancellation handling, unblock notifications, and operational metrics. Reusing `task_links` would be incorrect because both endpoints are Tasks, not a Task and a module record.

Recommended conceptual columns:

| Field | Purpose |
|---|---|
| `id` | Stable dependency identifier |
| `dependent_task_id` | Task whose start/completion is constrained |
| `prerequisite_task_id` | Task that must be completed |
| `created_by`, `created_at` | Creation history |
| `removed_by`, `removed_at`, `removal_reason` | Soft-removal history |
| `waived_by`, `waived_at`, `waiver_reason` | Explicit supervisor override; distinct from removal |

Store `depends_on` in the table and API vocabulary; do not store both `depends_on` and `blocks`. `blocks` is the derived inverse shown when viewing the prerequisite. This gives one unambiguous edge direction:

```text
dependent_task_id depends_on prerequisite_task_id
prerequisite_task_id blocks dependent_task_id   (derived display only)
```

The table does not need a relationship-type column while only one operational dependency concept exists. Adding a constant `dependency_type='depends_on'` would create no information and invite aliases. If a later approved milestone adds materially different constraint semantics, it should first justify a type column and migration.

### Resolution and blocked state

An active dependency is satisfied when either:

1. its prerequisite Task has `status='completed'`; or
2. the edge has an authorized `waived_at` value.

Soft-removed edges are no longer constraints. A cancelled prerequisite is not satisfied. A dependent Task is blocked when at least one active dependency is unresolved.

Blocked state is derived, not copied into `tasks.status`. This avoids contradictory combinations such as `status='blocked'` plus `status='waiting'`, preserves every approved status transition, and makes the reason inspectable as a set of prerequisite Tasks. Query surfaces may return `is_blocked`, `unresolved_count`, and visible prerequisite summaries, but these are projections of the graph.

### Mutation and read boundaries

A future implementation should follow existing CorLink conventions:

- all mutations through SECURITY DEFINER RPCs with pinned `search_path`;
- SELECT-only RLS on dependency/history tables;
- actor identity from `auth.uid()` only;
- `can_view_task()` reused for each endpoint;
- `can_manage_task()` reused for each endpoint for create/remove;
- a narrower supervisor/admin helper for waiver authorization;
- neutral not-found responses when either endpoint is not visible;
- soft removal, never client-side DELETE;
- ordinary `audit_logs` entries plus existing `notifications` rows.

The dependency table should retain history after removal and waiver. Waiver means “this prerequisite was consciously bypassed for this dependent Task”; removal means “this edge is no longer part of the dependency definition.” They must never be synonyms in audit or reports.

For exact enterprise analytics and idempotent fan-out, a future implementation should also use an append-only `task_dependency_events` ledger. Each event records the dependency and both Task ids, organization, event type, actor, timestamp, optional reason, and a unique causal key. It captures created, removed, waived, prerequisite-completed, prerequisite-cancelled, blocked, and unblocked transitions. Edge columns remain the live source of truth; the event ledger is immutable operational history for duration reporting and notification deduplication, not a second mutable state machine.

### Audit and Task Activity

Compliance audit should continue through `audit_logs`, using a dedicated `record_type='task_dependency'` whose visibility helper checks both endpoints. Recommended actions are dependency created, removed, waived, prerequisite completed/cancelled, and dependent unblocked. The dependency event id should be the audit `record_id`; reasons belong in audit notes and the structured dependency event.

Do not put prerequisite identity into a companion `record_type='task'` audit row, because Task audit visibility requires only the dependent Task and could expose an otherwise hidden prerequisite. A future Task Activity panel may merge dependency audit/events only through a two-sided-visibility RPC, just as it currently merges Task audit and comments. Existing Task lifecycle audit rows remain unchanged.

### Concurrency and cycle safety

Creation must take one organization-scoped transaction advisory lock before duplicate and recursive-cycle checks, following the proven T3E pattern. With same-organization edges, every graph mutation for an organization uses one lock domain; there is no multi-lock acquisition order and therefore no advisory-lock deadlock cycle.

Under that lock, reject:

- a Task depending on itself;
- an already-active directed edge;
- the reverse edge, because two Tasks cannot operationally depend on each other;
- any edge for which the prerequisite already reaches the dependent through active dependencies.

A partial unique index remains defense in depth for duplicate active directed pairs. Cycle detection must consider unresolved, satisfied, and waived active edges alike: completion or waiver changes enforcement, not graph topology. Removed edges alone leave the active graph.

## Business Rules

### Vocabulary and cardinality

- Store only `depends_on`; derive `blocks` for inverse display.
- One Task may depend on zero, one, or many Tasks.
- One prerequisite may block zero, one, or many Tasks.
- V1 uses AND semantics: all active prerequisites must be satisfied.
- OR dependencies are not implicit and must not be simulated by deleting whichever alternatives lose a race.
- Duplicate and reverse active edges are prohibited.
- Dependencies and informational relationships may coexist between the same pair because they answer different business questions.

### Why AND only

AND prerequisites match accountable enterprise work: each edge is a stated requirement, the blocked reason is deterministic, and completion eligibility is explainable. OR groups require a group entity, minimum-satisfied counts, group-level authorization, partial-resolution notifications, UI wording, audit semantics, and reporting rules. Those are valid future capabilities, but introducing them in V1 would turn a dependency graph into a workflow-expression engine.

### Cross-module behavior

Dependencies operate between Tasks, not their origins. Therefore all of these are allowed when both Tasks belong to the same organization and the actor passes both-endpoint authorization:

- Request Task → Meeting Task;
- Meeting Task → Entry Task;
- Entry Task → standalone Task;
- Prisoner Letter Task → Internal Collaboration Task;
- a case-associated Task → any other same-organization Task.

“Case” in the current application is a user-facing workflow concept around Requests and their Internal Collaboration threads, not a separate Task dependency endpoint. A dependency remains between the Tasks; existing `task_links` determine which case/module cards are displayed.

No dependency operation may create, remove, or alter a `task_links` row. No Task completion/cancellation may update a linked module record, and no Request closure, Meeting completion, Entry closure, Internal Collaboration response, Prisoner Letter delivery, or case closure may automatically satisfy a Task dependency. Existing module lifecycle independence remains intact.

### Cross-organization behavior

Dependencies must not cross organizations. Tasks have one explicit `organization_id`, Task assignees must belong to it, `can_view_task()` is organization-bound, and module links already handle dual-organization records without making Tasks cross-organization objects. A cross-organization edge would create asymmetric visibility, override, notification, audit, and escalation ownership that the Task permission model cannot safely express.

Where two organizations coordinate through a Request or Prisoner Letter, each organization should own its own Task. The shared module record remains the collaboration boundary. Any future inter-organization workflow contract requires a separately approved architecture rather than weakening Task confidentiality.

### Deletion and history

CorLink currently has no hard-delete Task workflow. Future foreign keys should use RESTRICT/NO ACTION for dependency history rather than cascade deletion. If hard deletion is ever introduced, it must refuse while active or historical dependency records reference the Task, unless a separately approved retention process exports and removes that history. A prerequisite disappearing must never silently unblock dependents.

## Lifecycle

Dependency state constrains only transitions that represent beginning or finishing execution. It does not replace Task status.

| Action on blocked Task | Rule |
|---|---|
| Create as `draft` | Allowed |
| Open (`draft → open`) | Allowed; planning and assignment can proceed |
| Assign/unassign | Allowed |
| Watch/comment/edit metadata | Allowed under existing permissions |
| Start (`open/waiting → in_progress`) | Rejected while any prerequisite is unresolved |
| Move to `waiting` | Allowed; `waiting` remains a business status, not a dependency alias |
| Complete | Rejected while any prerequisite is unresolved |
| Cancel | Allowed under existing cancellation authorization |

Creating any dependency for a dependent Task already in `in_progress`, `completed`, or `cancelled` should be rejected. It is allowed only for a dependent in `draft`, `open`, or `waiting`. This avoids silently reversing work already started, rewriting terminal history, or leaving an “in progress but blocked” contradiction. A dependency whose prerequisite is already completed may be added to those three eligible statuses and is satisfied immediately, though the audit must record that fact. A new edge to an already-cancelled prerequisite should be rejected as knowingly unsatisfiable; cancellation after a valid edge exists follows the exception workflow below.

### Prerequisite completion

When a prerequisite completes, all active edges pointing to it become satisfied by derivation. Each dependent is reevaluated in the same transaction or through a transactionally reliable event/outbox step:

- if unresolved prerequisites remain, it stays blocked;
- if none remain, it becomes unblocked without changing its Task status;
- stakeholders receive one deduplicated “ready to start/resume” notification after commit.

The system must not automatically move `open` or `waiting` Tasks to `in_progress`. Unblocking grants eligibility; a person still chooses when work starts.

### Prerequisite cancellation

Cancellation does not satisfy a dependency. The dependent remains blocked in an exception state requiring an authorized choice: replace/remove the dependency, cancel the dependent, or waive the prerequisite. Stakeholders should receive a high-signal notification and dashboard warning. No cancellation cascades in either direction.

### Dependent cancellation

A blocked dependent may be cancelled. Its outgoing dependency edges remain as retained history but no longer need operational notifications. Its cancellation must not cancel prerequisites or other dependents.

### Prerequisite deletion

Hard deletion should be prevented by foreign keys and retention rules. If a future archival model hides a prerequisite, dependency enforcement remains intact; viewers lacking two-sided visibility receive only a neutral transition denial, not the hidden Task’s identity or existence.

## Permissions

### Visibility

Dependency SELECT visibility requires `can_view_task(dependent_task_id) AND can_view_task(prerequisite_task_id)`. Listing, counts, search candidates, dashboard drill-down, notification recipients, audit visibility, and reporting exports must apply that same two-sided rule. A viewer who sees only one endpoint gets no dependency row, count, title, number, status, or inferred hidden endpoint.

Lifecycle enforcement still applies regardless of the caller’s visibility. If an unresolved hidden prerequisite prevents a transition, the error must be neutral (“Task cannot transition at this time”) rather than identifying dependency type, count, or endpoint. Dashboard “blocked” badges and counts must include only dependencies whose endpoints the viewer can see; operational supervisors should receive access through the existing Task scope model, not a dependency-specific bypass.

### Create and remove

Creation and removal require `can_manage_task()` on both endpoints and same-organization membership, matching the mandatory T3E authorization rule. Client capability flags mirror this result but never authorize a mutation. Search candidates must be bounded, same-organization, RLS-filtered, exclude the current Task, and disable existing/reverse/cycle-invalid candidates when that can be calculated safely; the RPC remains authoritative for races.

### Supervisor override

Waiver is allowed, but only as an explicit exception—not as a normal assignee action. The actor must:

- be a super-admin, organization admin, or supervisor whose scope covers both Task endpoints;
- pass `can_manage_task()` for both endpoints;
- supply a non-empty reason;
- confirm the exact prerequisite(s) being waived.

An assignee or creator who is not also an appropriately scoped supervisor/admin cannot waive. A waiver is edge-specific. “Override all” may be a convenience RPC/UI action only if it atomically enumerates and records every waived edge; it must not store an unexplained dependent-level boolean.

Each waiver records actor, timestamp, reason, dependent, and prerequisite; writes structured dependency audit history that the Task timeline may read only through its two-sided-visibility surface; notifies visible stakeholders; and remains visible after later removal. Waiver never changes either Task’s status and never grants visibility to someone who could not already view both Tasks.

## Notifications

Notification delivery should reuse the existing `notifications` table and Task stakeholder sets. Recipients must be deduplicated, exclude the actor, remain active users, and pass two-sided visibility at send time. Module participants are not notified merely because one endpoint has a `task_links` origin; they receive dependency notifications only if they are also Task stakeholders.

Recommended events:

| Event | Recipients | Purpose |
|---|---|---|
| Dependency created and unresolved | Dependent creator, active assignees, watchers; prerequisite active assignees/creator | Explain new blocked work and downstream impact |
| Dependency created already satisfied | Dependent creator/assignees only | Inform without false blocked urgency |
| Prerequisite completed, more remain | Dependent creator, active assignees, watchers | Progress update, optionally batched |
| Last prerequisite satisfied | Dependent creator, active assignees, watchers | High-signal “ready to start/resume” event |
| Prerequisite cancelled | Dependent creator, active assignees, watchers, and scoped supervisors | Exception requiring intervention |
| Dependency waived | Stakeholders of both Tasks and scoped supervisors | Make exceptional bypass visible |
| Dependency removed/replaced | Dependent creator, active assignees, watchers | Explain why blocking changed |

Avoid per-edge notification storms when one prerequisite completion unblocks many Tasks. Produce one notification per affected dependent, batch fan-out, and enforce idempotency keys such as `(event, dependency/dependent, causal event id, recipient)`. Insert the existing in-app `notifications` rows in the same transaction so rollback removes them too; the UI observes them only after commit. If external channels are added later, they should consume an outbox rather than send inside the lifecycle transaction.

## Dashboard

Blocked work is a derived operational dimension, not a new status. Recommended additions:

- **Blocked Tasks** widget for Tasks assigned to the viewer, ordered by due-date urgency then blocked age.
- A visible **Blocked** badge on Task cards/rows when the dependency is visible to the viewer.
- An unresolved-prerequisite count and oldest-blocked-since value on Task Detail.
- A supervisor **Blocked Workload** summary grouped by section and assignee.
- A **Recently Unblocked** widget so staff can resume newly available work.
- An exception treatment for “prerequisite cancelled” distinct from ordinary blocking.

Existing metrics should change carefully:

- My Tasks and status totals remain unchanged; blocked is a subset, not a seventh status.
- Due Today and Overdue continue counting blocked Tasks because deadlines and accountability remain real; rows gain a blocked indicator.
- Awaiting My Action should split or filter into **Actionable Now** (unblocked) and **Blocked** so it does not overstate executable work.
- Completion Summary remains completion-based and unchanged.
- Team Workload gains blocked count/rate but retains existing open/in-progress totals for trend continuity.
- Priority counts remain unchanged; critical blocked Tasks should be highlighted as exceptions.

Current dashboards aggregate bounded client-side `list_tasks(limit: 200)` results and disclose capped totals. Enterprise dependency KPIs should use dedicated, RLS-safe aggregate RPCs rather than extending client-side approximations. Drill-down must use the existing Task List where possible, adding dependency filters in a later implementation rather than creating a competing list page.

## Reporting

Recommended operational reports:

1. Current blocked Tasks by organization, section, assignee, priority, due date, and blocked age.
2. Overdue blocked Tasks, including the visible unresolved prerequisite and its owner.
3. Dependency exceptions: cancelled prerequisites, waived edges, and unresolved Tasks with no active assignee.
4. Recently unblocked Tasks and time-to-start after unblock.
5. Average and percentile blocked duration by section, priority, origin module, and month.
6. Override report by supervisor, reason, section, age, and downstream outcome.
7. Dependency fan-out: prerequisites blocking the most downstream Tasks.
8. Hierarchy depth and longest dependency chain, with cycle validation health.
9. Completion lead time split into active versus blocked duration.
10. Module-origin view showing blocked Request/Meeting/Internal Collaboration/Entry/Prisoner Letter/standalone Tasks without changing those modules’ lifecycle.

Every report and export must apply two-sided visibility row by row. Organization administrators may receive organization-wide results through existing authorization; no reporting-only bypass should be introduced. Historical blocked-duration analytics should be based on structured dependency events or reproducible edge/lifecycle timestamps, not parsed free-text audit notes.

## Performance

Recommended indexes for a future `task_dependencies` table:

- partial unique `(dependent_task_id, prerequisite_task_id) WHERE removed_at IS NULL`;
- partial lookup `(dependent_task_id, created_at) WHERE removed_at IS NULL`;
- partial reverse lookup `(prerequisite_task_id, created_at) WHERE removed_at IS NULL`;
- partial unresolved/waiver support keyed by `dependent_task_id` where active and not waived;
- history indexes on `created_at`, `removed_at`, and `waived_at` for reporting;
- an organization-leading index only if `organization_id` is deliberately denormalized and protected against endpoint drift.

The append-only event ledger should index `(dependent_task_id, occurred_at)`, `(prerequisite_task_id, occurred_at)`, `(organization_id, event_type, occurred_at)`, and uniquely index its causal idempotency key.

The hot lifecycle check is “does this dependent have any active, unwaived prerequisite whose Task is not completed?” It should use `EXISTS`, not count every edge. Listing may aggregate visible prerequisites in one query and must avoid per-card Task lookups. Reverse completion fan-out should use the prerequisite index and update/notify affected dependents in bounded batches.

Recursive cycle checks should use indexed adjacency, `UNION`/visited-node protection, and a configurable maximum traversal depth or statement timeout as defense against pathological graphs. Rejecting cross-organization edges bounds lock and traversal domains. Organization-scoped advisory locking is safe and simple for initial correctness; if write contention becomes measurable at production scale, a later milestone may evaluate deterministic graph-component locks without weakening cycle guarantees.

Dashboard/report aggregates should be server-side and RLS-safe. For very large history, consider time-partitioned structured dependency events or refreshed materialized aggregates, while preserving live authorization at query time. Monitor edge count per Task, maximum/95th-percentile depth, cycle-check latency, lock wait time, completion fan-out, dashboard aggregate latency, and notification batch size.

## Migration Strategy

This design requires no T3F migration. A later approved implementation should be additive and staged:

1. Add dependency tables/constraints/indexes, SELECT-only RLS, visibility/capability helpers, mutation/list RPCs, audit values, and notification values.
2. Ship with no backfill. Existing `task_relationships` rows remain informational and are never converted automatically.
3. Integrate dependency checks into the existing non-terminal start transition path and `complete_task()` without changing the approved transition graph.
4. Integrate prerequisite completion/cancellation fan-out transactionally, preserving existing Task completion notifications.
5. Add Task Detail, bounded search, dashboard indicators, and server-side aggregate reporting behind the new RPC capabilities.
6. Validate on a fresh disposable database through the complete approved chain, including concurrency, two-sided visibility, lifecycle regression, all five module integrations, dashboard, notifications, audit, rollback, and reapplication.
7. Deploy schema before UI. Existing Tasks remain unblocked because the new table starts empty.

Rollback must refuse while dependency history exists, including removed or waived rows, unless operators explicitly export and delete it. It must restore lifecycle RPCs, notification/audit constraints, schema objects, and grants exactly to the pre-dependency baseline.

## Future Enhancements

- OR/threshold prerequisite groups with an explicit group entity and separately approved semantics.
- Lead/lag timing, “not before prerequisite + N days,” and scheduling forecasts.
- Critical-path and impact visualization for deep graphs.
- Bulk dependency templates for recurring operational processes.
- Dependency-specific escalation policies and SLA timers.
- Cross-organization workflow contracts, only with a dedicated shared-visibility and ownership model.
- Structured event streaming to analytics, without replacing the human-readable Task timeline.
- Production-driven lock partitioning if organization-scoped serialization becomes a demonstrated bottleneck.

## Implementation Plan

A future implementation should be split into independently reviewable milestones:

1. **Database foundation:** dedicated schema, strict constraints, cycle/concurrency proof, two-sided RLS, SECURITY DEFINER mutations, audit, rollback, and exhaustive SQL tests.
2. **Lifecycle enforcement:** guard start and completion, handle prerequisite completion/cancellation, add waiver RPCs, and regression-test the complete existing Task transition graph.
3. **Task Detail experience:** dependency panel, derived Depends On/Blocks views, bounded candidate search, create/remove, supervisor waiver, neutral hidden-prerequisite errors, loading/empty/retry states.
4. **Notifications:** transactional event/outbox integration, recipient visibility filtering, deduplication, cancellation exceptions, and unblocked fan-out.
5. **Dashboard and reporting:** blocked/actionable widgets, server-side aggregates, drill-down filters, supervisor metrics, and export-safe visibility.
6. **Staging/UAT:** verify real staff, assignee, creator, supervisor, admin, and confidential-module roles; concurrency; deep graphs; cancellation exceptions; notifications; dashboards; and module lifecycle independence.

Each milestone must preserve the mandatory both-endpoint authorization rule. Dependency or lifecycle enforcement must never be added to informational Task Relationships, and no linked module architecture should require redesign.
