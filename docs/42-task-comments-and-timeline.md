# 42 — Task Comments & Timeline (T2C)

Adds an "Activity" panel to Task Detail (docs/41): `task_comments`
(full content) merged with `audit_logs`-derived lifecycle events into
one chronological feed, plus a comment composer. Attachments,
Assignment/Watcher editing, Related Tasks, Dashboard, Saved Filters,
and lifecycle-action implementation (Complete/Cancel/Assign/Unassign
still don't mutate — docs/41) remain explicitly out of scope.

## Architecture

**No SQL, RPC, index, or policy was added.** Reuses `add_task_comment()`
for writes and two plain `SELECT`-RLS reads for the feed: the existing
`TasksAPI.fetchTaskComments()` (unchanged, already existed) and one new
`TasksAPI.fetchTaskAuditTrail()` in `js/data/tasks-api.js`, which is the
same `.from('audit_logs').select('*, user:users(full_name,
designations(name))').eq('record_type', ...).eq('record_id',
...).order('created_at')` shape `MeetingsAPI.fetchSeriesAuditTrail()`
and `RequestsAPI`'s own case-audit read already use — copied, not
reinvented.

`js/views/task-detail.js` gains: `_loadActivity()`, `_commentEvent()`,
`_auditEvent()`, `_activityHtml()`/`_activityEventHtml()`,
`_commentFormHtml()`/`_bindActivityPanel()`. The Activity panel loads
independently of the rest of the page (its own loading/retry state) —
the same pattern the Supporting Tasks panels on
`request-detail.js`/`entry-detail.js`/`meetings.js`/`prisoner-letter-
detail.js` already use, so a slow or failing activity fetch never
blocks the header/details/linked-records from rendering.

`css/style.css` gains one small block (`.task-activity-feed` /
`.task-activity-item` / `.task-activity-comment-body` /
`.task-activity-comment-form`) — everything else (`.panel`,
`.field-input-plain` including its existing `textarea.field-input-
plain { resize: vertical; min-height: 90px; }` rule, `.empty-state`,
`.alert-error`, `.structure-empty`) is reused as-is.

## Components

**Activity panel** (new, in the main column after Linked Records):
a single merged list, each item either a real comment (author, full
body text, timestamp) or a lifecycle event (actor, readable action
description, timestamp) — visually distinguished only by whether a
body is present, never as two separate sections. Below the list, a
comment composer (`<textarea>` + Comment button).

**No separate "Comments" or "Audit" section exists anywhere in the UI**
— satisfying the T2C brief's explicit "they should appear together"
requirement structurally, not just visually.

## Ordering rules

**Chronological, oldest first.** This was a judgment call the T2C brief
explicitly left open ("newest activity should appear first unless
existing CorLink convention requires chronological order") — checked
against the actual codebase before deciding: `RequestsAPI.getConversation()`
orders `.order('created_at', { ascending: true })`,
`MeetingsAPI.fetchSeriesAuditTrail()` orders the same way, and
`TasksAPI.fetchTaskComments()` itself (already shipped, unchanged) also
defaults to ascending. Every existing timeline/conversation/audit-trail
read in this codebase is chronological — that is the convention, so
this panel follows it rather than introducing the one
newest-first exception.

**Comment/audit de-duplication.** `add_task_comment()` writes both a
`task_comments` row (with the real body) AND an `audit_logs` row with
`action = 'commented'` (no body — see its own `INSERT` in
`patch-shared-task-foundation.sql`, which supplies no `notes`). Showing
both would render the same comment event twice with no added
information from the audit copy. `action = 'commented'` audit rows are
therefore explicitly skipped when building the merged feed — the real
`task_comments` row is what represents that event. Verified in
`supabase/test-task-audit-visibility.sql` TEST 8 (both rows genuinely
exist after a real `add_task_comment()` call) and independently in the
T2A/T2B/T2C headless frontend harness (only one rendered event, not
two).

**Deterministic tie-ordering (added T2C.1).** Two events sharing an
identical `created_at` (two rows written in the same transaction/
millisecond) no longer rely on `Array.prototype.sort`'s stability
alone. `js/views/task-detail.js`'s sort comparator breaks ties in a
fixed order: `created_at ASC`, then a fixed item-type/action rank
(`_AUDIT_TYPE_RANKS`: created < edited < assigned < unassigned <
completed < cancelled; comments always rank after any audit event at
the same instant), then the row's own `id ASC` as the final,
always-unique tie-break. This guarantees the same rendered order on
every load, in every browser/JS engine — verified with a dedicated
fixture (two audit rows at an identical timestamp, deliberately
inserted array-side in reverse-`id` order) in the headless harness.

## Permission behavior

**No new authorization logic was written for reads.** `task_comments`
and `audit_logs` are both plain `SELECT`-RLS tables; this panel makes
no visibility decision of its own — a row either comes back (RLS
allowed it) or doesn't. The comment composer is unconditionally shown
on any successfully-loaded Task Detail page, because reaching that page
at all already required `can_view_task()` to be true (`get_task()`'s
own RLS gate), and `add_task_comment()`'s only authorization check is
that same `can_view_task()` — so no additional client-side permission
mirror was needed for it (unlike the Actions panel's Complete/Cancel/
Assign/Unassign buttons in docs/41, which do mirror a real predicate).
A comment submission failing with an authorization error is therefore a
genuine, if rare, race (e.g. visibility changed mid-session) rather
than a normal expected path — handled with a distinct, friendlier
message, not new logic deciding who gets to comment.

### Task audit visibility — corrected in T2C.1

T2C's original release found and disclosed (but deliberately did not
fix) a real gap: `can_view_case_audit_record()` (`supabase/rls.sql`) —
the function `audit_logs`' `audit_select_own_records` policy calls to
decide whether an *ordinary* (non-admin) user can see a given audit
row — had branches for `record_type IN ('request', 'response',
'internal_request', 'external_correspondence', 'meeting_series')` only,
with **no branch for `record_type = 'task'`**. An ordinary task viewer
(creator, assignee, watcher, section member, org-visibility) reading
`audit_logs WHERE record_type = 'task'` got zero rows back regardless
of how much genuine task history existed — only an org admin or super
admin (via the separate `audit_select` policy) could see it. This made
the Timeline show comment events correctly but no lifecycle events at
all for most real users.

**A dedicated follow-up milestone (T2C.1,
`supabase/patch-task-audit-visibility.sql`) has since closed this gap**
for `record_type = 'task'` specifically. The new branch does not
reimplement task visibility rules — it delegates directly:

```sql
OR (p_record_type = 'task' AND can_view_task(p_record_id));
```

`can_view_task()` (`supabase/patch-shared-task-foundation.sql`) is
already the single source of truth for task visibility — the same
function that gates `tasks_select`, every task child-table policy, and
every task-mutating RPC's own authorization check. Delegating rather
than re-deriving means any future change to who can see a task only
ever needs to happen in that one place, never here too.

All five prior branches (`request`/`response`/`internal_request`/
`external_correspondence`/`meeting_series`) are preserved byte-for-byte
— verified via `pg_get_functiondef()` diff before/after, and via a
rollback→reapply cycle (`docs/rollback/011-task-audit-visibility.md`)
that confirmed the rollback SQL genuinely reproduces the original
zero-rows behavior and reapplication genuinely restores the fix.
`supabase/test-task-audit-visibility.sql` covers creator, active
assignee, active watcher, an authorized section-scoped supervisor
(all see it), unrelated same-org staff and a cross-org user (neither
sees it, and an unauthorized `SELECT *` returns zero rows with no error
and no leakage of existence), the comment/audit dual-write from TEST 8
above, and confirms Request/Internal Collaboration audit visibility is
unchanged and Prisoner Letter confidentiality remains exactly as
restrictive as before — 11/11 scenarios, run under a real
`authenticated` role via `request.jwt.claims` impersonation, not
superuser-only assertions.

**`record_type IN ('meeting', 'prisoner_letter')` remain separately,
deliberately deferred** — this milestone's explicit scope was `'task'`
only. R9 (docs/38) already found and declined to fix `'meeting'`
(for the same reasoning: proportionate, separately-scoped change), and
Prisoner Letter's confidentiality model is deliberately the strictest
in this codebase (R8) — `supabase/test-task-audit-visibility.sql` TEST
11 explicitly confirms this patch left it untouched, not just that it
happens to still be restrictive.

A second, smaller limitation in the same area remains open: `update_task()`'s
`'edited'` audit row carries no `notes` describing *what* changed —
title, description, priority, due/start date, and a non-terminal status
move (e.g. `open → in_progress`) are all indistinguishable in the audit
trail. Rather than fabricate specificity the data doesn't support (the
T2C brief separately names "Status changes" and "Priority changes" as
desired event types), every `'edited'` row renders with one honest,
generic label ("Updated task details"). Distinguishing them would
require `update_task()` to start writing a description of the diff into
`notes` — a backend change, out of scope for the same reason as above.

