# 34 — Meetings ↔ Shared Tasks Integration

## Architecture

Second consumer of `task_links` (`supabase/patch-request-task-integration.sql`,
"R4"). `task_links.module_key`'s `CHECK` constraint widens from
`'request'`-only to `'request', 'meeting'` — the exact "future
module_key values add a branch here" extension point R4's own docs
(docs/33) described. Nothing about `task_links` itself, `can_view_task()`,
or the Task foundation (R3) was redesigned.

**Meeting Decisions (new, minimal).** The existing Meetings schema was
inspected before writing anything (every `patch-meetings-*.sql` file) —
there is no decision or action-item concept anywhere; `minutes` is a
single free-text column on `meetings`. Per this milestone's own
instruction to implement only the smallest model needed,
`meeting_decisions` is a plain business record — `meeting_id`,
`organization_id`, `title`, `description`, `created_by`, `created_at`,
nothing else, no status or lifecycle of its own.

`task_links.record_id` (`module_key='meeting'`) points at a
**decision**, not the meeting directly — matching "A Meeting Decision
may have zero/one/many Tasks" literally: `create_meeting_task()` and
`link_existing_task_to_meeting()` both resolve-or-create a decision
first, so a second (or third) task can attach to the *same* decision
by passing its `decision_id`, or each task can log its own new
decision. There is no separate decision-management RPC surface in
this milestone — decisions are only ever created as a side effect of
attaching a task, kept deliberately small rather than building a
parallel CRUD API nothing yet requires.

## Core principles (unchanged from R4, verified for Meetings specifically)

Meeting lifecycle and Task lifecycle remain fully independent. No code
path in this patch reads or writes `meetings.status` from a Task RPC,
or `tasks.status` from a Meeting RPC:

- A meeting's "completed" state is a **computed read-time value**
  (`meeting_effective_status()`) — never a stored status at all, so
  there is nothing to accidentally couple a Task's completion to in
  the first place.
- Cancelling a meeting (`cancel_meeting()`, a real status write) is
  untouched by this patch and never inspects `task_links`.
- Completing a Task (`complete_task()`, from R3) is untouched by this
  patch and never inspects `meetings` or `meeting_decisions`.

Verified directly (not just by inspection) — see "Tests" below,
scenarios 7–8.

## Authorization and RLS

Reuses `can_view_meeting()` and `can_manage_meeting()`
(`patch-meetings-foundation.sql`) exactly as-is — both already existed,
unlike Requests (R4) where only a view-predicate existed and a
`can_manage_task()`-equivalent had to be added. One new helper,
`can_manage_meeting_task_link(meeting_id)`, composes
`can_manage_meeting()` with the same module-enablement check
`meetings_select`'s own RLS policy already applies
(`current_user_module_enabled('meetings') AND can_view_meeting(id)`) —
`can_manage_meeting()` alone does not check module-enablement, so this
adds it rather than silently relying on an already-narrower predicate
elsewhere.

`can_view_task_link()` (from R4) gained a `module_key='meeting'`
branch via `CREATE OR REPLACE FUNCTION` — the same technique R2's
search-path patch used on functions originally declared in
`schema.sql`/`rls.sql`, so R4's file is never touched. Both the Task
and the Meeting must independently pass visibility for the link to be
visible — a user can never learn a hidden Task is linked to a visible
Meeting Decision, or vice versa, because both conditions are required
by the same `AND` expression, not checked separately anywhere.

