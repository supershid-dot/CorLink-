# Task Relationships

## Architecture

T3E adds task-to-task relationships without changing the existing polymorphic `task_links` architecture used by Requests, Meetings, Entry, Internal Collaboration, and Prisoner Letters. The dedicated `task_relationships` table stores two task foreign keys, relationship direction, creation metadata, and soft-removal metadata. Task Detail consumes four focused RPCs through `TasksAPI`.

The table exposes SELECT only. Creation and removal are exclusively SECURITY DEFINER RPC mutations with a pinned `search_path`, explicit authenticated-caller checks, and grants limited to `authenticated`.

## Relationship model

The supported types are `related`, `blocked_by`, `blocks`, `duplicate`, `parent`, and `child`. A type is expressed from the source task's perspective. When the target task is viewed, `list_related_tasks()` returns the inverse (`blocks`/`blocked_by` and `parent`/`child`); `related` and `duplicate` are symmetric.

Only one active relationship is allowed for an unordered pair of tasks. Removal is soft, allowing the same pair to be related again later while retaining prior rows for history.

## Permissions

Visibility requires `can_view_task()` for both endpoints. The SELECT RLS policy and listing RPC both delegate to that existing predicate, so a relationship cannot reveal a hidden task.

Creating requires `can_manage_task()` on the source task and visibility of the target. Removing requires visibility of both endpoints and management of either endpoint. `get_task_relationship_capabilities()` provides the server-derived create/remove capability used by Task Detail; UI gating is convenience only and every mutation is re-authorized by its RPC.

## Validation

Self-references are rejected by both the RPC and a table constraint. A partial unique expression index prevents duplicate active unordered pairs, including inverse duplicates. Parent/child edges are normalized to parent-to-child direction inside a recursive CTE; creation is rejected when the proposed child already reaches the proposed parent.

The modal excludes the current task, marks already-related results unavailable, and displays backend errors for duplicate, permission, and circular-chain races.

## Performance

Partial indexes cover active lookups from both source and target. The unordered-pair unique index gives constant-index duplicate enforcement. Relationship listing performs one query and aggregates active assignee names per related task. Search is bounded to 20 visible same-organization tasks and uses the existing Tasks SELECT RLS.

## Responsive behavior

Related Tasks uses the existing Task Detail main column, task cards, buttons, badges, modal, and user-picker result patterns. It introduces no breakpoint; existing Task Detail and card wrapping behavior controls narrow layouts.

## Testing

`supabase/validate-task-relationships.sql` verifies table structure, SELECT-only RLS, indexes, RPC presence and hardening, and `can_view_task()` delegation. `supabase/test-task-relationships.sql` is a rollback-wrapped local/disposable-database behavioral suite covering creation, inverse listing, self and duplicate rejection, circular parent/child rejection, server capabilities, soft deletion, and post-removal visibility.

Frontend verification covers initial loading, empty state, retry, bounded number/title search, creation, removal, navigation, and server capability gating. Existing static frontend checks and JavaScript syntax checks remain regression gates.

## Known limitations

- Task search is substring-based and intentionally limited to visible tasks in the current task's organization.
- Relationships have no free-text notes, ordering, or notification fan-out.
- Only parent/child relationships are cycle-checked; blocking cycles are not prohibited by the T3E model.
- Soft-removed history has no dedicated UI.

## Future enhancements

Potential follow-ups include relationship history, notes, notifications, bulk management, indexed full-text task search, and an administrative hierarchy visualization. Each should extend the dedicated task relationship architecture rather than changing cross-module Task Links.
