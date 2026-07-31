# Rollback — 006: Requests ↔ Shared Tasks Integration

Companion to `docs/33-request-task-integration.md`. Explains how to
undo `supabase/patch-request-task-integration.sql` if it needs to be
reversed after being applied. As of this document's creation, the
migration has **not** been applied to any Supabase project — it has
only been applied to, and tested against, a local disposable
PostgreSQL instance built by replaying the full existing migration
chain plus `patch-security-definer-search-path-hardening.sql` (R2) and
`patch-shared-task-foundation.sql` (R3).

This rollback is scoped to what this milestone actually created: 1 new
table (`task_links`), 6 new RPCs, 3 new helper functions, 1 new RLS
policy, 6 new indexes, and 1 extended `CHECK` constraint
(`audit_logs.action`). It does not touch `tasks`, `task_assignments`,
`task_watchers`, `task_comments`, `requests`, or any object R3 or
earlier created — none of those are written to by this migration.

**`task_links` is deliberately generic shared infrastructure** — a
later Meetings/Entry/Internal-Collaboration/Prisoner-Letters milestone
is expected to reuse this same table by widening its `module_key`
`CHECK` constraint, not by creating a parallel table. Rolling this
milestone back after that has happened would delete another module's
real data model, not just Requests' — §1 below detects and refuses
that situation rather than silently proceeding.

---

## 1. Prerequisite / dependency-detection check (must pass before running §2)

Run this **before** §2, every time, regardless of how confident you
are that no later integration exists yet:

```sql
DO $$
DECLARE
  v_bad_module_keys TEXT;
  v_check_def TEXT;
BEGIN
  -- Refuse if the module_key CHECK has been widened beyond 'request'
  -- — a later module integration depends on this table.
  SELECT pg_get_constraintdef(oid) INTO v_check_def
  FROM pg_constraint
  WHERE conrelid = 'task_links'::regclass AND contype = 'c' AND conname LIKE '%module_key%';

  IF v_check_def IS NOT NULL
     AND v_check_def NOT LIKE '%(ARRAY[''request''::text])%'
     AND v_check_def NOT LIKE '%module_key = ''request''%' THEN
    RAISE EXCEPTION
      'ROLLBACK REFUSED: task_links.module_key CHECK constraint no longer restricts to only ''request'' (found: %). A later module integration depends on this table — do not drop it.',
      v_check_def;
  END IF;

  -- Refuse if any row exists with a module_key other than 'request'
  -- (defense in depth beyond the CHECK-definition test above, in case
  -- the CHECK was manually reverted but rows for another module remain).
  SELECT string_agg(DISTINCT module_key, ', ') INTO v_bad_module_keys
  FROM task_links WHERE module_key <> 'request';

  IF v_bad_module_keys IS NOT NULL THEN
    RAISE EXCEPTION
      'ROLLBACK REFUSED: task_links contains rows for module_key(s) other than ''request'' (%). A later module integration has real data here — do not drop it.',
      v_bad_module_keys;
  END IF;

  RAISE NOTICE 'Dependency check passed: task_links is still Requests-only.';
END $$;
```

Additionally, **before running §2**, grep the current `supabase/`
directory for any `patch-*.sql` file (other than
`patch-request-task-integration.sql` itself) referencing `task_links`,
`can_view_task_link`, `can_manage_task`, `can_manage_request_task_
link`, `get_request_task_capabilities`, or `list_task_request_links`:

```sh
grep -l "task_links\|can_view_task_link\|can_manage_task\|can_manage_request_task_link\|get_request_task_capabilities\|list_task_request_links" \
  supabase/patch-*.sql | grep -v patch-request-task-integration.sql
```

If this returns anything, **STOP** — a later patch file already builds
on this milestone's infrastructure; §1's runtime check above cannot
see a patch file that hasn't been applied yet, only live database
state, so this static check is a required second layer.

Then, same as `docs/rollback/005`'s own pattern, confirm no row uses
either of this milestone's two new `audit_logs.action` values before
the `CHECK`-reversion step in §2 fails on it:

```sql
SELECT id, action, record_id FROM audit_logs WHERE action IN ('task_linked', 'task_unlinked');
```

If any rows are returned, either delete them (acceptable if this
rollback is happening because the whole milestone is being abandoned,
since `task_links` itself is about to be dropped in §2 anyway) or
reconsider whether a full rollback is appropriate.

## 2. Remove the new database objects safely

Run as a superuser/service-role connection, in this exact order:

