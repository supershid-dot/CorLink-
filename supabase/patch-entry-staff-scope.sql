-- ─── Patch: scope is_entry_staff() away from a blanket supervisor bypass ───
-- is_entry_staff() previously OR'd in "(get_my_org_id() = p_org_id AND
-- is_supervisor_or_above())" — meaning every supervisor/mcs_admin/
-- authority_admin/super_admin in the org could see and manage every
-- logged entry, regardless of section. Reported as "all the entry is
-- visible to all the supervisors." Visibility should instead be scoped
-- to: a member of one of the org's designated entry_sections (or any
-- org member when none are configured yet, same never-breaks-on-
-- upgrade fallback as before), OR — via external_correspondence_select's
-- other existing branches, unchanged by this patch — the entry's
-- to_section_id member, the assigned staff member, or whoever logged it.
--
-- Idempotent (CREATE OR REPLACE) — safe to run more than once.

BEGIN;

CREATE OR REPLACE FUNCTION is_entry_staff(p_org_id UUID)
RETURNS BOOLEAN AS $$
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM entry_sections WHERE org_id = p_org_id)
      THEN EXISTS (
        SELECT 1 FROM entry_sections es
        WHERE es.org_id = p_org_id AND es.section_id IN (SELECT my_section_ids())
      )
    ELSE get_my_org_id() = p_org_id
  END;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

COMMIT;
