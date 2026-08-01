# 39 — Task Application: Architecture & UI Design (T1)

**Status: design only.** Nothing in this document has been built. No SQL,
RPC, or JS was created or modified for T1. This is the information
architecture and UI design for the standalone Task application that will
sit on top of the existing R2–R9 Shared Task Foundation backend, to be
implemented in a later, separately-approved milestone.

## 0. Backend as reviewed (inputs to this design, not redesigned)

Everything below is existing, shipped, R9-approved backend. This design
takes it as fixed and builds UI against it exactly as implemented.

**Core `tasks` table.** `status` ∈ `draft, open, in_progress, waiting,
completed, cancelled` (with a defined valid-transition graph — no reverse
edges from a terminal state). `priority` ∈ `low, normal, high, critical`.
`visibility` ∈ `private, section, organization`. Every task belongs to one
`organization_id` and optionally one `owning_section_id`. `task_number` is
a generated, human-readable identifier (same pattern as Request/Entry
reference numbers).

**Foundation RPCs** (`patch-shared-task-foundation.sql`): `create_task`,
`update_task`, `cancel_task`, `complete_task`, `assign_task`,
`unassign_task`, `watch_task`, `unwatch_task`, `add_task_comment`,
`get_task` (single task + assignees/watchers/comment_count as JSON),
`list_tasks` (org/section/status/assigned-to-me filters, 1000-row cap).
`task_assignments`, `task_watchers`, `task_comments` are plain
SELECT-RLS tables gated by `can_view_task()`.

**Visibility (`can_view_task`)**: creator, completer, an active assignee,
a watcher, `visibility='organization'` for anyone in the org,
`visibility='section'` for anyone in the owning section, a
supervisor-or-above whose scope covers the section (or task has no
section), any org admin, or super admin. This is the single predicate
every Task Detail permission decision in this design derives from.

**Module links (`task_links`, one row per module_key)**: `request`,
`meeting`, `internal_request`, `external_correspondence`,
`prisoner_letter`. A task can be linked to zero, one, or many records
across any mix of these five modules. Each module exposes
`list_task_<module>_links(task_id)` (reverse direction: given a task,
list its linked records in that module) and the module's own detail page
exposes a forward "Supporting Tasks" panel (given a record, list its
linked tasks) — R4 through R8 built the forward direction; T1's Task
Detail page is what builds the reverse direction's UI.

**Roles actually in the system** (`user_assignments.role`, scoped by
`scope_type` ∈ `organization, command, department, division, section`):
`staff`, `supervisor`, `assigned_receiver`, `authority_admin`,
`mcs_admin` (+ a separate super-admin flag). This design maps the
functional titles requested for T1 onto that real model rather than
inventing new roles:

| Requested title | Real role / scope |
|---|---|
| Officer | `staff`, no supervisor scope |
| Supervisor / Section Head | `supervisor` scoped at `section` |
| Department Head | `supervisor` scoped at `department` |
| Command Head | `supervisor` scoped at `command` |
| CP/DCP | `mcs_admin` / `authority_admin` (organization-wide) |
| External organizations | a different `organization_id` entirely — reached only through a dual-org module's own visibility (Requests, Prisoner Letters), never through Task visibility directly |

No new role, scope type, or permission primitive is introduced by this
design — every permission-based UI decision below is a restatement of
`can_view_task()`, `is_supervisor_or_above()`, `is_admin()`, or a
module's own `can_view_<module>()`, never a new rule.

---

## 1. Application Overview

The Task application is the first UI surface where Tasks are a
first-class destination rather than a panel bolted onto another record.
Today, a task is only visible from the record that spawned it (a
Request's Supporting Tasks panel, a Letter's Supporting Tasks panel, an
Entry's Supporting Tasks panel, etc.) or from ad-hoc standalone tasks
with no linked record at all. T1 designs the missing complement: a place
to see and manage *all* the tasks a user has a stake in, regardless of
which module (if any) they came from, plus a Task Detail page that shows
its own linked records rather than only being reachable from one.

Design principles:

- **The task always knows where it came from.** Every task list row and
  the Task Detail header always show origin — "Standalone" or a labeled
  chip identifying the linked module and record — never an unlabeled
  bare task.
- **One permission model, restated, not reinvented.** Every affordance
  (edit button, assign control, complete action, comment box) is visible
  exactly when the underlying RPC would succeed, and hidden otherwise —
  no UI-only permission logic that could drift from the RLS/RPC layer.
- **Enterprise scale from the start.** Every list is paginated and
  filterable server-side; nothing loads "all tasks" into the browser.
  `list_tasks`' existing 1000-row cap is treated as a safety ceiling, not
  a page size — real pages are far smaller (see §4).
- **Fail-closed, not fail-ugly.** A task the viewer can't see never
  appears in a count, a list, or a linked-record chip — consistent with
  every module integration's own tested behavior (0 rows, never an
  error, for hidden records).

