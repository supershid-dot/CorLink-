# 37 — Prisoner Letters ↔ Shared Tasks Integration

This is the fifth and final milestone of the Shared Task Foundation
program (R3–R8).

## Architecture

Fifth consumer of `task_links` (R4 Requests, R5 Meetings, R6 Internal
Collaboration, R7 Entry). `task_links.module_key`'s `CHECK` constraint
widens from `('request', 'meeting', 'internal_request',
'external_correspondence')` to also allow `'prisoner_letter'` — the
canonical value this codebase already uses for this concept everywhere
else (`audit_logs.record_type`, `cc_recipients`/
`attachments.record_type`, `PrisonerLettersAPI`'s own `logAudit()`
calls, all consistently `'prisoner_letter'`, singular — deliberately
**not** `'prisoner_letters'`, the table name, which would have been an
invented alias).

**Attachment point.** Like Entry (R7), Prisoner Letters is a
first-class primary record — `task_links.record_id` is simply
`prisoner_letters.id`. No parent-navigation metadata concern.

Prisoner Letters and Tasks remain fully independent business objects,
same as R4–R7: `task_links.record_id` has no foreign key. No code path
in this patch reads or writes `prisoner_letters.status` from a Task
RPC, or the reverse. Submitting, marking received, routing, replying,
or marking delivered never touches a linked Task; completing/
cancelling a Task never touches its linked letter.

## Confidentiality model (repository evidence)

Prisoner Letters uses a **materially different, stricter** visibility
model than every other module in the Shared Task Foundation program —
confirmed directly from `supabase/rls.sql` and
`supabase/patch-prisoner-letters-staff-flag.sql` (the file that
actually governs the table's live policies; chain-order confirmed —
it runs after `patch-prisoner-registry-section.sql`, so its policy
bodies are the ones in effect):

```sql
is_prisoner_letters_staff()
AND (from_prison_id = get_my_org_id() OR to_org_id = get_my_org_id())
```

`is_prisoner_letters_staff()` is a **per-user boolean flag**
(`users.is_prisoner_letters_staff`), granted individually via Admin >
Manage User — **not** a section membership, **not** a role, and — per
that patch file's own comment — "deliberately with NO automatic bypass
for supervisors/admins." This is the strongest confidentiality gate of
any module in CorLink: even an org admin or supervisor cannot see a
prisoner letter, or now a Task linked to one, without the individual
flag.

`can_view_prisoner_letter()` mirrors this predicate **verbatim** — no
narrowing, no widening. `can_manage_prisoner_letter_task_link()`
reuses it directly (`= can_view_prisoner_letter()`), the same
technique R4's/R7's own `can_manage_..._task_link()` helpers used —
the real `prisoner_letters_update` RLS policy is exactly as coarse as
`prisoner_letters_select` (same predicate, no `assigned_to`/supervisor
narrowing at the database layer).