## Responsive behavior

No new list/table component — the Activity feed is a plain vertical
list (`.task-activity-feed`), which naturally reflows at any width with
no breakpoint-specific CSS needed. Inherits the same desktop
two-column / tablet-and-mobile single-column collapse as the rest of
Task Detail (docs/41 §Layout, unchanged).

## Testing

**Standing constraint honored: this environment has no staging/
production credentials and must never connect to either** — no browser
test against the real (production-configured) app was possible or
attempted.

What was run:
1. `node --check` on every touched file — all pass.
2. The same isolated, non-repo headless-Chromium harness from T2A/T2B
   (mocked `getSupabase`/`Auth`/`Router`/`AppShell`, zero real network),
   extended with `task_comments`/`audit_logs` mock tables and an
   `add_task_comment` RPC mock, plus a working `.order()` implementation
   in the mock query builder (needed correctness here for the first
   time — earlier milestones' mock data happened to already be in
   order). Verified:
   - A task with 3 audit rows (`created`/`commented`/`edited`) and 1
     real `task_comments` row renders exactly 3 events, not 4 — the
     `commented` audit row is correctly suppressed, and the remaining
     events are in the right chronological order.
   - The real comment's full body text renders correctly.
   - Posting a new comment round-trips through the mocked RPC, the feed
     grows from 3 to 4 events, and the input clears.
   - A task with zero comments and zero audit rows shows "No activity
     yet" (not an error).
   - A comment submission that fails with an authorization-shaped error
     message shows the friendlier "You no longer have permission…"
     wording rather than the raw RPC error.
   - **Full regression**: every T2A (Task List) and T2B (Task Detail
     foundation) scenario from their own harnesses was re-run in the
     same session and still passes — scope visibility, permission
     mirroring, origin resolution (including the meeting-origin bug fix
     from T2B), filtering, pagination, and the not-found/no-access
     states are all unchanged.
   - Zero JavaScript errors across every scenario.
