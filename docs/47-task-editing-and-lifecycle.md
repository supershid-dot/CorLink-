# 47 — Task Editing & Lifecycle Actions (T3C)

Makes Task Detail fully interactive: the Details panel becomes editable
(Title, Description, Priority, Due Date, Visibility), and Complete/Cancel
become real, RPC-backed actions instead of the non-mutating placeholders
T2B originally shipped. Explicitly not implemented, per spec: Attachments,
Related Tasks, Saved Views, calendar, Kanban, Gantt, Dashboard changes,
new reporting, and bulk editing.

## Architecture

**No SQL, RPC, table, policy, or index was added.** Every mutation in
this milestone goes through an RPC that already existed and was already
wrapped in `js/data/tasks-api.js` before T3C began —
`update_task()`/`complete_task()`/`cancel_task()` via
`TasksAPI.updateTask()`/`completeTask()`/`cancelTask()`. No changes were
needed in `tasks-api.js` at all.

**Editing reuses `get_task()`'s own already-fetched task object** to
pre-fill the form and, on save, calls `update_task()` and then reloads
the whole page via the existing `_load()` — the same "re-fetch from the
source of truth rather than hand-patch local state" choice every prior
mutation on this page (comments, assignees, watchers) already makes.
This one call refreshes the header, badges, the Details display, the
Actions panel's eligibility, and the Activity panel's new lifecycle
event, all from one round trip.

## Editable fields

