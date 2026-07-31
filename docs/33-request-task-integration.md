# 33 — Requests ↔ Shared Tasks Integration

## Architecture

`task_links` (`supabase/patch-request-task-integration.sql`) is a
**generic, reusable** join table between `tasks` and any approved
CorLink module — not a Requests-specific table. It has a
`module_key`/`record_id` polymorphic shape, the same convention this
codebase already uses for `cc_recipients` and `audit_logs`
(`record_type`/`record_id`, no foreign key on the polymorphic side).
This milestone restricts `module_key` to `'request'` via a `CHECK`
constraint; a later Meetings/Entry/Internal-Collaboration/Prisoner-
Letters milestone widens that same `CHECK` and adds its own capability
RPC (`get_meeting_task_capabilities`, etc.) rather than creating a
parallel table.

Requests and Tasks remain fully independent (R3's own architecture
promise, unchanged here):

- A Request may have zero, one, or many supporting Tasks.
- A Task may link to a Request, stand alone, or (later) link to
  another module — including, potentially, more than one Request at
  once, since nothing here caps how many active links a Task can have.
- **No code path in this patch reads or writes `requests.status` from
  a Task RPC, or `tasks.status` from a Request RPC.** Closing,
  cancelling, responding to, routing, returning, or approving a
  Request never touches a linked Task's assignments, status, or
  existence. Completing or cancelling a Task never touches its linked
  Request. This was verified directly (not just by inspection) — see
  "RLS testing" below, scenarios 8–9.
- `task_links.record_id` has no foreign key to `requests(id)` (or
  anything else) by design, so a hypothetical future hard-delete of a
  request cannot cascade into `task_links` or `tasks` — there is
  nothing for Postgres to cascade along. `task_links.task_id` **does**
  cascade to `tasks(id)`, matching `task_assignments`/`task_watchers`/
  `task_comments` in R3 (all child-of-task rows), but no code path
  anywhere hard-deletes a task, so this never triggers in practice.

## Authorization model

Three new helpers, each `SECURITY DEFINER` with `SET search_path =
public, pg_temp`:

- **`can_manage_request_task_link(request_id)`** — "can this user
  actively work on this request." Reuses
  `can_view_request_or_response()` (already `SECURITY DEFINER`, added
  by `patch-narrow-supervisor-visibility.sql`) rather than re-deriving
  Request access. That predicate already requires org membership on
  the correct side *plus* section membership/admin/creator/receiver —
  never bare org membership alone — so "do not grant access merely
  because a user belongs to either organization" holds without extra
  code. It is deliberately **narrower** than full `requests_select`
  visibility: CC recipients, internal-collaboration looped-in
  sections, and the unrouted-pool assigned-receiver grant can all see
  a request without this returning true, since none of those
  represent "actively working on it" for the purpose of creating or
  linking supporting work.
- **`can_manage_task(task_id)`** — "can this user edit/assign/link
  this task": creator, an active assignee, or a supervisor/admin
  scoped to the task's section. Factored out here because R4 needs
  this exact predicate a sixth time (`update_task`/`cancel_task`/
  `complete_task`/`assign_task`/`unassign_task` each already inline it
  in R3) and **R4 must not modify `patch-shared-task-foundation.sql`**
  — not a duplication of `can_view_task()`, which is broader (also
  includes watchers and section/org visibility).
- **`can_view_task_link(task_id, module_key, record_id)`** — the only
  place "can this user see this link" is decided: `can_view_task(task_id)
  AND` a `module_key`-specific visibility check (today just
  `can_view_request_or_response('request', record_id)`). A user can
  never learn a hidden Task is linked to a visible Request, or that a
  visible Task is linked to a hidden Request, because both conditions
  are required by the same `AND`, not checked separately anywhere.

**Organization compatibility**: the schema was inspected directly
(not assumed) — `requests` has both `from_org_id` and `to_org_id`
(`schema.sql:238-239`), so a supporting Task's `organization_id` must
equal **either** side, never a third organization. `create_request_
supporting_task()` derives it from the actor's own org (`users.org_id`)
and rejects if that org isn't a party to the request;
`link_existing_task_to_request()` rejects if the existing task's
`organization_id` isn't a party to the request either.

## Link lifecycle

`task_links` rows are soft-removed only (`removed_at`/`removed_by`),
never hard-deleted — history is retained. At most one **active** link
may exist between a given `(task_id, module_key, record_id)` at a
time, enforced by a partial unique index
(`idx_task_links_active_unique ... WHERE removed_at IS NULL`), race-
safely via `INSERT ... ON CONFLICT ... DO NOTHING` rather than a
check-then-insert. A task can be unlinked and later relinked to the
same request — confirmed directly in testing (see below).

