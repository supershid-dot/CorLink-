# 49 — Meeting Attachment Storage Authorization Fix (T3D.1)

A corrective maintenance milestone only. Fixes the pre-existing,
unrelated Storage-policy gap discovered while making the `'task'`
addition in T3D (`docs/48` §Known limitations item 3): meeting
attachment **uploads** had been silently rejected by Supabase Storage
ever since meeting attachments shipped. No Storage redesign, no
attachment-API redesign, no permissions redesign, no Task or Meeting
feature work, and no UI change beyond what was needed to verify the
fix — all explicitly out of scope, per this milestone's own spec.

## Root cause

Meeting attachments have **two independent authorization layers**,
same as every other record type in this app:

1. The `attachments` table's own RLS (`attachments_select`/
   `attachments_insert`/`attachments_delete`) — gates the metadata row.
2. A separate, coarser `storage.objects` bucket-level policy
   (`supabase/storage-policies.sql`'s `attachments_storage_insert`) —
   gates the raw file write, scoped only as tightly as Storage itself
   allows: uploader must own the object, and the upload path's first
   folder segment must be on a fixed allowlist.

**Layer 1 was never broken.** `patch-meetings-foundation.sql`
(2026-07-22) added a correct `'meeting'` branch to all three
table-level policies at the same time it shipped meeting attachments,
and `patch-meetings-lock.sql` (2026-07-23) correctly carried that
branch forward when it added the lock guard. Both were re-confirmed
directly by reading the current, authoritative version of each policy
(`patch-task-attachments.sql`, the most recent restatement, per T3D)
before writing any fix — `'meeting'` is present and correct in
`attachments_select`, `attachments_insert`, and `attachments_delete`
today, unchanged by this milestone.

**Layer 2 was the actual gap.** `attachments_storage_insert`'s folder
allowlist —

```sql
AND (storage.foldername(name))[1] IN ('request', 'response',
  'internal_request', 'prisoner_letter', 'prisoner_reply',
  'internal_reply', 'external_correspondence',
  'external_correspondence_reply', 'task')
```

— never had `'meeting'` added to it. `storage-policies.sql` is a
directly-maintained, re-runnable setup script, not part of the
historical DROP+CREATE patch chain the table-level policies live in
(its own header already documented one earlier in-place fix, for a
missing `'internal_reply'` entry); when `patch-meetings-foundation.sql`
added the table-level `'meeting'` branches, this file was never
touched to match.

`js/data/attachments-api.js`'s `upload()` writes to Storage **first**,
then inserts the `attachments` metadata row second. Because the
Storage write always happened first and was always rejected for a
`meeting/...` path, the table-level RLS being correct never mattered —
the request never got that far. Every `AttachmentsAPI.upload('meeting',
...)` call (`js/views/meetings.js`'s existing meeting attachment
upload UI) has therefore been failing at the Storage layer since
2026-07-22, silently, with no reported bug — likely because no one had
yet exercised meeting attachment upload against a real deployed
environment since it shipped.

**Downloads and deletes were never affected.** Neither
`attachments_storage_select` (delegates to the `attachments` table's
own RLS via an `EXISTS` subquery, no per-type allowlist at all) nor
`attachments_storage_delete` (owner-scoped only, no per-type
allowlist) ever gated on folder name — only `attachments_storage_
insert` did. Any meeting attachment row that happened to already exist
(e.g. inserted directly, bypassing the client) would always have been
downloadable/deletable normally; it just could never be created via
the app's own upload UI in the first place.

## Correction

The minimum change required: add `'meeting'` to `attachments_storage_
insert`'s allowlist, directly in `supabase/storage-policies.sql`
(matching where `'task'` was added in T3D, for the same reason — this
file is edited in place, not restated inside a new patch file).

```sql
AND (storage.foldername(name))[1] IN ('request', 'response',
  'internal_request', 'prisoner_letter', 'prisoner_reply',
  'internal_reply', 'external_correspondence',
  'external_correspondence_reply', 'task', 'meeting')
```

Nothing else changed. `git diff supabase/storage-policies.sql` shows
exactly this one-value addition to the `IN`-list plus an updated
comment — no table, function, RPC, index, or other policy was touched.
`attachments_select`/`attachments_insert`/`attachments_delete` and
`attachments_record_type_check` are byte-for-byte unchanged by this
milestone (they didn't need to be — they were already correct).

## Validation

`supabase/validate-meeting-attachments.sql` — structural, via
`pg_get_expr()`/`pg_get_constraintdef()` introspection against a
disposable local Postgres with the fixed `storage-policies.sql`
applied. Confirms:
- `attachments_storage_insert`'s allowlist now includes `'meeting'`.
- Every pre-existing entry (`request`, `response`, `internal_request`,
  `prisoner_letter`, `prisoner_reply`, `internal_reply`,
  `external_correspondence`, `external_correspondence_reply`, `task`)
  is still present — this was an addition, not a rewrite.
- `attachments_storage_insert` still requires `bucket_id =
  'attachments'` and `owner = auth.uid()` — the fix only widened the
  folder allowlist, not the ownership/bucket boundary.
- `attachments_storage_select`/`attachments_storage_delete` are
  untouched — still delegate to the `attachments` table's own RLS /
  still owner-scoped only, neither has (or needs) a folder allowlist.
- `attachments_record_type_check` still includes `'meeting'`
  (unchanged, pre-existing).
- The table-level `attachments_select`/`_insert`/`_delete` `'meeting'`
  branches are unchanged — still delegate to `can_view_meeting()`/
  `can_manage_meeting()`/`is_meeting_lock_overridable()`, not
  re-derived.
- No duplicate policy overloads exist after the DROP+CREATE.

All checks pass.

## Regression testing

`supabase/test-meeting-attachments.sql` — behavioral, real RLS-
impersonated checks against the same disposable database:

1. **Upload** — a meeting manager's Storage-level `INSERT` for a
   `meeting/{id}/...` path, previously rejected, now succeeds (the
   actual fix under test), verified by both the `INSERT` not raising
   and an RLS-bypassing follow-up count (not a same-role count, which
   would false-negative here — the uploader can't yet `SELECT` the
   object until the matching `attachments` row exists, the same
   chicken-and-egg boundary `storage-policies.sql`'s own comments
   describe).
2. **Full lifecycle** — the metadata `INSERT` (attachments table) for
   the same file succeeds immediately after, proving the complete
   real upload sequence (Storage write, then table row) now works
   end-to-end for meetings, not just the Storage layer in isolation.
3. **Download** — a participant with view-only (not manage) access can
   `SELECT` the Storage object once the metadata row exists — confirmed
   still working, unaffected by the fix.
4. **Permissions regression** — a stranger with neither grant sees
   neither the metadata row nor the Storage object, and cannot insert a
   metadata row for this meeting even though `'meeting'` is now a
   generally-allowed folder name — the per-file table-level
   `attachments_insert` policy (`can_manage_meeting()`) still gates it
   independently of the coarser Storage allowlist.
5. **Replace** — upload-new-then-delete-old (the same client-
   orchestrated sequence `docs/48` documents for tasks; meetings have
   no dedicated Replace UI today, but the underlying primitives behave
   identically) succeeds cleanly.
6. **Delete** — the uploader can remove their own upload at both
   layers, unaffected by the fix.
7. **Allowlist regression** — every other record type's folder prefix
   (Requests, Entry's `external_correspondence`/`_reply`, Internal
   Collaboration's `internal_request`/`internal_reply`, Prisoner
   Letters' `prisoner_letter`/`prisoner_reply`, Tasks) is still present
   in the allowlist, confirmed via the same structural introspection
   used in the validation script.
8. **Default-deny still holds** — an unrecognized folder name
   (`bogus_type/...`) is still rejected; the fix widened the allowlist
   by exactly one entry, not opened it up generally.

All 9 checks pass; re-run twice to confirm idempotency.

**Task regression, specifically** (this milestone's own instruction to
verify Tasks did not regress): the existing, unmodified `supabase/
test-task-attachments.sql` (T3D's own test suite, all 9 scenarios) was
re-run in full against the same database with the fixed `storage-
policies.sql` applied — all 9 still pass. Expected and unsurprising:
this fix never touches the table-level `attachments_*` policies Task
attachments actually depend on, and empirically confirmed anyway.

**Requests / Entry / Internal Collaboration / Prisoner Letters**: no
dedicated attachments-specific SQL test file exists for these modules
individually (attachments support for each was verified inline at the
time each module's own attachment integration shipped). Regression
evidence here is: (a) `git diff supabase/storage-policies.sql` proves
the change is purely additive — no existing allowlist entry was
removed, reordered, or altered; (b) items 7–8 above directly confirm
every one of those modules' folder prefixes is still present and the
allowlist is still a real boundary; (c) this fix touches no table-level
RLS for any of those record types at all.

## Production impact

- **Fixes** meeting attachment upload for any organization with the
  Meetings module active, as soon as this migration reaches that
  environment — a real, previously-silent bug (no error was
  surfaced anywhere obvious; a failed Storage `INSERT` from
  `AttachmentsAPI.upload()` throws, which `js/views/meetings.js`'s
  existing `_uploadAttachments` already catches and displays inline,
  so users likely saw a generic upload-failed message with no
  indication it was a Storage-policy gap rather than, say, a network
  issue).
- **No effect** on meeting attachment download or delete (never
  broken) or on any other record type's attachment upload/download/
  delete (allowlist entries for all of them are unchanged).
- **No data migration required** — this is a pure policy-definition
  change. No existing rows are affected; there is nothing to backfill.
- **Staging/UAT verification against real Supabase Storage still
  required** before this is considered fully proven in a deployed
  environment — this environment has no staging/production
  credentials and must never connect to either (standing constraint);
  all verification above used a disposable local Postgres, never a
  real Supabase project.
