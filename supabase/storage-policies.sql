-- ============================================================
-- CorLink — Storage Bucket Policies
-- Run AFTER creating the buckets listed in supabase/auth-setup.md
-- (Storage → New bucket). This file only covers `org-logos`, the
-- one bucket whose access rules the app currently exercises;
-- `attachments` / `prisoner-letters` policies land with Phases 3-4.
-- ============================================================

-- org-logos is a PUBLIC bucket (logos are shown on shared login/branding
-- screens), so anyone can read. Only super admins can write — this
-- mirrors the "orgs_update" table policy, which restricts organization
-- edits (of which the logo is one) to super admins.
CREATE POLICY "org_logos_public_read" ON storage.objects
  FOR SELECT USING (bucket_id = 'org-logos');

CREATE POLICY "org_logos_admin_insert" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'org-logos' AND is_super_admin());

CREATE POLICY "org_logos_admin_update" ON storage.objects
  FOR UPDATE USING (bucket_id = 'org-logos' AND is_super_admin());

CREATE POLICY "org_logos_admin_delete" ON storage.objects
  FOR DELETE USING (bucket_id = 'org-logos' AND is_super_admin());
