-- ─── Patch: Entry can be logged by multiple sections ─────────────
-- Replaces organizations.entry_section_id (a single nullable FK — only
-- one section per org could log incoming Entry correspondence) with a
-- join table, entry_sections, so an org can designate more than one
-- desk (e.g. both a front office and a legal-affairs section) to log
-- public/family mail, outside-office correspondence, and prisoner
-- complaints. Zero rows configured for an org still means "any org
-- member may log", same never-breaks-on-upgrade shape as before.
--
-- Idempotent — safe to run more than once.

BEGIN;

-- 1. New join table + backfill from the old single column.
CREATE TABLE IF NOT EXISTS entry_sections (
  org_id     UUID        NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  section_id UUID        NOT NULL REFERENCES sections(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (org_id, section_id)
);
CREATE INDEX IF NOT EXISTS idx_entry_sections_org ON entry_sections(org_id);

INSERT INTO entry_sections (org_id, section_id)
SELECT id, entry_section_id FROM organizations WHERE entry_section_id IS NOT NULL
ON CONFLICT DO NOTHING;

ALTER TABLE organizations DROP COLUMN IF EXISTS entry_section_id;

ALTER TABLE entry_sections ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "entry_sections_select" ON entry_sections;
CREATE POLICY "entry_sections_select" ON entry_sections
  FOR SELECT USING (is_super_admin() OR org_id = get_my_org_id());

-- 2. is_entry_staff() now checks membership across any configured
--    entry section instead of a single column.
CREATE OR REPLACE FUNCTION is_entry_staff(p_org_id UUID)
RETURNS BOOLEAN AS $$
  SELECT
    (get_my_org_id() = p_org_id AND is_supervisor_or_above())
    OR CASE
      WHEN EXISTS (SELECT 1 FROM entry_sections WHERE org_id = p_org_id)
        THEN EXISTS (
          SELECT 1 FROM entry_sections es
          WHERE es.org_id = p_org_id AND es.section_id IN (SELECT my_section_ids())
        )
      ELSE get_my_org_id() = p_org_id
    END;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- 3. update_org_workflow_settings() takes an array now instead of a
--    single section id. Must DROP the old 5-arg signature first —
--    CREATE OR REPLACE cannot change a parameter's type in place, it
--    would just create a second overload and leave the old one callable.
DROP FUNCTION IF EXISTS update_org_workflow_settings(UUID, UUID, TEXT, UUID, UUID);

CREATE OR REPLACE FUNCTION update_org_workflow_settings(
  p_org_id UUID,
  p_default_receiving_section_id UUID,
  p_reference_number_format TEXT,
  p_prisoner_registry_section_id UUID DEFAULT NULL,
  p_entry_section_ids UUID[] DEFAULT NULL
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

  IF p_entry_section_ids IS NOT NULL AND EXISTS (
    SELECT 1 FROM unnest(p_entry_section_ids) sid
    WHERE NOT EXISTS (SELECT 1 FROM sections WHERE id = sid AND org_id = p_org_id)
  ) THEN
    RAISE EXCEPTION 'entry_section_ids must all belong to the target organization';
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

  DELETE FROM entry_sections WHERE org_id = p_org_id;
  IF p_entry_section_ids IS NOT NULL THEN
    INSERT INTO entry_sections (org_id, section_id)
    SELECT p_org_id, sid FROM unnest(p_entry_section_ids) sid;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMIT;
