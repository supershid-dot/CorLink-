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

DROP POLICY IF EXISTS "attachments_storage_insert" ON storage.objects;
CREATE POLICY "attachments_storage_insert" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'attachments'
    AND owner = auth.uid()
    AND (storage.foldername(name))[1] IN ('request', 'response', 'internal_request', 'prisoner_letter', 'prisoner_reply')
  );

DROP POLICY IF EXISTS "attachments_storage_delete" ON storage.objects;
CREATE POLICY "attachments_storage_delete" ON storage.objects
  FOR DELETE USING (bucket_id = 'attachments' AND owner = auth.uid());
