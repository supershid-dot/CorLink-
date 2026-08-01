# 40 — Task List Implementation (T2A)

Implements exactly the List surface of docs/39's Task Application design:
My Tasks, Assigned By Me, Team Tasks, and Organization Tasks as one
shared list component. Task Detail, Dashboard, Comments, Timeline,
Attachments, a dedicated Watchers panel, Related Tasks, and Saved
Filters are all explicitly out of scope here (see §Future Extension
Points) — this milestone is the List only.

## Architecture

**No SQL, index, or RPC was added.** Every mutation goes through the
existing `complete_task`/`cancel_task`/`assign_task`/`unassign_task`/
`watch_task`/`unwatch_task` RPCs exactly as R2–R9 shipped them, and every
read goes through `list_tasks()` plus three small new bulk reads (below)
— all plain `SELECT`s against tables that already carry their own RLS,
the same pattern `fetchTaskComments`/`fetchTaskAssignments` in
`js/data/tasks-api.js` already used for single-task reads.

**Files:**
- `js/views/tasks.js` (new) — `TasksView`, the entire List component:
  scope tabs, toolbar/filters, table rendering, row actions, pagination.
- `js/data/tasks-api.js` (extended) — three new bulk-read helpers plus
  an origin-module lookup table (see below); nothing existing changed.
- `js/router.js` — unchanged. `tasks` is not in `MODULE_ROUTES`, so it's
  treated the same as `dashboard`: reachable by any authenticated user,
  no Layer 1 module-enablement gate (Shared Task Foundation has no
  `platform_modules` row of its own — it's cross-cutting infrastructure,
  not a toggleable module, matching how the backend itself was designed).
- `js/app.js` — registers the `tasks` route.
- `js/views/shell.js` — adds a "Tasks" nav link to the sidebar, topbar,
  and mobile bottom nav (three lines, one per surface — no new
  permission logic, just three more calls to the same `item()`/`link()`
  helpers every other nav entry already uses).
- `css/style.css` — one new block (`.row-actions-menu-wrap` /
  `.row-actions-menu`), a per-row overflow menu using the same visual
  language as the existing `.user-menu-dropdown` (this app had no
  generic per-row action menu before). Everything else (`.data-table`,
  `.panel`, `.page-header`, `.tabs`, `.list-toolbar`, `.badge` +
  variants, `.empty-state`, `.search-box`, `.field-hint`,
  `.deadline-remaining--overdue`) is reused as-is, unmodified.
- `index.html` — adds the `tasks.js` script tag and bumps the `?v=`
  cache-buster on every file this milestone touched (`style.css`,
  `tasks-api.js`, `shell.js`, `app.js`, plus the new `tasks.js` tag) —
  the exact gap R9 (docs/38) found and fixed for R4–R8 is not repeated
  here.

### Components

`TasksView` is a single object (same shape as `EntryView`/
`PrisonerLettersView`) with one `_state` object driving everything:
`scope`, `status`, `teamSectionId`, three client-side quick-filter
fields (`priorityFilter`/`originFilter`/`dueFilter`), `search`, and
`limit`. One `_shell()`/`_bindShell()` render pass builds the page
chrome and scope tabs; `_loadAndRender()` does the actual fetch + bulk
reads + render for whichever scope is active. There is exactly one
table-rendering code path (`_panelHtml`/`_rowHtml`) shared by all four
scopes — scope only changes which `list_tasks()` arguments get built
(`_fetchArgs()`) and which quick-filters apply afterward
(`_visibleItems()`), never a second component.

### Origin resolution (bulk, not per-row)

`list_tasks()` returns bare task rows — no assignee names, no
module/link info. Rather than one extra round trip per row (which for a
25-row page across 5 possible modules would mean up to 125 calls),
`_loadAndRender()` does exactly:

1. `list_tasks()` — 1 call.
2. `TasksAPI.fetchTaskLinksBulk(ids)` — 1 call (`task_links` filtered by
   `task_id IN (...)`).
3. `TasksAPI.fetchTaskAssignmentsBulk(ids)` — 1 call.
4. `TasksAPI.fetchMyWatchedTaskIds(ids, userId)` — 1 call.
5. `TasksAPI.fetchOriginRecords(links)` — up to 5 calls, one per module
   actually present on the page (never one per row).

At most 8 calls per page load, bounded by page size and module count,
not by row count — the same N+1-avoidance discipline the rest of this
codebase already applies elsewhere.

