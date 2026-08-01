# 41 — Task Detail Foundation (T2B)

Implements the Task Detail *foundation* only: header, details, linked
records, assignee/watcher display, and permission-aware (but
non-mutating) action buttons. Comments, Timeline, Watcher/Assignment
management, Attachments, Related Tasks, and Dashboard are all
explicitly out of scope — later milestones per docs/39's roadmap.

## Architecture

**No SQL, RPC, index, or policy was added.** `js/views/task-detail.js`
(new) reads exclusively through `get_task()` and the five existing
`list_task_<module>_links()` RPCs, plus plain `SELECT`s against
`users`/`organizations`/`sections` for display names — the same
"let RLS decide what comes back" posture the rest of this codebase
(and `js/data/tasks-api.js`'s Task List bulk reads, T2A) already
established. Nothing in `tasks-api.js` needed a new method for this
milestone; `listRequestLinks`/`listMeetingLinks`/`listInternalCollabLinks`/
`listEntryLinks`/`listPrisonerLetterLinks` already existed since the
Shared Task Foundation program shipped (R4–R8) and were simply unused
by any page until now.

**Files:**
- `js/views/task-detail.js` (new) — `TaskDetailView`.
- `js/app.js` — registers the `task-detail` route (`id` param, same
  convention as `request-detail`/`entry-detail`/`prisoner-letter-detail`).
- `js/views/tasks.js` — task numbers in the List now link directly to
  `#task-detail?id=...` instead of showing T2A's "not built yet"
  placeholder (see docs/40's Addendum).
- `js/data/tasks-api.js` — one bug fix, unrelated to adding new
  capability (see §Bug fix below).
- `css/style.css` — one new block (`.task-detail-layout` /
  `.task-detail-sidebar` / `.task-detail-actions`), a responsive
  two-column grid. Everything else (`.panel`, `.panel-header`,
  `.detail-grid`, `.data-table`, `.badge` + variants, `.badge-list`,
  `.empty-state`, `.field-hint`, `.structure-empty`) is reused as-is.
- `index.html` — new script tag plus cache-buster bumps for every file
  this milestone touched.

### Route

`task-detail` is not in `router.js`'s `MODULE_ROUTES` (same as `tasks`
itself, T2A) — reachable by any authenticated user, no Layer 1
module-enablement gate, matching Shared Task Foundation having no
`platform_modules` entry of its own.

### Linked-record resolution — via the real RPCs directly

Task Detail is a single task, not a page of many, so the bulk-batching
concern that shaped the Task List's origin resolution (T2A,
`fetchTaskLinksBulk`/`fetchOriginRecords`) doesn't apply here. Instead,
`_fetchLinkedRecords()` calls all five `list_task_<module>_links(taskId)`
RPCs directly in parallel — the exact RPCs R4–R8 built for precisely
this purpose. Each already returns a human-readable title/number/status
for its module (`list_task_request_links` → `subject`/`reference_number`/
`status`; `list_task_meeting_links` → `meeting_title`/`decision_title`;
`list_task_internal_collaboration_links` → `subject`/`status`/
`parent_type`/`parent_id`; etc.), so nothing here re-derives visibility
or authorization — the RPCs' own `SELECT`s (each gated by that module's
own `can_view_X()`) are the only thing deciding what comes back.

