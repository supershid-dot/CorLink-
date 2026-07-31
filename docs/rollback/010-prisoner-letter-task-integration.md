# Rollback — 010: Prisoner Letters ↔ Shared Tasks Integration

Companion to `docs/37-prisoner-letter-task-integration.md`. Explains
how to undo `supabase/patch-prisoner-letter-task-integration.sql` if
it needs to be reversed after being applied. As of this document's
creation, the migration has **not** been applied to any Supabase
project — it has only been applied to, and tested against, a local
disposable PostgreSQL instance built by replaying the full existing
migration chain plus R2, R3, R4, R5, R6, and R7.

This is the final rollback document in the Shared Task Foundation
program (R3–R8). It is scoped to what this milestone actually created:
**no new table** (`prisoner_letters` already existed, long before this
milestone — same shape as R6's `internal_requests` and R7's
`external_correspondence`), 8 new functions (6 RPCs + 2 helpers), and
1 widened shared constraint (`task_links.module_key` — reverted here
to `(request, meeting, internal_request, external_correspondence)`,
i.e. exactly R7's post-rollback state). It does not touch `task_links`
itself (only its `module_key` CHECK definition), `prisoner_letters`,
`prisoner_replies`, `tasks`, `task_assignments`, `requests`, `meetings`,
`internal_requests`, `external_correspondence`, or anything R2–R7 or
the pre-existing Prisoner Letters workflow created — none of those are
written to by this migration.

**`task_links` remains generic shared infrastructure after this
rollback** — Requests (R4), Meetings (R5), Internal Collaboration
(R6), and Entry (R7) all continue to work exactly as before; only the
Prisoner Letters branch is removed. If a *later* module has since
widened `module_key` further still (there is no more planned in this
program, but the check is unconditional), §1 below detects and refuses
that situation rather than silently reverting past it.

---

## 1. Prerequisite / dependency-detection check (must pass before running §2)

```sql
DO $$
DECLARE
  v_check_def TEXT;
  v_bad_module_keys TEXT;
BEGIN
  -- Refuse if module_key allows anything beyond (request, meeting,
  -- internal_request, external_correspondence, prisoner_letter) — a
  -- later module integration now depends on this table too.
  SELECT pg_get_constraintdef(oid) INTO v_check_def
  FROM pg_constraint WHERE conrelid = 'task_links'::regclass AND contype = 'c' AND conname LIKE '%module_key%';

  IF v_check_def IS NOT NULL
     AND v_check_def NOT LIKE '%(ARRAY[''request''::text, ''meeting''::text, ''internal_request''::text, ''external_correspondence''::text, ''prisoner_letter''::text])%' THEN
    RAISE EXCEPTION
      'ROLLBACK REFUSED: task_links.module_key CHECK constraint allows more than (request, meeting, internal_request, external_correspondence, prisoner_letter) (found: %). A later module integration depends on this table — do not drop the prisoner_letter branch.',
      v_check_def;
  END IF;

  -- Refuse if any row exists with a module_key other than the five
  -- currently supported values (defense in depth beyond the
  -- CHECK-definition test above).
  SELECT string_agg(DISTINCT module_key, ', ') INTO v_bad_module_keys
  FROM task_links WHERE module_key NOT IN ('request', 'meeting', 'internal_request', 'external_correspondence', 'prisoner_letter');

  IF v_bad_module_keys IS NOT NULL THEN
    RAISE EXCEPTION
      'ROLLBACK REFUSED: task_links contains rows for unexpected module_key(s) (%).',
      v_bad_module_keys;
  END IF;

  RAISE NOTICE 'Dependency check passed: task_links module_key is exactly (request, meeting, internal_request, external_correspondence, prisoner_letter).';
END $$;
```

Additionally, **before running §2**, grep the current `supabase/`
directory for any `patch-*.sql` file (other than
`patch-prisoner-letter-task-integration.sql` itself) referencing
`can_view_prisoner_letter`, `can_manage_prisoner_letter_task_link`,
`create_prisoner_letter_supporting_task`,
`link_existing_task_to_prisoner_letter`,
`unlink_task_from_prisoner_letter`, `list_prisoner_letter_tasks`, or
`list_task_prisoner_letter_links`:

```sh
grep -l "can_view_prisoner_letter\|can_manage_prisoner_letter_task_link\|create_prisoner_letter_supporting_task\|link_existing_task_to_prisoner_letter\|unlink_task_from_prisoner_letter\|list_prisoner_letter_tasks\|list_task_prisoner_letter_links" \
  supabase/patch-*.sql | grep -v patch-prisoner-letter-task-integration.sql
```

If this returns anything, **STOP** — a later patch file already builds
on this milestone's infrastructure.

Then confirm no `task_links` row still uses `module_key =
'prisoner_letter'` before the CHECK-reversion step in §2 fails on it:

```sql
SELECT id, task_id, record_id FROM task_links WHERE module_key = 'prisoner_letter';
```

If any rows are returned, either delete them (acceptable if this
rollback is happening because the whole milestone is being abandoned —
deleting the `task_links` rows first does not delete the underlying
Task or the letter itself, only the cross-reference) or reconsider
whether a full rollback is appropriate.

## 2. Remove the new database objects safely

```sql
BEGIN;

-- 1. Drop the 6 RPCs and 2 helpers.
DROP FUNCTION IF EXISTS create_prisoner_letter_supporting_task(UUID, TEXT, TEXT, UUID, TEXT, TEXT, DATE, DATE, UUID[]);
DROP FUNCTION IF EXISTS link_existing_task_to_prisoner_letter(UUID, UUID);
DROP FUNCTION IF EXISTS unlink_task_from_prisoner_letter(UUID, TEXT);
DROP FUNCTION IF EXISTS list_prisoner_letter_tasks(UUID, TEXT, BOOLEAN, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS list_task_prisoner_letter_links(UUID, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS get_prisoner_letter_task_capabilities(UUID);
DROP FUNCTION IF EXISTS can_manage_prisoner_letter_task_link(UUID);
DROP FUNCTION IF EXISTS can_view_prisoner_letter(UUID);

-- 2. Revert can_view_task_link() to R7's request+meeting+internal_
--    request+external_correspondence-only definition — removes the
--    prisoner_letter branch, keeps the other four branches untouched.
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
    OR (p_module_key = 'internal_request' AND can_view_internal_request(p_record_id))
    OR (p_module_key = 'external_correspondence' AND can_view_entry(p_record_id))
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp;

-- 3. Revert task_links.module_key to (request, meeting,
--    internal_request, external_correspondence). Fails here if §1's
--    prerequisite check was skipped and a live row still uses
--    module_key='prisoner_letter'.
ALTER TABLE task_links DROP CONSTRAINT IF EXISTS task_links_module_key_check;
ALTER TABLE task_links ADD CONSTRAINT task_links_module_key_check
  CHECK (module_key IN ('request', 'meeting', 'internal_request', 'external_correspondence'));

COMMIT;
```

**This is safe and non-destructive to the rest of CorLink**, provided
§1 passed: `task_links` itself, `prisoner_letters`, `prisoner_replies`,
`tasks`, `requests`, `meetings`, `internal_requests`,
`external_correspondence`, and everything R4/R5/R6/R7 built are
untouched — this rollback only removes the Prisoner-Letters-specific
extension layered on top. `task_links`'s `record_id` has no foreign
key (by design, see docs/33), so there is nothing to cascade into on
the Prisoner Letters side either. No table is dropped by this rollback
at all — same smallest-footprint shape as R6's and R7's own rollbacks.

**Do not** run any broader statement (`DROP SCHEMA`, `TRUNCATE` on any
pre-existing table, or anything wildcard-based) to accomplish this
rollback — the explicit list above is the entire footprint of this
milestone.

## 3. No separate follow-on step needed

Every object this milestone created is dropped in §2.

## 4. What was actually tested (this session, local Postgres only)

- **Dependency-detection refusal confirmed real**: after manually
  widening `task_links_module_key_check` to also allow
  `'room_booking'` (a placeholder — this is the final module_key value
  the program adds, so there is no real next candidate), §1's check
  correctly raised `ROLLBACK REFUSED: task_links.module_key CHECK
  constraint allows more than (request, meeting, internal_request,
  external_correspondence, prisoner_letter) ...` (tested inside its
  own rolled-back transaction, never committed).
- **Prerequisite failure confirmed real**: with live `task_links` rows
  carrying `module_key = 'prisoner_letter'` present (from this
  milestone's own behavioral testing), running the §2 script failed at
  the `task_links_module_key_check` step with `ERROR: check constraint
  "task_links_module_key_check" of relation "task_links" is violated by
  some row` — and the entire transaction rolled back atomically
  (confirmed `to_regprocedure('can_view_prisoner_letter(uuid)')` still
  resolved immediately after the failed attempt).
- **Clean success after clearing the conflicting rows**: deleting the
  offending `task_links` rows and re-running the identical §2 script
  completed with a clean `COMMIT` and no errors.
- **Clean removal confirmed**: `to_regprocedure('create_prisoner_
  letter_supporting_task(uuid,text,text,uuid,text,text,date,date,
  uuid[])')`, `can_manage_prisoner_letter_task_link(uuid)`, and
  `can_view_prisoner_letter(uuid)` all confirmed absent from `pg_proc`
  after rollback; `can_view_task_link`'s function body confirmed to no
  longer reference `can_view_prisoner_letter` while still referencing
  `can_view_request_or_response`, `meeting_decisions`,
  `can_view_internal_request`, and `can_view_entry`.
- **No collateral damage confirmed**: `prisoner_letters`,
  `prisoner_replies`, `task_links`, `external_correspondence`,
  `internal_requests`, and `tasks` tables still existed with identical
  row counts before and after (aside from the deliberately-deleted
  conflicting `task_links` rows in the prerequisite-failure test
  above); `supabase/validate-request-task-integration.sql` (R4),
  `supabase/validate-meeting-task-integration.sql` (R5),
  `supabase/validate-internal-collaboration-task-integration.sql` (R6),
  and `supabase/validate-entry-task-integration.sql` (R7) all passed
  identically immediately after this rollback, confirming Requests',
  Meetings', Internal Collaboration's, and Entry's own supporting-tasks
  features are completely unaffected by removing Prisoner Letters'.
- **Reapply-and-revalidate confirmed**: re-running
  `patch-prisoner-letter-task-integration.sql` after the rollback
  recreated all 8 functions and re-widened the constraint —
  `supabase/validate-prisoner-letter-task-integration.sql` passed
  identically to its pre-rollback run.

## 5. Confirm existing CorLink functionality remains intact

After a full rollback (§2), verify:

- Existing users can log in and land on the Dashboard; Requests
  (including its R4 panel), Meetings (R5), Internal Collaboration (R6),
  Entry (R7), Prisoner Letters itself (submitting, marking received,
  routing, replying, marking delivered — none of which this milestone
  ever touched), and standalone Tasks are all reachable exactly as
  before this milestone.
- `SELECT COUNT(*) FROM prisoner_letters;`, `SELECT COUNT(*) FROM
  tasks;`, `SELECT COUNT(*) FROM task_links WHERE module_key IN
  ('request', 'meeting', 'internal_request', 'external_correspondence');`
  all match their pre-rollback values exactly.
- `supabase/validate-prisoner-letter-task-integration.sql`'s queries
  against the 8 new functions all report `exists = f` after a full
  rollback — confirming clean removal.
- The Supporting Tasks panel added to `js/views/prisoner-letter-detail.js`
  calls `get_prisoner_letter_task_capabilities()`/
  `list_prisoner_letter_tasks()`, both now-dropped RPCs — after a
  rollback, that panel will error on fetch. Its own error handling
  (docs/37 "Error isolation") means this shows as that one panel's
  inline error state, not a page-wide failure — but the frontend files
  themselves are not reverted by this document (a separate, ordinary
  code deploy/rollback, not a database migration concern).
