# 36 — Entry ↔ Shared Tasks Integration

## Architecture

Fourth consumer of `task_links` (R4 Requests, R5 Meetings, R6 Internal
Collaboration). `task_links.module_key`'s `CHECK` constraint widens
from `('request', 'meeting', 'internal_request')` to also allow
`'external_correspondence'` — the canonical value this codebase already
uses for the Entry module everywhere else (the `external_correspondence`
table itself, `audit_logs.record_type`, `cc_recipients`/
`attachments.record_type`, `EntryAPI`'s own `logAudit()`). No alias was
invented.

**Attachment point.** Unlike Internal Collaboration (R6), Entry is a
first-class primary record, not a satellite thread anchored to a
parent — `task_links.record_id` is simply `external_correspondence.id`.
There is no "parent navigation metadata" concern the way R6's
`list_task_internal_collaboration_links()` had; `list_task_entry_links()`
mirrors R4's `list_task_request_links()` shape exactly (entry id,
subject, status, reference number).

Entry and Tasks remain fully independent business objects, same as
R4/R5/R6: `task_links.record_id` has no foreign key (deliberate,
matching the existing `cc_recipients`/`audit_logs` precedent) — so
deleting an Entry cannot cascade into tasks, and no code path in this
patch reads or writes `external_correspondence.status` from a Task
RPC, or the reverse. Logging, routing, marking received, assigning,
replying, or closing an Entry never touches a linked Task; completing/
cancelling a Task never touches its linked Entry.

## Workflow decisions (repository evidence)

The Entry lifecycle, confirmed directly from `schema.sql` and
`js/views/entry-detail.js`'s own `_renderActions()`:

| Status | What the repo's own UI actually offers |
|---|---|
| `logged` | Entry staff (`is_entry_staff`): Edit Draft, Route to Section |
| `routed` | Receiving section (`to_section`): Mark as Received; scoped supervisor: Assign/Reassign; assigned user or supervisor: Draft Reply |
| `responded` | Entry staff: Close (once the sent reply has a `delivery_method` recorded) |
| `closed` | **Nothing** — `_renderActions()` renders zero buttons at this status |

Unlike Internal Collaboration (R6), Entry has no clean "asking vs.
receiving, only one side ever does ongoing work" split — Entry staff
themselves take substantive lifecycle actions throughout (not just an
initial hand-off), and the receiving section does the routed-through-
responded work. Every party the existing visibility policy grants
access to is therefore a legitimate case worker at some stage.

**Closed Entries restrict creation/linking** (per the milestone's own
instruction, and matching the `closed` row's own zero-actions
behavior above): `create_entry_supporting_task()` and
`link_existing_task_to_entry()` both reject a `closed` entry. `unlink`
has no such gate — soft-removing a stale reference is never "new
work," matching R4/R5/R6's own unlink RPCs.

## Authorization matrix

There is no pre-existing standalone callable visibility predicate for
Entry (unlike Requests'/Meetings' own reused helpers) —
`external_correspondence_select`'s visibility logic has only ever lived
inline in that one RLS policy and in the `external_correspondence`
branch of `can_view_case_audit_record()`. This milestone introduces
`can_view_entry(id)`, mirroring that policy **verbatim** (no disclosed
deviation needed this time — `assigned_to` was already one of the
policy's own branches, unlike R6's `internal_requests_select`, which
needed one added).

`can_manage_entry_task_link(id)` reuses `can_view_entry()` directly —
the same technique R4's `can_manage_request_task_link()` used
(`= can_view_request_or_response()`). View and manage are the same
predicate here because, per the workflow evidence above, every party
`can_view_entry()` grants access to is already a legitimate case
worker at some stage — narrower than plain org membership
(`is_entry_staff`/`to_section`/`assigned_to`/`entered_by` are all still
individually scoped grants, never "any org member").

| Actor | View | Manage (create/link/unlink) |
|---|---|---|
| Entry staff (`is_entry_staff`) | Yes | Yes |
| `to_section` member | Yes | Yes |
| Entry's `assigned_to` user | Yes | Yes |
| Entry's `entered_by` (logger) | Yes | Yes |
| Section looped in via an Internal Collaboration thread on this Entry | Yes (context only, via `external_correspondence_select_via_internal_collab`) | **No — deliberately excluded, see below** |
| Unrelated same-org section/user | No | No |
| Cross-org user | No | No |

