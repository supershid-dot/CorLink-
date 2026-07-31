# Rollback — 007: Meetings ↔ Shared Tasks Integration

Companion to `docs/34-meeting-task-integration.md`. Explains how to
undo `supabase/patch-meeting-task-integration.sql` if it needs to be
reversed after being applied. As of this document's creation, the
migration has **not** been applied to any Supabase project — it has
only been applied to, and tested against, a local disposable
PostgreSQL instance built by replaying the full existing migration
chain plus R2, R3, and R4.

This rollback is scoped to what this milestone actually created: 1 new
table (`meeting_decisions`), 8 new functions (6 RPCs + 2 helpers), 1
new RLS policy, and 1 widened shared constraint
(`task_links.module_key` — reverted here to `request`-only, i.e.
exactly R4's post-rollback state). It does not touch `tasks`,
`task_assignments`, `task_links` itself (only its `module_key` CHECK
definition), `meetings`, `meeting_participants`, or any object R2/R3/R4
or the pre-existing Meetings module created — none of those are
written to by this migration.

**`task_links` remains generic shared infrastructure after this
rollback** — Requests (R4) continues to work exactly as before; only
the Meetings branch is removed. If a *later* module (Entry, Internal
Collaboration, Prisoner Letters) has since widened `module_key` further
still, §1 below detects and refuses that situation rather than
silently reverting past it.

---

## 1. Prerequisite / dependency-detection check (must pass before running §2)

```sql
DO $$
DECLARE
  v_check_def TEXT;
  v_bad_module_keys TEXT;
BEGIN
  -- Refuse if module_key allows anything beyond (request, meeting) —
  -- a later module integration now depends on this table too.
  SELECT pg_get_constraintdef(oid) INTO v_check_def
  FROM pg_constraint WHERE conrelid = 'task_links'::regclass AND contype = 'c' AND conname LIKE '%module_key%';

  IF v_check_def IS NOT NULL
     AND v_check_def NOT LIKE '%(ARRAY[''request''::text, ''meeting''::text])%' THEN
    RAISE EXCEPTION
      'ROLLBACK REFUSED: task_links.module_key CHECK constraint allows more than (request, meeting) (found: %). A later module integration depends on this table — do not drop the meeting branch.',
      v_check_def;
  END IF;

  -- Refuse if any row exists with a module_key other than request/meeting
  -- (defense in depth beyond the CHECK-definition test above).
  SELECT string_agg(DISTINCT module_key, ', ') INTO v_bad_module_keys
  FROM task_links WHERE module_key NOT IN ('request', 'meeting');

  IF v_bad_module_keys IS NOT NULL THEN
    RAISE EXCEPTION
      'ROLLBACK REFUSED: task_links contains rows for unexpected module_key(s) (%).',
      v_bad_module_keys;
  END IF;

  RAISE NOTICE 'Dependency check passed: task_links module_key is exactly (request, meeting).';
END $$;
```

Additionally, **before running §2**, grep the current `supabase/`
directory for any `patch-*.sql` file (other than
`patch-meeting-task-integration.sql` itself) referencing
`meeting_decisions`, `can_manage_meeting_task_link`,
`resolve_or_create_meeting_decision`, `create_meeting_task`,
`link_existing_task_to_meeting`, `unlink_task_from_meeting`,
`list_meeting_tasks`, or `list_task_meeting_links`:

```sh
grep -l "meeting_decisions\|can_manage_meeting_task_link\|resolve_or_create_meeting_decision\|create_meeting_task\|link_existing_task_to_meeting\|unlink_task_from_meeting\|list_meeting_tasks\|list_task_meeting_links" \
  supabase/patch-*.sql | grep -v patch-meeting-task-integration.sql
```

If this returns anything, **STOP** — a later patch file already builds
on this milestone's infrastructure.

Then confirm no `task_links` row still uses `module_key = 'meeting'`
before the CHECK-reversion step in §2 fails on it:

```sql
SELECT id, task_id, record_id FROM task_links WHERE module_key = 'meeting';
```

If any rows are returned, either delete them (acceptable if this
rollback is happening because the whole milestone is being abandoned,
since `meeting_decisions` itself is about to be dropped in §2 anyway —
deleting the `task_links` rows first does not delete the underlying
Task, only the cross-reference) or reconsider whether a full rollback
is appropriate.

## 2. Remove the new database objects safely

```sql
BEGIN;

-- 1. Drop the 6 RPCs and 2 helpers.
DROP FUNCTION IF EXISTS create_meeting_task(UUID, TEXT, TEXT, UUID, TEXT, TEXT, DATE, DATE, UUID[], UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS link_existing_task_to_meeting(UUID, UUID, UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS unlink_task_from_meeting(UUID, TEXT);
DROP FUNCTION IF EXISTS list_meeting_tasks(UUID, TEXT, BOOLEAN, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS list_task_meeting_links(UUID, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS get_meeting_task_capabilities(UUID);
DROP FUNCTION IF EXISTS can_manage_meeting_task_link(UUID);
DROP FUNCTION IF EXISTS resolve_or_create_meeting_decision(UUID, UUID, UUID, UUID, TEXT, TEXT);

-- 2. Revert can_view_task_link() to R4's request-only definition —
--    removes the meeting branch, keeps the request branch untouched.
CREATE OR REPLACE FUNCTION can_view_task_link(p_task_id UUID, p_module_key TEXT, p_record_id UUID)
RETURNS BOOLEAN AS $$
  SELECT can_view_task(p_task_id) AND (
    (p_module_key = 'request' AND can_view_request_or_response('request', p_record_id))
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- 3. Drop the RLS policy.
DROP POLICY IF EXISTS "meeting_decisions_select" ON meeting_decisions;

-- 4. Revert task_links.module_key to request-only.
--    Fails here if §1's prerequisite check was skipped and a live row
--    still uses module_key='meeting'.
ALTER TABLE task_links DROP CONSTRAINT IF EXISTS task_links_module_key_check;
ALTER TABLE task_links ADD CONSTRAINT task_links_module_key_check
  CHECK (module_key IN ('request'));

-- 5. Drop meeting_decisions itself.
DROP TABLE IF EXISTS meeting_decisions;

COMMIT;
```

**This is safe and non-destructive to the rest of CorLink**, provided
§1 passed: `task_links` itself, `tasks`, `meetings`,
`meeting_participants`, and everything R4 (Requests) built are
untouched — this rollback only removes the Meetings-specific extension
layered on top. `task_links`'s `record_id` has no foreign key (by
design, see docs/33), so there is nothing to cascade into on the
Meetings side either.

