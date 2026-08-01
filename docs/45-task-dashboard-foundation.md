# 45 — Task Dashboard Foundation (T3A)

Adds a single new Task Dashboard page (`js/views/task-dashboard.js`) — an
overview of eight widgets, each showing a count, up to five tasks, and a
"View All" link into the **existing** Task List (docs/40) with the
widget's own filters pre-applied. Explicitly out of scope, per spec, and
not implemented here: analytics, charts, reports, saved layouts, custom
widgets, drag-and-drop, dashboard configuration, calendar, Gantt, Kanban,
attachments, and task editing.

## Architecture

**No SQL, RPC, table, policy, or index was added.** The dashboard is
built entirely from three existing surfaces: `TasksAPI.listTasks()`
(T2A), `TasksAPI.getTask()` via the existing `task-detail` route (T2B),
and the existing Task List's own filtering/permissions/RLS. This file
adds no visibility logic of its own — a task a viewer cannot see never
reaches `list_tasks()`'s result set in the first place, the same
structural guarantee every prior task milestone has relied on.

`list_tasks()` (`supabase/patch-shared-task-foundation.sql`) has the same
narrow, already-disclosed signature docs/40 documented for the Task
List: `p_organization_id`, `p_owning_section_id`, `p_status` (single
exact match), `p_assigned_to_me`, `p_limit` — no date-range filter, no
priority filter, no multi-status filter, no `updated_at` ordering
(results are always `created_at DESC`), and no total-count column. Eight
widgets each need a different slice (due date, priority, status set,
recency) this RPC cannot express directly. Rather than invent RPC
parameters, this file reuses the exact "broad server fetch, then
client-side quick filter" pattern the Task List itself already
established for its own priority/origin/due-date quick filters — fetch
once via the parameters `list_tasks()` **does** support, then derive
each widget's specific view by filtering client-side over that one
fetch.

**Three base fetches, not eight.** Rather than one `list_tasks()` call
per widget (mostly redundant — several widgets share the same underlying
scope), widgets are grouped by which of three possible base fetches they
actually need:

| Base | Fetch | Widgets using it |
|---|---|---|
| `assigned` | `listTasks({ assignedToMe: true, limit: 200 })` | My Tasks, Due Today, Overdue, High Priority, Completed Today, Awaiting My Action |
| `org` | `listTasks({ organizationId, limit: 200 })` | Recently Updated |
| `section` | `listTasks({ owningSectionId, limit: 200 })` (or an org-wide admin fallback — see below) | Team Workload |

Regardless of widget count, this is **at most 3 network requests** per
dashboard load, satisfying the spec's "avoid unnecessary duplicate
requests / do not introduce N+1" requirement directly.

**"Each widget loads independently" is UI-level independence, not
one-request-per-widget.** A literal one-request-per-widget reading would
directly conflict with the anti-duplication requirement above, so this
was interpreted as: every widget has its own DOM node, its own loading
spinner, its own error banner, and its own retry button, driven off its
*base's* load state — a failure in one base (e.g. `org`) never breaks or
blocks a widget on a different base (e.g. `assigned`), and retrying a
failed base only re-fetches that one base, leaving the others untouched.
See §Testing for the verified failure-isolation case.

**Count without a count column.** Since `list_tasks()` returns no
total-count field, each widget's displayed count is `items.length` from
the same `limit: 200` fetch already needed for the up-to-5-task display
— no separate count-only query — with a `+` suffix appended if the
count hits the fetch's own 200-row cap, so the number shown is never
silently wrong, only honestly capped. This mirrors the Task List's own
existing cap-disclosure convention (docs/40).

## Widget design

All eight widgets share one render path (`_widgetHtml`): a `.panel`
header with icon/title/count, up to five `.task-card`-styled rows (T2E's
existing card pattern, reused as-is), an empty-state message when a
widget has zero matching items, and a "View All" footer link.

| Widget | Base | Filter | Supervisor/admin only |
|---|---|---|---|
| My Tasks | assigned | all | no |
| Due Today | assigned | `due_date === today` | no |
| Overdue | assigned | `due_date < today` and not completed/cancelled | no |
| High Priority | assigned | priority in (high, critical) | no |
| Recently Updated | org | all, sorted by `updated_at` desc | no |
| Completed Today | assigned | `status === completed` and `completed_at` is today | no |
| Awaiting My Action | assigned | status in (open, in_progress, waiting) | no |
| Team Workload | section | status in (open, in_progress) | **yes** |

## Task row fields

