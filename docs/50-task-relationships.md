# Task Relationships

## Architecture

T3E adds task-to-task relationships without changing the existing polymorphic `task_links` architecture used by Requests, Meetings, Entry, Internal Collaboration, and Prisoner Letters. The dedicated `task_relationships` table stores two task foreign keys, relationship direction, creation metadata, and soft-removal metadata. Task Detail consumes four focused RPCs through `TasksAPI`.

The table exposes SELECT only. Creation and removal are exclusively SECURITY DEFINER RPC mutations with a pinned `search_path`, explicit authenticated-caller checks, and grants limited to `authenticated`.

## Relationship model

The only stored and createable types are `related`, `duplicate`, and `parent`. `related` and `duplicate` are symmetric and stored in canonical UUID order. `parent` is directional: source is parent and target is child. `child` is a read-only inverse label derived by `list_related_tasks()` when the target endpoint is viewed; it is never stored or accepted by creation.

Only one active relationship is allowed for an unordered pair of tasks. Removal is soft, allowing the same pair to be related again later while retaining prior rows for history.

## Permissions

Visibility requires `can_view_task()` for both endpoints. The SELECT RLS policy and listing RPC both delegate to that existing predicate, so a relationship cannot reveal a hidden task.

Creating requires `can_manage_task()` on both endpoints and requires both tasks to belong to the same organization. Removing requires visibility and `can_manage_task()` on both endpoints. `get_task_relationship_capabilities()` and per-row `can_remove` values mirror those rules; UI gating is convenience only and every mutation is re-authorized by its RPC.

## Validation

Self-references are rejected by both the RPC and a table constraint. A partial unique expression index prevents duplicate active unordered pairs, including inverse and contradictory parent duplicates. Parent edges are rejected when the proposed child already reaches the proposed parent. An organization-scoped transaction advisory lock serializes the duplicate and recursive-cycle decision with insertion, making those checks safe under concurrent calls without multi-lock deadlock ordering.

The modal excludes the current task, marks already-related results unavailable, and displays backend errors for duplicate, permission, and circular-chain races.

## Performance

Partial indexes cover active lookups from both source and target. The unordered-pair unique index gives constant-index duplicate enforcement. Relationship listing performs one query and aggregates active assignee names per related task. Search is bounded to 20 visible same-organization tasks and uses the existing Tasks SELECT RLS.

## Responsive behavior

Related Tasks uses the existing Task Detail main column, task cards, buttons, badges, modal, and user-picker result patterns. It introduces no breakpoint; existing Task Detail and card wrapping behavior controls narrow layouts.

## Testing

`supabase/validate-task-relationships.sql` verifies the exact stored vocabulary, canonical storage, SELECT-only RLS, grants, RPC hardening, both-endpoint authorization, derived `child`, and confidential audit visibility. On a fresh disposable PostgreSQL 17.10 database rebuilt through T3D.1, `supabase/test-task-relationships.sql` passes 30/30 authenticated scenarios, including real concurrent duplicate, reverse, and parent-cycle calls. The required T3D.1 security, task foundation, five module integration, audit, task attachment, and meeting attachment validators all pass after reapplication.

The Playwright/Edge headless harness passes 17/17 scenarios covering exact creation options, derived child rendering, loading, empty, retry, navigation, permission gating, confirmed removal and failure handling, candidate exclusion, creation failure, responsive rendering, regression markers, and zero page errors. Every modified JavaScript file also passes `node --check`.

The rollback audit proves refusal while any active or removed relationship history exists. After explicit disposable-data removal, schema objects and grants match the T3D.1 capture exactly (the random `pg_dump` restriction nonce is normalized for comparison), and T3E/T3E.1 reapply cleanly with all validation repeated.

## Known limitations

- Task search is substring-based and intentionally limited to visible tasks in the current task's organization.
- Relationships have no free-text notes, ordering, or notification fan-out.
- Parent hierarchy is intentionally the only directional relationship model; task dependencies are outside T3E scope.
- Soft-removed history has no dedicated UI.

## Future enhancements

Potential follow-ups include relationship history, notes, notifications, bulk management, indexed full-text task search, and an administrative hierarchy visualization. Each should extend the dedicated task relationship architecture rather than changing cross-module Task Links.
