# 48 — Task Attachments (T3D)

Adds an Attachments panel to Task Detail: upload, replace, delete, and
download, reusing the existing generic attachments infrastructure this
app already has for requests/responses/internal requests/prisoner
letters/entry/meetings. Explicitly not implemented, per spec: Related
Tasks, Saved Views, search redesign, pagination redesign, dashboard
work, calendar, Kanban, Gantt.

## Architecture

**No new attachment architecture was created.** `js/data/attachments-
api.js`'s `AttachmentsAPI` is already fully generic — every method
takes a `record_type`/`record_id` pair, storage paths are already
`{record_type}/{record_id}/{timestamp}-{filename}`, and the client-side
type/size validation (`ALLOWED_EXTENSIONS`, `MAX_FILE_BYTES`,
`MAX_TOTAL_BYTES`) already applies uniformly to any record type. This
file required **zero changes** — `list('task', taskId)`,
`upload('task', taskId, file)`, `getSignedUrl(path)`, and
`remove(attachment)` are called exactly as every other module already
calls them.

**The genuine backend gap, proven before writing any SQL**: `patch-
shared-task-foundation.sql`'s own header comment already disclosed
this ("attachments are 'supported later' per spec, meaning a future
patch") — confirmed by inspection that `attachments_record_type_check`
had no `'task'` value and none of `attachments_select`/
`attachments_insert`/`attachments_delete` had a `'task'` branch. A task
attachment upload/read/delete would have been rejected outright. This
is exactly the kind of "genuine backend gap" the milestone's own
instructions anticipate — closed by `supabase/patch-task-
attachments.sql`, one new file following the exact same convention
every prior attachments integration (Entry, Internal Reply, Meetings)
already used: **restate the full `attachments_select`/
`attachments_insert`/`attachments_delete` policies (DROP+CREATE —
there is no incremental "add one branch" ALTER POLICY), every existing
branch preserved verbatim, with exactly one new `'task'` branch
appended to each**, plus extending the `attachments_record_type_check`
CHECK constraint the same way.

**No table, index, or new RPC was added.** `attachments` itself is
unchanged (still `id/record_type/record_id/filename/storage_path/
mime_type/file_size/uploaded_by/created_at` — no version/supersedes
column, relevant to "Replace" below).

**Verification, not just written-and-hoped-for SQL.** The new policy
branches were applied and exercised against a disposable local Postgres
(never staging/production) replaying the relevant parts of the real
migration chain — `schema.sql` → `rls.sql` → the attachments-touching
patches in their real chronological order → `patch-shared-task-
foundation.sql` → this new patch — with two permanent, repo-committed
companion files: `supabase/test-task-attachments.sql` (behavioral —
real RLS-impersonated SELECT/INSERT/DELETE checks: creator/assignee/
supervisor-of-section can see it, an unrelated same-org stranger with a
private-visibility task cannot; a stranger cannot insert; an active
assignee can; an uploader can delete their own file only while their
edit access lasts, not frozen at upload time; the pre-existing
request-attachment branch still works unchanged after the restatement)
and `supabase/validate-task-attachments.sql` (structural — confirms
every branch, old and new, is present in the final policy text via
`pg_get_expr`/`pg_get_constraintdef` introspection). Both pass in full.

## Storage reuse

The private `attachments` Storage bucket, its path convention, and its
two-layer authorization (the `attachments` table's own RLS, reused via
an `EXISTS` subquery — not re-derived — plus a separate, coarser
`storage.objects` folder-name allowlist) are all reused exactly as
`supabase/storage-policies.sql`'s own comments describe. `'task'` was
added to `attachments_storage_insert`'s allowlist there directly
(that file is a directly-maintained, re-runnable setup script, not
part of the historical DROP+CREATE patch chain the table-level
policies live in — its own header already documents at least one
earlier in-place fix), not duplicated inside the new patch file.

**A pre-existing, unrelated gap was found while making this exact
change** — see §Known limitations below. It was deliberately **not
fixed** here, out of this milestone's own scope.

## Permissions

**No authorization logic was duplicated, and none was invented beyond
what `update_task()`'s own predicate already establishes.** The new
`attachments_insert`/`attachments_delete` `'task'` branches are
identical to each other (deliberately symmetric) and mirror
`update_task()`'s/`complete_task()`'s real authorization exactly —
creator, active assignee, supervisor-in-scope, or admin — the same
shape `js/views/task-detail.js`'s own `_canEdit()` mirror already uses
(T3C). No completed/cancelled lock guard was added: `update_task()`
itself has none (T3C's own "editing is not status-gated" finding), so
attachments don't invent a stricter rule the task module's real editing
authority doesn't otherwise have.

**Delete is further restricted to the uploader**, matching the
`uploaded_by = auth.uid() AND (...)` wrapper every other module's
`attachments_delete` branch already sits inside — not a
task-specific rule. This means losing edit access (e.g. being
unassigned) also revokes delete on files you previously uploaded,
re-checked live on every delete attempt, not frozen at upload time —
verified directly in both the SQL-level test and the harness.

**The client-side mirrors** (`_canUploadAttachment()` = `_canEdit()`;
`_canDeleteAttachment(a)` = `a.uploaded_by === user.id && _canEdit()`)
exist only to decide what to show — never expose the Upload dropzone or
a Delete/Replace button where the RLS branch above would reject the
call anyway. The RLS remains the only real enforcement.

## Task Detail — Attachments panel

Loaded independently of the rest of the page (own loading/error/retry
state), the same "a slow/failing panel doesn't block the rest of the
page" pattern this file already uses for Activity (T2C). Each row
shows exactly the required fields — Filename (clickable, opens via a
signed URL), Size (human-readable), Uploaded by, Uploaded date — plus
Download (always, for anyone who can already see the task at all) and,
when permitted, Replace and Delete.

This is a **new row layout**, not a copy of an existing view's
attachment display: every existing `_renderAttachments()` elsewhere in
this app (`request-detail.js`, `meetings.js`) shows only a compact
filename chip with no Size/Date/Delete — none of them satisfy T3D's own
required field list. The upload affordance itself (`.attachment-
dropzone`, drag-and-drop + click-to-browse) is reused byte-for-byte
from that same established pattern; only the per-attachment row below
it is new.

## Upload lifecycle

**Upload** — multiple files at once (`<input type="file" multiple>` +
drag/drop), uploaded sequentially (not `Promise.all`, so one large
file's progress doesn't starve the others and a partial failure doesn't
abort files already queued), each failure collected and reported
together rather than the whole batch stopping at the first error —
same shape `js/views/meetings.js`'s own `_uploadAttachments` already
uses.

**Replace has no backend concept of its own** — `attachments` has no
version/supersedes column, and no RPC exists for it. It is a
client-orchestrated **upload-the-new-file-first, then delete-the-old-
one** sequence over the two existing primitives
(`AttachmentsAPI.upload()`/`remove()`), deliberately in that order: if
the upload step fails, the original file is completely untouched
(never silently lost); if the upload succeeds but the follow-up delete
of the old file fails, both files are left in place with an explicit
error naming the original file to remove manually — an honest,
visible degraded state rather than a silent one.

**Delete** requires a confirmation step (`window.confirm`) before
calling the RPC — the same lightweight confirmation pattern this app's
own "unlink a task from a record" actions already use elsewhere
(`entry-detail.js`/`meetings.js`/`request-detail.js`/`prisoner-letter-
detail.js`), not the heavier custom modal T3C's Complete/Cancel actions
use — attachment deletion is a real, permanent action but a
substantially lower-stakes one than closing out an entire task.

**Duplicate filenames are fully supported, with zero extra work.**
`storage_path` is timestamp-prefixed per upload
(`{record_type}/{record_id}/{timestamp}-{filename}`), so two files
sharing a display name never collide in Storage, and `attachments` has
no uniqueness constraint on `filename`. The UI keys every row by the
attachment's own `id`, never by filename, so two identically-named
attachments always render and behave as fully independent rows.

## Responsive behavior

The Attachments panel sits inside the same `.panel` /
`.task-detail-layout` grid every other Task Detail panel already uses
(desktop/tablet/mobile, unchanged since T2B) — no new breakpoints. Row
content wraps naturally (`word-break: break-word` on the filename,
`flex-wrap` implicit via the existing panel width) rather than a
dedicated mobile layout, matching how the existing Assignees/Watchers
people-rows already behave at narrow widths.

## Testing

**Standing constraint honored: this environment has no staging/
production credentials and must never connect to either** — no browser
test against the real (production-configured) app was possible or
attempted; the SQL-level verification above used a disposable local
Postgres, not a real Supabase project.

What was run:
1. `node --check` on every touched JS file — passes.
2. `supabase/test-task-attachments.sql` and `supabase/validate-task-
   attachments.sql` against a disposable local Postgres replaying the
   real migration chain (see §Architecture) — both pass in full,
   including a cross-module regression check that the pre-existing
   `request` attachment branch still works unchanged after the
   restatement.
3. The same isolated, non-repo headless-Chromium harness used for
   T2A–T3C (mocked data, zero network), extended with a self-contained
   `AttachmentsAPI` mock mirroring the real API's own validation
   exactly (extension allowlist, per-file/per-record size caps), and
   `window.confirm`/`window.open` overrides so both delete-confirmed/
   delete-cancelled paths and the exact download URL opened could be
   asserted directly rather than assumed. Verified:
   - Correct Filename/Size/Uploaded-by/Uploaded-date display and
     correct per-row Delete/Replace gating (present only for the
     viewer's own uploads, on a task they can edit).
   - Download resolves and opens the exact expected signed URL for the
     row's own storage path.
   - Single-file and multiple-file upload, both increasing the row
     count correctly.
   - **Duplicate filenames**: uploading a second file with an
     already-used name produces two fully independent, correctly
     rendered rows, not a merge or overwrite.
   - **Large files**: a file exceeding the 20 MB per-file cap is
     rejected client-side with the expected message, no row added.
   - A disallowed file extension is rejected with the expected message.
   - A simulated backend upload failure surfaces inline, no row added.
   - **Replace**: success (old row gone, new row present, net-neutral
     total count) and failure-at-the-upload-step (original file
     completely unaffected, explicit "unchanged" wording) both
     verified.
   - **Delete**: declining the confirmation performs no mutation;
     confirming actually removes the row; a simulated backend failure
     leaves the file in place with an inline error.
   - **Permissions**: a viewer with no edit access to the task (not
     creator/assignee/supervisor-in-scope/admin) sees no upload
     dropzone and no Delete/Replace on any row regardless of who
     uploaded it, while Download remains available (view-only, not
     hidden).
   - **Full regression**: every pre-existing T2A–T3C scenario re-run in
     the same session still passes unmodified.
   - Zero JavaScript errors across every scenario.
4. **Not independently re-verified**: real Supabase-backed auth/session
   flow or real Supabase Storage behavior (no credentials in this
   environment, per standing constraints — the local Postgres
   verification covers the `attachments` table's own RLS, not the
   Storage service itself), and any real-device rendering.

## Known limitations

1. **No versioning.** "Replace" is a client-orchestrated upload-then-
   delete-old sequence, not a real backend version/history concept —
   there is no way to see or recover a replaced file's prior version.
2. **The same 20 MB per-file / 100 MB per-record limits apply to
   tasks as everywhere else** — unchanged, not task-specific.
3. **A pre-existing, unrelated Storage-policy gap was found (but
   deliberately NOT fixed) while adding `'task'` to
   `attachments_storage_insert`'s allowlist**: `'meeting'` was never
   added to that same allowlist when meeting attachments shipped
   (`patch-meetings-foundation.sql`, 2026-07-22, added a `'meeting'`
   branch to the table-level `attachments_select`/`_insert`/`_delete`
   policies but never touched `storage-policies.sql`). Every meeting
   attachment upload has likely been silently rejected by Supabase
   Storage since that feature shipped — the table-level RLS would
   allow it, but the Storage bucket's own separate folder-name
   allowlist would not. Left as-is, flagged in a comment directly in
   `storage-policies.sql` and here, out of this milestone's own scope
   (Task Attachments) — recommended as a separate, dedicated fix.
4. **No per-attachment description/label field** — only a filename,
   matching every other module's attachments today; not requested by
   this milestone.

## Future enhancements

- Fix the pre-existing `'meeting'` Storage-allowlist gap described
  above, in its own dedicated, separately-approved milestone.
- A real "replace" concept at the backend (a version/supersedes
  column), if the current client-orchestrated sequence's failure modes
  (a stranded old file if the follow-up delete fails) ever prove
  insufficient in practice.
- Bulk delete / bulk download, if a task's typical attachment count
  ever grows enough to make one-at-a-time actions a real friction
  point — not built here, since no realistic task volume approaches
  that today.
