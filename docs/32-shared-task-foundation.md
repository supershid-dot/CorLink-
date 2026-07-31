# 32 — Shared Task Foundation

## Architecture

Tasks are an **independent business object**, not a feature bolted onto
any single module. `supabase/patch-shared-task-foundation.sql` creates
five tables:

| Table | Purpose |
|---|---|
| `tasks` | Core record — title, description, status, priority, dates, ownership, visibility |
| `task_assignments` | Multiple assignees per task, with history (an unassigned row is kept, not deleted) |
| `task_watchers` | Optional followers, fanned out to on completion/comment notifications |
| `task_comments` | Flat (non-threaded) discussion on a task |
| `task_number_sequences` | Org+year numbering state for `generate_task_number()` |

A task may later be linked to a Request, Meeting, Entry, Internal
Collaboration case, or Prisoner Letter — or to nothing at all. That
linking mechanism (`task_links`, not created by this patch) and every
module-specific integration are separate milestones. This patch
contains **zero** references to `requests`, `internal_requests`,
`meetings`, `external_correspondence`, or `prisoner_letters` — task
lifecycle never depends on a parent module, by construction.

Numbering follows the same `TSK-{ORG}-{YEAR}-{SEQ}` shape as
`generate_entry_reference()`/`generate_prisoner_letter_reference()`:
an org+year keyed sequence table, incremented atomically via a single
`INSERT ... ON CONFLICT ... DO UPDATE ... RETURNING` statement (no
explicit row locking needed — Postgres serializes concurrent callers
on that statement automatically).

## Lifecycle

Status is a plain `TEXT` column with a `CHECK` constraint (this
codebase never uses Postgres `ENUM` types or lookup tables for status
fields):

```
draft → open → in_progress ⇄ waiting → completed
  ↓        ↓         ↓                    ↑
cancelled cancelled cancelled     (also reachable from in_progress/waiting)
```

Enforced two ways, matching `valid_request_status_transition()` /
`trigger_check_request_status()` in `schema.sql`:

1. `valid_task_status_transition(old, new)` — a pure allow-list function.
2. `trigger_check_task_status()` — a `BEFORE UPDATE OF status` trigger
   that rejects anything not on the allow-list, regardless of which
   code path attempted it (defense-in-depth independent of the RPCs'
   own authorization checks).

`complete_task()`/`cancel_task()` are the only paths to `completed`/
`cancelled` — `update_task()` explicitly refuses those two target
statuses and directs the caller to the dedicated RPC, so
`completed_at`/`completed_by` can never be left unset on a completed
row.

## Security model

**Mutation is exclusively through SECURITY DEFINER RPCs.** `tasks`,
`task_assignments`, `task_watchers`, and `task_comments` all carry
SELECT-only RLS — there is no INSERT/UPDATE/DELETE policy on any of
them, the same shape `patch-rooms-booking-foundation.sql` established
for `meeting_room_bookings`/`meeting_room_blocks`. Every RPC re-derives
the actor from `auth.uid()` server-side; none accept a client-supplied
user id as "who did this."