RLS on `task_links` is **SELECT-only**, same as `tasks` itself in R3:
no INSERT/UPDATE/DELETE policy exists; every mutation goes through the
RPCs below. The SELECT policy does **not** filter `removed_at` —
anyone who could see the active link can also see it after removal
(supporting a future audit/history view with zero new RLS); the two
list RPCs are what filter to "active only" for normal UI listings.

## RPCs

All six are `SECURITY DEFINER` with `SET search_path = public,
pg_temp`, deriving the actor exclusively from `auth.uid()`:

| RPC | Purpose |
|---|---|
| `create_request_supporting_task(...)` | Creates a new Task (via R3's own `create_task()`, not duplicated) + assigns it (via `assign_task()`) + links it, atomically |
| `link_existing_task_to_request(task_id, request_id)` | Links a Task the actor can already manage to a Request the actor can already manage |
| `unlink_task_from_request(link_id, reason)` | Soft-removes the link; never touches Task or Request status |
| `list_request_supporting_tasks(...)` | Active links + Task summary for a Request, paginated |
| `list_task_request_links(task_id, ...)` | Active links + Request summary for a Task — the future Task Detail page's data source |
| `get_request_task_capabilities(request_id)` | Four booleans only: `can_create_task`/`can_link_existing`/`can_unlink`/`can_view_tasks` — fails closed on an unauthenticated caller or an unfound request |

`create_request_supporting_task()` deliberately reuses R3's own
`create_task()` and `assign_task()` internally rather than
re-implementing numbering/validation/audit/notification — the only new
work it does is the `task_links` insert and one `task_linked` audit
row.

`list_request_supporting_tasks()`/`list_task_request_links()` are
**plain functions, not `SECURITY DEFINER`** — same choice R3 made for
`get_task()`/`list_tasks()`: ordinary RLS on `task_links`/`tasks` (via
`can_view_task_link()`/`can_view_task()`) filters their output, so the
visibility predicate isn't re-implemented a third and fourth time.
`list_request_supporting_tasks()` additionally inlines each task's
`assignees` (as a `jsonb` array) and `owning_section_name` directly in
the row, the same way R3's `get_task()` already inlines `assignees` —
avoids an N+1 fetch per card in the UI.

## UI behavior

`js/views/request-detail.js` adds a "Supporting Tasks" `<details>`
panel per conversation round, visually identical in structure to the
existing Internal Collaboration panel (same collapse/expand chevron,
same badge-count-in-summary convention). States:

- **Hidden** — `get_request_task_capabilities().can_view_tasks` is
  false. No disabled buttons are ever rendered; a capability the actor
  lacks simply never appears, matching "do not expose disabled actions
  that reveal hidden permissions."
- **Loading** — folded into the page's single existing `.tab-loading`
  spinner (this app has no per-panel loading convention anywhere; see
  "Pagination" below for the one deliberate exception).
- **Empty** — `<p class="structure-empty">Nothing here yet.</p>`,
  identical wording/markup to the Internal Collaboration panel's empty
  state.
- **Populated** — one `.task-card` per linked task: task number,
  title, status badge, priority badge, owning section, assignees, and
  a due-date chip reusing `RequestsView._deadlineCell()` (the same
  overdue/due-soon logic Requests itself uses — `tasks.due_date` is a
  bare `DATE`, which that helper already handles).
- **Error** — isolated per panel: `_load()` wraps each round's
  capability+list fetch in its own `try/catch` so one failure shows
  that panel's own `.alert.alert-error`, not the whole page's error
  state.
- **Permission-gated actions** — "Create Supporting Task"/"Link
  Existing Task" buttons only render when the corresponding capability
  is true; "Unlink" only renders per-card when `can_unlink` is true
  (and the task isn't already cancelled).

Both create-task and link-existing-task are modals, using this file's
existing `_openModal()`/`_closeModal()` machinery and `.modal-form`/
`.field-group`/`.modal-actions` CSS — no new modal framework. "Create
Supporting Task" reuses the request's already-prefetched
`this._toOrgUsers`/`this._fromOrgUsers` staff lists (no extra query)
for an assignee checklist. It does **not** copy the request's subject
or body into the task's title/description — those fields start empty;
the user types them deliberately.

## Pagination

The rest of this codebase has no "Load More" pattern anywhere — every
existing list (Requests inbox, Internal Collaboration, Attachments,
Review Comments) either loads everything in one batched query or caps
at a fixed limit with a static "showing N of M" hint. The Supporting
Tasks panel is the one deliberate exception: `list_request_supporting_
tasks()` returns `total_count` via `COUNT(*) OVER()` in the same round
trip, and a genuine "Load More" button appends the next page into
already-rendered panel state (`_rerender()`, no full-page reload) when
more rows exist. This is a new, panel-local pattern — introduced
because the milestone's own spec explicitly required a distinct
pagination/Load-More state, which the codebase's dominant
"show-everything-once" convention doesn't naturally provide. Default
page size is 5 (`SUPPORTING_TASKS_PAGE_SIZE`); the RPC itself caps
`p_limit` at 100 regardless of what the client asks for.

"Link Existing Task"'s task picker deliberately does **not** use
free-text server-side search (`list_tasks()` has no text-search
parameter, and R4 must not modify R3's file to add one) — it fetches
an already-authorized, already-capped (200-row), org-scoped candidate
list via `TasksAPI.listTasks({ organizationId, limit: 200 })`, then
narrows by title/task-number substring **client-side** over that
already-small set. This is a documented, deliberate scope choice, not
an unbounded fetch: the server-side org/status filtering is real; only
the free-text match happens after that authorized narrowing.

## Audit decision

No new `record_type`. Two new `action` values only: `task_linked`,
`task_unlinked`, logged under `record_type = 'request'` (the same
`audit_logs` shape `routed`/`assigned`/`returned_to_sender` already
use for a request). `request-detail.js`'s own Activity Log renderer
(`_renderActivityLog`, called with an explicit action allow-list —
`['routed', 'assigned', 'returned_to_sender']`) does **not** include
these two new actions, so they do not appear in the existing
conversation timeline — satisfying "do not merge Task activity into
the Request conversation timeline in R4" with zero extra filtering
code, just by not adding them to that allow-list.

## Notification decision

**Deliberately omitted.** No new notification type was added for
linking/unlinking. Reasoning:

1. `create_request_supporting_task()` already fans out `task_assigned`
   notifications via its reused `assign_task()` calls — an assignee
   finds out about new supporting work through the existing R3
   notification, not a new one.
2. Linking an *existing* task to a request is a lightweight
   cross-reference, not new work for anyone — the task's existing
   assignees/watchers/creator already know about the task itself.
3. The spec explicitly warned against notifying every visible Request
   participant automatically and against notification spam. A
   `task_linked` notification would have to choose recipients somehow
   (creator? all section staff? all watchers?) with no clear
   "who needs to know" answer, unlike `task_assigned` (obviously the
   assignee) or `task_completed` (obviously the creator/watchers).

If a future milestone identifies a concrete need (e.g., "notify the
request's assigned staff when someone else links work to their case"),
add it then, scoped to that real need, rather than pre-emptively here.

## Future reuse for other modules

Nothing in `task_links`, `can_view_task_link()`, or the RLS policy is
Requests-specific except the `module_key` `CHECK` constraint. A future
Meetings integration adds `'meeting'` to that `CHECK`, adds a
`(p_module_key = 'meeting' AND can_view_meeting(...))` branch to
`can_view_task_link()`, and writes its own `create_meeting_supporting_
task()`/`link_existing_task_to_meeting()`/`get_meeting_task_
capabilities()` RPCs following the exact same shape as this file's —
no schema change to `task_links` itself is needed beyond widening the
one `CHECK`. `list_task_request_links()` on the Task side would gain a
`module_key`-generic sibling (or itself generalize) once a second
module exists; this milestone keeps it Requests-specific since no
second module exists yet to generalize against.

## Deployment order

Apply after `patch-shared-task-foundation.sql` (R3) — this patch
assumes `tasks`/`task_assignments`, `create_task()`/`assign_task()`,
and `can_view_task()` already exist. Idempotent — safe to re-run
(every `CREATE TABLE`/`CREATE INDEX` uses `IF NOT EXISTS`, the one
`CREATE POLICY` is preceded by `DROP POLICY IF EXISTS`, every function
is `CREATE OR REPLACE` — `list_request_supporting_tasks()` is preceded
by an explicit `DROP FUNCTION IF EXISTS` first, since `CREATE OR
REPLACE` cannot change a `RETURNS TABLE` function's output columns).
Run `supabase/validate-request-task-integration.sql` immediately
after, in every environment.

### A note on local test-chain reconstruction (not a repository bug)

While building a local reference database to test this milestone
(replaying the full documented + previously-reconstructed migration
chain), two undocumented "straggler" patches —
`patch-default-section-reference-numbers.sql` and `patch-prisoner-
registry-section.sql` — needed to run in that specific relative order
for `update_org_workflow_settings()` to end up as a single function
rather than two stale overloads (each file's own `DROP FUNCTION`
targets the exact signature the *other* file's `CREATE OR REPLACE`
produces). This is **not** a bug in either committed file — a real,
already-migrated database only ever applied these once, in whatever
order they actually ran, and has one correct overload today regardless.
It's a reconstruction-order sensitivity in the *undocumented* portion
of the chain, consistent with the documentation-lag gap the R1 audit
already flagged (`supabase/auth-setup.md` §2 was never updated to
include several of these files). Noted here for whoever documents that
chain properly later; out of scope to fix as part of R4.