`internal_request` links route to their parent Request/Entry (via
`parent_type`/`parent_id`, already resolved server-side by the RPC —
only populated when the actor can independently view that parent, per
that RPC's own long-standing contract) rather than a dedicated
`internal-request-detail` route, which doesn't exist and wasn't
invented for this milestone. Every other module routes to its existing
detail page (`request-detail`, `entry-detail`, `prisoner-letter-detail`)
or existing route with a param (`meetings?meetingId=...`) — no new
route was created, per the T2B brief's "reuse the existing linked-record
routing" instruction.

### Bug fix (found while building this milestone)

While wiring linked-record display via `list_task_meeting_links()`, it
became clear `task_links.record_id` for `module_key='meeting'` is a
`meeting_decisions.id`, not a `meetings.id` — that RPC (`patch-meeting-
task-integration.sql`) joins `task_links -> meeting_decisions ->
meetings`, a two-hop relationship. T2A's own `TasksAPI.ORIGIN_MODULES.meeting`
(in `js/data/tasks-api.js`, used by the Task List's bulk origin lookup)
was querying `meetings` directly by that id, which would never match —
a meeting-linked task's Origin chip in the Task List would silently
fail to resolve. Fixed by pointing that config entry at
`meeting_decisions` (with a nested `meeting:meetings(title)` embed) and
adding a `routeIdField` so the chip's route param uses `meeting_id`
rather than the row's own `id`. This is a JS-only correction to
already-shipped code, not a backend defect — no SQL/RPC was touched.
Full detail in docs/40's Addendum. Re-verified against the same
headless test harness described below: a meeting-linked task's origin
now resolves correctly in both the Task List (T2A) and Task Detail
(T2B, which was never affected by this bug in the first place, since it
uses `list_task_meeting_links()` directly rather than a raw table read).

## Layout

**Desktop (≥900px)**: `.task-detail-layout` is a 2-column CSS grid
(`2fr 1fr`) — Details + Linked Records in the main column, Assignees +
Watchers + Actions in a right sidebar. Same 900px breakpoint the app
already uses for the sidebar-nav/topbar-nav split (`css/style.css`'s
existing `@media (min-width: 900px)` block) — reused, not a new
threshold invented for this page.

**Tablet (640–899px)**: the grid collapses to one column (topbar nav,
not sidebar) — sidebar panels stack below the main content in the same
priority order (Assignees, Watchers, Actions).

**Mobile (<640px)**: same single-column stack, plus the bottom tab bar
in place of the topbar's nav links — identical mechanism the rest of
the app already uses for this breakpoint.

## Components

- **Header** — task number, title, status badge, priority badge,
  created/updated timestamps and creator name.
- **Details** — description, due date, start date, visibility,
  organization name, section name (or "Organization-wide" if
  `owning_section_id` is null), and a completed-by line when
  `status = 'completed'`.
- **Linked Records** — a table, one row per link across all five
  modules; "Not linked to any record" empty state for a standalone
  task; a row whose target isn't independently viewable (link visible,
  record not) renders "Not viewable" instead of a broken or empty link,
  matching the "visible link, not necessarily navigable" contract every
  module integration (R4–R8) and docs/39 already committed to.
- **Assignees / Watchers** — name lists (`badge-list`), display only,
  "Unassigned"/"No watchers" empty states. No add/remove control — that
  is explicitly out of scope (Assignment/Watcher management, later
  milestones).
- **Actions** — Complete/Cancel/Assign to Me/Unassign Me/Watch/Unwatch,
  shown per the same permission mirror as the Task List (see below).
  Per the T2B brief ("buttons need not perform mutations yet"), clicking
  one shows an acknowledgment rather than calling the real RPC — see
  §Known Limitations for exactly how small the remaining gap is.

## Permission behavior

Identical predicates to `js/views/tasks.js` (T2A), copied rather than
shared — this codebase's established convention for small per-view UI
helpers (see `entry.js`'s own comment above its filter-chip helpers,
which states the same rationale explicitly). No new authorization logic
was written:

- `_canManage()`: `is_super_admin() OR created_by === me OR
  (isSupervisorOrAbove(me) AND organization_id === me.org_id AND
  (owning_section_id IS NULL OR owning_section_id ∈ mySectionIds))` —
  a direct restatement of `cancel_task()`/`assign_task()`'s shared
  `IF NOT (...)` guard.
- Complete shown when `status ∈ {in_progress, waiting}` AND
  (`canManage()` OR active assignee) — mirrors `complete_task()`.
- Cancel shown when `status ∈ {draft, open, in_progress, waiting}` AND
  `canManage()` — mirrors `cancel_task()`.
- Assign to Me shown when `canManage()` and not already assigned;
  Unassign Me shown whenever currently assigned (`unassign_task()`
  unconditionally allows `p_user_id = auth.uid()`).
- Watch/Unwatch always shown — `watch_task()` only requires
  `can_view_task()` (already true, the page loaded), `unwatch_task()`
  has no further check.

**Not-found vs. no-permission**: `get_task()` is a plain (non-DEFINER)
function relying on ordinary `SELECT`-RLS via `can_view_task()` — a
nonexistent task id and a task this viewer can't see both return zero
rows, indistinguishably. Rather than infer "this task exists, you just
can't see it" (which would leak existence to someone not supposed to
know), both collapse into one neutral state — deliberately the same
fail-closed, no-existence-leakage posture already reviewed and approved
for Prisoner Letters (docs/37, R8) and reused verbatim here, not a new
decision made for this page. The genuinely distinct "Not Found" case is
a missing/blank `id` route parameter — a routing-level problem with
nothing to even query — checked before `get_task()` is ever called.
This matches the established pattern already in `request-detail.js`/
`entry-detail.js` (neither of which distinguishes "doesn't exist" from
"not visible" either — both fall through to one generic error state);
Task Detail's version is just an intentional `empty-state` render
instead of a generic `alert-error`.