```sql
BEGIN;

-- 1. Drop the 6 RPCs.
DROP FUNCTION IF EXISTS create_request_supporting_task(UUID, TEXT, TEXT, UUID, TEXT, TEXT, DATE, DATE, UUID[]);
DROP FUNCTION IF EXISTS link_existing_task_to_request(UUID, UUID);
DROP FUNCTION IF EXISTS unlink_task_from_request(UUID, TEXT);
DROP FUNCTION IF EXISTS list_request_supporting_tasks(UUID, TEXT, BOOLEAN, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS list_task_request_links(UUID, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS get_request_task_capabilities(UUID);

-- 2. Drop the RLS policy.
DROP POLICY IF EXISTS "task_links_select" ON task_links;

-- 3. Drop the 3 helper functions.
DROP FUNCTION IF EXISTS can_view_task_link(UUID, TEXT, UUID);
DROP FUNCTION IF EXISTS can_manage_task(UUID);
DROP FUNCTION IF EXISTS can_manage_request_task_link(UUID);

-- 4. Revert audit_logs.action to its pre-R4 (R3's) definition.
--    Fails here if §1's prerequisite check was skipped and a live row
--    still uses task_linked/task_unlinked.
ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_action_check;
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_action_check
  CHECK (action IN (
    'created', 'edited', 'submitted', 'approved', 'returned',
    'sent', 'received', 'routed', 'assigned', 'returned_to_sender', 'cancelled',
    'extension_requested', 'extension_approved', 'extension_denied',
    'viewed', 'login', 'logout', 'login_failed', 'locked',
    'password_changed', 'user_created', 'user_deactivated',
    'rejected', 'rescheduled', 'conflict_overridden', 'unassigned',
    'participant_added', 'participant_removed', 'attachment_added', 'attachment_removed',
    'invitation_responded', 'attendance_marked', 'minutes_updated', 'minutes_finalized',
    'meeting_locked', 'meeting_unlocked', 'meeting_group_created', 'meeting_group_updated',
    'meeting_group_deleted', 'meeting_group_members_updated', 'meeting_series_created',
    'meeting_draft_deleted', 'meeting_series_updated', 'meeting_series_split', 'meeting_series_cancelled',
    'completed', 'commented'
  ));

-- 5. Drop task_links itself (its 6 indexes drop automatically with it).
DROP TABLE IF EXISTS task_links;

COMMIT;
```

**This is safe and non-destructive to the rest of CorLink**, provided
§1 passed: every dropped object is exclusively new and exclusively
created by this milestone. `tasks`, `task_assignments`,
`task_watchers`, `task_comments`, and `requests` are never written to
by this rollback — `task_links.record_id` was deliberately created
with no foreign key (see docs/33's "Architecture" section), so there
is nothing for this rollback to cascade into on the Requests side
either.

**Do not** run any broader statement (`DROP SCHEMA`, `TRUNCATE` on any
pre-existing table, or anything wildcard-based) to accomplish this
rollback — the explicit list above is the entire footprint of this
milestone.

## 3. No separate follow-on step needed

Every object this milestone created is dropped in §2 — there is
nothing left over, no grant table, no separate cleanup.

## 4. What was actually tested (this session, local Postgres only)

- **Dependency-detection refusal confirmed real**: after manually
  widening `task_links_module_key_check` to also allow `'meeting'`
  (simulating a future integration having shipped), §1's check
  correctly raised `ROLLBACK REFUSED: task_links.module_key CHECK
  constraint no longer restricts to only 'request' ...` and the
  simulated change was rolled back (this was done inside its own test
  transaction, never committed).
- **Prerequisite failure confirmed real** (the audit-row check): with
  4 live `audit_logs` rows carrying `action IN ('task_linked',
  'task_unlinked')` present (from this milestone's own behavioral
  testing), running the §2 script failed at the
  `audit_logs_action_check` step with `ERROR: check constraint
  "audit_logs_action_check" of relation "audit_logs" is violated by
  some row` — and the entire transaction rolled back atomically
  (confirmed `to_regclass('public.task_links')` still resolved
  immediately after the failed attempt — not a partial rollback).
- **Clean success after clearing the conflicting rows**: deleting the
  4 offending `audit_logs` rows and re-running the identical §2 script
  completed with a clean `COMMIT` and no errors.
- **Clean removal confirmed**: `to_regclass('public.task_links')`
  returned `NULL` after rollback; `create_request_supporting_task`,
  `link_existing_task_to_request`, `can_view_task_link`,
  `can_manage_task`, and `can_manage_request_task_link` all confirmed
  absent from `pg_proc`.
- **No collateral damage confirmed**: `tasks`/`task_assignments`
  tables still existed and were unaffected; `organizations` (2 rows)
  and `requests` (1 row) had identical counts before and after the
  full rollback cycle; `supabase/validate-shared-task-foundation.sql`
  (R3's own validator) and `supabase/validate-security-definer-
  search-path.sql` (R2's own validator) both still passed unchanged
  immediately after this rollback.
- **Reapply-and-revalidate confirmed**: re-running
  `patch-request-task-integration.sql` after the rollback recreated
  `task_links`, its 6 indexes, the RLS policy, all 3 helpers, and all
  6 RPCs — `supabase/validate-request-task-integration.sql` passed
  identically to its pre-rollback run.

## 5. Confirm existing CorLink functionality remains intact

After a full rollback (§2), verify:

- Existing users can log in and land on the Dashboard; Requests,
  Entry, Prisoner Correspondence, Internal Collaboration, Meetings,
  Rooms, Administration, and standalone (unlinked) Tasks are all
  reachable exactly as before this milestone — none of them reference
  `task_links` or any RPC this rollback removed.
- `SELECT COUNT(*) FROM tasks;`, `SELECT COUNT(*) FROM
  task_assignments;`, and `SELECT COUNT(*) FROM requests;` match their
  pre-rollback values exactly — a standalone task created before this
  milestone shipped (or one that was never linked to anything) is
  completely unaffected, since nothing about a `tasks` row itself
  changes here.
- `supabase/validate-request-task-integration.sql`'s queries against
  `task_links` and the 9 helpers/RPCs all report `exists = f` (or the
  final `DO $$` block raises the "missing" exception) after a full
  rollback — confirming clean removal.
- The Supporting Tasks panel in `js/views/request-detail.js` calls
  `get_request_task_capabilities()`/`list_request_supporting_tasks()`,
  both now-dropped RPCs — after a rollback, that panel will error on
  fetch. Its own per-panel error handling (docs/33 "UI behavior") means
  this shows as that one panel's inline error state, not a page-wide
  failure — but the frontend files themselves are not reverted by this
  document (that's a separate, ordinary code deploy/rollback, not a
  database migration concern).
