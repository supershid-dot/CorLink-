# CAP-002 Phase 1 — Workflow Backend Foundation

## Scope

This milestone implements the inert, reusable persistence and security foundation approved in `docs/60-workflow-engine-architecture.md`. It does not execute workflows. It adds no adapter, module integration, approval/routing behavior, timer, escalation, notification, designer, API integration, or frontend.

The engine stores opaque `subject_type` and `subject_id` values. It never queries or mutates Requests, Entry, Meetings, Tasks, Internal Collaboration, Prisoner Letters, or any future subject module. This preserves the architecture's workflow/module separation until adapters are separately approved.

## Implemented objects

### Definition plane

- `workflow_definitions` is the stable workflow family and organization/platform scope.
- `workflow_definition_versions` stores immutable payload snapshots, capability version, SHA-256 content fingerprint, publication identity, and monotonically increasing version number.
- A family has at most one draft and points to exactly one active published version when active.
- Phase 1 publication accepts only payloads containing empty `nodes` and `edges` arrays. This makes accidental workflow execution structurally impossible while preserving the versioning contract for the runtime phase.

### Instance plane

- `workflow_instances` pins definition/version, opaque subject identity, home and participant organization scope, execution epoch, aggregate lock version, correlation identity, state, and terminal outcome.
- `workflow_instance_steps` stores future node-run state without executing it.
- `workflow_tokens` stores future execution tokens without advancing them.
- `workflow_work_items` stores bounded, indexable human-work queue records without claiming or completing them.
- `workflow_participants` is the explicit visibility and authority snapshot for an instance or work item.
- `workflow_decisions` is append-only evidence reserved for later decision execution.
- `workflow_variables` stores typed, classified instance variables; restricted values require instance-management authority.
- `workflow_events` is append-only, per-instance ordered history with correlation, causation, idempotency, and JSON metadata.

Only `create_workflow_instance` creates runtime-plane data in Phase 1. It creates a `pending` instance, one owner participant, and one `instance_created` event. It creates no step, token, work item, decision, variable, timer, notification, or module mutation.

## RPCs

- `create_workflow_definition` creates an organization/platform family and draft version 1.
- `create_workflow_definition_version` creates the next draft under a locked family.
- `publish_workflow_definition_version` performs optimistic publication of an inert version.
- `create_workflow_instance` creates an inert pending aggregate for an opaque subject.
- `get_workflow_instance` returns a narrow participant-authorized projection.
- `list_workflow_work_items` returns an explicit assignee/candidate queue with keyset pagination and a hard 100-row bound.

The foundation intentionally does not define `advance_workflow`, `cancel_workflow`, or `complete_workflow`. Those are runtime commands and would violate this milestone's explicit “no workflow runtime” boundary.

## Authorization

Existing CorLink helpers remain authoritative:

- `auth.uid()` identifies the actor.
- `is_super_admin()`, `is_admin()`, and `get_my_org_id()` decide definition and Phase 1 instance-creation authority.
- `workflow_actor_is_active()` adds the existing active-user precondition.
- `can_view_workflow_instance()` and `can_manage_workflow_instance()` evaluate immutable, explicit participant snapshots; they do not infer access from module records.

Organization administrators may manage organization definitions and create pending instances only for their home organization. Super administrators may manage platform definitions and retain emergency instance visibility. Phase 1 deliberately restricts instance creation to an administrator because no subject adapter yet exists to prove module-specific authority. Adapters will replace this bootstrap boundary in a later approved phase.

All callable mutation/read boundaries are `SECURITY DEFINER` with `search_path = public, pg_temp`. Public and anonymous execution is revoked. Trigger-only functions have no application execution grant.

## RLS and data exposure

All ten tables have RLS enabled and exactly one `SELECT` policy. There are no insert, update, or delete policies and authenticated users have only table-level `SELECT` grants.