---

## 2. Navigation

A new top-level **Tasks** entry is added to the existing shell
navigation (`js/views/shell.js`'s nav model), positioned after the
module entries it draws from (Requests, Meetings, Entry, Internal
Collaboration, Prisoner Letters) and before Admin — consistent with the
existing ordering convention of "operational modules, then
administration."

**Tasks nav item expands to:**

- **My Tasks** (default landing view when "Tasks" is clicked)
- **Assigned By Me**
- **Team Tasks** *(only rendered for `is_supervisor_or_above()` — hidden
  entirely for plain staff, not shown-disabled)*
- **Organization Tasks** *(only rendered for `is_admin()`)*
- A persistent **+ New Task** action, always visible in the nav region
  (creating a standalone task requires no special role beyond being an
  active user of an org — same gate `create_task` already enforces)

A secondary, always-visible **global search field** sits in the shell
header (not nested under Tasks) so a user can jump to a task by number
or title from anywhere in the app, mirroring how Requests/Entry already
surface their own reference-number search.

**Breadcrumb convention:** `Tasks / My Tasks / TSK-2026-000412` on List
→ Detail navigation; `Requests / REQ-2026-00812 / TSK-2026-000412` when a
task is reached by drilling into a Supporting Tasks panel from a parent
record instead — the breadcrumb itself is the "how did I get here"
affordance, independent of the origin chip inside the page.

---

## 3. Information Architecture

```
Tasks (top-level)
├── My Tasks                     list view, default filters: assignee = me, status != cancelled
├── Assigned By Me               list view, default filters: created_by = me
├── Team Tasks                   list view, scope = my section(s)/division/department per supervisor scope
├── Organization Tasks           list view, scope = org-wide (admin only)
├── Task Detail (TSK-YYYY-NNNNNN)
│   ├── Header (number, title, status, priority, origin chip)
│   ├── Details panel (description, dates, section, visibility)
│   ├── Assignees
│   ├── Watchers
│   ├── Linked Records            reverse of every module's own Supporting Tasks panel
│   ├── Comments
│   ├── Attachments                (future — see §11; no attachments RPC exists on tasks today)
│   ├── Timeline / History        derived from audit_logs (record_type='task') + comments, merged
│   └── Related Tasks             (future — see §11; no task-to-task relation exists today)
└── (no separate "Saved Filters" top-level entry — surfaced inside Filters, see §7)
```

Every list view (My Tasks / Assigned By Me / Team Tasks / Organization
Tasks) is the *same* list component with a different default filter
preset — not four different pages — so filter, sort, pagination, and
empty/error/loading states are implemented once and only once.

---

## 4. Dashboard

The Task Dashboard is a distinct landing surface (`Tasks` nav item's
"Overview" tab, shown before "My Tasks" on first visit, with My Tasks one
click away) built from widgets, each independently loading and
independently empty/error-capable — one widget failing to load never
blocks the others.

| Widget | Query shape | Notes |
|---|---|---|
| **Due Today** | assignee = me, due_date = today, status not in (completed, cancelled) | |
| **Overdue** | assignee = me, due_date < today, status not in (completed, cancelled) | Rendered with visual urgency (color, not solely icon — see accessibility note §9) |
| **Awaiting My Action** | assignee = me, status in (open, in_progress, waiting) | The catch-all "what do I still owe" view |
| **Tasks Assigned To Me** | assignee = me, any status, small count/link to My Tasks | Summary tile, not a full list |
| **Recently Updated** | tasks I can view, updated_at desc, small N | Cross-cuts My/Team/Org scope by visibility, not by assignee |
| **High Priority** | assignee = me OR (supervisor scope) , priority in (high, critical) | |
| **Completed Today** | completed_by = me, completed_at = today | Positive-reinforcement widget, deliberately small |
| **My Team's Workload** | *(supervisor+ only)* count of open/in_progress tasks grouped by assignee within scope | Supervisor-only widget — simply absent from the dashboard grid for staff, not rendered empty |

Widgets are read-only entry points — clicking a widget navigates to the
List view pre-filtered to that widget's query, never manages tasks
inline on the dashboard itself. This keeps the dashboard a single
well-tested filter-application pattern rather than a second place mutual
task actions could happen.

---

## 5. Task List (My Tasks / Assigned By Me / Team Tasks / Organization Tasks)

**Columns (desktop table view):** Status (icon+label), Priority (icon,
color-coded), Task Number, Title, Origin (module chip or "Standalone"),
Assignee(s) (avatar stack, overflow "+N"), Due Date (relative + absolute
on hover, red if overdue), Section, Updated (relative time).

**Row actions** (visible only when the underlying RPC would succeed for
the viewer): Complete, Cancel, Assign/Unassign, Watch/Unwatch — as an
overflow menu, not inline buttons, to keep the row scannable at high
density.

**Empty states** (per view, not a single generic message):
- My Tasks, no filters active: "No tasks assigned to you right now." +
  New Task action.
- My Tasks, filters active and zero matches: "No tasks match these
  filters." + Clear Filters action (distinct from the true-zero case —
  a user should never wonder whether their filter or their workload is
  empty).
