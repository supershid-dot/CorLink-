-- ============================================================
-- CorLink — Storage Bucket Policies
-- Run AFTER creating the buckets listed in supabase/auth-setup.md
-- (Storage → New bucket). Covers `org-logos` and `attachments`;
-- `prisoner-letters` bucket policies remain a future addition.
-- ============================================================

-- org-logos is a PUBLIC bucket (logos are shown on shared login/branding
-- screens), so anyone can read. Only super admins can write — this
-- mirrors the "orgs_update" table policy, which restricts organization
-- edits (of which the logo is one) to super admins.
--
-- DROP POLICY IF EXISTS first so this file can be re-run safely (e.g.
-- if it was already applied once, or the Supabase bucket UI created a
-- same-named default policy when the bucket was marked Public).
DROP POLICY IF EXISTS "org_logos_public_read" ON storage.objects;
CREATE POLICY "org_logos_public_read" ON storage.objects
  FOR SELECT USING (bucket_id = 'org-logos');

DROP POLICY IF EXISTS "org_logos_admin_insert" ON storage.objects;
CREATE POLICY "org_logos_admin_insert" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'org-logos' AND is_super_admin());

DROP POLICY IF EXISTS "org_logos_admin_update" ON storage.objects;
CREATE POLICY "org_logos_admin_update" ON storage.objects
  FOR UPDATE USING (bucket_id = 'org-logos' AND is_super_admin());

DROP POLICY IF EXISTS "org_logos_admin_delete" ON storage.objects;
CREATE POLICY "org_logos_admin_delete" ON storage.objects
  FOR DELETE USING (bucket_id = 'org-logos' AND is_super_admin());

-- attachments is a PRIVATE bucket (requests/responses/internal-request
-- supporting documents). Upload path convention:
-- attachments/{record_type}/{record_id}/{filename}. The SELECT policy
-- deliberately reuses the `attachments` TABLE's own RLS (attachments_select)
-- via an EXISTS subquery instead of re-deriving that visibility logic
-- here — Supabase Storage RLS runs under the requesting user's own role
-- (no privilege escalation happens in this path), so the subquery is
-- genuinely filtered by attachments_select, same as any other query
-- that role would run. This is the standard "linking table" pattern for
-- Storage authorization, not a shortcut.
--
-- INSERT can't require a matching `attachments` row to already exist
-- (chicken-and-egg — the row is only created after a successful
-- upload), so it's scoped only as tightly as Storage itself allows: the
-- uploader must own the object, and the path's first segment must be
-- one of the record types attachments actually supports. This is a
-- soft boundary against storage-quota abuse, not a visibility control —
-- nothing can ever be read back without a corresponding `attachments`
-- row satisfying attachments_select regardless of what gets uploaded.
DROP POLICY IF EXISTS "attachments_storage_select" ON storage.objects;
CREATE POLICY "attachments_storage_select" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'attachments'
    AND EXISTS (SELECT 1 FROM attachments a WHERE a.storage_path = storage.objects.name)
  );

-- 'internal_reply' was missing from this list — added as its own
-- attachments record_type later (patch-internal-reply-attachments.sql,
-- for Draft Reply attachments in Internal Collaboration) but this
-- allowlist was never updated to match, so every upload attempt for an
-- internal reply's attachment (path internal_reply/{id}/{filename})
-- has been silently rejected by Storage since that feature shipped.
DROP POLICY IF EXISTS "attachments_storage_insert" ON storage.objects;
CREATE POLICY "attachments_storage_insert" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'attachments'
    AND owner = auth.uid()
    AND (storage.foldername(name))[1] IN ('request', 'response', 'internal_request', 'prisoner_letter', 'prisoner_reply', 'internal_reply', 'external_correspondence', 'external_correspondence_reply')
  );

DROP POLICY IF EXISTS "attachments_storage_delete" ON storage.objects;
CREATE POLICY "attachments_storage_delete" ON storage.objects
  FOR DELETE USING (bucket_id = 'attachments' AND owner = auth.uid());

-- ─── Server-side upload limits ──────────────────────────────────
-- js/data/attachments-api.js already checks extension/size before
-- uploading, but that's a client-side convenience check only — a
-- direct call to the Storage API bypasses it entirely. Setting these
-- on the bucket row itself makes Storage reject the upload server-side
-- regardless of which client (or lack of one) is doing the uploading.
-- Mirrors ALLOWED_EXTENSIONS/MAX_FILE_BYTES in attachments-api.js —
-- keep both in sync if either changes. Buckets must already exist
-- (created manually per supabase/auth-setup.md) for these UPDATEs to
-- affect anything; harmless no-op otherwise.
UPDATE storage.buckets SET
  file_size_limit = 20971520, -- 20 MB, matches MAX_FILE_BYTES
  allowed_mime_types = ARRAY[
    'application/pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'image/jpeg',
    'image/png'
  ]
WHERE id = 'attachments';

-- org-logos: no client-side type check exists today beyond the file
-- input's `accept` attribute (not a security boundary) — this is the
-- only actual enforcement.
UPDATE storage.buckets SET
  file_size_limit = 2097152, -- 2 MB — a logo has no business being larger
  allowed_mime_types = ARRAY['image/png', 'image/jpeg']
WHERE id = 'org-logos';
