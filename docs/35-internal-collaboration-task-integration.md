# 35 — Internal Collaboration ↔ Shared Tasks Integration

## Architecture

Third consumer of `task_links` (`supabase/patch-request-task-integration.sql`,
"R4"; `supabase/patch-meeting-task-integration.sql`, "R5"). `task_links.module_key`'s
`CHECK` constraint widens from `'request', 'meeting'` to also allow
`'internal_request'` — the exact canonical value this codebase already
uses for this concept everywhere else (the `internal_requests` table
itself, `audit_logs.record_type`, `cc_recipients.record_type`,
`attachments.record_type`, `InternalRequestsAPI`'s own `logAudit()`).
No alias was invented; `'internal_request'` is simply reused, per the
milestone's own instruction to use the repository's actual canonical
value rather than guessing between `internal_request`/`internal_requests`/
`internal_collaboration`.

**Attachment point.** Tasks attach to the specific `internal_requests`
row — the individual loop-in **thread** — not to its parent Request or
Entry. `task_links.record_id` (`module_key='internal_request'`) is an
`internal_requests.id`. Every RPC below takes an exact
`p_internal_request_id` and filters/checks against that one id only, so
"Thread A shows only Thread A's tasks" is structural, not a UI
convention: there is no code path anywhere in this patch that queries
by `parent_request_id`/`parent_entry_id` instead of the thread's own
id. Verified directly with a three-sibling-thread fixture — see
"Tests" below.

Internal Collaboration and Tasks remain fully independent business
objects, same as R4/R5: `task_links.record_id` has no foreign key (a
deliberate polymorphic-column choice, matching the existing
`cc_recipients`/`audit_logs` `record_type`+`record_id` precedent) — so
deleting an `internal_requests` row cannot cascade into tasks, and
there is no code path anywhere in this patch that writes
`internal_requests.status` from a Task RPC or reads it to drive
`tasks.status`, or the reverse. Marking received, assigning, rerouting,
returning to sender, replying, approving, or closing a thread never
touches a linked Task; completing/cancelling a Task never touches its
linked thread or that thread's parent Request/Entry.

## Authorization matrix

There is no pre-existing standalone callable visibility predicate for
Internal Collaboration (unlike Requests' `can_view_request_or_response()`
or Meetings' `can_view_meeting()`, both reused directly by R4/R5) —
`internal_requests_select`'s visibility logic has only ever lived
inline in that one RLS policy (`supabase/rls.sql`) and in the
`internal_request` branch of `can_view_case_audit_record()`. This
milestone introduces `can_view_internal_request(id)`, mirroring that
policy, and `can_manage_internal_collab_task_link(id)`, a narrower
"can actively do supporting work" predicate — the same "view broader
than manage" split R4 established with `can_view_request_or_response()`
vs. its own new `can_manage_task()`.

The instruction was to evaluate the actual workflow (repository
evidence, not assumption) and implement the narrowest rules it
supports. `js/views/request-detail.js`'s `_renderInternalRequestRow`
(duplicated verbatim in `js/views/entry-detail.js`) is the ground
truth: `canReceive`/`canReply` are gated on `to_section` membership
alone; `canAssign` on `to_section` supervisor scope; `canReplyNow`
additionally requires being the specific `assigned_to` user (or a
supervisor); the asking side (`from_section`) has exactly one action
available at any stage — `Return to Sender` (misroute correction, not
"doing the work") — and closing (`canCloseNow`) is gated to the
literal creator, not the whole `from_section`. Nowhere does the asking
side manage ongoing substantive work on a thread.

| Actor | Can VIEW the thread (and, transitively, its links) | Can MANAGE (create/link/unlink) supporting tasks |
|---|---|---|
| `to_section` member (any role) | Yes | Yes |
| Thread's `assigned_to` user | Yes (added deliberately — see below) | Yes |
| Supervisor scoped to `to_section`'s org | Yes | Yes |
| `from_section` member (asking side, incl. the thread's own creator) | Yes | **No** |
| Thread's literal creator (if not otherwise covered above) | Yes | **No** |
| Section that previously held the thread (`previous_section_id`) | Yes | No |
| Unrelated same-org section | No | No |
| Cross-org user | No | No |

**Closed threads**: `create_internal_collaboration_supporting_task()`
and `link_existing_task_to_internal_collaboration()` both reject a
thread with `status = 'closed'`. This mirrors the existing UI exactly —
`_renderInternalRequestRow` shows **zero** action buttons once a thread
reaches `closed` (no Mark Received/Assign/Reply/Route/Return/Close is
ever offered again), so blocking new supporting work at that point is
the narrowest rule the repository's own behavior supports. `unlink` has
**no** status gate — soft-removing a stale reference is never "new
work," matching R4/R5's own unlink RPCs.

**One deliberate, disclosed deviation from a byte-for-byte mirror**:
`can_view_internal_request()` adds an `ir.assigned_to = auth.uid()`
branch that the real `internal_requests_select` policy does not have.
In the existing assignment workflow, `assigned_to` is always chosen
from the receiving section's own staff (`js/views/request-detail.js`'s
`_openAssignModal` only lists `to_section` staff), so this branch is
normally redundant with `to_section` membership. It was added anyway,
for defense-in-depth, after this milestone's own behavioral testing
caught a real gap: `can_manage_internal_collab_task_link()` (required
to account for "current assigned user" per this milestone's spec)
already grants manage authority via `assigned_to` independent of
`to_section` membership; without the matching view-side branch, a user
assigned outside the normal `to_section` path (a scenario not currently
reachable through the UI, but not prevented by any DB constraint
either) could create/link a task via the RPC and then be unable to see
the very link they just created. This is a narrow, additive widening of
a brand-new function this milestone itself introduces — not a change
to the real `internal_requests_select` policy on the table.

No cross-org linking: `internal_requests` has no `organization_id`
column of its own — `from_section_id`/`to_section_id` always resolve to
the same org (a structural invariant enforced by RLS, documented in
`schema.sql`'s own comment on the table). Every RPC below derives the
thread's one true org via `scope_org_id('section', ir.to_section_id)`
and requires the actor's own org, and any linked Task's
`organization_id`, to match it exactly.

## RLS and two-sided visibility

`can_view_task_link()` (from R4, already widened once by R5) gained a
third `module_key='internal_request'` branch via `CREATE OR REPLACE
FUNCTION` — R4's and R5's own files are never touched. Both the Task
and the thread must independently pass visibility for the link to be
visible — a user can never learn a hidden Task is linked to a visible
thread, or that a visible Task is linked to a hidden thread, because
both conditions are required by the same `AND` expression, evaluated in
one place.

No new table this milestone (`internal_requests` already existed), so
no new RLS policy either — `task_links_select` (from R4) already covers
this module_key value once `can_view_task_link()` knows about it.

## RPCs

All eight new functions, `SECURITY DEFINER` with `SET search_path =
public, pg_temp`, deriving the actor from `auth.uid()`:

| RPC | Purpose |
|---|---|
| `can_view_internal_request(id)` | Helper: mirrors `internal_requests_select` (+ the disclosed `assigned_to` addition) |
| `can_manage_internal_collab_task_link(id)` | Helper: `to_section` membership, `assigned_to`, or scoped supervisor |
| `create_internal_collaboration_supporting_task(...)` | Creates a Task (via R3's `create_task()`), assigns it (via `assign_task()`), links it — atomically, blocked on a closed thread |
| `link_existing_task_to_internal_collaboration(task_id, thread_id)` | Links a Task the actor can already manage to a thread they can manage, blocked on a closed thread |
| `unlink_task_from_internal_collaboration(link_id, reason)` | Soft-removes the link; never touches Task or thread status; no closed-thread gate |
| `list_internal_collaboration_tasks(thread_id, ...)` | Active links + Task summary for **one exact thread**, paginated |
| `list_task_internal_collaboration_links(task_id, ...)` | Active links + thread/parent summary for a Task — the future Task Detail page's data source |
| `get_internal_collaboration_task_capabilities(thread_id)` | Four booleans only, fails closed |

`create_internal_collaboration_supporting_task()` reuses `create_task()`
and `assign_task()` internally exactly as R4's and R5's equivalents did
— the only new work is the `task_links` insert. `list_internal_collaboration_tasks()`/
`list_task_internal_collaboration_links()` are plain (non-`DEFINER`)
functions, same choice R4/R5 made: ordinary RLS on
`task_links`/`tasks`/`internal_requests`/`requests`/`external_correspondence`
filters their output, so visibility isn't re-implemented a further
time — this is also what makes the parent-navigation metadata safe (see
below).

## Thread-isolation behavior

Verified directly (not just by inspection) with a fixture parent
Request carrying **three** sibling `internal_requests` threads (one
open/assigned, one open/unassigned, one closed): each thread's
`list_internal_collaboration_tasks()` returns only its own active
links (confirmed via `array_agg`/set-overlap assertion, not just a
count); `get_internal_collaboration_task_capabilities()` is evaluated
independently per thread (the closed sibling correctly blocks
create/link while the open siblings allow it, for the same actor, in
the same call sequence); unlinking a task on one thread leaves a
sibling thread's own active link completely untouched; and pagination
(`LIMIT`/`OFFSET`) never crosses thread boundaries, since every list
query's `WHERE` clause is an exact `record_id` match. See
`supabase/test-internal-collaboration-task-integration.sql`, TEST
12/12B.

## Deep-link navigation metadata

`list_task_internal_collaboration_links()` returns `parent_type`
(`'request'` or `'external_correspondence'`) and `parent_id` for a
future Task Detail page, resolved via plain `LEFT JOIN`s to `requests`
and `external_correspondence` — **not** a hand-written boolean
re-derivation of `requests_select`/`external_correspondence_select`'s
own visibility logic. Because the function is a plain (non-`DEFINER`)
SQL function, those joins run under the actor's own RLS: if the actor
cannot independently see the parent Request/Entry, the joined columns
come back `NULL`, not a wrongly-populated value — this is real RLS
enforcement, the same technique R4/R5 used to avoid maintaining a
second, parallel visibility predicate. Verified for both parent types:
a Request-hosted thread resolves `parent_type='request'` for a viewer
with genuine Request visibility (via `requests_select_via_internal_collab`,
the existing looped-in-section policy); an Entry-hosted thread resolves
`parent_type='external_correspondence'`. A viewer with no visibility
into the Task or thread at all gets **zero rows**, not a partially
populated one — the strongest form of "don't expose it."

## UI implementation

Internal Collaboration has no standalone detail page — threads render
inline inside two different host pages, `js/views/request-detail.js`
(Request-hosted) and `js/views/entry-detail.js` (Entry-hosted), each
with its own independently-maintained `_renderInternalRequestRow()`.
The Supporting Tasks panel (`_renderInternalCollabSupportingTasks(ird)`)
was added to both, right after the reply thread and before the row's
own action buttons, reusing R4's exact CSS classes
(`.supporting-tasks-panel`, `.task-card`, `.task-picker-list`, etc.,
`css/style.css`) — **zero new CSS**. `_renderTaskCard`/
`_taskStatusBadgeClass`/`_taskPriorityBadgeClass`/`_capitalizeWords`
already existed in `request-detail.js` (from R4) and were reused
as-is (`_renderTaskCard` gained one new optional parameter,
`unlinkAttr`, so this thread-level panel's Unlink button can bind to a
distinct `data-unlink-internal-task` attribute without colliding with
the request-level panel's own `data-unlink-task` on the same page);
`entry-detail.js` had none of these four helpers (it has no R4 panel of
its own — Entry's own direct Shared Task panel is explicitly out of
scope), so they were duplicated there, matching R5's own precedent of
duplicating small UI helpers across separate top-level view objects
with no shared module to hold them.

Per-thread states, driven entirely by real server-fetched state
(`ird.taskCapabilities`/`supportingTasks`/`supportingTasksError`,
populated in each file's own `_load()`):

- **Hidden** — `get_internal_collaboration_task_capabilities().can_view_tasks`
  false (includes a genuinely nonexistent thread and a real-but-invisible
  one identically, per TEST 21).
- **Loading** — fetched alongside every other per-thread field in
  `_load()`'s existing `Promise.all`, isolated per thread (see "Error
  isolation" below).
- **Empty** — `<p class="structure-empty">Nothing here yet.</p>`.
- **Populated** — one `.task-card` per linked task: task number, title,
  status/priority badges, owning section, assignees, and a due-date
  chip (`RequestsView._deadlineCell()`, same as R4/R5).
- **Error** — isolated per thread, own inline error, never blanks the
  host page.
- **Load More** — genuine pagination. `request-detail.js` reuses its
  existing `_rerender()` (page-level, in-memory). `entry-detail.js` had
  no equivalent — one was added (`_rerender()`, identical shape to
  request-detail.js's own), since Load More needs a cheap in-memory
  re-render and `entry-detail.js`'s only prior re-render path was a
  full `_load()` network round-trip.

Create/Link/Unlink all reuse each file's own established mutation
pattern (`_runAction()`/full `_load()` reload after a mutating RPC),
identical to how every other Internal Collaboration action in these
files already works — no new convention introduced.

**Create Supporting Task** asks only for the R3-supported fields
(title, description, priority, dates, owning section, assignees,
visibility) — none pre-filled from the thread's own subject/body, no
auto-copying of collaboration messages, reply text, attachment names,
or confidential parent content. Owning-section/staff pickers fetch
fresh via `AdminAPI.listSectionsByOrg`/`listUsersByOrg(this._user.org_id)`
on every open (no caching), matching R5's own fix for the cross-org
staff-list caching bug found during that milestone.

**Link Existing Task** uses the same bounded, client-side-narrowed
search over a capped `TasksAPI.listTasks({ organizationId, limit: 200 })`
call R4/R5 already established — excludes already-linked and cancelled
tasks; the underlying `listTasks()` call itself already excludes
cross-org and unauthorized tasks (server-side, via RLS).

## Error isolation

Every thread's capability+task fetch is wrapped in its own
`try`/`catch` inside `_load()`'s `Promise.all` — a failure sets that
one `ird`'s `supportingTasksError` and continues; it never rejects the
whole `Promise.all`, never blanks the Request/Entry page, and never
breaks a sibling thread, replies, attachments, or the parent record's
own actions. Same isolation technique R4 established for the
request-level panel, applied per-thread here.

## Audit decision

**No `audit_logs` schema change was needed** — genuinely reuse-only,
narrower than even R4's own footprint. `record_type='internal_request'`
was already a valid value (added long before this milestone);
`action IN ('task_linked', 'task_unlinked')` was added by R4 and is
reused as-is. Unlike R5's Meetings milestone (which needed to bracket
its own audit-visibility test with a superuser bypass, since
`can_view_case_audit_record()` had no `'meeting'` branch),
`can_view_case_audit_record()` already had a full `internal_request`
branch mirroring `internal_requests_select` — so `task_linked`/
`task_unlinked` rows are visible to the exact same audience as the
thread itself, with **no RLS bypass needed**, verified directly (TEST
15). Task activity is **not** merged into the reply conversation/audit
timeline shown per row — `_renderAuditEvents('internal_request', ir.id,
['received', 'routed', 'assigned', 'returned_to_sender'])` in both host
files already passes a fixed action allow-list that does not include
`task_linked`/`task_unlinked`, so no extra filtering work was needed to
keep them out of that specific view, matching R4's identical decision
for the Request conversation timeline.

## Notification decision

**Deliberately omitted**, same reasoning as R4/R5:
`create_internal_collaboration_supporting_task()` already fans out
`task_assigned` via its reused `assign_task()` calls; linking an
existing task to a thread is a lightweight cross-reference, not new
work for anyone already watching/assigned to that task. No Internal-
Collaboration-specific Task notification type was added.

## Validation

`supabase/validate-internal-collaboration-task-integration.sql`
confirms the widened `module_key` CHECK (still allows `'request'` and
`'meeting'`, now also `'internal_request'`, still rejects a fourth
value like `'entry'`), that R4's original `task_links` indexes are
still intact (a regression here would silently affect all three
modules at once, so this validator checks it explicitly even though R6
added no new index of its own), `can_view_task_link()`'s
`internal_request` branch specifically (function-body substring check,
not just existence — and confirms the `request`/`meeting` branches
survived the third widening), a shape spot-check on
`can_view_internal_request()` (confirms `from_section_id`/
`to_section_id`/`previous_section_id`/`created_by`/`assigned_to` are
all genuinely present in the function body), every new helper/RPC,
`search_path` pinning on every new `SECURITY DEFINER` function, that
`task_links` still carries exactly one policy (`SELECT`-only, no
mutation policy was accidentally introduced), and a live smoke test of
`idx_task_links_active_unique` specifically with an `internal_request`
module_key value (self-cleaning — inserts and then deletes its own
probe row, skips gracefully if no fixture data exists). Hard-fails (not
silent) if anything is missing.

## Tests

`supabase/test-internal-collaboration-task-integration.sql` — 21+ real,
non-superuser `authenticated`-role RPC calls against disposable
fixtures (two orgs, a case-owner section, a helper section, an
outsider section, a cross-org section, a parent Request, a parent
Entry, and four `internal_requests` threads — three siblings on the
Request, one on the Entry), covering every category the milestone
specified: authorized-receiving-section creation, sender-side rejection
(documented business-rule decision, not a bug), assignee-only manage
authority isolated from `to_section` membership, unrelated-section and
cross-org denial, both directions of "sees one side but not the other"
visibility, duplicate-link rejection, unlink without side effects on
either lifecycle, three-thread isolation (including a closed sibling),
deterministic thread-scoped pagination, direct-write denial, audit
visibility without an RLS bypass, standalone-task non-regression,
Request-hosted and Entry-hosted parent resolution with safe navigation
metadata, and capabilities failing closed identically for a
real-but-hidden vs. a genuinely nonexistent thread.

Run repeatedly (3 consecutive times) against a freshly-built database
(full chain + R2 + R3 + R4 + R5 + R6) to confirm idempotency. Three
real bugs were caught and fixed while writing this file: (1) several
lookups ordered a temp capture table by its random `task_id`/`link_id`
UUID column instead of true insertion order, which is not reliable —
fixed by adding an `inserted_at` (`clock_timestamp()`-defaulted) column
and ordering by that instead; (2) three of the create/link steps
(TESTs 1, 3, 7, 20) were not idempotent — each unconditionally created
a new Task on every run instead of checking for an existing one by
title first, breaking exact-count assertions (TEST 20) and,
separately, re-driving a full `draft → open → in_progress → completed`
transition on an already-`completed` task from a prior run
(`valid_task_status_transition()` has no `completed → open` edge) —
fixed by wrapping each in the same `IF NOT EXISTS (... WHERE title =
...)` idempotency guard R5's own test file already used for its
cancellation-test fixture; (3) the real `can_view_internal_request()`
gap described in "Authorization matrix" above was caught by exactly
this idempotency testing (TEST 3's assignee-authorized flow failed on
a second run because the assignee could manage but not view/re-find
their own link) and fixed in the patch file itself, not worked around
in the test.

Also re-ran `supabase/test-request-task-integration.sql` (R4) and
`supabase/test-meeting-task-integration.sql` (R5) end-to-end against
this same R6-patched database (3 consecutive times each) — both passed
identically to their pre-R6 runs, confirming zero regression from
widening `task_links.module_key` a second time or from this milestone's
own `can_view_task_link()` extension.

## Performance

No new index was added — `EXPLAIN` confirms
`idx_task_links_record_active_created (module_key, record_id, created_at
DESC) WHERE removed_at IS NULL` (from R4) is used directly, via its
leading `(module_key, record_id)` columns, for
`list_internal_collaboration_tasks()`'s thread-scoped lookup, with no
new schema change required — `'internal_request'` is simply another
value in the same composite index's leading column. The task-side
lookup (`list_task_internal_collaboration_links()`) is planned
identically to R4's own `list_task_request_links()` on this test
dataset's small row counts (both use `idx_task_links_record_active_created`
with `task_id` as a filter rather than `idx_task_links_task_active_created`
as an index condition) — confirmed this is pre-existing planner
behavior shared across all three `module_key` values on a small table,
not a regression introduced by this milestone; `idx_task_links_task_active_created`
remains available for the planner to select at production scale. All
pagination is server-side `LIMIT`/`OFFSET` (no unbounded query, no raw
`COUNT` leak — `total_count` is returned via `COUNT(*) OVER()` in the
same row, matching R4/R5). No N+1 capability loop: each host page
fetches every thread's capabilities+first task page in one batched
`Promise.all`, isolated per thread only for error handling, not for
network round-trips.

## Deployment order

Apply after `patch-meeting-task-integration.sql` (R5) — this patch
assumes `task_links`, `can_view_task_link()`, `can_manage_task()`, and
`can_view_task()` already exist (R3/R4), plus the widened
`module_key` CHECK and `can_view_task_link()`'s meeting branch (R5).
Idempotent — safe to re-run. Run
`supabase/validate-internal-collaboration-task-integration.sql`
immediately after, in every environment.
