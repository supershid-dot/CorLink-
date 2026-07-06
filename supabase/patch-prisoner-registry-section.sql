-- ─── Patch: Prisoner Registry Section Restriction ──────────────
-- 1. Only an MCS org's designated section can add/edit prisoners in
--    the registry (mirrors the default_receiving_section_id pattern —
--    opt-in, falls back to org-wide if unset so no org is locked out
--    by upgrading).
-- 2. Closes a gap where an authority-org member could submit a
--    prisoner_letter directly via the API despite the compose button
--    being hidden client-side: from_prison_id must now actually be an
--    'mcs'-type org and to_org_id an 'authority'-type org — letters
--    only ever flow MCS -> authority; the authority side only replies.
-- Idempotent — safe to run more than once.

BEGIN;

-- 1a. New org setting, same shape as default_receiving_section_id.
ALTER TABLE organizations
  ADD COLUMN IF NOT EXISTS prisoner_registry_section_id UUID REFERENCES sections(id);

-- 1b. True if the caller may add/edit p_org_id's prisoner registry:
-- a supervisor/admin of that org, OR (if the org has designated a
-- section) any member of that section regardless of role — same
-- my_section_ids() membership test internal_requests_select etc. use
-- elsewhere — OR (if no section is set yet) any member of the org at
-- all, same never-breaks-on-upgrade shape as is_default_section_receiver.
CREATE OR REPLACE FUNCTION is_prisoner_registry_manager(p_org_id UUID)
RETURNS BOOLEAN AS $$
  SELECT
    (get_my_org_id() = p_org_id AND is_supervisor_or_above())
    OR CASE
      WHEN (SELECT prisoner_registry_section_id FROM organizations WHERE id = p_org_id) IS NOT NULL
        THEN (SELECT prisoner_registry_section_id FROM organizations WHERE id = p_org_id) IN (SELECT my_section_ids())
      ELSE get_my_org_id() = p_org_id
    END;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

DROP POLICY IF EXISTS "prisoners_insert" ON prisoners;
CREATE POLICY "prisoners_insert" ON prisoners
  FOR INSERT WITH CHECK (org_id = get_my_org_id() AND is_prisoner_registry_manager(org_id));

DROP POLICY IF EXISTS "prisoners_update" ON prisoners;
CREATE POLICY "prisoners_update" ON prisoners
  FOR UPDATE USING (org_id = get_my_org_id() AND is_prisoner_registry_manager(org_id))
  WITH CHECK (org_id = get_my_org_id() AND is_prisoner_registry_manager(org_id));

-- 1c. Let an org's own admin configure prisoner_registry_section_id
-- through the same RPC used for default_receiving_section_id /
-- reference_number_format (orgs_update is super-admin-only; this
-- SECURITY DEFINER function is the narrow, validated door for an org
-- admin to touch just these three columns on their own org). Must
-- DROP the old 3-arg signature first — CREATE OR REPLACE cannot add
-- a parameter to an existing function, it would just create a second
-- overload and leave the old one callable.
DROP FUNCTION IF EXISTS update_org_workflow_settings(UUID, UUID, TEXT);

CREATE OR REPLACE FUNCTION update_org_workflow_settings(
  p_org_id UUID,
  p_default_receiving_section_id UUID,
  p_reference_number_format TEXT,
  p_prisoner_registry_section_id UUID DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
  IF NOT (is_super_admin() OR (is_admin() AND p_org_id = get_my_org_id())) THEN
    RAISE EXCEPTION 'Not authorized to update this organization';
  END IF;

  IF p_default_receiving_section_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sections WHERE id = p_default_receiving_section_id AND org_id = p_org_id
  ) THEN
    RAISE EXCEPTION 'default_receiving_section_id must belong to the target organization';
  END IF;

  IF p_prisoner_registry_section_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sections WHERE id = p_prisoner_registry_section_id AND org_id = p_org_id
  ) THEN
    RAISE EXCEPTION 'prisoner_registry_section_id must belong to the target organization';
  END IF;

  IF p_reference_number_format IS NULL OR trim(p_reference_number_format) = ''
     OR p_reference_number_format NOT LIKE '%{SEQ}%' THEN
    RAISE EXCEPTION 'reference_number_format must be non-empty and include the {SEQ} token';
  END IF;

  UPDATE organizations
  SET default_receiving_section_id = p_default_receiving_section_id,
      reference_number_format = p_reference_number_format,
      prisoner_registry_section_id = p_prisoner_registry_section_id
  WHERE id = p_org_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. Letters only ever flow MCS -> authority.
DROP POLICY IF EXISTS "prisoner_letters_insert" ON prisoner_letters;
CREATE POLICY "prisoner_letters_insert" ON prisoner_letters
  FOR INSERT WITH CHECK (
    submitted_by = auth.uid()
    AND from_prison_id = get_my_org_id()
    AND EXISTS (SELECT 1 FROM organizations o WHERE o.id = from_prison_id AND o.type = 'mcs')
    AND EXISTS (SELECT 1 FROM organizations o WHERE o.id = to_org_id AND o.type = 'authority')
  );

COMMIT;
