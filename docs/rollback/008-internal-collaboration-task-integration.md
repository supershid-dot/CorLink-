# Rollback — 008: Internal Collaboration ↔ Shared Tasks Integration

Companion to `docs/35-internal-collaboration-task-integration.md`.
Explains how to undo
`supabase/patch-internal-collaboration-task-integration.sql` if it
needs to be reversed after being applied. As of this document's
creation, the migration has **not** been applied to any Supabase
project — it has only been applied to, and tested against, a local
disposable PostgreSQL instance built by replaying the full existing
migration chain plus R2, R3, R4, and R5.

This rollback is scoped to what this milestone actually created: **no
new table** (unlike R4's `task_links` or R5's `meeting_decisions` —
`internal_requests` already existed, long before this milestone), 8
new functions (6 RPCs + 2 helpers), and 1 widened shared constraint
(`task_links.module_key` — reverted here to `(request, meeting)`, i.e.
exactly R5's post-rollback state). It does not touch `task_links`
itself (only its `module_key` CHECK definition), `internal_requests`,
`internal_request_replies`, `tasks`, `task_assignments`, `requests`,
`external_correspondence`, or anything R2/R3/R4/R5 or the pre-existing
Internal Collaboration workflow created — none of those are written to
by this migration.

**`task_links` remains generic shared infrastructure after this
rollback** — Requests (R4) and Meetings (R5) continue to work exactly
as before; only the Internal Collaboration branch is removed. If a
*later* module (Entry, Prisoner Letters) has since widened `module_key`
further still, §1 below detects and refuses that situation rather than
silently reverting past it.

---

## 1. Prerequisite / dependency-detection check (must pass before running §2)

```sql
DO $$
DECLARE
  v_check_def TEXT;
  v_bad_module_keys TEXT;
BEGIN
  -- Refuse if module_key allows anything beyond (request, meeting,
  -- internal_request) — a later module integration now depends on
  -- this table too.
  SELECT pg_get_constraintdef(oid) INTO v_check_def
  FROM pg_constraint WHERE conrelid = 'task_links'::regclass AND contype = 'c' AND conname LIKE '%module_key%';

  IF v_check_def IS NOT NULL
     AND v_check_def NOT LIKE '%(ARRAY[''request''::text, ''meeting''::text, ''internal_request''::text])%' THEN
    RAISE EXCEPTION
      'ROLLBACK REFUSED: task_links.module_key CHECK constraint allows more than (request, meeting, internal_request) (found: %). A later module integration depends on this table — do not drop the internal_request branch.',
      v_check_def;
  END IF;

  -- Refuse if any row exists with a module_key other than the three
  -- currently supported values (defense in depth beyond the
  -- CHECK-definition test above).
  SELECT string_agg(DISTINCT module_key, ', ') INTO v_bad_module_keys
  FROM task_links WHERE module_key NOT IN ('request', 'meeting', 'internal_request');

  IF v_bad_module_keys IS NOT NULL THEN
    RAISE EXCEPTION
      'ROLLBACK REFUSED: task_links contains rows for unexpected module_key(s) (%).',
      v_bad_module_keys;
  END IF;

  RAISE NOTICE 'Dependency check passed: task_links module_key is exactly (request, meeting, internal_request).';
END $$;
```

Additionally, **before running §2**, grep the current `supabase/`
directory for any `patch-*.sql` file (other than
`patch-internal-collaboration-task-integration.sql` itself) referencing
`can_view_internal_request`, `can_manage_internal_collab_task_link`,
`create_internal_collaboration_supporting_task`,
`link_existing_task_to_internal_collaboration`,
`unlink_task_from_internal_collaboration`,
`list_internal_collaboration_tasks`, or
`list_task_internal_collaboration_links`:

```sh
grep -l "can_view_internal_request\|can_manage_internal_collab_task_link\|create_internal_collaboration_supporting_task\|link_existing_task_to_internal_collaboration\|unlink_task_from_internal_collaboration\|list_internal_collaboration_tasks\|list_task_internal_collaboration_links" \
  supabase/patch-*.sql | grep -v patch-internal-collaboration-task-integration.sql
```

If this returns anything, **STOP** — a later patch file already builds
on this milestone's infrastructure.

Then confirm no `task_links` row still uses `module_key =
'internal_request'` before the CHECK-reversion step in §2 fails on it:

```sql
SELECT id, task_id, record_id FROM task_links WHERE module_key = 'internal_request';
```

If any rows are returned, either delete them (acceptable if this
rollback is happening because the whole milestone is being abandoned —
deleting the `task_links` rows first does not delete the underlying
Task or the internal_requests thread, only the cross-reference) or
reconsider whether a full rollback is appropriate.

## 2. Remove the new database objects safely

```sql
BEGIN;

-- 1. Drop the 6 RPCs and 2 helpers.
DROP FUNCTION IF EXISTS create_internal_collaboration_supporting_task(UUID, TEXT, TEXT, UUID, TEXT, TEXT, DATE, DATE, UUID[]);
DROP FUNCTION IF EXISTS link_existing_task_to_internal_collaboration(UUID, UUID);
DROP FUNCTION IF EXISTS unlink_task_from_internal_collaboration(UUID, TEXT);
DROP FUNCTION IF EXISTS list_internal_collaboration_tasks(UUID, TEXT, BOOLEAN, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS list_task_internal_collaboration_links(UUID, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS get_internal_collaboration_task_capabilities(UUID);
DROP FUNCTION IF EXISTS can_manage_internal_collab_task_link(UUID);
DROP FUNCTION IF EXISTS can_view_internal_request(UUID);

-- 2. Revert can_view_task_link() to R5's request+meeting-only
--    definition — removes the internal_request branch, keeps the
--    request and meeting branches untouched.
CREATE OR REPLACE FUNCTION can_view_task_link(p_task_id UUID, p_module_key TEXT, p_record_id UUID)
RETURNS BOOLEAN AS $$
  SELECT can_view_task(p_task_id) AND (
    (p_module_key = 'request' AND can_view_request_or_response('request', p_record_id))
    OR (p_module_key = 'meeting' AND EXISTS (
      SELECT 1 FROM meeting_decisions md
      WHERE md.id = p_record_id
        AND current_user_module_enabled('meetings')
        AND can_view_meeting(md.meeting_id)
    ))
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- 3. Revert task_links.module_key to (request, meeting).
--    Fails here if §1's prerequisite check was skipped and a live row
--    still uses module_key='internal_request'.
ALTER TABLE task_links DROP CONSTRAINT IF EXISTS task_links_module_key_check;
ALTER TABLE task_links ADD CONSTRAINT task_links_module_key_check
  CHECK (module_key IN ('request', 'meeting'));

COMMIT;
```

**This is safe and non-destructive to the rest of CorLink**, provided
§1 passed: `task_links` itself, `internal_requests`,
`internal_request_replies`, `tasks`, `requests`,
`external_correspondence`, and everything R4 (Requests)/R5 (Meetings)
built are untouched — this rollback only removes the Internal
Collaboration-specific extension layered on top. `task_links`'s
`record_id` has no foreign key (by design, see docs/33), so there is
nothing to cascade into on the Internal Collaboration side either. No
table is dropped by this rollback at all — the smallest footprint of
any of the three module-integration rollbacks so far (004 excepted).

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
  constraint allows more than (request, meeting, internal_request)
  ...` (tested inside its own rolled-back transaction, never
  committed).
- **Prerequisite failure confirmed real**: with live `task_links` rows
  carrying `module_key = 'internal_request'` present (from this
  milestone's own behavioral testing), running the §2 script failed at
  the `task_links_module_key_check` step with `ERROR: check constraint
  "task_links_module_key_check" of relation "task_links" is violated by
  some row` — and the entire transaction rolled back atomically
  (confirmed `to_regprocedure('can_view_internal_request(uuid)')` still
  resolved immediately after the failed attempt).
- **Clean success after clearing the conflicting rows**: deleting the
  offending `task_links` rows and re-running the identical §2 script
  completed with a clean `COMMIT` and no errors.
- **Clean removal confirmed**: `to_regprocedure('create_internal_
  collaboration_supporting_task(uuid,text,text,uuid,text,text,date,
  date,uuid[])')`, `can_manage_internal_collab_task_link(uuid)`, and
  `can_view_internal_request(uuid)` all confirmed absent from `pg_proc`
  after rollback; `can_view_task_link`'s function body confirmed to no
  longer reference `can_view_internal_request` while still referencing
  `can_view_request_or_response` and `meeting_decisions`.
- **No collateral damage confirmed**: `internal_requests`,
  `internal_request_replies`, `task_links`, and `tasks` tables still
  existed with identical row counts before and after (aside from the
  deliberately-deleted conflicting `task_links` rows in the
  prerequisite-failure test above); both
  `supabase/validate-request-task-integration.sql` (R4) and
  `supabase/validate-meeting-task-integration.sql` (R5) passed
  identically immediately after this rollback, confirming Requests' and
  Meetings' own supporting-tasks features are completely unaffected by
  removing Internal Collaboration's.
- **Reapply-and-revalidate confirmed**: re-running
  `patch-internal-collaboration-task-integration.sql` after the
  rollback recreated all 8 functions and re-widened the constraint —
  `supabase/validate-internal-collaboration-task-integration.sql`
  passed identically to its pre-rollback run. (The behavioral test
  suite was not re-run against this same session — the prerequisite-
  failure test above had deliberately deleted its own `module_key
  = 'internal_request'` fixture rows to reach a clean rollback, which
  left the *task* rows from that same test run orphaned from their
  links; re-running the test file's idempotency logic against that
  self-inflicted, artificially-inconsistent state is not a meaningful
  check. `supabase/test-internal-collaboration-task-integration.sql`'s
  actual idempotency — 3 consecutive clean runs against a freshly
  built database, with no manual data surgery in between — was
  verified separately, before this rollback exercise; see docs/35.)

## 5. Confirm existing CorLink functionality remains intact

After a full rollback (§2), verify:

- Existing users can log in and land on the Dashboard; Requests
  (including its R4 Supporting Tasks panel), Meetings (including its
  R5 Supporting Tasks panel), Internal Collaboration itself (looping in
  a section, marking received, assigning, replying, approving,
  returning, closing — none of which this milestone ever touched), and
  standalone Tasks are all reachable exactly as before this milestone.
- `SELECT COUNT(*) FROM internal_requests;`, `SELECT COUNT(*) FROM
  tasks;`, `SELECT COUNT(*) FROM task_links WHERE module_key IN
  ('request', 'meeting');` all match their pre-rollback values exactly.
- `supabase/validate-internal-collaboration-task-integration.sql`'s
  queries against the 8 new functions all report `exists = f` after a
  full rollback — confirming clean removal.
- The Supporting Tasks panels added to `js/views/request-detail.js` and
  `js/views/entry-detail.js` for each Internal Collaboration thread
  call `get_internal_collaboration_task_capabilities()`/
  `list_internal_collaboration_tasks()`, both now-dropped RPCs — after
  a rollback, those panels will error on fetch. Each thread's own
  per-thread error handling (docs/35 "Error isolation") means this
  shows as that one thread's inline error state, not a page-wide
  failure — but the frontend files themselves are not reverted by this
  document (a separate, ordinary code deploy/rollback, not a database
  migration concern).