**Do not** run any broader statement (`DROP SCHEMA`, `TRUNCATE` on any
pre-existing table, or anything wildcard-based) to accomplish this
rollback — the explicit list above is the entire footprint of this
milestone.

## 3. No separate follow-on step needed

Every object this milestone created is dropped in §2.

## 4. What was actually tested (this session, local Postgres only)

- **Dependency-detection refusal confirmed real**: after manually
  widening `task_links_module_key_check` to also allow `'entry'`
  (simulating a future integration having shipped), §1's check
  correctly raised `ROLLBACK REFUSED: task_links.module_key CHECK
  constraint allows more than (request, meeting) ...` (tested inside
  its own rolled-back transaction, never committed).
- **Prerequisite failure confirmed real**: with 10 live `task_links`
  rows carrying `module_key = 'meeting'` present (from this milestone's
  own behavioral testing), running the §2 script failed at the
  `task_links_module_key_check` step with `ERROR: check constraint
  "task_links_module_key_check" of relation "task_links" is violated
  by some row` — and the entire transaction rolled back atomically
  (confirmed `to_regclass('public.meeting_decisions')` still resolved
  immediately after the failed attempt).
- **Clean success after clearing the conflicting rows**: deleting the
  10 offending `task_links` rows and re-running the identical §2
  script completed with a clean `COMMIT` and no errors.
- **Clean removal confirmed**: `to_regclass('public.meeting_decisions')`
  returned `NULL` after rollback; `create_meeting_task`,
  `can_manage_meeting_task_link`, and `resolve_or_create_meeting_decision`
  all confirmed absent from `pg_proc`.
- **No collateral damage confirmed**: `task_links` and `tasks` tables
  still existed and were unaffected; `organizations` (4 rows) and
  `meetings` (2 rows) had identical counts before and after; both
  `supabase/validate-shared-task-foundation.sql` (R3) and
  `supabase/validate-request-task-integration.sql` (R4) passed
  identically immediately after this rollback, confirming Requests'
  supporting-tasks feature is completely unaffected by removing
  Meetings'.
- **Reapply-and-revalidate confirmed**: re-running
  `patch-meeting-task-integration.sql` after the rollback recreated
  `meeting_decisions`, its policy, and all 8 functions —
  `supabase/validate-meeting-task-integration.sql` passed identically
  to its pre-rollback run.

## 5. Confirm existing CorLink functionality remains intact

After a full rollback (§2), verify:

- Existing users can log in and land on the Dashboard; Meetings (all
  its existing panels — participants, minutes, attendance, RSVP,
  room booking), Requests (including its own R4 Supporting Tasks
  panel), and standalone Tasks are all reachable exactly as before
  this milestone.
- `SELECT COUNT(*) FROM meetings;`, `SELECT COUNT(*) FROM
  meeting_participants;`, `SELECT COUNT(*) FROM tasks;`, and `SELECT
  COUNT(*) FROM task_links WHERE module_key = 'request';` all match
  their pre-rollback values exactly.
- `supabase/validate-meeting-task-integration.sql`'s queries against
  `meeting_decisions` and the 8 new functions all report `exists = f`
  (or the final `DO $$` block raises the "missing" exception) after a
  full rollback — confirming clean removal.
- The Supporting Tasks panel in `js/views/meetings.js`'s meeting
  detail modal calls `get_meeting_task_capabilities()`/
  `list_meeting_tasks()`, both now-dropped RPCs — after a rollback,
  that panel will error on fetch. Its own per-meeting error handling
  (docs/34 "UI") means this shows as that one panel's inline error
  state inside the modal, not a modal-wide failure — but the frontend
  files themselves are not reverted by this document (a separate,
  ordinary code deploy/rollback, not a database migration concern).
