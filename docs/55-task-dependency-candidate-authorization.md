# Task Dependency Candidate Authorization

## Scope and root cause

T3F.2A corrects only `search_tasks_for_dependency(uuid, text, integer)`. The approved T3F.1 picker already enforced two-sided visibility, same-organization scope, self exclusion, active direct/reverse-edge exclusion, prefix search, deterministic ordering, and a 50-row maximum. It did not require management authority over either endpoint even though `create_task_dependency()` requires `can_manage_task()` for both.

That mismatch allowed a manageable current Task to return visible candidate Tasks the actor could not manage. Creation still rejected those candidates, so this was not a mutation-authority bypass, but it violated the picker contract and forced the future UI either to show unusable choices or reconstruct permissions client-side.

## Corrected contract

The RPC now requires all four delegated predicates:

```sql
can_view_task(current_task.id)
AND can_manage_task(current_task.id)
AND can_view_task(candidate.id)
AND can_manage_task(candidate.id)
```

No role logic is copied into the picker. `can_manage_task()` remains the single authority for creator, active-assignee, scoped-supervisor, administrator, and super-administrator behavior. An inaccessible or unmanageable current Task produces an empty result, preserving fail-closed, non-leaking behavior. View-only, hidden, cross-organization, self, and already-linked candidates are not returned. Counts outside the authorized result set are not exposed.

The signature, return columns, defaults, prefix matching, ordering, limit clamp, ownership, `STABLE` volatility, SECURITY DEFINER posture, pinned `search_path`, and grants are unchanged. Duplicate and cycle checks remain authoritative in `create_task_dependency()`.

## Performance

The disposable PostgreSQL 17 performance probe used 10,000 same-organization candidates, a 99-row selective Task-number prefix, and a requested limit of 20. The server-authoritative RPC returned 20 rows in approximately 58 ms. The equivalent predicate plan completed in approximately 0.09 ms and used `tasks_pkey` for the current Task plus the existing T3F.1 `idx_tasks_dependency_picker_number` index for candidates. The management helpers account for the remaining authorization cost; the query stays organization/prefix bounded and no new index was justified.

## Rollback and deployment

Deploy after T3F.2:

1. apply `supabase/patch-task-dependency-candidate-management.sql`;
2. run `supabase/validate-task-dependency-candidate-management.sql`;
3. run the authenticated 25-scenario suite and the performance probe;
4. run the complete Task dependency, lifecycle, relationship, module, audit, attachment, security, and frontend regressions.

`supabase/rollback-task-dependency-candidate-management.sql` transactionally restores the exact pre-T3F.2A function body. CREATE OR REPLACE preserves ownership and ACLs. Rollback verification compares normalized function definitions and grants, confirms the corrected validator fails specifically because management predicates are absent, then reapplies and retests the correction. No dependency data or unrelated object is changed.

## Deferred UI

T3F.3 Task Dependency UI and Management remains deferred until this correction is reviewed, approved, pushed, and remotely verified. This milestone adds no frontend, lifecycle, relationship, notification, audit, dashboard, waiver, or Task-status behavior.