**Organization compatibility**: meetings have a single
`organization_id` (unlike Requests' `from_org_id`/`to_org_id`), so the
check is simpler than R4's — a Task's `organization_id` must equal the
Meeting's `organization_id` exactly, checked in both
`create_meeting_task()` (via reusing `create_task()`'s own org check)
and `link_existing_task_to_meeting()` (explicit equality check).

**Meetings module gating**: the Meetings module is disabled per-org by
default (confirmed directly — the seed data's `organization_modules`
rows both have `is_enabled = false` for `module_key='meetings'`). Every
authorization path here checks `current_user_module_enabled('meetings')`
explicitly, matching how `meetings_select`'s own RLS policy composes
it — this is not something `can_view_meeting()`/`can_manage_meeting()`
check internally.

RLS on `meeting_decisions` is SELECT-only (`current_user_module_enabled('meetings')
AND can_view_meeting(meeting_id)`), no INSERT/UPDATE/DELETE policy —
rows are only ever created inside the two RPCs below, same posture as
`task_links` itself.

## RPCs

All six required RPCs, `SECURITY DEFINER` with `SET search_path =
public, pg_temp`, deriving the actor from `auth.uid()`:

| RPC | Purpose |
|---|---|
| `create_meeting_task(...)` | Resolves/creates a decision, creates a Task (via R3's `create_task()`), assigns it (via `assign_task()`), links it — atomically |
| `link_existing_task_to_meeting(...)` | Resolves/creates a decision, links a Task the actor can already manage |
| `unlink_task_from_meeting(link_id, reason)` | Soft-removes the link; never touches Task or Meeting status |
| `list_meeting_tasks(...)` | Active links + Task summary for a Meeting, paginated, joined through `meeting_decisions` |
| `list_task_meeting_links(task_id, ...)` | Active links + Meeting/Decision summary for a Task — the future Task Detail page's data source |
| `get_meeting_task_capabilities(meeting_id)` | Four booleans only, fails closed |

`create_meeting_task()` reuses `create_task()` and `assign_task()`
internally exactly as R4's Requests equivalent did — the only new work
is decision resolution and the `task_links` insert. `list_meeting_tasks()`/
`list_task_meeting_links()` are plain (non-`DEFINER`) functions, same
choice R4 made: ordinary RLS on `task_links`/`meeting_decisions`/`tasks`
filters their output, so visibility isn't re-implemented a further
time. `list_meeting_tasks()` additionally inlines `assignees` and
`owning_section_name`, and now also `decision_title`, directly in each
row — avoids an N+1 fetch per card, same technique R4 used.

## UI

**Deviation from the spec's file name**: the spec named
`js/views/meeting-detail.js`. That file does not exist in this
repository — Meetings has no separate detail route; the whole module
lives in `js/views/meetings.js`, and "detail" is a modal
(`_openMeetingDetailModal`/`_renderMeetingDetailModal`), not a page.
The Supporting Tasks panel was added there instead, functionally
equivalent to what the spec asked for.

The panel reuses R4's exact CSS classes (`.supporting-tasks-panel`,
`.task-card`, `.task-picker-list`, etc., `css/style.css`) — no new CSS
was needed. States:

- **Hidden** — `get_meeting_task_capabilities().can_view_tasks` false.
- **Loading** — fetched alongside participants/booking/attachments in
  `_openMeetingDetailModal()`'s existing `Promise.all`, so it's part of
  the same "loading the whole modal" moment as everything else in it.
- **Empty** — `<p class="structure-empty">Nothing here yet.</p>`.
- **Populated** — one `.task-card` per linked task, showing task
  number, title, status/priority badges, **which decision** it
  supports, owning section, assignees, and a due-date chip (reusing
  `RequestsView._deadlineCell()`, exactly as R4's panel does).
- **Error** — isolated per meeting: the capability+list fetch is
  wrapped in its own `try/catch`, so a failure shows this panel's own
  inline error, not a modal-wide failure.
- **Load More** — genuine pagination, same reasoning as R4's panel
  (this codebase's dominant convention is "show everything in one
  batch," but the milestone spec explicitly required this state). One
  difference from R4's implementation: since Meetings' detail view is
  a **modal**, not a full page, "Load More" here patches just the
  panel's own `<details>` element in place (`outerHTML` swap keyed by
  `id="supporting-tasks-panel-${meetingId}"`) rather than calling a
  page-level `_rerender()` — there is no page-level re-render function
  in this file to reuse.

Create/Link/Unlink all reuse this file's own established mutation
pattern: run the RPC, close the modal, reopen it fresh
(`_openMeetingDetailModal(meeting)`) — identical to how
`_openEditMinutesModal()`'s submit handler already works, not a new
convention.

**Task creation from a Meeting** always asks for a short "Decision"
title (what was decided) as a separate field from the task's own
title/description — the meeting's notes/minutes are never
auto-copied into it. Every field the spec listed (title, description,
priority, dates, assignees, visibility) is user-editable in the modal;
none are pre-filled from the meeting except organization (implicit)
and owning section (left to the user, not defaulted from the meeting).

## Audit

No new `record_type` or `action` values. `'meeting'` was already a
valid `audit_logs.record_type` (added by
`patch-meetings-foundation.sql`, long before this milestone).
`'task_linked'`/`'task_unlinked'` already exist (added by R4) and are
reused as-is, logged under `record_type='meeting'`, `record_id` = the
meeting's id (matching how `cancel_meeting()` itself already logs
`'cancelled'` under `record_type='meeting'`).

## Notifications

**Deliberately omitted**, same reasoning as R4's Requests integration:
`create_meeting_task()` already fans out `task_assigned` via its
reused `assign_task()` calls; linking an existing task to a meeting is
a lightweight cross-reference, not new work for anyone already
watching/assigned to that task.

## Validation

`supabase/validate-meeting-task-integration.sql` confirms
`meeting_decisions`' table/columns/indexes/RLS, the widened
`module_key` CHECK (still allows `'request'`, now also allows
`'meeting'`, still rejects a third value), `can_view_task_link()`'s
meeting branch specifically (not just its existence — the function
body is checked for `meeting_decisions`), every new
helper/RPC, and `search_path` pinning on every new `SECURITY DEFINER`
function. Hard-fails (not silent) if anything is missing.

## Tests

`supabase/test-meeting-task-integration.sql` — real, non-superuser
`authenticated`-role RPC calls against disposable fixtures, run
repeatedly (3 consecutive times) against a freshly-built database
(full chain + R2 + R3 + R4 + R5) to confirm idempotency. Two real bugs
were caught and fixed while writing this file (see
`docs/rollback/007`'s own note and the R5 final report's "Regression
observations" — a section-membership fixture mistake, and a
permanently-cancelled shared fixture meeting breaking later re-runs,
fixed by giving the cancellation test its own disposable meeting).

## Deployment order

Apply after `patch-request-task-integration.sql` (R4) — this patch
assumes `task_links`, `can_view_task_link()`, `can_manage_task()`, and
`can_view_task()` already exist, plus `can_view_meeting()`/
`can_manage_meeting()`/`meetings_module_active_for()` from
`patch-meetings-foundation.sql`. Idempotent — safe to re-run. Run
`supabase/validate-meeting-task-integration.sql` immediately after, in
every environment.
