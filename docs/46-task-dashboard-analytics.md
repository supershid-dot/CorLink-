# 46 — Task Dashboard Analytics & Supervisor Metrics (T3B)

Enhances the existing Task Dashboard (docs/45) with five KPI summary
cards: Task Status Summary, Priority Summary, Due Date Summary,
Completion Summary, and a supervisor/admin-only Team Workload Summary
grouped by section. Explicitly not implemented, per spec: task editing,
attachments, Related Tasks, Saved Views, calendar, Kanban, Gantt, and
reports export. No chart or graph library was added — every card is a
simple stat row with an optional progress bar, exactly as specified.

## Architecture

**No SQL, RPC, table, policy, or index was added.** All five cards are
built entirely from data the Task Dashboard already fetches (docs/45) —
`TasksAPI.listTasks()` — plus one already-existing, already-used-
elsewhere plain read, `AdminAPI.listSectionsByOrg()` (a `SELECT` against
`sections`, unchanged), for section-name resolution in one specific
fallback case below.

**The four general cards (Task Status, Priority, Due Date, Completion)
add ZERO additional requests.** They reuse the exact same `'assigned'`
base fetch (`listTasks({ assignedToMe: true, limit: 200 })`) that six of
T3A's own eight widgets already depend on — each card is just a
different client-side aggregation over data already sitting in memory
by the time these cards render.

**Team Workload Summary is a "grouped by section" version of T3A's own
single-section Team Workload widget**, and reuses the same `'section'`/
`'org'` base logic wherever it can, adding new requests only where the
existing single-section fetch genuinely doesn't cover the data needed:

| Supervised sections | Data source | Extra requests |
|---|---|---|
| 0, not admin | none — honest empty result | 0 |
| 0, admin | reuse the already-fetched `'org'` base, group by `owning_section_id` | 0 |
| 1 | reuse the already-fetched `'section'` base directly (identical query to T3A's own `_fetchBase('section')`) | 0 |
| 2+ | reuse `'section'` base for the first section; fetch the **rest** directly | bounded by `(section count − 1)`, never by task count |

The 2+-section case is the only one that issues new requests, and it's
bounded by how many sections a person supervises (realistically 1–3),
the same "one extra query per grouping unit actually present, never per
task" discipline T2E's own extras queries already established (docs/44)
— not per-task N+1, and never a request this file could have avoided by
reusing something already fetched.

## Metrics

Every card's rows are literal counts over a client-side filter — the
same "broad fetch, then filter" pattern established in docs/45/docs/40
for the reasons `list_tasks()` still doesn't support server-side
date-range, priority, multi-status, or `completed_at`-range filtering.
Two places reconcile the spec's own generic wording against this app's
actual schema, documented rather than silently resolved:

- **Task Status Summary shows six rows, not the five the spec names.**
  `patch-shared-task-foundation.sql`'s own `status` `CHECK` constraint
  has six values (`draft`, `open`, `in_progress`, `waiting`,
  `completed`, `cancelled`); the spec's list omits `waiting`. Dropping it
  would mean a task in that real, reachable status simply vanishes from
  the summary instead of being counted anywhere — so a sixth "Waiting"
  row was added rather than silently under-counting.
- **Priority Summary's "Medium" is the schema's `normal`.** The
  `priority` `CHECK` constraint has exactly four values (`low`,
  `normal`, `high`, `critical`) — the same count the spec names
  (Critical/High/Medium/Low), just with different naming for the third
  tier. "Medium" is used as the display label; `priorityFilter=normal`
  is what's actually sent to the Task List (the value the toolbar's own
  Priority dropdown already uses).

**Due Date Summary's four rows are not fully mutually exclusive by
design.** "Due This Week" reuses `js/views/tasks.js`'s own existing
`dueFilter=week` semantics verbatim (`due_date` between today and
+7 days inclusive) — which already includes today, overlapping with the
"Due Today" row. This was a deliberate choice over inventing a new,
narrower "week excluding today" definition: it guarantees the card's
own count and its "View All" destination's row count always match
exactly, which matters more for user trust than the rows summing to a
clean total. "Overdue" excludes completed/cancelled tasks, matching
T3A's own Overdue widget; "No Due Date" is a simple `due_date IS NULL`
count, unaffected by status.

**Completion Summary's three rows are rolling windows, not calendar
boundaries, and are nested/cumulative.** "Today" = exact date match,
"This Week" = last 7 days ending today, "This Month" = last 30 days
ending today — a task completed today counts in all three, by design
(the natural reading of "completed today / this week / this month" as
increasingly-wide lookbacks, not three disjoint buckets). The
denominator for each row's progress bar is the count of completed tasks
among the viewer's assigned tasks (not their total task count), since
that's the more meaningful proportion for a card about completion.