Every widget row shows exactly what the spec requires and nothing more:
task number, title, a priority badge, a status badge, due date, and an
Origin module chip/label — reusing `TasksAPI.fetchTaskLinksBulk()` and
`TasksAPI.fetchOriginRecords()` (both unchanged from T2A) to resolve
origin, batched once per base-fetch group over only the union of tasks
actually being *displayed* across that base's widgets (never the full
200-row base fetch) — the same N+1-avoidance discipline T2A/T2E already
established. Clicking a row navigates to the existing `task-detail`
route (`#task-detail?id=...`) — no new detail page.

## Navigation

**"View All" opens the existing Task List, never a second list page.**
Each widget declares a `viewAllParams` object (e.g. `{ scope: 'my',
dueFilter: 'today' }`) that becomes the query string of an
`#tasks?...` link. `js/views/tasks.js`'s `render()` already read
`params.scope`/`params.status` as deep-link entry points (a T2A code
comment had explicitly flagged this exact "a future Dashboard widget
linking into a pre-filtered list" case as the motivating reason); this
milestone extends that same handling to also read and validate
`params.priorityFilter`/`params.dueFilter`/`params.originFilter`,
checked against the identical value sets the Task List's own toolbar
dropdowns offer — the same fail-closed posture already used for
`scope`/`status` (an unrecognized value is simply ignored, never
applied). No new filtering capability was invented; the Task List's own
existing client-side quick-filter state fields are reused verbatim.

**Nav entry point.** The "Tasks" link in the sidebar/topbar/bottom nav
(`js/views/shell.js`) now points at `#task-dashboard` instead of
`#tasks` — the Dashboard is the new landing page for the Tasks section.
The Task List remains fully reachable (its own "View Task List" link on
the Dashboard, and every widget's "View All"). `tasks.js`/`task-
detail.js` were updated to pass `'task-dashboard'` as their own
`AppShell.topbarHtml`/`bottomNavHtml` active-route identifier so the nav
link stays highlighted consistently across all three task-related pages.

## Permissions

**No authorization logic was duplicated.** Widget visibility
(`supervisorOnly`) is a pure display-layer check
(`AppShell.isSupervisorOrAbove()`), exactly mirroring the same
already-established client-side mirror pattern the Task List uses for
its own "Team Tasks" scope tab — the real enforcement is `list_tasks()`
/ RLS, which a hidden widget never even queries against. Team Workload
is shown only to supervisors and admins.

**Team Workload's section resolution:**
- A supervisor with a real supervised section fetches that section's
  tasks only (`owningSectionId` = their first supervised section).
- An admin with no supervised section of their own falls back to an
  **org-wide** fetch — mirroring `can_view_task()`'s own admin bypass
  (an admin's real authority is org-wide, not scoped to a guessed
  section).
- A non-admin supervisor with no supervised sections gets an honest
  **empty** widget, not a guessed section and not an error — the same
  edge-case handling the Task List's own "Team Tasks" scope already
  established in T2A.

## Responsive behavior

`.task-dashboard-grid` is a CSS grid: 4 columns at desktop width
(≥900px), 2 at tablet (640–899px), 1 at mobile (<640px) — the same
900px/640px breakpoints already used throughout this app (T2E's own
linked-records card grid, the sidebar-nav split, `.data-table`'s
card-transform), not new thresholds. Confirmed by an actual
`getComputedStyle` measurement of `grid-template-columns` at three
viewport widths in the headless test harness (see §Testing) — not just
inspection of the CSS rule.

## Performance

Per dashboard load: at most 3 `list_tasks()` calls (one per base
actually needed by a visible widget — 2 for plain staff, since Team
Workload's `section` base never fetches when the widget itself is
hidden) plus, per base group, one batched `fetchTaskLinksBulk()` +
`fetchOriginRecords()` pair scoped only to the tasks actually displayed
by that base's widgets (never the full 200-row fetch). No SQL, RPC, or
backend change was made to support this. No per-widget re-fetch: a
widget re-renders from its base's already-fetched data, never issuing
its own request.

## Testing

**Standing constraint honored: this environment has no staging/
production credentials and must never connect to either** — no browser
test against the real (production-configured) app was possible or
attempted.

What was run:
1. `node --check` on every touched/added file — passes.
2. The same isolated, non-repo headless-Chromium harness used for
   T2A–T2E (mocked data, zero network), extended with:
   - Fixture tasks assigned to the test user with a due date of exactly
     today and a task completed earlier today (the generator's own
     fixture loop never lands on "today" itself), plus a task link so
     one dashboard-widget row exercises the same origin-resolution path
     already regression-tested in the Task List.
   - The real `css/style.css` stylesheet (not previously loaded by this
     harness, since no earlier milestone needed a computed-layout
     check) — added specifically so the responsive grid check below
     measures actual rendered CSS, not just asserts the rule exists in
     the stylesheet text.
   - Test hooks in the mock `list_tasks` RPC to simulate a single failed
     base-fetch (for the retry test) and an artificially slow one (for
     the loading-state test) — both inert/no-op for every pre-existing
     T2A–T2E scenario.

   Verified:
   - **Widget rendering**: all 8 widgets render for a supervisor (7 for
     plain staff, Team Workload correctly absent); each widget's count,
     row count, and specific content match the fixture data for My
     Tasks, Due Today, Overdue, High Priority, Completed Today, and
     Awaiting My Action; Recently Updated renders without error over
     the full org-wide fixture set.
   - **Origin resolution** inside a widget row: a linked task shows its
     resolved origin label; unlinked tasks show "Standalone".
   - **"View All" links**: correct `#tasks?...` href with the expected
     query params for every widget.
   - **Deep-link wiring end-to-end**: a widget's own "View All" href fed
     into `TasksView.render()` actually sets the Task List's
     `scope`/`dueFilter`/`priorityFilter`/`status` state — not just that
     the href string looks right.
   - **Task row navigation**: a widget row's href matches the existing
     `#task-detail?id=...` pattern.
   - **Team Workload permission/fallback**: hidden for plain staff;
     section-scoped count for a supervisor with a real supervised
     section; a strictly larger org-wide count for an admin with no
     supervised section (proving the fallback path actually ran, not
     just that some number appeared); an honest zero/empty state for a
     non-admin supervisor with an empty supervised section.
   - **Widget failure isolation + retry**: with the `org` base's first
     `list_tasks()` call forced to fail, Recently Updated shows an error
     banner and a retry button while My Tasks (`assigned` base) and Team
     Workload (`section` base) render normally and are unaffected;
     clicking retry recovers Recently Updated without touching the other
     widgets.
   - **Loading state**: with an artificial RPC delay, a spinner is
     visible mid-flight and is replaced by real content once the fetch
     resolves.
   - **Empty state**: Team Workload's empty-section case renders the
     dedicated empty-state message, not a blank panel or an error.
   - **Responsive**: `.task-dashboard-grid`'s computed
     `grid-template-columns` resolves to 4 columns at 1280px, 2 at
     800px, and 1 at 400px.
   - **Full regression**: every pre-existing T2A/T2B/T2C/T2D/T2E
     scenario re-run in the same session still passes unmodified.
   - Zero JavaScript errors across every scenario.
3. **Not independently re-verified**: real Supabase-backed auth/session
   flow, and any real-device rendering (the harness's `getComputedStyle`
   check confirms the CSS grid's column count at exact pixel widths, not
   a physical device's rendering) — both require either credentials this
   environment does not have and must not use, or hardware this
   environment does not have.

## Known limitations

1. **No total-count column.** Every widget's count is `items.length`
   over a `limit: 200` fetch, with a `+` suffix if the cap is hit —
   never a fabricated or separately-queried exact count beyond that
   cap. Same disclosed shape as the Task List (docs/40).
2. **No date-range, priority, multi-status, or `updated_at`-ordering
   parameter on `list_tasks()`.** Every widget's specific filter is
   applied client-side over a broader fetch, not server-side — the same
   already-disclosed limitation and workaround docs/40 established for
   the Task List's own quick filters.
3. **"Completed Today" is scoped to "assigned to me AND completed
   today," not "completed by me today."** `list_tasks()` has no
   `completed_by` filter — only `assigned_to_me` — so a task someone
   else completed today, on which the viewer is merely an assignee,
   correctly still counts; a task the viewer personally completed today
   but is not (or is no longer) assigned to would not appear. Documented
   here rather than silently assumed.
4. **Team Workload's admin fallback is org-wide, not "all sections I
   supervise."** An admin with no supervised section of their own sees
   every open/in_progress task in the organization, not a synthesized
   multi-section view — consistent with `can_view_task()`'s own
   org-wide admin bypass, but worth knowing if an admin also happens to
   supervise one specific section (their fallback still shows the whole
   org, not just that section).
5. **No analytics.** Completion rate, average completion time,
   burndown, trend charts, and heat maps are explicitly out of scope for
   this milestone per the spec and are not present in any form —
   counts shown are always literal, current-state counts, never a
   computed metric.

## Future enhancements

- Analytics widgets (completion rate, average completion time,
  burndown/trend charts) — explicitly deferred, a separate milestone.
- If `list_tasks()` is ever extended with date-range/priority/
  multi-status/`updated_at`-ordering parameters (a future, separately-
  scoped backend change), the corresponding widgets' client-side filters
  could be replaced with server-side ones — the widget rendering itself
  wouldn't need to change, only `_fetchBase()`'s call parameters.
- A real total-count RPC/column, removing the `limit: 200` cap's `+`
  suffix in favor of an exact count.
- Saved/configurable widget layouts, drag-and-drop reordering, and
  custom widgets — explicitly out of scope per the spec.