- Definition/version rows are visible only to their definition managers.
- An instance and its steps, tokens, work items, participants, decisions, and events require explicit participant visibility (or super-administrator authority).
- Variables require owner/manager authority, preventing a viewer from reading restricted process context.
- Same-organization membership alone does not expose an instance.
- Definition and instance projections do not dereference subjects, so they cannot leak module titles, references, content, or permission reasoning.

## Concurrency and idempotency

Commands require caller-supplied UUID idempotency keys. Reuse with different input fails.

Lock order is consistent:

1. caller/idempotency advisory lock;
2. definition aggregate row lock, when applicable;
3. active-subject advisory lock, for instance creation;
4. insert definition/version/instance rows;
5. append participant/event rows.

Definition publication uses a family row lock plus an expected `lock_version`. Definition version creation locks the same family before allocating the next version number. Instance creation uses a stable advisory key over definition, subject type, and subject ID, then relies on the partial unique active-subject index. These keys isolate unrelated actors, definitions, subjects, and organizations.

## Performance and scaling

- Work queues use partial indexes for assigned-user and organization/state access, hard page bounds, and `(created_at, id)` keyset cursors.
- Instance lookup indexes cover active subject uniqueness, home-organization state pages, subject history, and definition-version history.
- Current steps and tokens use partial state indexes.
- Event history uses `(instance_id, event_sequence DESC)`; correlation traversal uses `(correlation_id, created_at, id)`; a BRIN time index supports very large append-only event ranges with low maintenance cost.
- Participants use a partial active uniqueness constraint and user-first visibility index.
- Decisions and variables use aggregate-local indexes.

The disposable scale probe inserts 200 instances, 20,000 work items, and 100,000 events and runs `EXPLAIN (ANALYZE, BUFFERS)` for queue, event-history, active-subject, and correlation queries. Production partitioning is intentionally deferred until event volume and retention evidence justify it; the architecture's aggregate sequence and global event ID remain partition-safe.

## Validation and testing

- `validate-workflow-backend-foundation.sql` hard-fails on missing tables, SELECT-only RLS, grants, pinned definer paths, absent immutability guards, absent indexes/FKs, runtime RPC drift, module coupling, or baseline regressions.
- `test-workflow-backend-foundation.sql` covers 24 authenticated behavior scenarios.
- `test-workflow-backend-foundation-rls.sql` covers 12 owner, manager, participant, outsider, cross-organization, missing-identity, and anonymous-execution scenarios.
- `test-workflow-backend-foundation-concurrency.sql` covers five retry, aggregate-uniqueness, version-allocation, cross-organization, and deadlock-free scenarios through independent `dblink` sessions.
- `test-workflow-backend-foundation-performance.sql` performs the disposable scale and plan probes.
- Existing repository validators provide the module, attachment, audit, Task relationship/dependency, and security-definer regression boundary.

## Rollback

`rollback-workflow-backend-foundation.sql` is transactional, uses no `CASCADE`, and refuses to run if any workflow table contains data. It removes only Phase 1 functions and tables. `validate-workflow-backend-foundation-rollback.sql` confirms those objects are absent while approved CorLink baseline objects remain.

The verified sequence is: apply, validate/test, empty fixture cleanup, rollback, rollback validation, reapply, and full validation. This preserves all module data and supports clean reapplication.

## Limitations and future phases

- Definition graph semantics beyond the inert empty shape are not yet validated.
- Instances do not start, advance, suspend, cancel, complete, reject, withdraw, or fail through RPCs.
- Steps, tokens, work items, decisions, and variables have storage shape but no application mutation commands.
- No approval, routing, delegation, substitution, escalation, SLA, deadline, reminder, conditional branch, timer, or notification behavior exists.
- No subject adapter validates a subject's existence or maps workflow state back to a module.
- No cross-organization routing behavior exists; participant organization arrays reserve the architecture shape only.
- No frontend, designer, reporting UI, or operational dashboard is included.

Later phases should proceed in the approved architecture order: definition validation and runtime commands; work-item decision/routing execution; timer/outbox workers; generic operational UI; then one module adapter at a time without changing existing module APIs prematurely.