**Disclosed observation, not fixed (out of scope)**:
`js/data/prisoner-letters-api.js`'s own top-of-file comment describes
a narrower intended actor set for replying/advancing status ("the
assigned staff member, the original submitter, or a supervisor at
either participating org") and cites `prisoner_letters_update` RLS as
the enforcement — but the actual RLS predicate on that table has no
such narrowing; the narrower behavior is enforced only client-side
(`prisoner-letter-detail.js`'s own button gating: `isSubmitter`,
`isAssignee`, `isSupervisor`, checked in JS, not SQL). This milestone
deliberately reuses the *real*, currently-enforced database predicate
— not the aspirational UI-only one described in that comment —
because inventing a narrower DB-level check here that doesn't exist
anywhere else on this table would be new authorization design, not
reuse, and the milestone's own instruction was "reuse existing... do
not redesign."

## Authorization matrix

| Actor | View | Manage (create/link/unlink) |
|---|---|---|
| Any `is_prisoner_letters_staff`-flagged user at `from_prison_id`'s org | Yes | Yes |
| Any `is_prisoner_letters_staff`-flagged user at `to_org_id`'s org | Yes | Yes |
| Same-org user **without** the flag | **No** | **No** |
| Cross-org user (flagged or not) | **No** | **No** |

No leakage of: hidden letters (a viewer without the flag gets `FALSE`
from `can_view_prisoner_letter()`, identically whether the letter id
is real or fabricated — verified, see "Behavioral tests"), hidden
Tasks (two-sided `can_view_task_link()`), letter existence (the
capabilities RPC returns uniform all-false booleans, never a
distinguishable "not found" vs. "not authorized" response), prisoner
information (never queried or exposed by any new RPC — only
`prisoner_name`/`reference_number`/`status` are surfaced by
`list_task_prisoner_letter_links()`, matching R4's own
`list_task_request_links()` shape, not the full `prisoner_letters` row
or anything from the `prisoners` registry), or cross-organization
information (`from_prison_id`/`to_org_id` both checked explicitly on
every RPC, same technique R4's dual-org Requests used).

**Module enablement**: `platform_modules` registers a
`prisoner_correspondence` module key, and `AppShell.canAccessPrisonerLetters()`
+ `isModuleEnabled(user, 'prisoner_correspondence')` gates the
client-side nav link — but this is **client-side UI convenience only**.
Inspected directly: none of `prisoner_letters_select`/`_insert`/
`_update` call `current_user_module_enabled(...)` at the RLS layer
(unlike Meetings/Rooms, which do). Per "reuse existing... module
enablement," this milestone's helpers mirror that reality — no
`current_user_module_enabled('prisoner_correspondence')` check was
added to `can_view_prisoner_letter()`, since the real table-level RLS
this function mirrors has none either. Inventing a stronger DB-level
restriction than the actual reused policy enforces would not be reuse.

## Business rules (status flow: `submitted → received → replied → delivered`)

| Status | What the repo's own UI actually offers (`prisoner-letter-detail.js`'s `_renderActions()`) |
|---|---|
| `submitted` | Destination-org supervisor: Mark Received, Route to Section (if unrouted); MCS side: Print Hand-over Slip |
| `received` | Assignee or destination-org supervisor: Draft Reply (once, if no reply exists yet) |
| `replied` | MCS-side submitter/supervisor: Mark Delivered |
| `delivered` | **Nothing** — `_renderActions()` renders zero buttons; attachment upload also locks on both sides (`l.status !== 'delivered'` gate) |

**Delivered letters restrict Task creation** (per the milestone's own
instruction, matching the `delivered` row's own zero-actions
behavior): `create_prisoner_letter_supporting_task()` and
`link_existing_task_to_prisoner_letter()` both reject a `delivered`
letter. `unlink` has no such gate — soft-removing a stale reference is
never "new work," matching R4–R7's own unlink RPCs.

## RLS

No new table this milestone (`prisoner_letters` already existed), so
no new RLS policy either — `task_links_select` (R4) already covers
this `module_key` value once `can_view_task_link()` knows about it.
SELECT-only, RPC-only writes, unchanged.

## RPCs

All 8 new functions, `SECURITY DEFINER` with `SET search_path = public,
pg_temp` (RPCs + helpers) or plain SQL relying on RLS (the two `list_*`
functions):

| RPC | Purpose |
|---|---|
| `can_view_prisoner_letter(id)` | Helper: mirrors `prisoner_letters_select` verbatim |
| `can_manage_prisoner_letter_task_link(id)` | Helper: `= can_view_prisoner_letter()` |
| `create_prisoner_letter_supporting_task(...)` | Creates a Task (via `create_task()`), assigns it (via `assign_task()`), links it — atomically, blocked on a delivered letter |
| `link_existing_task_to_prisoner_letter(task_id, letter_id)` | Links a Task the actor can already manage, blocked on a delivered letter |
| `unlink_task_from_prisoner_letter(link_id, reason)` | Soft-removes the link; never touches Task or letter status; no delivered-letter gate |
| `list_prisoner_letter_tasks(letter_id, ...)` | Active links + Task summary for the letter, paginated |
| `list_task_prisoner_letter_links(task_id, ...)` | Active links + letter summary (prisoner name, status, reference number only) for a Task — future Task Detail data source |
| `get_prisoner_letter_task_capabilities(letter_id)` | Four booleans only, fails closed |

`can_view_task_link()` (already widened four times by R5/R6/R7) gained
a fifth and final `module_key='prisoner_letter'` branch via `CREATE OR
REPLACE FUNCTION` — R4's/R5's/R6's/R7's own files are never touched.

## UI implementation

Prisoner Letters has one detail page
(`js/views/prisoner-letter-detail.js`) — the Supporting Tasks panel
(`_renderSupportingTasks(l)`) was added right after the letter/reply
thread and before the Actions panel, reusing R4's exact CSS classes —
**zero new CSS**. This file had none of `_renderTaskCard`/
`_taskStatusBadgeClass`/`_taskPriorityBadgeClass`/`_capitalizeWords`/
`_rerender` (it's a separate top-level view object from
`request-detail.js`/`entry-detail.js`, with no shared module to hold
them), so all five were duplicated here, matching R6's/R7's own
precedent for the identical situation.

States, driven entirely by real server-fetched state
(`this._taskCapabilities`/`_supportingTasks`/`_supportingTasksError`,
populated in `_load()`):

- **Hidden** — `get_prisoner_letter_task_capabilities().can_view_tasks`
  false (includes a genuinely nonexistent letter and a real-but-hidden
  one identically).
- **Loading** — fetched alongside the letter/replies/attachments in
  `_load()`'s existing sequence, isolated in its own `try`/`catch`.
- **Empty** — `<p class="structure-empty">Nothing here yet.</p>`.
- **Populated** — one `.task-card` per linked task: task number,
  title, status/priority badges, owning section, assignees, due-date
  chip (`RequestsView._deadlineCell()`, cross-file reuse — confirmed
  `requests.js` loads before `prisoner-letter-detail.js` in
  `index.html`, same as R6/R7 rely on).
- **Error** — isolated, own inline error, never blanks the page.
- **Load More** — genuine pagination via a newly-added `_rerender()`
  (this file had no lightweight re-render path before this milestone,
  every prior mutation used a full `_load()` reload — same situation
  R7 found in `entry-detail.js`).

Create/Link/Unlink reuse this file's own established mutation pattern
(`_runAction()`/full `_load()` reload). **Create Supporting Task** asks
only for R3's supported fields — no auto-copying of the letter's own
body, prisoner details, or reply content. Owning-section/staff pickers
resolve `ownOrgId` the same way `request-detail.js`'s own create-task
modal does (the actor's own org, whichever of the letter's two parties
it is) and fetch fresh via `AdminAPI.listSectionsByOrg`/
`listUsersByOrg` on every open (no caching). **Link Existing Task**
reuses the same bounded, client-narrowed `TasksAPI.listTasks({
organizationId, limit: 200 })` search R4–R7 already established.

## Error isolation

The Supporting Tasks fetch is wrapped in its own `try`/`catch`,
separate from the letter/replies/attachments fetch — a failure never
blanks the page or breaks the reply thread, attachments, or the
Actions panel.

## Audit

**No `audit_logs` schema change was needed** — the third milestone in
a row (after R6, R7) to need zero. `record_type='prisoner_letter'` was
already valid (present since long before this milestone);
`action IN ('task_linked', 'task_unlinked')` (added by R4) is reused
as-is.

**Disclosed pre-existing gap, not fixed (out of scope)**:
`can_view_case_audit_record()` has **no** `prisoner_letter` branch at
all — confirmed by inspecting the function directly (it has branches
for `request`, `response`, `internal_request`, and
`external_correspondence`, but never `prisoner_letter`). This means
`task_linked`/`task_unlinked` rows for this module are visible only to
org admins via the base `audit_select` policy, not to the
`is_prisoner_letters_staff`-flagged audience that can otherwise see
everything else about the letter — the exact same shape of gap R5
found for `record_type='meeting'`. This milestone does not add a
branch (that would require modifying `rls.sql`, the file that governs
every other module's audit visibility too, which is out of scope for
a single-module integration) — the behavioral test for audit
visibility is bracketed with a superuser `RESET ROLE` bypass, matching
R5's own precedent exactly.

Task activity is not merged into the letter's own thread —
`prisoner-letter-detail.js` has no audit-trail rendering surface at
all (no `_renderAuditEvents()`/`_renderProcessEvents()` equivalent
anywhere in the file), so there is nothing to exclude
`task_linked`/`task_unlinked` from.

## Notifications

**Deliberately omitted**, same reasoning as R4–R7:
`create_prisoner_letter_supporting_task()` already fans out
`task_assigned` via its reused `assign_task()` calls; linking/
unlinking is a lightweight cross-reference, not new work. No
Prisoner-Letter-specific Task notification type was added.

## Validation

`supabase/validate-prisoner-letter-task-integration.sql` confirms the
widened `module_key` CHECK (preserves all four prior values, adds
`prisoner_letter`, rejects a sixth placeholder value), that R4's
original `task_links` indexes are still intact, `can_view_task_link()`'s
new branch specifically (plus all four prior branches survived), a
shape spot-check on `can_view_prisoner_letter()`
(`is_prisoner_letters_staff`/`from_prison_id`/`to_org_id` all present),
every new helper/RPC, `search_path` pinning, that `task_links` still
carries exactly one SELECT-only policy, and a live
active-link-uniqueness smoke test with a `prisoner_letter` value.
Hard-fails if anything is missing.

## Behavioral tests

`supabase/test-prisoner-letter-task-integration.sql` — 18 scenarios
against disposable fixtures (three orgs — Org P/MCS the submitting
side, Org Q/authority the destination side, Org R a wholly unrelated
third org — an `is_prisoner_letters_staff`-flagged user at each of P
and Q, a **same-org-as-Q but unflagged** user (the confidentiality
test's own fixture), a flagged user at unrelated Org R, and three
letters: two open siblings and one `delivered`). Covers create/link/
unlink, both directions of "sees one side but not the other,"
cross-org denial, the confidentiality gate specifically (same org,
missing flag — distinct from and in addition to cross-org denial),
duplicate-link rejection, delivered-letter restrictions (create/link
blocked, view/unlink still allowed) plus sibling isolation, both
directions of lifecycle independence, deterministic pagination,
direct-write denial, audit visibility via the disclosed superuser
bypass, and a standalone-task regression check. Confirmed idempotent
across 3 consecutive runs on a freshly built database.

One fixture-design issue was caught while writing this file (not an
application bug): the original TEST 4 fixture tried to assign a
cross-org user (`otherorg`, a different organization entirely) to a
task, which `assign_task()` itself correctly rejects (`"Assignee must
be an active user in the task's organization"`) — cross-org assignment
was never the intended scenario for that direction of the visibility
test. Fixed by using `non_staff` (same org as the task, genuinely
assignable, but lacking the confidentiality flag) instead, which is
also the more precise fixture for "sees the Task, not the Letter,"
since it isolates the confidentiality flag specifically rather than
conflating it with org membership.

Also re-ran `supabase/test-request-task-integration.sql` (R4),
`supabase/test-meeting-task-integration.sql` (R5),
`supabase/test-internal-collaboration-task-integration.sql` (R6), and
`supabase/test-entry-task-integration.sql` (R7) end-to-end against
this same R8-patched database (3 consecutive times each) — all four
passed identically to their pre-R8 runs.

## Fresh database verification

Full migration chain (legacy baseline → Meetings/Rooms → R2 → R3 → R4
→ R5 → R6 → R7 → R8) applied cleanly from scratch; all 6 validators
pass; all 5 behavioral test suites pass.

## Performance

No new index needed — `EXPLAIN` confirms `idx_task_links_record_active_created`
(R4) is used directly via its leading `(module_key, record_id)`
columns for `list_prisoner_letter_tasks()`'s letter-scoped lookup —
`'prisoner_letter'` is simply another value in the same composite
index. All pagination is server-side `LIMIT`/`OFFSET` (no unbounded
query, no raw `COUNT` leak — `total_count` via `COUNT(*) OVER()`). No
N+1 capability loop: the letter page fetches capabilities + first task
page in one batched `Promise.all` alongside everything else `_load()`
already fetches.

## Rollback

`docs/rollback/010-prisoner-letter-task-integration.md` —
dependency-detection refusal, the real prerequisite failure (live
`prisoner_letter` rows present), clean rollback after clearing them,
and reapply-and-revalidate all tested end-to-end against a live
instance. `supabase/validate-request-task-integration.sql` (R4),
`supabase/validate-meeting-task-integration.sql` (R5),
`supabase/validate-internal-collaboration-task-integration.sql` (R6),
and `supabase/validate-entry-task-integration.sql` (R7) all confirmed
to pass identically immediately after this rollback.

## Deployment order

Apply after `patch-entry-task-integration.sql` (R7) — this patch
assumes `task_links`, `can_view_task_link()`, `can_manage_task()`, and
`can_view_task()` already exist (R3/R4), plus the widened `module_key`
CHECK and `can_view_task_link()`'s meeting/internal_request/
external_correspondence branches (R5/R6/R7). Idempotent — safe to
re-run. Run `supabase/validate-prisoner-letter-task-integration.sql`
immediately after, in every environment. This is the final migration
in the Shared Task Foundation program (R3–R8) — all five in-scope
modules (Requests, Meetings, Internal Collaboration, Entry, Prisoner
Letters) are now integrated with `task_links`.