**Visibility** is centralized in one helper, `can_view_task(task_id)`,
reused by:
- the `tasks_select` RLS policy (and, transitively, the three child
  tables' SELECT policies, each just `can_view_task(task_id)`)
- `add_task_comment()`, `watch_task()`, `unwatch_task()`'s own
  authorization checks

This mirrors `can_view_request_or_response()` /
`can_view_case_audit_record()` — a single source of truth instead of
the same predicate hand-copied at every call site. `can_view_task()`
is `SECURITY DEFINER` so its internal `SELECT FROM tasks` bypasses RLS
(avoiding recursion when invoked from the `tasks` table's own SELECT
policy), same technique those two existing helpers use.

A task is visible to:
- `is_super_admin()`, or, within the task's own organization:
- its creator or the user who completed it
- any user with an **active** assignment
- any watcher
- anyone if `visibility = 'organization'`
- anyone in `owning_section_id` (via `my_section_ids()`) if
  `visibility = 'section'`
- a supervisor/admin (`is_supervisor_or_above()`) scoped to the
  owning section, or org-wide if the task has no section
- `is_admin()` unconditionally

**Edit rights** (`update_task`/`cancel_task`/`complete_task`/
`assign_task`/`unassign_task`) are intentionally narrower than view
rights: creator, active assignee, or a supervisor/admin scoped to the
task's section — watchers and general section members who can merely
*see* a `section`/`organization`-visibility task cannot edit it.

`get_task()` and `list_tasks()` are the one deliberate exception to
"every access point is a SECURITY DEFINER RPC": they carry **no**
elevated privilege of their own (plain functions, not `SECURITY
DEFINER`), so ordinary RLS on `tasks` (via `can_view_task()`) filters
their output for the calling session automatically — this avoids
re-implementing the same visibility predicate a third and fourth time.
`list_tasks()` follows the existing `{ items, totalCount }`-style list
convention (`INBOX_LIST_CAP` in `js/config.js`) by capping at 1000 rows
server-side, same ceiling every other list method in this codebase
uses.

## Audit and notifications

No custom audit implementation — every mutating RPC writes a plain
`INSERT INTO audit_logs (...)` row, same as `create_booking_hold()`
and every other RPC-based module. `audit_logs_record_type_check` gains
`'task'`; `audit_logs_action_check` gains `'completed'` and
`'commented'` (the other actions this module needs — `created`,
`edited`, `assigned`, `unassigned`, `cancelled` — already existed).

Notification types are registered the same way every prior module
registered its own — widening `notifications_type_check`, there is no
separate type-registry table in this codebase:

- `task_assigned` — sent to the newly-assigned user
- `task_completed` — sent to the creator and all watchers (excluding the actor)
- `task_comment_added` — sent to the creator, all active assignees, and all watchers (excluding the actor)

No notification UI was built — these rows land in the existing
`notifications` table exactly like every other module's, ready for the
existing notification UI to surface once this table's rows start
appearing (no UI change was required or made to make that happen).

## Extensibility / future integration points

This patch deliberately stops short of:
- **`task_links`** — the polymorphic join table that will let a task
  reference a `request`/`internal_request`/`meeting`/
  `external_correspondence`/`prisoner_letter` row. Not created here so
  its shape can be designed once a real consuming module exists,
  rather than guessed at in isolation.
- **Module-specific RPCs** — e.g. "create a task from this meeting's
  action items" belongs to the Meetings integration milestone, not
  here.
- **Any UI** — no view, no route, no navigation entry. `js/data/
  tasks-api.js` is the only frontend artifact; it is not imported or
  referenced by any existing page yet.
- **Module-enablement gating** — unlike Rooms/Meetings
  (`current_user_module_enabled('rooms')`), Tasks has no
  `is_module_active('tasks')` gate in this patch. If a future
  milestone wants Tasks to be an opt-in per-org module rather than
  always-on, that gate can be added to the RPCs without touching the
  schema.

## Backward compatibility

Purely additive: five new tables, one new sequence table, sixteen new
functions/RPCs, and two widened `CHECK` constraints
(`audit_logs`/`notifications`). No existing table, column, function,
policy, or RPC was altered. No existing frontend file was changed.

## Deployment notes

- Apply after the full existing migration chain — this patch assumes
  `organizations`, `sections`, `users`, `user_assignments`,
  `audit_logs`, `notifications`, and the core RLS helper functions
  (`get_my_org_id()`, `my_section_ids()`, `is_admin()`,
  `is_supervisor_or_above()`, `is_super_admin()`) already exist, plus
  `trigger_set_updated_at()` from `schema.sql`.
- Idempotent — safe to re-run (every `CREATE TABLE`/`CREATE INDEX` uses
  `IF NOT EXISTS`, every `CREATE POLICY` is preceded by `DROP POLICY IF
  EXISTS`, every function is `CREATE OR REPLACE`).
- No new extensions, no storage objects, no `pg_cron` dependency.
- Run `supabase/validate-shared-task-foundation.sql` immediately after
  applying — it enumerates every table/index/constraint/policy/RPC
  this patch creates and raises a hard exception (not a silent
  warning) listing anything missing.

## Rollback notes

See `docs/rollback/005-shared-task-foundation.md`.