- Team/Organization Tasks: same true-zero vs. filtered-zero distinction,
  scoped to the wording ("No tasks in your team right now.").

**Error state:** a single retry-capable inline banner replacing the list
region (not a full-page error) — the shell/nav remains usable so a
failed Task List fetch doesn't strand the user.

**Loading state:** skeleton rows matching the table's real row height
and column layout (not a spinner) — consistent with how large tables
elsewhere in the app should avoid layout shift on load.

**Pagination:** cursor-style "Load more" / infinite scroll on top of
`list_tasks`, page size 25 (desktop) / 15 (mobile), never requesting the
existing 1000-row cap in one call. Sort defaults to `updated_at DESC`
except Assigned By Me, which defaults to `created_at DESC`.

---

## 6. Task Detail

**Header:** Task number, title (inline-editable if the viewer can
`update_task`), Status pill (with the legal-next-status set only, driven
by the same transition graph `valid_task_status_transition()` already
enforces server-side — never offering a status the RPC would reject),
Priority pill, Origin chip.

**Origin chip logic:** if the task has one or more `task_links` rows,
show a chip per linked module (e.g. "Linked: Request REQ-2026-00812") —
clicking navigates to that record's detail page, but ONLY if
`list_task_<module>_links()` actually returned that row (i.e., the
viewer can independently view the linked record too — the existing
"visible link but not necessarily navigable" contract every module
already implements is preserved, not overridden). If the viewer can see
the link exists but not the target record's content, the chip renders as
non-clickable text with a tooltip explaining why, never a dead link or a
silent 403.

**Details panel:** description (rich text, read-only unless editing),
due date, start date, owning section, visibility, created by / created
at.

**Assignees panel:** avatar list with assign/unassign controls (visible
only if the viewer can `assign_task`/`unassign_task` — i.e., can manage
the task, a strictly-narrower-or-equal set than can view it, same
"view ≥ manage" shape every module integration already uses).

**Watchers panel:** simple list + a self-service Watch/Unwatch toggle for
the current viewer (matches `watch_task`/`unwatch_task`'s own
"any viewer may watch" scope — no additional gate needed).

**Linked Records panel:** one section per module that has at least one
link (`list_task_request_links`, `list_task_meeting_links`,
`list_task_internal_collaboration_links`, `list_task_entry_links`,
`list_task_prisoner_letter_links`) — mirrors the Supporting Tasks panel
pattern already shipped on the five module detail pages, just facing the
opposite direction. A task with zero links shows a single "Not linked to
any record" line, not five empty per-module headers.