## Responsive behavior

See §Layout above. No new list/table components — `.data-table` inside
the Linked Records panel reuses the exact same `data-label`
mobile-card-transform every other list in this app already relies on.

## Testing

**Standing constraint honored: this environment has no staging/
production credentials and must never connect to either** — no browser
test against the real (production-configured) app was possible or
attempted.

What was run:
1. `node --check` on every touched/added JS file — all pass.
2. The same isolated, non-repo headless-Chromium harness from T2A
   (mocked `getSupabase`/`Auth`/`Router`/`AppShell`, zero real network),
   extended with a `get_task`/`list_task_*_links` mock layer and
   `users`/`organizations` mock tables, exercising:
   - Missing `id` param → "Task not found" (no query attempted).
   - Nonexistent task id → the same "Task not found" title, with the
     neutral "doesn't exist, or you don't have permission" subtitle —
     confirmed textually identical treatment for both cases, as
     designed.
   - A task the viewer created, `status='draft'` → Actions correctly
     offer Cancel + Assign to Me but NOT Complete (draft isn't a valid
     `complete_task()` source status) — confirms the status-gate, not
     just the ownership-gate, is honored.
   - A request-linked task → Linked Records renders one row with the
     request's own reference number, status, and a working Open button
     routed to the existing `request-detail` route.
   - A meeting-linked task (via `meeting_decisions`) → Linked Records
     correctly resolves and links to `#meetings?meetingId=...`,
     confirming the bug described above never affected this page (it
     was always going through the correct RPC).
   - Every scenario: at minimum the Watch action is always present
     (never a fully-empty Actions panel) and zero JavaScript errors
     were thrown across all six scenarios.
3. **Not independently re-verified**: the responsive breakpoint CSS
   itself (pre-existing/newly-added-but-conventional, not exercised at
   real viewport widths in this harness) and real Supabase-backed
   auth/session flow (requires staging credentials this environment
   does not have and must not use).

## Known Limitations

- **Actions don't mutate yet.** Per the T2B brief, Complete/Cancel/
  Assign to Me/Unassign Me/Watch/Unwatch are permission-gated and
  clickable but only acknowledge ("coming in a later milestone") rather
  than calling the real RPC. This is a small, well-understood gap:
  `js/views/tasks.js` already has working, tested calls to every one of
  these RPCs with this exact same permission mirror — wiring Task
  Detail's buttons to them is expected to be close to a copy-paste in
  the next milestone, not new design work.
- **Language/Classification omitted from Details.** The T2B spec names
  these as fields to display, but no such columns exist on `tasks`
  (`supabase/patch-shared-task-foundation.sql`: `id`/`task_number`/
  `title`/`description`/`status`/`priority`/`due_date`/`start_date`/
  `completed_at`/`completed_by`/`created_by`/`organization_id`/
  `owning_section_id`/`visibility`/timestamps only). A missing display
  field is not a backend defect under this milestone's "no backend
  changes unless a genuine defect is discovered" constraint, so neither
  a column nor a fabricated value was added — the two rows are simply
  omitted from the Details panel.
- **Linked Records has no pagination.** Each `list_task_<module>_links()`
  call is capped at 10 rows; a task linked to more than 10 records in
  one module would silently truncate. Not expected at realistic scale
  for a task's own link count, and out of scope to build proper
  pagination for in a "foundation" milestone — flagged for whichever
  future milestone expands this panel.

## Future Milestones

- **Wire Actions to real mutations** — reuse `TasksAPI.completeTask`/
  `cancelTask`/`assignTask`/`unassignTask`/`watchTask`/`unwatchTask`
  exactly as `js/views/tasks.js` already does.
- **Comments, Timeline** (merged audit-log + comment feed, per docs/39).
- **Assignee/Watcher management** (add/remove, not just display).
- **Attachments** — no `task_attachments` table/RPC exists yet (see
  docs/39 §11).
- **Related Tasks** — no task-to-task relation exists yet.
- **Dashboard** — per docs/39's own roadmap (T3).
