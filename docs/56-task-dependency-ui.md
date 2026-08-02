# Task Dependency UI and Management

## Architecture and scope

T3F.3 adds the Task Detail management experience for the operational dependency graph approved in `docs/51`–`docs/55`. It is frontend-only. No SQL, RPC, table, RLS policy, lifecycle transition, audit behavior, notification behavior, Task status, informational Task Relationship, module link, dashboard, or workflow rule changes.

The UI preserves the canonical stored direction:

```text
dependent Task depends_on prerequisite Task
prerequisite Task blocks dependent Task (derived display)
```

`TasksAPI` wraps the existing `list_task_dependencies`, `get_task_dependency_capabilities`, `get_task_dependency_lifecycle_state`, `search_tasks_for_dependency`, `create_task_dependency`, and `remove_task_dependency` RPCs with their exact named parameters. There are no direct `task_dependencies` reads or writes.

## Components

Task Detail has a new independently loaded **Dependencies** panel with two separate groups:

- **Prerequisites** — visible Tasks this Task depends on;
- **Blocked Tasks** — visible Tasks that depend on this Task.

Both groups reuse the existing `.task-card` component. Cards show Task number, backend-returned status, title, priority, due date, direction, Open Task, and a capability-gated Remove Dependency action. Prerequisite cards also show a non-color-only resolution badge: `Completed` only for `status='completed'`, and `Unresolved` for every other status including `cancelled`. The list RPC does not return assignees, so the UI performs no supplemental or per-card Task lookup.

## Dependency state and lifecycle integration

The panel consumes only `get_task_dependency_lifecycle_state()` for `READY`/`BLOCKED`, active prerequisite count, and unresolved prerequisite count. Counts render only when the RPC returns non-null values. The UI never calculates hidden counts from visible rows. A blocked state uses the neutral message “Blocked because one or more prerequisites are unresolved.”

The Actions panel and Dependencies panel share one in-flight lifecycle-state request during initial Task Detail load. After a dependency mutation, one forced state refresh updates both surfaces. Complete remains server-authoritative and is disabled while blocked; Cancel remains unchanged. Task Detail has no Start control, so none is introduced.

## Add workflow

`Add Prerequisite` is rendered only when `can_add_dependency` is true. Its modal:

1. accepts a Task number or title prefix;
2. calls the bounded `search_tasks_for_dependency()` RPC with limit 20;
3. displays exactly the eligible candidates returned by the server, without local permission or graph filtering;
4. selects one candidate and calls `create_task_dependency(currentTaskId, candidateId)`;
5. closes on success and refreshes only the Dependencies and lifecycle-action surfaces.

Search loading, no-results, and server-error states are contained within the modal. Duplicate, cycle, status-race, and concurrent-create rejections remain authoritative server errors and leave the modal usable.

## Remove workflow

Remove is shown only when the capability RPC permits removal and the list row returns `can_remove=true`. The confirmation identifies the visible related Task number and states that neither Task status changes. The UI calls `remove_task_dependency()`, which soft-removes the edge and audits server-side, then refreshes only the dependency/lifecycle surfaces. A failed removal preserves the card and displays an inline error.

## Permissions and confidentiality

The frontend does not reconstruct roles, endpoint visibility, or endpoint management. Add uses `can_add_dependency`; removal requires both global `can_remove_dependency` and per-row `can_remove`. Candidate results come only from the corrected bounded RPC. Hidden endpoints receive no cards, placeholders, counts, labels, ARIA text, or inferred totals.

## Loading and error isolation

The panel owns its loading, two independent empty states, error, retry, mutation-progress, search-loading, no-results, and search-error states. Panel failures do not alter the Task header, comments, attachments, assignments, watchers, linked records, activity, informational relationships, or lifecycle authorization.

## Responsive behavior

Desktop uses two side-by-side direction groups. At the existing 900px Task Detail breakpoint the groups stack. At the existing 640px mobile breakpoint state content stacks and card actions become touch-friendly. No new global breakpoint or card system is introduced.

## Accessibility

Actions and picker options are real buttons; Task navigation remains a link. Section headings are associated with their groups, state/search loading uses live status semantics, and resolution is expressed in text as well as color. The modal has `role="dialog"`, `aria-modal`, a labelled heading, initial search focus, a trapped Tab loop, Escape dismissal, and focus restoration to the opener. Hidden Task data is not placed in labels or off-screen content.

## Performance

Initial panel load performs one dependency list RPC, one capability RPC, and one lifecycle-state RPC in parallel. The Actions panel shares that lifecycle request instead of issuing a duplicate. Search is server-side and capped at 20 by the UI (and 50 by the backend). Cards use the display fields already returned by the list RPC, so there is no N+1 lookup. Each successful mutation performs one panel-level refresh and never reloads Task Detail.

## Testing

The headless Task frontend harness contains 59 passing scenarios with zero runtime errors. T3F.3 coverage includes state/count confidentiality, both direction groups, completed/cancelled resolution, capability gating, bounded search integration, successful add/remove, duplicate/cycle/concurrency errors, mutation refresh, lifecycle gating, retry/error isolation, empty/loading states, desktop/tablet/mobile rendering, keyboard modal behavior, and full T2A–T3F.2 regression. Every modified JavaScript file passes `node --check`. Existing backend validators are rerun unchanged because T3F.3 modifies no backend object.

## Limitations and staging/UAT checklist

Waivers, dependency notifications, graph visualization, dashboards, reports, bulk editing, automatic propagation, workflow redesign, Gantt, and Kanban remain out of scope. The list RPC is capped at 100 active visible rows and this UI does not add pagination; exceptionally large visible graphs require a future separately approved UX.

Before production, UAT should verify:

- creator, active-assignee, scoped-supervisor, administrator, and super-administrator add/remove behavior;
- confidential and one-endpoint-hidden Task combinations;
- Request, Meeting, Internal Collaboration, Entry, Prisoner Letter, and standalone Task combinations;
- duplicate, reverse, indirect-cycle, and concurrent mutation errors;
- completed and cancelled prerequisite rendering;
- blocked Complete behavior before and after add/remove;
- keyboard, screen-reader, tablet, and mobile behavior;
- staging-like candidate-search and 100-row list latency;
- no dependency notifications or linked-module lifecycle side effects.