Every one of these reads is a plain `SELECT` against a table with its
own existing RLS. A `task_links` row (or a linked record) this viewer
can't see simply never comes back — the same fail-closed guarantee
already verified for every module integration (R4–R8) and for
`get_task`/`list_tasks` themselves. This file adds no authorization
logic; it relies entirely on RLS to decide what comes back, exactly like
`fetchTaskComments`/`fetchTaskAssignments` already did before this
milestone.

`internal_request` links have no page of their own — same as
`request-detail.js`/`entry-detail.js`, they're only ever viewed embedded
in their parent's Info Requests tab — so an internal-collaboration
origin chip routes to the parent Request/Entry (via
`parent_request_id`/`parent_entry_id`, whichever is set) instead of a
route that doesn't exist. If a link is visible but its target record
isn't independently visible to this viewer, the origin chip is simply
omitted for that link rather than rendering a broken or misleading
reference — same "visible link, not necessarily navigable" contract
docs/39 committed to.

## Permissions

Every row action mirrors the real RPC's own authorization predicate,
copied directly from `supabase/patch-shared-task-foundation.sql`:

| Action | Client-side mirror | Real enforcement |
|---|---|---|
| Complete | `canManage(t) OR isActiveAssignee(t)`, only when `status ∈ {in_progress, waiting}` | `complete_task()`: creator, active assignee, scoped supervisor+, or super admin — plus the status-transition trigger |
| Cancel | `canManage(t)`, only when `status ∈ {draft, open, in_progress, waiting}` | `cancel_task()`: creator, scoped supervisor+, or super admin |
| Assign to Me | `canManage(t)` and not already assigned | `assign_task()`: creator, scoped supervisor+, or super admin |
| Unassign Me | always shown if currently assigned | `unassign_task()` explicitly allows `p_user_id = auth.uid()` unconditionally |
| Watch / Unwatch | always shown | `watch_task()` only requires `can_view_task()` (already true — the task is in the list); `unwatch_task()` has no further check |

`canManage(t)` is `is_super_admin() OR t.created_by === me OR
(isSupervisorOrAbove(me) AND t.organization_id === me.org_id AND
(t.owning_section_id IS NULL OR t.owning_section_id ∈ mySectionIds))` —
a direct restatement of `cancel_task`/`assign_task`'s shared predicate,
using `AppShell.isSupervisorOrAbove()` (existing) and
`RequestsAPI.mySections()` (existing — the same `my_section_ids()` RPC
wrapper `entry.js` already uses for its own section-membership checks).
**No new authorization logic was written for this milestone** — every
predicate above is either reused verbatim or a direct restatement of an
existing RPC's own `IF NOT (...)` guard. The RPC itself remains the real
boundary; hiding an action here that the RPC would still allow is a
missed convenience, not a hole — but nothing shown here is ever an
action the RPC would actually reject, verified against every predicate's
exact source in `patch-shared-task-foundation.sql`.

