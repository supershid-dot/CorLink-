-- ─── Validation: Platform Module Foundation ───────────────────
-- Read-only. Run manually against a project AFTER
-- patch-platform-module-foundation.sql has been applied there, to
-- confirm the migration behaved as designed. Every query below is a
-- SELECT — nothing here writes data. A query returning zero rows in
-- the "should be empty" checks means that check passed.
--
-- Corresponds to docs/03-migration-architecture.md Phase 1 and
-- docs/04-platform-module-foundation.md "Validation".

-- 1. All 11 required module keys exist exactly once.
SELECT module_key, COUNT(*) AS row_count
FROM platform_modules
GROUP BY module_key
HAVING COUNT(*) <> 1;
-- Expect: 0 rows.

SELECT ARRAY(SELECT module_key FROM platform_modules ORDER BY module_key)
     = ARRAY[
         'administration', 'calendar', 'document_signing', 'entry',
         'meetings', 'prison_registry', 'prisoner_correspondence',
         'reports', 'requests', 'rooms', 'tasks'
       ] AS all_required_keys_present;
-- Expect: all_required_keys_present = true.

-- 2. No duplicate organization-module assignments.
SELECT organization_id, module_id, COUNT(*) AS row_count
FROM organization_modules
GROUP BY organization_id, module_id
HAVING COUNT(*) > 1;
-- Expect: 0 rows.

-- 3. Every organization_modules row references a valid organization
--    and module (the FKs already guarantee this at the DB level — this
--    is a belt-and-suspenders check for orphans that could only arise
--    from a bypassed constraint).
SELECT om.id
FROM organization_modules om
LEFT JOIN organizations o     ON o.id = om.organization_id
LEFT JOIN platform_modules pm ON pm.id = om.module_id
WHERE o.id IS NULL OR pm.id IS NULL;
-- Expect: 0 rows.

-- 4. Current MCS access remains preserved: every 'mcs'-type
--    organization has requests/entry/prisoner_correspondence/
--    administration enabled.
SELECT o.id, o.name, pm.module_key
FROM organizations o
CROSS JOIN platform_modules pm
LEFT JOIN organization_modules om
  ON om.organization_id = o.id AND om.module_id = pm.id
WHERE o.type = 'mcs'
  AND pm.module_key IN ('requests', 'entry', 'prisoner_correspondence', 'administration')
  AND (om.is_enabled IS DISTINCT FROM TRUE);
-- Expect: 0 rows.

-- 5. External (authority) organizations have not gained any
--    unshipped/future module (anything whose route IS NULL must never
--    be enabled for any organization, regardless of type).
SELECT o.id, o.name, pm.module_key
FROM organizations o
CROSS JOIN platform_modules pm
JOIN organization_modules om
  ON om.organization_id = o.id AND om.module_id = pm.id
WHERE pm.route IS NULL
  AND om.is_enabled = TRUE;
-- Expect: 0 rows, for every organization of every type.

-- 5b. Reviewer note (not a pass/fail query): shows each authority-type
-- organization's enabled module list, for reference. This exact review
-- was already performed against live data in
-- docs/05-live-organization-module-assessment.md, which confirmed the
-- current seed (requests/entry/prisoner_correspondence/administration
-- enabled for EVERY organization, preserving today's actual
-- unrestricted nav/RLS behavior) is correct for the organizations that
-- exist today, with one flagged non-blocking follow-up (HRCM's Entry
-- module — a policy question, not a data gap). Re-run this query and
-- re-consult docs/05 if new authority-type organizations are added
-- before this migration reaches production.
SELECT o.name, o.type, pm.module_key, om.is_enabled
FROM organizations o
JOIN organization_modules om ON om.organization_id = o.id
JOIN platform_modules pm ON pm.id = om.module_id
WHERE o.type = 'authority'
ORDER BY o.name, pm.display_order;

-- 6. Ordinary (non-super-admin) users cannot modify organization
--    module settings. Run each SELECT below via `SET ROLE authenticated`
--    plus `SET request.jwt.claims` impersonating a representative
--    non-admin user (standard Supabase RLS testing pattern already
--    used for this repo's other patches) — or exercise it live via the
--    anon/authenticated client as that user and confirm the UPDATE is
--    rejected by RLS, not merely hidden by the UI.
-- UPDATE organization_modules SET is_enabled = TRUE WHERE id = '<any row>';
-- Expect: 0 rows affected / permission denied, when run as a
-- non-super-admin authenticated user.

-- 7. Anonymous users cannot read organization module assignments.
-- Run as the anon role (no auth.uid()):
-- SELECT * FROM organization_modules;
-- Expect: 0 rows (organization_modules_select requires
-- is_super_admin() OR organization_id = get_my_org_id(), both of which
-- resolve to false/NULL with no authenticated user).

-- 8. Helper functions return expected values for representative roles.
-- Run as a known user in a known org:
-- SELECT module_enabled_for_org('<org-id>', 'requests');       -- expect true (per check 4)
-- SELECT module_enabled_for_org('<org-id>', 'meetings');       -- expect false (no route yet)
-- SELECT current_user_module_enabled('requests');              -- expect true for any active org member
-- SELECT is_module_active('requests');                         -- expect true
-- SELECT is_module_active('nonexistent_key');                  -- expect false (COALESCE default)

-- 9. Rerunning the seed does not create duplicates or reset admin
--    overrides. Run patch-platform-module-foundation.sql a second time
--    against the same project, then re-run checks 1 and 2 above — both
--    must still return 0 rows. Additionally confirm a manually-set
--    platform_modules.is_active = FALSE (if any) survived the rerun:
-- SELECT module_key, is_active FROM platform_modules WHERE is_active = FALSE;
-- Expect: unchanged from before the rerun.