**Deliberate scope decision**: `can_view_entry()` does **not** include
`looped_in_via_internal_collab_entry()` — the grant that lets a
section looped in via R6's own Internal Collaboration feature see
enough of the parent Entry for context. That grant exists for a
*different* feature (R6's own thread-visibility need) and was never
meant to extend into managing the Entry's *own* supporting tasks — a
looped-in section already gets its own task-management surface, scoped
to its own thread, via R6.

No cross-org linking: `external_correspondence.org_id` is a direct
column (unlike Internal Collaboration's derived org) — every RPC
requires the actor's own org, and any linked Task's `organization_id`,
to match it exactly.

## RLS

No new table this milestone (`external_correspondence` already
existed), so no new RLS policy either — `task_links_select` (R4)
already covers this `module_key` value once `can_view_task_link()`
knows about it. SELECT-only, RPC-only writes, unchanged.

## RPCs

All 8 new functions, `SECURITY DEFINER` with `SET search_path = public,
pg_temp` (RPCs + helpers) or plain SQL relying on RLS (the two `list_*`
functions):

| RPC | Purpose |
|---|---|
| `can_view_entry(id)` | Helper: mirrors `external_correspondence_select` verbatim |
| `can_manage_entry_task_link(id)` | Helper: `= can_view_entry()` |
| `create_entry_supporting_task(...)` | Creates a Task (via `create_task()`), assigns it (via `assign_task()`), links it — atomically, blocked on a closed entry |
| `link_existing_task_to_entry(task_id, entry_id)` | Links a Task the actor can already manage, blocked on a closed entry |
| `unlink_task_from_entry(link_id, reason)` | Soft-removes the link; never touches Task or Entry status; no closed-entry gate |
| `list_entry_tasks(entry_id, ...)` | Active links + Task summary for the Entry, paginated |
| `list_task_entry_links(task_id, ...)` | Active links + Entry summary for a Task — future Task Detail data source |
| `get_entry_task_capabilities(entry_id)` | Four booleans only, fails closed |

`can_view_task_link()` (already widened by R5 and R6) gained a fourth
`module_key='external_correspondence'` branch via `CREATE OR REPLACE
FUNCTION` — R4's/R5's/R6's own files are never touched.

## UI implementation

Entry has one detail page (`js/views/entry-detail.js`) — the
Supporting Tasks panel (`_renderSupportingTasks(e)`) was added right
after the (R6) Internal Collaboration panel and before the Actions
panel, reusing R4's exact CSS classes — zero new CSS.
`_renderTaskCard`/`_taskStatusBadgeClass`/`_taskPriorityBadgeClass`/
`_capitalizeWords`/`_rerender` all already existed in this file (added
by R6, for its own per-thread panels) and are reused as-is;
`_renderTaskCard` gained no new parameter beyond what R6 already added
(`unlinkAttr`) — this panel just passes a different value
(`'data-unlink-task'`) than R6's per-thread panels
(`'data-unlink-internal-task'`), so both panel types coexist on the
same page without their Unlink buttons colliding.

States, driven entirely by real server-fetched state
(`this._entryTaskCapabilities`/`_entrySupportingTasks`/
`_entrySupportingTasksError`, populated in `_load()`):

- **Hidden** — `get_entry_task_capabilities().can_view_tasks` false.
- **Loading** — fetched alongside replies/attachments/Internal
  Collaboration threads in `_load()`'s existing sequence, isolated in
  its own `try`/`catch`.
- **Empty** — `<p class="structure-empty">Nothing here yet.</p>`.
- **Populated** — one `.task-card` per linked task: task number,
  title, status/priority badges, owning section, assignees, due-date
  chip.
- **Error** — isolated, own inline error, never blanks the page.
- **Load More** — genuine pagination via `_rerender()` (already added
  by R6 to this file — no network round-trip, appends to in-memory
  state).

Create/Link/Unlink reuse this file's own established mutation pattern
(`_runAction()`/full `_load()` reload). **Create Supporting Task** asks
only for R3's supported fields — no auto-copying of the Entry's own
subject/body/sender details/attachment names. Owning-section/staff
pickers fetch fresh via `AdminAPI.listSectionsByOrg`/
`listUsersByOrg(e.org_id)` on every open (no caching, matching R5's
fix and R6's own precedent). **Link Existing Task** reuses the same
bounded, client-narrowed `TasksAPI.listTasks({ organizationId, limit:
200 })` search R4/R5/R6 already established.

## Error isolation

The Entry-level Supporting Tasks fetch is wrapped in its own
`try`/`catch`, separate from the (R6) per-thread Internal Collaboration
fetches — a failure in either never affects the other, and neither
ever blanks the page, breaks replies/attachments, or breaks the
Actions panel.

## Audit

**No `audit_logs` schema change was needed** — the second milestone in
a row (after R6) to need zero. `record_type='external_correspondence'`
was already valid (added by `patch-entry-module.sql`, long before this
milestone); `action IN ('task_linked', 'task_unlinked')` (added by R4)
is reused as-is. `can_view_case_audit_record()` already had a full
`external_correspondence` branch mirroring
`external_correspondence_select` — so `task_linked`/`task_unlinked`
rows are visible to the exact same audience as the Entry itself, with
**no RLS bypass needed**, verified directly. Task activity is **not**
merged into `_renderProcessEvents()`'s own timeline — it already passes
a fixed action allow-list (`['routed', 'assigned', 'received']`) that
excludes `task_linked`/`task_unlinked`, matching R4's and R6's
identical decision.

## Notifications

**Deliberately omitted**, same reasoning as R4/R5/R6:
`create_entry_supporting_task()` already fans out `task_assigned` via
its reused `assign_task()` calls; linking/unlinking is a lightweight
cross-reference, not new work. No Entry-specific Task notification
type was added.

## Validation

`supabase/validate-entry-task-integration.sql` confirms the widened
`module_key` CHECK (preserves `request`/`meeting`/`internal_request`,
adds `external_correspondence`, rejects a fifth value like
`prisoner_letter`), that R4's original `task_links` indexes are still
intact, `can_view_task_link()`'s new branch specifically (plus all
three prior branches survived), a shape spot-check on `can_view_entry()`
(`is_entry_staff`/`to_section_id`/`assigned_to`/`entered_by` all
present), every new helper/RPC, `search_path` pinning, that `task_links`
still carries exactly one SELECT-only policy, and a live
active-link-uniqueness smoke test with an `external_correspondence`
value. Hard-fails if anything is missing.

## Behavioral tests

`supabase/test-entry-task-integration.sql` — 17 scenarios against
disposable fixtures (an org with an explicitly-configured
`entry_sections` row — needed so `is_entry_staff()` actually scopes to
one section rather than falling back to "any org member," which would
make the cross-section-denial test meaningless — two orgs, an entry
section, a receiving section, an outsider section, a cross-org
section, and three Entries: two routed siblings and one closed).
Covers create/link/unlink, both directions of "sees one side but not
the other," cross-org and cross-section denial, duplicate-link
rejection, closed-entry restrictions (create/link blocked, view/unlink
still allowed) plus sibling isolation, both directions of lifecycle
independence, deterministic pagination, direct-write denial, audit
visibility without an RLS bypass, and a standalone-task regression
check. Confirmed idempotent across 3 consecutive runs on a freshly
built database.

One real, instructive authorization-asymmetry issue was caught while
writing this file (not a bug — a design characteristic worth
documenting): `entry_staff` has manage authority over any Entry (via
`is_entry_staff()`) without necessarily having **Task-side** visibility
of a specific task someone else created with section-scoped or
private visibility — `can_manage_task()`/`can_view_task()` are
independent predicates from the Entry side entirely. Several tests
initially used `entry_staff` as the actor for assertions that read
`task_links`/called `assign_task()`/`link_existing_task_to_entry()`
afterward, which either silently under-tested (RLS-filtered to 0 rows
for reasons unrelated to the thing under test) or hard-failed for the
wrong reason (an unrelated `can_manage_task()` rejection masking the
actual assertion). Fixed by using an actor who has genuine visibility
*and* manage authority over the specific task in question (typically
`receiving`, the task's actual creator in these fixtures) for every
test that inspects task-side state afterward, while keeping
`entry_staff` for the tests that only need Entry-side authority
(closed-entry capability checks, audit visibility, standalone-task
creation). No application code change was needed — this is exactly
the intended two-sided visibility behavior working correctly; only the
test fixtures needed adjusting.

Also re-ran `supabase/test-request-task-integration.sql` (R4),
`supabase/test-meeting-task-integration.sql` (R5), and
`supabase/test-internal-collaboration-task-integration.sql` (R6)
end-to-end against this same R7-patched database (3 consecutive times
each) — all three passed identically to their pre-R7 runs.

## Fresh database verification

Full migration chain (legacy baseline → Meetings/Rooms → R2 → R3 → R4
→ R5 → R6 → R7) applied cleanly from scratch; all 5 validators pass;
all 4 behavioral test suites pass.

## Performance

No new index needed — `EXPLAIN` confirms `idx_task_links_record_active_created`
(R4) is used directly via its leading `(module_key, record_id)`
columns for `list_entry_tasks()`'s entry-scoped lookup —
`'external_correspondence'` is simply another value in the same
composite index. All pagination is server-side `LIMIT`/`OFFSET` (no
`OFFSET`-only unbounded query, no raw `COUNT` leak — `total_count` via
`COUNT(*) OVER()`). No N+1 capability loop: the Entry page fetches
capabilities + first task page in one batched `Promise.all` alongside
everything else `_load()` already fetches.

## Rollback

`docs/rollback/009-entry-task-integration.md` — dependency-detection
refusal (simulated future module widening), the real prerequisite
failure (live `external_correspondence` rows present), clean rollback
after clearing them, and reapply-and-revalidate all tested end-to-end
against a live instance. `supabase/validate-request-task-integration.sql`
(R4), `supabase/validate-meeting-task-integration.sql` (R5), and
`supabase/validate-internal-collaboration-task-integration.sql` (R6)
all confirmed to pass identically immediately after this rollback.

## Deployment order

Apply after `patch-internal-collaboration-task-integration.sql` (R6) —
this patch assumes `task_links`, `can_view_task_link()`,
`can_manage_task()`, and `can_view_task()` already exist (R3/R4), plus
the widened `module_key` CHECK and `can_view_task_link()`'s meeting and
internal_request branches (R5/R6). Idempotent — safe to re-run. Run
`supabase/validate-entry-task-integration.sql` immediately after, in
every environment.