| Field | Editable? | Why |
|---|---|---|
| Title | Yes | `update_task(p_title, ...)` |
| Description | Yes | `update_task(p_description, ...)` |
| Priority | Yes | `update_task(p_priority, ...)` |
| Due Date | Yes, with one caveat | `update_task(p_due_date, ...)` — see below |
| Visibility | Yes | `update_task(p_visibility, ...)` — supported by the RPC; T2B only ever *displayed* it, this milestone is what makes it genuinely editable |
| Start Date | No | Not requested by the T3C spec's editable-field list; left as T2B's existing read-only display |
| Classification | No, not even read-only | **No such column exists on `tasks`** (confirmed against `patch-shared-task-foundation.sql`'s `CREATE TABLE tasks` — id/task_number/title/description/status/priority/due_date/start_date/completed_at/completed_by/created_by/organization_id/owning_section_id/visibility/timestamps only). T2B's own docs/41 already made this exact call for the same field ("rather than fabricate a value... simply omitted") — T3C keeps that decision as-is rather than introducing a new "Not available" row for a field that was never displayed at all, staying consistent with the established precedent for this specific field. |

**`update_task()`'s own SQL uses `COALESCE(p_x, x)` for every column** —
passing `NULL` always means "leave this field unchanged," never "clear
it." This has one real, user-facing consequence: **a due date, once
set, cannot be cleared via `update_task()`.** Rather than silently
sending `NULL` (which would look like a successful clear but actually
leave the old date in place), the edit form detects this specific case
client-side — the due-date field is blank on submit, but the task
already had a due date — and blocks the save with an explicit message,
rather than either fabricating a "clear" capability the backend doesn't
have or silently no-op'ing without telling the user why.

Title is also guarded client-side against a blank/whitespace-only
value — not a new rule invented for this milestone, but a direct mirror
of the table's own `title CHECK (btrim(title) <> '')` constraint
(`create_task()` enforces the same thing explicitly; `update_task()`
relies on the table's own CHECK). This avoids a save attempt the
backend would reject anyway with a raw constraint-violation message,
without introducing any restriction the backend doesn't already have.

**Editing is not status-gated.** `update_task()` itself has no check
preventing it from being called against a `completed` or `cancelled`
task's other fields (its only status-related guard blocks *setting*
`status` to `completed`/`cancelled` directly — `IF p_status IN
('completed','cancelled') THEN RAISE EXCEPTION 'Use complete_task() or
cancel_task()...'`, which this milestone never sends anyway). Since the
backend genuinely allows it, no extra client-side restriction was added
to hide Edit once a task reaches a terminal status — inventing one would
be a fabricated rule the RPC doesn't actually enforce.

## Lifecycle

Complete and Cancel call `complete_task()`/`cancel_task()` directly — no
client-side status-transition logic is duplicated. `_actionsHtml()`'s
own eligibility check (`canComplete`/`canCancel`) mirrors
`valid_task_status_transition()`'s allow-list purely so an action that
would obviously fail server-side is never even offered; the RPC and its
`trigger_check_task_status()` trigger remain the sole, final authority
regardless of what the UI shows. Other transitions the same allow-list
table permits (`draft`→`open`, `waiting`↔`in_progress`, etc.) are
intentionally **not** exposed — T3C's own scope is Complete/Cancel only,
per spec; `update_task()` could technically be used to drive some of
these (it isn't blocked from setting non-terminal statuses), but doing
so here would be scope creep beyond what this milestone asked for.

Both `complete_task()`/`cancel_task()` already accept an optional
`p_notes`/`p_reason` parameter (used for the `audit_logs` row they
insert). The confirmation modal exposes this as an optional Notes/Reason
field — reusing an existing, already-supported RPC parameter, not
adding anything new.

## Confirmation

Both actions require an explicit confirmation step before the RPC is
called: clicking Complete or Cancel opens a modal with a clear
description of the (irreversible-from-here) action, an optional notes
field, and two buttons — a destructive-toned Confirm and a neutral
Back. Dismissing via Back (or the modal's own overlay-click/close
handling, already generic to every modal in this app) performs no
mutation at all. This app has no `.btn-danger` CSS class; Cancel's
confirm button reuses the exact same inline destructive-tone style
(`background:var(--color-error-bg); color:var(--color-error-dark)`)
`js/views/meetings.js`'s own delete confirmations already use, rather
than inventing a new button variant for this one case.

## Permissions

**No authorization logic was duplicated — but one existing mirror was
corrected.** `_canManage()` (creator / supervisor-in-scope / admin) was
already used by T2D for assignee management, and correctly matches
`assign_task()`/`unassign_task()`/`cancel_task()`'s own authorization
shape. `update_task()` and `complete_task()`, however, **also** allow an
**active assignee** who is neither the creator nor a supervisor — a
branch `_canManage()` alone doesn't cover. `_actionsHtml()`'s existing
`canComplete` check already correctly mirrored this
(`canManage() || isActiveAssignee()`); this milestone adds the same
correction as a new `_canEdit()` helper, used to gate the Edit button.
Without it, an assignee the backend would genuinely let edit a task
would have seen no Edit control at all — under-mirroring the real RPC,
not over-restricting it. `_canManage()` itself is unchanged and remains
correct for Cancel (which has no assignee branch).

No new RLS, policy, or backend authorization was added or changed —
every button shown here is a display-layer mirror of an RPC predicate
that already existed; the RPC itself remains the actual, only
enforcement.

## Validation

Client-side validation is limited to the two cases above (blank title,
attempted due-date clear) — both direct translations of a real backend
constraint into an actionable message, not invented client-only rules.
Every other validation error — including a permission race (e.g.
visibility changed mid-session) or any other backend rejection — is
surfaced verbatim from the RPC's own error message, displayed inline in
the form/modal, exactly as this app already does for every other
mutation (comments, assignee add/remove, watch/unwatch).

## Loading behavior

Saving, Completing, and Cancelling all follow the same shape already
established by `_runPeopleMutation()` for assignee/watcher actions:
the triggering button (and its sibling Cancel/Back button) disables and
shows a spinner + in-progress label; on success the whole page reloads
from `_load()`; on failure both buttons re-enable, the form/modal stays
open with the user's input intact (never silently reverted), and an
inline error explains what happened. A failed save or lifecycle action
never leaves the UI in an ambiguous "did it work?" state.

## Refresh behavior

**No new cache-invalidation code was written, because none was
needed.** This app's router (`js/router.js`) re-invokes a view's own
`render()` on every hash-change navigation — there is no
route-level caching or "already mounted, skip re-fetch" behavior
anywhere in this codebase, and every view's `render()` has always
issued a fresh fetch on every call (confirmed and relied on identically
by T2A's Task List, T3A/T3B's Dashboard, and every other view in this
app). Task Detail is also its own full-page route, never a modal layered
over the Task List or Dashboard — so "already open" for either of those
can only ever mean "the user navigates there next," at which point their
own `render()` already re-fetches unconditionally. The spec's "Refresh
Task List if already open / Refresh Dashboard widgets if already open"
requirement is therefore satisfied structurally by the existing
architecture, not by new plumbing — verified directly (not just
assumed) in testing: completing a task from Task Detail, then rendering
`TasksView` and `TaskDashboardView` fresh, confirms both immediately
reflect the new status with zero additional code.

## Responsive behavior

The edit form and confirmation modals reuse this app's existing form
(`.field-group`/`.field-label`/`.field-input-plain`/`.field-select`) and
modal (`.modal-overlay`/`.modal-box`/`.modal-actions`) styles as-is — no
new breakpoints or layout rules were introduced. The Details panel
itself is unchanged by T3C's responsive behavior; it already sat inside
`.task-detail-layout`'s existing desktop/tablet/mobile grid (docs/41).

## Testing

**Standing constraint honored: this environment has no staging/
production credentials and must never connect to either** — no browser
test against the real (production-configured) app was possible or
attempted.

What was run:
1. `node --check` on every touched file — passes.
2. The same isolated, non-repo headless-Chromium harness used for
   T2A–T3B (mocked data, zero network), extended with an `update_task`
   mock RPC (mirroring the real RPC's own `COALESCE`-style "NULL means
   unchanged" semantics and its `audit_logs` insert) and
   failure-simulation hooks for `update_task`/`complete_task`/
   `cancel_task`, plus four dedicated single-purpose task fixtures so
   the Complete/Cancel success and failure flows never interfere with
   each other. Verified:
   - **Permission mirrors**: a plain non-manager, non-assignee viewer
     sees no Edit button and no lifecycle actions; a viewer who is an
     active assignee but neither creator nor supervisor sees Edit and
     Complete (the corrected `_canEdit()`/existing `canComplete` mirror)
     but not Cancel (no assignee branch in `cancel_task()`) — proving
     the assignee-branch correction actually works, not just that
     *some* button renders.
   - **Editing**: the form is genuinely pre-filled from the current
     task; a blank title is blocked client-side with no RPC call and no
     mutation; clearing an already-set due date is blocked with an
     honest explanation and no mutation; discarding via the form's own
     Cancel reverts to display mode without saving; a simulated backend
     failure shows an inline error, re-enables the buttons, and leaves
     the user's edited input intact (not reverted); a real save
     persists every changed field, the page reloads with the new title/
     priority/visibility visible, the Edit button reappears, and the
     Activity panel shows the new `edited` event.
   - **Lifecycle**: Complete and Cancel each open a confirmation modal;
     dismissing via Back performs no mutation; confirming (with an
     optional note) transitions the task, closes the modal, and
     reloads the page with the correct status badge and an updated,
     now-empty Actions panel; a simulated backend failure on either
     action shows an inline error inside the still-open modal and
     leaves the task's status unchanged.
   - **Refresh**: completing a task from Task Detail, then separately
     rendering `TasksView` and `TaskDashboardView` fresh, confirms both
     immediately show the new status with no additional plumbing.
   - **Full regression**: every pre-existing T2A–T3B scenario re-run in
     the same session still passes (several count assertions were
     updated to reflect the four new T3C-only task fixtures now present
     in the shared fixture set — a fixture-count adjustment, not an
     application behavior change).
   - Zero JavaScript errors across every scenario.
3. **Not independently re-verified**: real Supabase-backed auth/session
   flow (no credentials in this environment, per standing constraints),
   and any real-device rendering.

## Known limitations

1. **A due date, once set, cannot be cleared via `update_task()`** —
   `COALESCE(p_due_date, due_date)` treats `NULL` as "leave unchanged"
   for every column, not just this one. The edit form blocks the
   attempt with an explanation rather than silently no-op'ing it.
2. **Classification has no backing column at all** and is not offered
   for editing, or shown read-only — consistent with T2B's own original
   decision for this same field (docs/41).
3. **Editing is available regardless of task status**, including on a
   completed or cancelled task — `update_task()` itself allows this;
   no extra client-side status gate was added since the backend
   genuinely permits it.
4. **Only Complete and Cancel are exposed as lifecycle actions**, per
   spec. Other transitions the schema's own allow-list supports
   (`draft`→`open`, `waiting`↔`in_progress`, etc.) are not offered here,
   though nothing about the backend prevents adding them in a future,
   separately-scoped milestone.
5. **The `edited`/`completed`/`cancelled` Activity events are generic**
   — this is an existing T2C limitation (docs/42), not new to T3C:
   `update_task()`'s own `edited` audit row carries no description of
   *what* changed (title vs. priority vs. due date are indistinguishable
   in the timeline), and this milestone doesn't change that.

## Future enhancements

- Exposing additional lifecycle transitions (Start/Move to Waiting/
  Reopen) the schema's `valid_task_status_transition()` already allows,
  if a future milestone's spec calls for them.
- A dedicated `update_task()` parameter or separate RPC to genuinely
  clear a due date, if that capability is ever prioritized — the
  current client-side block would then simply become unnecessary rather
  than requiring any UI redesign.
- A structured "what changed" audit record for edits (e.g. a diff
  stored in `audit_logs.notes`), which would let the Activity panel show
  specific field-level changes instead of a generic "Updated task
  details" event — a backend change, out of scope here.