**Scope visibility**: Team Tasks only appears in the nav for
`isSupervisorOrAbove()`; Organization Tasks only for `isAdmin()` — nav
hiding, not the real boundary (`list_tasks()`'s own RLS is), same
posture the rest of this app already takes for every other nav item.

**Organization Tasks** always scopes to the viewer's own
`organization_id`. `is_admin()` (mcs_admin/authority_admin) is
org-scoped in the real RLS (`can_view_task`'s admin branch still
requires `organization_id = get_my_org_id()`); `is_super_admin()` is the
only cross-org bypass, and this milestone does not add an org-picker for
that rare case — deliberately, to avoid building UI for a scenario the
List's own `list_tasks()` call doesn't need to special-case.

## Responsive behavior

Desktop/tablet/mobile all reuse the existing `.data-table` +
`data-label` convention (`css/style.css`'s existing `@media (max-width:
640px)` block, unmodified) — the same mechanism `entry.js`/
`requests.js`/`prisoner-letters.js` already rely on for their own list
tables. Below 640px, the table becomes a stacked card list with no
separate mobile markup; above it, a normal table. Page size is 25
(desktop/tablet) or 15 (`window.matchMedia('(max-width: 640px)')`,
mobile), matching the T2A spec's stated defaults.

## Testing

**Standing constraint honored: this environment has no staging/
production credentials and must never connect to either.**
`js/config.js` carries the real production Supabase URL, so no browser
test against the live app was possible or attempted.

What was actually run:
1. **Static validation** — `node --check` on every touched JS file
   (`tasks-api.js`, `tasks.js`, `shell.js`, `app.js`, `router.js`): all
   pass.
2. **Isolated headless-browser test** — a throwaway harness (outside the
   repo, in the scratchpad directory, not committed) that loads the
   *real* `tasks-api.js` and `tasks.js` files into a headless Chromium
   page with `getSupabase()`/`Auth`/`Router`/`AppShell` replaced by
   in-memory mocks — no network call of any kind, real or mocked-remote,
   ever leaves the page. Verified:
   - Staff sees only My Tasks/Assigned By Me; a supervisor additionally
     sees Team Tasks; an admin additionally sees Organization Tasks.
   - Row-action permission mirroring: a task assigned-to-but-not-
     created-by the viewer correctly offers Complete + Unassign Me but
     NOT Cancel/Assign (manage-only actions), matching
     `complete_task`/`cancel_task`'s different predicates exactly.
   - Origin chip renders a clickable link with the linked request's own
     reference number for a linked task, and is absent/non-navigable
     logic was exercised via the internal_request parent-routing path.
   - Priority quick-filter correctly narrows the visible row count.
   - Assign-to-Me mutation round-trips through the mocked RPC and
     re-renders without error.
   - Load More: with 30 underlying mock tasks and a 25-row default page,
     the button appears at 25/30, loads the remainder on click, and
     disappears once all 30 are shown.
   - True-empty vs. filtered-empty: a supervisor whose only supervised
     section has zero tasks sees "No tasks in this section yet" (the
     true-empty message), not "No tasks match these filters."
   - Zero JavaScript errors across every scenario.
3. **Not independently re-verified**: the `.data-table` mobile
   card-transform itself (pre-existing CSS, unmodified, already relied
   on by four other views) and the real Supabase-backed auth/session
   flow (would require staging credentials this environment does not
   have and must not use).

## Known Limitations (disclosed, not defects)

`list_tasks()` (`supabase/patch-shared-task-foundation.sql`) takes
`organization_id`, `owning_section_id`, `status`, `assigned_to_me`, and
`limit` — no `created_by`, `priority`, module, or date-range parameter,
and no `OFFSET`. docs/39 §7 already flagged every one of these as
"future RPC parameter" before this milestone started; T2A's own brief
("Do not create... RPCs unless a genuine backend defect is discovered")
means none of them were added here. Concretely:

- **Assigned By Me** has no server-side creator filter. It fetches the
  same paged, most-recent-first window every other scope would for the
  same filters, then narrows to `created_by === me` client-side. A field
  hint on that scope discloses this: an older task you created can fall
  outside the fetched window if you haven't narrowed with Search. This
  is the one place this milestone's implementation is honestly weaker
  than "true server-side scoping" — a `p_created_by` parameter on
  `list_tasks()` would fix it properly, and is the leading candidate for
  T2A's own follow-up rather than something silently worked around.
- **Priority, Origin Module, and Due Date** filters apply only to the
  currently-loaded page, not the full underlying dataset — exactly the
  tradeoff docs/39 §7 pre-committed to.
- **Pagination** ("Load more") re-issues `list_tasks()` with a larger
  `p_limit` each time rather than using a real `OFFSET` — because
  `list_tasks()` has no offset parameter to use. This is a different
  mechanism from the `OFFSET`-based "Load More" already used by the
  reverse Supporting Tasks panels (`list_task_request_links` etc.),
  which do have a real offset RPC parameter — not a bug, just a
  consequence of which RPC this milestone was told to reuse as-is.
- **Search** matches task number/title on the currently-loaded page,
  except an *exact* task-number match, which does a real, unbounded,
  RLS-protected direct lookup (`TasksAPI.findTaskByNumber`) regardless
  of what's currently loaded.

## Future Extension Points

- **Task Detail** (T2B) — clicking a task number today shows a
  placeholder alert ("Task Detail isn't built yet") after confirming via
  a real RLS-protected lookup that the task exists and is visible to the
  viewer, rather than a dead link or silent no-op.
- **`list_tasks()` parameter expansion** (T4 per docs/39 §12) —
  `p_created_by`, `p_priority`, module, and date-range parameters would
  let every "client-side quick filter" above become a real, full-dataset
  server-side filter.
- **Dashboard, Comments, Timeline, Attachments, a dedicated Watchers
  panel, Related Tasks, Saved Filters** — all explicitly out of scope
  per the T2A brief, unchanged from docs/39's roadmap.