## Navigation

Every KPI row deep-links into the existing Task List
(`js/views/tasks.js`) — no new page. Two small, backend-free extensions
to the Task List were needed so these new links actually reproduce the
count they promise:

1. **A `completedFilter` quick filter** (`today`/`week`/`month`),
   structurally identical to the existing `dueFilter` pattern — added a
   `_state.completedFilter` field, a toolbar dropdown, deep-link
   validation, and a client-side filter over `completed_at` (already
   returned by `list_tasks()`, no backend change). Without this, the
   three Completion Summary rows would have had no way to reproduce
   their own counts on the List side — every one would have collapsed
   onto the same `status=completed` view regardless of which row was
   clicked.
2. **`teamSectionId` as a general section-narrowing deep-link param**,
   usable with either `team` or `organization` scope. `list_tasks()`
   already accepts `p_organization_id` and `p_owning_section_id`
   together — this only wires the UI to pass both when narrowing to one
   specific section from a KPI row. Needed for Team Workload Summary's
   per-section stats: a section the viewer genuinely supervises links
   via `scope=team` (already validated against their real supervised-
   section list downstream by `list_tasks()`'s own RLS); a section only
   reachable through an admin's org-wide fallback links via
   `scope=organization` instead, since `tasks.js`'s own `team`-scope
   guard rejects that scope entirely when the viewer supervises zero
   sections. Neither path is a new trust decision — `teamSectionId` only
   ever narrows a real, RLS-governed `list_tasks()` call; an
   unrecognized or unauthorized id simply yields zero rows server-side,
   the same fail-closed guarantee every task read in this app already
   has.

## Permissions

**No authorization logic was duplicated.** The four general cards are
visible to everyone (they summarize the viewer's own assigned tasks,
already fully visible to them elsewhere on this same dashboard). Team
Workload Summary is gated by the same `AppShell.isSupervisorOrAbove()`
display-layer mirror T3A's own Team Workload widget already uses — the
real enforcement is `list_tasks()` / RLS underneath, unchanged. Its
per-section admin-fallback grouping mirrors `can_view_task()`'s own
admin bypass exactly as T3A's `_fetchBase('section')` already
established: an admin with no personally-supervised section sees every
section present in the org-wide fetch, not a guessed one.

## Responsive behavior

New cards use the exact same `.task-dashboard-grid` T3A already
established (4 columns ≥900px, 2 at 640–899px, 1 at <640px) — no new
breakpoints, no separate layout. Team Workload Summary's per-section
rows stack vertically within its one card regardless of breakpoint (a
grouped table doesn't need its own column-count behavior; the grid
governs the number of *cards* per row, not what's inside one card).

## Performance

Per dashboard load: the four general KPI cards add **zero** additional
`list_tasks()` calls beyond what T3A already issues. Team Workload
Summary adds **zero** additional calls in three of its four cases (0
sections, 1 section, or the admin org-wide fallback) and at most
`(supervised section count − 1)` calls in the fourth (2+ supervised
sections) — bounded by how many sections a person supervises, never by
how many tasks exist. No KPI card issues its own per-card request; every
card's numbers come from a base fetch already shared with other widgets.

## Testing

**Standing constraint honored: this environment has no staging/
production credentials and must never connect to either** — no browser
test against the real (production-configured) app was possible or
attempted.

What was run:
1. `node --check` on every touched/added file — passes.
2. The same isolated, non-repo headless-Chromium harness used for
   T2A–T3A (mocked data, zero network), extended with independently-
   computed expected counts for every card (worked out by hand from the
   fixture data, then verified against the rendered DOM — not just
   "does it render without throwing"). Verified:
   - All four general KPI cards' every row count, for a plain staff
     viewer, matching hand-computed values from the fixture set (Status:
     draft/open/in_progress/completed = 1 each, waiting/cancelled = 0;
     Priority: high = 2, "Medium" = 1, low = 1, critical = 0; Due Date:
     overdue/today/none = 1 each, week = 2 (deliberately overlapping
     today); Completion: today/week/month = 1 each).
   - The "Medium" label is genuinely what's rendered for `priority =
     'normal'`, not the schema's own internal name leaking through.
   - The "Waiting" status row renders (count 0 in this fixture set) —
     confirming it isn't silently dropped despite not being in the
     spec's own named list.
   - Every KPI row's href, and end-to-end: feeding a generated href into
     `TasksView.render()` reproduces both the correct filter *state* and
     the exact row count the KPI card itself displayed.
   - Team Workload Summary's all four section-count branches: exactly 1
     supervised section (reuses the base fetch, zero extra requests,
     stats independently verified against hand-computed SECTION_MINE
     totals: Assigned 20 / Open 3 / In Progress 5 / Completed 6 /
     Overdue 4); exactly 2 supervised sections (the second section's
     data — not silently dropped — arrives via one bounded extra
     request, verified count 15); an admin with zero supervised sections
     (org-wide fallback reusing the `'org'` base with zero extra
     requests, both org sections appear with names resolved via
     `AdminAPI.listSectionsByOrg()`, and the non-supervised section's
     link correctly uses `organization` scope rather than `team`); a
     supervisor with one real, named, currently-empty section (shows
     that section with honest zero counts, not a blank state); a
     supervisor with genuinely zero supervised sections (the true
     "Nothing here right now" empty state).
   - The admin-fallback deep link was followed end-to-end into
     `tasks.js`, confirming `organization` scope + `teamSectionId`
     together narrow to exactly the right section's row count (15).
   - **Independent widget failure + retry**: with the `'assigned'` base
     (shared by all four general KPI cards and six of T3A's own eight
     widgets) forced to fail once, every card/widget on that base shows
     its own error+retry while Team Workload Summary (a different base)
     is completely unaffected; retrying recovers all of them together
     (they share one underlying fetch, so one retry click is correct,
     not a bug).
   - Responsive: `.task-dashboard-grid` unchanged at 4/2/1 columns
     across 1280px/800px/400px, confirmed via `getComputedStyle`.
   - **Full regression**: every pre-existing T2A/T2B/T2C/T2D/T2E/T3A
     scenario re-run in the same session still passes unmodified (two
     T3A-era widget-count assertions were updated to use an ID-prefix
     selector instead of the shared `.task-widget-card` class, since
     T3B's KPI cards now also carry that class for consistent styling —
     a test-selector correction, not an application behavior change).
   - Zero JavaScript errors across every scenario.
3. **Not independently re-verified**: real Supabase-backed auth/session
   flow (no credentials in this environment, per standing constraints),
   and any real-device rendering beyond the harness's `getComputedStyle`
   measurement.

## Known limitations

1. **No total-count column, same as docs/45.** Every card's counts are
   exact only up to the shared `limit: 200` base fetch's own cap.
2. **Task Status Summary's sixth "Waiting" row is an addition beyond
   the spec's own named list** — included so the card's counts are
   honest and complete rather than silently dropping a real status.
3. **Priority Summary's "Medium" label maps to the schema's `normal`
   value** — a naming reconciliation, not a new priority tier.
4. **Due Date Summary's "Due Today" and "Due This Week" rows overlap**
   by design (reusing the Task List's own existing week-filter
   semantics), so the four rows do not sum to a clean total. Chosen so
   every row's count exactly matches its own View All destination.
5. **Completion Summary's three windows are rolling (last 7/30 days),
   not calendar week/month, and are nested/cumulative**, not mutually
   exclusive — a task completed today is counted in all three rows.
6. **Team Workload Summary excludes tasks with no `owning_section_id`**
   — there is no section to group them into. These tasks remain fully
   visible elsewhere on the dashboard (My Tasks, Recently Updated,
   etc.), just not attributed to any section here.
7. **The admin org-wide fallback groups by whatever sections are
   present in a 200-row-capped fetch** — same disclosed cap as every
   other base fetch on this dashboard; a very large organization's least-
   recently-created tasks could fall outside that window.
8. **No analytics computations.** Completion rate, average completion
   time, burndown, trend charts, and heat maps remain explicitly out of
   scope (per spec) and are not present in any form — every number shown
   is a literal, current-state count, never a computed or historical
   metric.

## Future enhancements

- Completion-rate and average-completion-time metrics, burndown/trend
  charts — explicitly deferred (out of scope for this milestone).
- If `list_tasks()` is ever extended with a `completed_at` range
  parameter or a multi-section `p_owning_section_id` array (future,
  separately-scoped backend changes), the corresponding client-side
  filters/per-section extra-fetch loop here could be replaced with
  server-side equivalents without changing how any card renders.
- A real total-count RPC/column, removing the shared `limit: 200` cap
  from every card's denominator.
- Configurable KPI card selection/ordering — explicitly out of scope
  per the spec (dashboard configuration is excluded).
