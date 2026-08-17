# 106 — UAT Fix: Standalone Task Creation UI

**Type:** Focused UAT correction. Not a redesign, no change to Task authorization
semantics, no Supabase schema change, no Production change, no CAP-003 Phase 2.
**Baseline:** branch `claude/phase-2-continuation-mc4hr1`, HEAD `38afa62` ("fix(frontend):
prevent staging bootstrap loading hang").
**Date:** 2026-08-17.

---

## 1. UAT finding

The Tasks Dashboard and Task List both load and render correctly, but there is no
visible "Create Task" / "New Task" action anywhere in either view — a user cannot
create a standalone task from the UI at all, even though nothing prevents it on the
backend.

## 2. Root cause / existing backend capability

The backend already fully supports standalone task creation and always has:

- `create_task()` (`supabase/patch-shared-task-foundation.sql`) is a `SECURITY DEFINER`
  RPC that inserts one row into `tasks`, deriving the actor from `auth.uid()`
  server-side and rejecting any organization mismatch (`v_actor_org <> p_organization_id`,
  bypassable only by `is_super_admin()`), or an owning-section choice outside the
  caller's own section memberships (`p_owning_section_id NOT IN (SELECT my_section_ids())`).
- `js/data/tasks-api.js`'s `TasksAPI.createTask({...})` already wraps this RPC exactly
  (`db.rpc('create_task', {...})`) — no direct table write, correct parameter names.
  This has existed since the Task foundation shipped; nothing about it was missing or
  broken.
- Every table involved (`tasks`) carries **no** `origin`/`classification`/`source_type`
  column at all. A task only ever becomes linked to a parent record (a Request, Meeting,
  Entry, Internal Collaboration case, or Prisoner Letter) via a **separate** row in
  `task_relationships` or a module's own linking table, written by a *different* code
  path than `create_task()`. `create_task()` itself never writes such a row. This means
  there is no "standalone" value to pass at all — **every task `create_task()` creates
  is standalone by construction**, simply because nothing else links it to anything.

**What was genuinely missing:** a UI entry point. No view file, button, or modal
anywhere in `js/views/` ever called `TasksAPI.createTask()` — confirmed by a
repository-wide search for `create_task`, `createTask`, "Create Task", and "New Task"
across `js/views/tasks.js`, `js/views/task-dashboard.js`, `js/views/shell.js`, and
`js/app.js` before this fix: the only matches were the data-layer function itself and
its RPC call. There was no hidden or half-built form to reconnect — this was a genuine
gap, not a wiring bug.

## 3. Authorization — no new permission model invented

`create_task()`'s own rules ARE the eligibility model; nothing new is introduced:

- Any **active, authenticated** user may create a task in their **own** organization
  (`organizationId` is always read from the caller's cached, server-issued profile —
  `user.org_id` — never a form field, so the browser cannot forge organization
  ownership).
- The **Owning Section** field is optional and, when set, is populated only from
  `RequestsAPI.mySections()` (the same "sections I belong to" call `js/views/tasks.js`
  already uses for its own filters) — so a regular user can never even present a section
  outside their own membership to `create_task()`, matching the RPC's own enforcement.
- Tasks has no Layer-1 module gate (`router.js`'s `MODULE_ROUTES` never lists
  `task-dashboard`/`tasks`/`task-detail` — confirmed in `docs/102` §12 and unchanged
  since) and no role restriction beyond "authenticated, active, same org" exists on
  `create_task()` — so every user who can already reach the Tasks Dashboard or Task List
  at all (both views already `if (!user) { Router.navigate('login'); return; }` before
  rendering anything) is, by the backend's own rule, authorized to create a task. The
  **Create Task** button is therefore shown unconditionally to any authenticated user,
  identically to how "New Request" is already shown unconditionally on the Dashboard.
  There is no "authorized vs. unauthorized *authenticated* user" distinction the
  frontend could safely draw here without inventing a restriction the backend doesn't
  have — which the task instructions explicitly prohibited.
- Frontend visibility remains convenience only. `create_task()` re-derives and
  re-checks the actor's organization and section membership itself on every call — the
  button being shown or hidden changes nothing about what a call to `create_task()` is
  actually allowed to do.

## 4. UI change

New shared file `js/views/task-create-modal.js` (a global `TaskCreateModal` object with
one `open(user)` method) — shared because the Task Dashboard and Task List need the
identical action, unlike most single-view modals in this app which are only ever opened
from one file.

- **Task Dashboard** (`js/views/task-dashboard.js`): a primary **Create Task** button
  added to the page header, next to the existing "View Task List" link.
- **Task List** (`js/views/tasks.js`): a primary **Create Task** button added to the
  page header.

Both use the existing `.btn.btn-primary.btn-sm` classes and `<i class="ti ti-plus">`
icon already used elsewhere (e.g. Dashboard's own "New Request" button) — no new CSS,
no redesign of either page's existing layout.

## 5. Fields exposed

Exactly the fields `create_task()` supports and that make sense for standalone
creation — nothing speculative:

| Field | Required | Maps to |
|---|---|---|
| Title | Yes | `p_title` |
| Description | No | `p_description` |
| Priority (Low/Normal/Critical/High) | No — defaults to Normal | `p_priority` |
| Owning Section | No — "— No section —" option, else one of the caller's own sections | `p_owning_section_id` |
| Start Date | No | `p_start_date` |
| Due Date | No | `p_due_date` |

`visibility` is left at `create_task()`'s own default (`'section'`) — not exposed, since
it isn't in the task's requested field list and the RPC already has a sensible default.
The schema's `due_date`/`start_date` columns are `DATE`, not `TIMESTAMPTZ` — the form
uses plain `<input type="date">`, matching the actual backend requirement rather than
the task prompt's looser "date/time" phrasing.

## 6. Validation

Client-side (mirrors, does not replace, server-side enforcement):

- Title required (HTML5 `required` plus a `trim()`-based check in the submit handler,
  since `required` alone does not catch a whitespace-only value).
- Due date, if set together with a start date, must not be before the start date.
- Priority and Owning Section are both `<select>` elements, so only valid values can
  ever be submitted.

`create_task()` remains authoritative — a validation-error message from the RPC itself
(e.g. an org/section mismatch) is displayed exactly as returned, not swallowed.

## 7. Success / failure flow

- **Success:** the modal closes and the app navigates to `task-detail` for the new
  task's id (`Router.navigate('task-detail', { id: taskId })`) — the same convention
  `js/views/requests.js`'s own "New Request" compose modal already uses. The task
  number is visible immediately, since `js/views/task-detail.js` already displays
  `task_number` from `getTask()`. No page reload occurs (hash navigation only, matching
  this app's existing architecture). Returning to the Dashboard or Task List afterward
  shows the new task because both views already re-fetch fresh data on every `render()`
  call — no separate "refresh" mechanism was needed or added.
- **Failure** (permission denied, invalid section, invalid dates, RPC error, network
  error): the RPC's `err.message` is shown inline in the still-open modal
  (`.modal-error`), the submit button is re-enabled in a `finally` block, and the form
  remains fully usable — the UI is never left stuck in a loading state.

## 8. Tests

`tests/task-standalone-creation-frontend.test.js` (new) — 13 checks:

- Static/source checks (no browser): `TasksAPI.createTask()` calls the `create_task`
  RPC and never `.from('tasks').insert(...)`; `create_task()` itself derives the actor
  server-side and rejects organization spoofing; `create_task()` writes no
  `task_relationships`/`task_links` row (confirming the "standalone" classification is
  correct — there is no such column to set); the modal sends `organizationId` from the
  caller's profile, never a form field; both views wire their button to
  `TaskCreateModal.open(this._user)`; both views already redirect unauthenticated
  visitors to login before any such button could render (the one "unauthorized" case
  the frontend can safely determine).
- Browser checks (headless Chromium via the `playwright` package against this
  environment's pre-installed `/opt/pw-browsers/chromium` — same
  `PLAYWRIGHT_CORE_PATH`/`EDGE_PATH` gap already documented in `docs/98` and
  `tests/frontend-bootstrap-integrity-frontend.test.js`, so this suite degrades
  gracefully rather than false-passing if neither is available): modal renders all
  expected fields; whitespace-only title is rejected without calling `createTask`;
  due-before-start is rejected client-side; a valid submission calls
  `TasksAPI.createTask()` with exactly the expected arguments and navigates to
  `task-detail`; a simulated RPC failure shows a recoverable, dismissable error and
  re-enables the submit button.

```
$ node tests/task-standalone-creation-frontend.test.js
PASS: js/data/tasks-api.js createTask() calls the create_task RPC, not a direct insert
PASS: create_task() itself has no client-suppliable organization/actor override — identity is server-derived
PASS: create_task() writes no parent-linkage row — every task it creates is standalone by construction
PASS: task-create-modal.js sends organizationId from the caller-supplied user profile, never a form field
PASS: task-create-modal.js validates required title and due >= start client-side
PASS: Task List header wires the Create Task button to TaskCreateModal.open
PASS: Task Dashboard header wires the Create Task button to TaskCreateModal.open
PASS: both views already redirect to login before any authenticated-only UI (including the button) can render — the one "unauthorized" case the frontend can safely determine
PASS: modal opens with title, priority, section, and date fields
PASS: whitespace-only title is rejected client-side without calling createTask
PASS: due date before start date is rejected client-side
PASS: valid submission calls TasksAPI.createTask() with server-derived org, correct fields, and navigates to task-detail
PASS: RPC failure (e.g. permission denied) shows a recoverable error, re-enables submit, does not hang
TASK STANDALONE CREATION: 13 PASSED, 0 FAILED
```

Existing suites re-run, unmodified, with no regression:

```
$ node tests/frontend-bootstrap-integrity-frontend.test.js
FRONTEND BOOTSTRAP: 7 PASSED, 0 FAILED

$ bash tests/test-frontend-config.sh
── Summary: 11 passed, 0 failed ──
```

A full end-to-end check (real `index.html`, all scripts, a stubbed Supabase client, a
valid cached session) confirmed zero JavaScript page errors on both `#task-dashboard`
and `#tasks`, the Create Task button present on both, and the modal opening correctly
from each.

## 9. Deployment SHA

See the accompanying final report for the exact commit SHA.

## 10. Production untouched confirmation

No Supabase tool was invoked against `infjjroktzzhaxjvfknr` (Production) or
`vjobntuyzymhcuanyeak` (Staging) — this was a pure frontend change; no migration was
applied or needed. `config/environments/production.env` and `main` are unchanged
(confirmed via `git diff`, empty). Only `index.html`, `js/views/task-dashboard.js`,
`js/views/tasks.js` were modified, plus two new files
(`js/views/task-create-modal.js`, `tests/task-standalone-creation-frontend.test.js`) —
none environment-specific, so the fix ships identically to whichever Supabase project a
given build targets.
