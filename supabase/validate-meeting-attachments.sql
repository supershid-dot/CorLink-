-- ============================================================
-- CorLink — Structural/introspection validation: Meeting Attachment
-- Storage Authorization fix (T3D.1). Companion to
-- test-meeting-attachments.sql.
--
-- Uses pg_get_expr()/pg_get_constraintdef() against pg_policy/
-- pg_constraint to confirm the CORRECTED state of the Storage-level
-- allowlist, and that nothing else (the `attachments` table's own
-- CHECK constraint or its SELECT/INSERT/DELETE RLS — all already
-- correct before this milestone) was altered by this fix. Run against
-- a disposable/local test database with storage-policies.sql
-- (post-fix) applied — NEVER against staging or production.
-- Read-only; safe to run any number of times.
-- ============================================================

\set ON_ERROR_STOP on

-- ─── 1. attachments_storage_insert now includes 'meeting' ────────
SELECT
  pg_get_expr(polwithcheck, polrelid) LIKE '%''meeting''%' AS storage_insert_allows_meeting
FROM pg_policy WHERE polname = 'attachments_storage_insert';

-- ─── 2. ...and every pre-existing entry is still present (this was
-- an ADDITION, not a rewrite — nothing should have been dropped) ───
SELECT
  pg_get_expr(polwithcheck, polrelid) LIKE '%''request''%'                       AS has_request,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''response''%'                      AS has_response,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''internal_request''%'              AS has_internal_request,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''prisoner_letter''%'               AS has_prisoner_letter,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''prisoner_reply''%'                AS has_prisoner_reply,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''internal_reply''%'                AS has_internal_reply,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''external_correspondence''%'       AS has_external_correspondence,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''external_correspondence_reply''%' AS has_external_correspondence_reply,
  pg_get_expr(polwithcheck, polrelid) LIKE '%''task''%'                          AS has_task
FROM pg_policy WHERE polname = 'attachments_storage_insert';

-- ─── 3. attachments_storage_insert still requires bucket_id =
-- 'attachments' and owner = auth.uid() — the fix only widened the
-- folder allowlist, not the ownership/bucket boundary. ─────────────
SELECT
  pg_get_expr(polwithcheck, polrelid) LIKE '%bucket_id = ''attachments''%' AS storage_insert_still_bucket_scoped,
  pg_get_expr(polwithcheck, polrelid) LIKE '%owner = auth.uid()%'          AS storage_insert_still_owner_scoped
FROM pg_policy WHERE polname = 'attachments_storage_insert';

-- ─── 4. attachments_storage_select is untouched by this fix — no
-- per-record-type allowlist at all (it delegates to the `attachments`
-- table's own RLS via EXISTS), so 'meeting' downloads were never
-- blocked at this layer and don't need — and don't have — an explicit
-- mention here. ─────────────────────────────────────────────────────
SELECT
  pg_get_expr(polqual, polrelid) LIKE '%FROM attachments a%WHERE (a.storage_path = objects.name)%'
    AS storage_select_still_delegates_to_attachments_table,
  pg_get_expr(polqual, polrelid) NOT LIKE '%foldername%'
    AS storage_select_has_no_folder_allowlist
FROM pg_policy WHERE polname = 'attachments_storage_select';

-- ─── 5. attachments_storage_delete is untouched by this fix — owner-
-- scoped only, no folder allowlist, same as before. ─────────────────
SELECT
  pg_get_expr(polqual, polrelid) LIKE '%owner = auth.uid()%' AS storage_delete_still_owner_scoped,
  pg_get_expr(polqual, polrelid) NOT LIKE '%foldername%'     AS storage_delete_has_no_folder_allowlist
FROM pg_policy WHERE polname = 'attachments_storage_delete';

-- ─── 6. Table-level attachments_record_type_check is UNCHANGED by
-- this milestone — 'meeting' was already a valid record_type before
-- T3D.1 (added by patch-meetings-foundation.sql), and still is. ────
SELECT
  pg_get_constraintdef(oid) LIKE '%''meeting''%' AS check_constraint_has_meeting
FROM pg_constraint WHERE conname = 'attachments_record_type_check';

-- ─── 7. Table-level attachments_select/_insert/_delete 'meeting'
-- branches are UNCHANGED by this milestone (this fix touched
-- storage-policies.sql only) — still present, still delegating to
-- can_view_meeting()/can_manage_meeting()/is_meeting_lock_overridable(),
-- not re-derived here. ──────────────────────────────────────────────
SELECT
  pg_get_expr(polqual, polrelid) LIKE '%''meeting''::text) AND can_view_meeting(record_id)%'
    AS table_select_meeting_branch_unchanged
FROM pg_policy WHERE polname = 'attachments_select';

SELECT
  pg_get_expr(polwithcheck, polrelid) LIKE '%''meeting''::text) AND can_manage_meeting(record_id)%'
    AS table_insert_meeting_branch_unchanged
FROM pg_policy WHERE polname = 'attachments_insert';

SELECT
  pg_get_expr(polqual, polrelid) LIKE '%''meeting''::text) AND (EXISTS%'
    AS table_delete_meeting_branch_unchanged
FROM pg_policy WHERE polname = 'attachments_delete';

-- ─── 8. No duplicate policy overloads (DROP+CREATE should leave
-- exactly one policy per name per table). ──────────────────────────
SELECT polname, count(*) AS n
FROM pg_policy
WHERE polname IN (
  'attachments_storage_insert', 'attachments_storage_select', 'attachments_storage_delete',
  'attachments_select', 'attachments_insert', 'attachments_delete'
)
GROUP BY polname
HAVING count(*) <> 1;
-- ^ Expect ZERO rows returned — any row here is a duplicate-policy bug.