**Comments panel:** chronological `task_comments` (author, timestamp,
body), add-comment box gated on `can_view_task()` (same predicate that
gates the SELECT — anyone who can see the task can comment, matching
`add_task_comment`'s own authorization).

**Timeline / History panel:** a single merged, chronological feed built
from `audit_logs WHERE record_type = 'task' AND record_id = <task>` 
(created, edited, assigned, unassigned, completed, cancelled,
commented, task_linked, task_unlinked entries — all already-emitted
action types) interleaved with `task_comments`, rendered as one visual
stream so a viewer sees "what happened" and "what was said" in one place
instead of two disconncted lists.

**Related Tasks panel:** *(future — §11)*. No task-to-task relation
exists in the schema today; the panel is designed as an empty
placeholder with a "Related Tasks — coming soon" state, not built.

**Attachments panel:** *(future — §11)*. No `task_attachments` table or
RPC exists today (unlike Requests/Entry, which have their own
attachments tables). Placeholder only, same treatment as Related Tasks.

---

## 7. Filtering

A single filter bar component, shared by every List view, with the
following facets — each maps to an existing column or an existing
`list_tasks` parameter, with the module/creator/updated-date facets
requiring a client-side or a small future RPC-parameter extension noted
inline:

| Filter | Backed by |
|---|---|
| Status | `list_tasks(p_status)` — existing |
| Priority | column filter — existing column, `list_tasks` doesn't take it as a param yet (future RPC parameter, not a T1 build item) |
| Module (origin) | requires joining against `task_links.module_key` — future RPC parameter, noted not built |
| Organization | `list_tasks(p_organization_id)` — existing (admin-only facet, since staff/supervisor are already org-scoped by RLS) |
| Section | `list_tasks(p_owning_section_id)` — existing |
| Assignee | `list_tasks(p_assigned_to_me)` today only supports "me" — an arbitrary-assignee facet is a future RPC parameter |
| Creator | future RPC parameter |
| Due date (range) | future RPC parameter |
| Created date (range) | future RPC parameter |
| Updated date (range) | future RPC parameter |
| Tags | future schema addition — no `tags` concept exists on `tasks` today |

Filters marked "future RPC parameter" are designed now (facet UI, applied
as client-side filters over the page already fetched, capped to correct
page sizes so this never silently mis-filters a partial page) so the
list UI doesn't need a second redesign once `list_tasks` grows those
parameters in a later backend milestone — but no backend change is
implied or required by writing this down.

**Saved Filters (future-ready):** the filter bar's state model is
designed as a single serializable object (facet → value) from day one,
specifically so persisting one to a `user_saved_task_filters` table (not
built) is additive later — a "Save this filter" affordance is included
in the design as disabled/hidden today, not wired to anything.

---

## 8. Searching

A global Task search (shell header, §2) matching by `task_number`
(exact/prefix) and `title` (substring), server-side, same shape as the
existing Request/Entry reference-number search boxes. Results are a
lightweight dropdown (task number, title, status pill, origin chip) — no
separate full search-results page for T1, since Task volume per org
doesn't yet justify one (revisit if/when it does, per §11).

Search results are subject to the exact same `can_view_task()` filter as
every other list — a task the searcher can't see never appears, not even
as a "restricted" placeholder row, matching the fail-closed posture used
everywhere else in this program.

---

## 9. Permission-Based UI (Supervisor / Administrator / External)

No new permission surface — every gate below is a UI-side mirror of an
already-enforced server-side predicate, restated for clarity:

| Viewer | Sees | Cannot do |
|---|---|---|
| **Officer (`staff`, no scope)** | My Tasks, Assigned By Me, Task Detail for any task `can_view_task()` grants (own/assigned/watched/org-visible/section-visible) | No Team/Organization Tasks nav item; cannot assign tasks outside their own section (mirrors `create_task`'s own section-membership check) |
| **Supervisor / Section Head** (`supervisor` @ section) | Everything Officer sees + Team Tasks scoped to their section(s) + workload dashboard widget | Cannot see Organization Tasks (admin-only) |
| **Department Head / Command Head** (`supervisor` @ department/command) | Same as Section Head, with Team Tasks scope widened by `scope_section_ids()` to their department/command's sections | Same admin-only restriction |
| **CP/DCP** (`mcs_admin`/`authority_admin`) | Organization Tasks nav item; can view/manage any task in their org regardless of section, matching `is_admin()`'s existing bypass | Still cannot see another organization's tasks — org boundary is absolute, admin bypass is intra-org only, matching every module's own confidentiality model |
| **External organizations** | Never see another org's Task list directly; a task surfaces to them only indirectly, through a dual-org module's own visibility (e.g., a Prisoner Letter's Supporting Tasks panel, already gated by `can_view_prisoner_letter()`) | No "Tasks" nav item scoped to a foreign org, ever — this is a hard boundary, not a filtered view |

The distinction between Section/Department/Command Head is a *scope
width* difference only (which `scope_section_ids()` set their Team Tasks
query resolves to), not a different permission model — one "Team Tasks"
view, one query shape, parameterized by the viewer's own
`user_assignments` row(s), consistent with "one permission model,
restated" from §1.

---

## 10. Responsive Design

**Desktop (≥1024px):** table-based List view (§5 columns), two-column
Task Detail (main content left ~65%, Assignees/Watchers/Linked
Records/Timeline stacked in a right rail ~35%), dashboard as a
multi-column widget grid (3–4 widgets per row).

**Tablet (768–1023px):** List view collapses to a denser table (Section
and Updated columns move into a row-expand disclosure rather than being
dropped), Task Detail becomes single-column with the right-rail panels
stacked below the main content in the same priority order, dashboard
grid drops to 2 widgets per row.

**Mobile (<768px):** List view becomes a card list (one card per task:
status+priority chips on top, title, origin chip, assignee avatar, due
date), not a horizontally-scrolled table. Task Detail becomes a
single-column, section-collapsed view (Details panel open by default;
Assignees/Watchers/Linked Records/Comments/Timeline collapsed
accordions, each remembering its own open/closed state per session).
Filter bar becomes a bottom-sheet triggered by a single "Filters" button
with an active-filter-count badge, rather than an always-visible bar
competing for the same width as the card list. Dashboard becomes a
single-column stack, Overdue and Due Today promoted to the top two
positions (highest-urgency-first ordering specific to the mobile
layout, since a supervisor's workload widget is comparatively low
urgency on a small screen).

All three breakpoints share one component tree with layout-only
variation (grid → stack, table → cards) — no separate mobile-only or
desktop-only view/route, consistent with how the existing app's other
views (Requests, Entry) already handle responsive layout.

---

## 11. Future Enhancements

Explicitly out of scope for T1's design and for the eventual first
implementation milestone, listed here so they're not silently forgotten
or silently smuggled in later without their own review:

1. **Task Attachments** — no `task_attachments` table/RPC exists;
   would need its own schema + RLS + RPC milestone, same shape as
   `attachments-api.js`'s existing pattern for Requests.
2. **Related Tasks (task-to-task links)** — no schema for this exists;
   would need a decision on whether it reuses `task_links` (widening
   `module_key` to include `'task'` itself, which has real self-reference
   and cycle implications) or a dedicated `task_relations` table.
3. **Tags** — no `tags` column/table exists on `tasks`.
4. **Saved Filters persistence** — `user_saved_task_filters` table not
   built; UI state model is designed to make this additive (§7).
5. **`list_tasks` filter-parameter expansion** — module/creator/assignee-
   other-than-me/date-range parameters, to replace the client-side
   post-filtering fallback described in §7 once Task volume makes that
   fallback's per-page accuracy limits matter.
6. **Full Task search results page** — if per-org Task volume grows
   enough that the header dropdown (§8) stops being sufficient.
7. **Task-level notifications preferences** — today notifications for
   `task_assigned`/`task_completed`/`task_comment_added` are all-or-
   nothing per user; per-task mute is not designed here.

---

## 12. Implementation Roadmap

Recommended build order for the eventual implementation milestone(s),
sequenced to ship the highest-value, lowest-risk surface first and defer
anything touching `list_tasks`'s RPC signature:

1. **T2 — Task List + Task Detail (read + existing mutations only).**
   Wire up My Tasks/Assigned By Me/Team/Organization list views and the
   Task Detail page's Header/Details/Assignees/Watchers/Comments/Linked
   Records panels entirely against RPCs that already exist today
   (`get_task`, `list_tasks`, `list_task_*_links`, `assign_task`,
   `unassign_task`, `watch_task`, `unwatch_task`, `add_task_comment`,
   `complete_task`, `cancel_task`). No backend change required.
2. **T3 — Task Dashboard.** Widget grid against the same existing RPCs,
   client-side-composed queries (e.g., "Overdue" = `list_tasks` +
   client-side due-date/status filter) — no backend change required
   unless per-widget query volume at scale argues for dedicated
   summary RPCs (a performance call to make with real usage data, not
   up front).
3. **T4 — Filtering/Search UI polish + `list_tasks` parameter
   expansion.** The one milestone in this roadmap that does touch the
   backend — adding the priority/module/assignee-other-than-me/date-
   range parameters flagged as "future" in §7, as its own scoped,
   reviewed, tested change.
4. **T5+ — Future Enhancements items (§11), each its own milestone,**
   prioritized by real usage feedback from T2–T4 rather than decided
   speculatively now.

---

## Summary

This design reuses the existing Shared Task Foundation exactly as R2–R9
shipped it — no new table, RPC, role, or permission rule is proposed.
Every list, panel, filter, and permission gate in this document is
either a direct UI wrapper around an RPC/predicate that already exists,
or is explicitly labeled "future" and excluded from the recommended
first implementation milestone (§12, item 1).
