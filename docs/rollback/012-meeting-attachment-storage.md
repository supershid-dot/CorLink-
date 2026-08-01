# Rollback — 012: Meeting Attachment Storage Authorization Fix (T3D.1)

Companion to the change made directly in `supabase/storage-policies.sql`
(no separate patch file — see `docs/49-meeting-attachment-storage-fix.md`
for why this one is edited in place rather than added to the historical
DROP+CREATE patch chain). Explains how to undo it if it needs to be
reversed after being applied.

## Rollback strategy

This fix creates **no new tables, columns, indexes, constraints, or
functions** — it only re-declares one already-existing `storage.objects`
policy, `attachments_storage_insert`, via `DROP POLICY` + `CREATE
POLICY`, appending exactly one new value (`'meeting'`) to its per-
record-type folder allowlist (`(storage.foldername(name))[1] IN
(...)`). No other policy, table, or function is touched — confirmed by
`git diff supabase/storage-policies.sql`, which shows only a comment
update and that one-value list change.

Rollback is a single `DROP POLICY` + `CREATE POLICY` restoring the
exact pre-fix (9-entry, no `'meeting'`) allowlist:

```sql
BEGIN;

DROP POLICY IF EXISTS "attachments_storage_insert" ON storage.objects;
CREATE POLICY "attachments_storage_insert" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'attachments'
    AND owner = auth.uid()
    AND (storage.foldername(name))[1] IN ('request', 'response', 'internal_request', 'prisoner_letter', 'prisoner_reply', 'internal_reply', 'external_correspondence', 'external_correspondence_reply', 'task')
  );

COMMIT;
```

This is the exact `CREATE POLICY` statement `storage-policies.sql`
carried immediately before this fix (the T3D-era state — 'task' present,
'meeting' absent) — copied verbatim via `git show
d14574f8db2a9bd9cb8cb24a5cdf76fcf4a2d019:supabase/storage-policies.sql`
(the approved T3D checkpoint), not hand-retyped, to eliminate
transcription-error risk. Confirmed byte-for-byte identical to the
version this fix's `git diff` shows being replaced.

## Assumptions

- `attachments_storage_insert` is the only policy this fix touched —
  cross-check with `git diff supabase/storage-policies.sql` (or `git log
  -p -- supabase/storage-policies.sql`) if there is ever doubt.
- No other change was applied on top of this one that itself further
  modified `attachments_storage_insert`'s allowlist (e.g. a future
  record-type addition) — if one has, capture **that** version's
  pre-change state instead of reusing this document's SQL verbatim, same
  caveat `docs/rollback/011`'s own document makes for its function set.
- Rolling back this fix does not require rolling back anything else
  first or after — it has no dependents. It does not touch the
  `attachments` table's own RLS (`attachments_select`/`_insert`/
  `_delete`, `attachments_record_type_check`) or the `attachments_storage_
  select`/`attachments_storage_delete` policies, all of which already
  correctly supported `record_type = 'meeting'` before this fix and are
  completely unaffected by rolling it back.
- Wrote no data — this is a pure policy-definition change, not a
  migration that moved or transformed rows.

## Verification performed for this document

Run against a disposable local database with the minimal hand-traced
chain described in `supabase/test-meeting-attachments.sql`'s own header
(never against staging or production):

1. Applied `supabase/storage-policies.sql` (post-fix) — confirmed via
   `pg_get_expr(polwithcheck, polrelid)` that `attachments_storage_
   insert`'s allowlist includes `'meeting'`.
2. Applied the rollback SQL above — confirmed via the same introspection
   query that `'meeting'` is now **absent** and every other entry
   (including `'task'`, added by T3D) is still present — i.e. rollback
   genuinely restores the original, pre-fix (broken-for-meetings)
   behavior, not just "a" different behavior.
3. Reapplied `supabase/storage-policies.sql`.
4. Re-ran `supabase/validate-meeting-attachments.sql` — PASSED (all
   structural checks, including `storage_insert_allows_meeting = t`).
5. Confirmed the rollback→reapply cycle touched nothing beyond
   `attachments_storage_insert` — `attachments_storage_select` and
   `attachments_storage_delete`'s policy text were identical before step
   1 and after step 3.

## After rollback

- Meeting attachment uploads (`AttachmentsAPI.upload('meeting', ...)`,
  used by `js/views/meetings.js`) will once again be rejected at the
  Storage layer with a permission error, exactly as they were before
  this fix and as they have been, unnoticed, since meeting attachments
  first shipped (`patch-meetings-foundation.sql`, 2026-07-22) — this is
  the original, long-standing (if broken) behavior, not a new failure
  mode.
- Meeting attachment **downloads** and **deletes** are unaffected by
  either applying or rolling back this fix — those Storage policies were
  never allowlist-gated and don't reference `'meeting'` at all (see
  `docs/49` §Root cause). Any meeting attachment rows that happen to
  already exist in the `attachments` table (e.g. seeded directly, or
  uploaded through a path that bypassed the client) remain fully
  downloadable/deletable after rollback; only new **uploads** regress.
- No frontend code change accompanies this fix in either direction —
  `js/views/meetings.js`'s existing attachment upload UI (which already
  calls `AttachmentsAPI.upload('meeting', ...)`) needs no change to
  benefit from the fix, and needs no change to fail safely again after
  a rollback (`_uploadAttachments`'s existing error banner already
  surfaces the rejected-upload error message to the user either way).