3. **T2C.1 addendum — the audit-visibility gap described above WAS
   independently verified against a live database**, unlike the rest of
   this milestone's testing. A disposable local Postgres replayed the
   real, correctly-ordered migration chain (base schema through every
   module integration), confirmed `can_view_case_audit_record()`'s
   pre-fix definition really did lack a `'task'` branch (not just by
   reading `supabase/rls.sql` — the live, current function body, via
   `pg_get_functiondef()`), applied `supabase/patch-task-audit-
   visibility.sql`, and ran `supabase/test-task-audit-visibility.sql`'s
   11 scenarios under a real `authenticated` role with `request.jwt.claims`
   impersonation — all passing, idempotently, and confirmed via a full
   rollback→reapply cycle. See `docs/rollback/011-task-audit-
   visibility.md` for the rollback verification detail.
4. **Not independently re-verified**: real Supabase-backed auth/session
   flow against staging or production (requires credentials this
   environment does not have and must not use), and the full R2
   `supabase/validate-security-definer-search-path.sql` regression pass
   surfaced one unrelated, pre-existing finding (`update_org_workflow_
   settings()`, a function this milestone never touches, in an
   unrelated legacy feature area) — confirmed identical whether or not
   `patch-task-audit-visibility.sql` is applied, so not a regression
   introduced here; out of this milestone's scope to fix.

## Known Limitations

1. ~~Ordinary (non-admin) users see no lifecycle events, only
   comments~~ — **fixed in T2C.1** (see §Permission behavior above).
2. **`'edited'` events are generic**, since `update_task()`'s audit row
   doesn't record which field changed. Still open — out of T2C.1's
   scope (it corrected *who* can see task audit rows, not *what detail*
   they contain).
3. **Linked-record changes (`task_linked`/`task_unlinked`) never appear
   in a task's own Timeline.** Each module integration (R4–R8) writes
   those audit rows with `record_type` set to the *linked module's*
   record (e.g. `'request'`/the request's id), not `'task'`/the task's
   id — a deliberate design choice made and approved in each of those
   milestones (consistent with each module's own audit trail already
   showing its own task-linking history). This means a task's Timeline
   genuinely cannot show "linked to Request X" today without either a
   backend change (writing a second, dual audit row) or a UI-side
   fabrication of an event the data doesn't actually contain — neither
   was done here, consistent with "do not redesign the backend."
4. **Comments have no language field and are never rendered as rich
   HTML.** `task_comments.body` is plain `TEXT` (no `language` column
   exists, and `add_task_comment()` never calls `RichEditor.sanitize()`
   the way Requests/Entry bodies do at write time). Rendering it as
   `innerHTML` would be a real XSS risk given it was never sanitized as
   rich content, so it is rendered as escaped plain text
   (`white-space: pre-wrap`) instead — "rich text rendering if already
   supported" is honestly not supported today, so none was added.

## Future Enhancements

- ~~Extend `can_view_case_audit_record()` to cover `'task'`~~ — **done,
  T2C.1**. The still-open `'meeting'`/`'prisoner_letter'` gaps from
  docs/38 remain deliberately deferred, each its own explicitly-scoped,
  separately-tested milestone if ever undertaken — T2C.1 intentionally
  did not fold them in (see §Permission behavior above).
- Have `update_task()` write a structured diff into its audit row's
  `notes` so "Status changed to X" / "Priority changed to Y" can be
  shown specifically instead of a generic "Updated task details."
- Decide how (or whether) linked-record changes should surface on a
  task's own Timeline, given the current dual-attribution design.
- Rich text / language support for task comments, if ever desired,
  needs its own schema change (a `language` column) and a sanitize-at-
  write-time pass through `RichEditor.sanitize()` — not something to
  bolt onto the existing plain-text `body` column casually.
