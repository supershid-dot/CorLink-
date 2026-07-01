-- ============================================================
-- CorLink — Patch: close RLS gaps in prisoner_letters/
-- prisoner_replies ahead of Phase 4 (Prisoner Letters).
--
-- Run this INSTEAD of re-running the full rls.sql — it only touches
-- the two policies below.
--
-- 1. prisoner_letters_update's supervisor clause had no org-membership
--    check — ANY supervisor in ANY organization could update ANY
--    prisoner letter, including ones belonging to a completely
--    unrelated MCS/authority pair. Mirrors the requests_update_
--    supervisor gap fixed in the Phase 3 patch.
-- 2. prisoner_replies_insert only checked replied_by = auth.uid(),
--    with no restriction on which letter_id you could attach a reply
--    to — any authenticated user who obtained a letter_id (even one
--    they can't see) could insert a reply against it. Now mirrors
--    prisoner_letters_select's visibility.
-- ============================================================

BEGIN;

DROP POLICY IF EXISTS "prisoner_letters_update" ON prisoner_letters;
CREATE POLICY "prisoner_letters_update" ON prisoner_letters
  FOR UPDATE USING (
    submitted_by = auth.uid()
    OR assigned_to = auth.uid()
    OR (
      is_supervisor_or_above()
      AND (from_prison_id = get_my_org_id() OR to_org_id = get_my_org_id())
    )
  );

DROP POLICY IF EXISTS "prisoner_replies_insert" ON prisoner_replies;
CREATE POLICY "prisoner_replies_insert" ON prisoner_replies
  FOR INSERT WITH CHECK (
    replied_by = auth.uid()
    AND EXISTS (
      SELECT 1 FROM prisoner_letters pl
      WHERE pl.id = letter_id
        AND (
          pl.submitted_by = auth.uid()
          OR pl.assigned_to = auth.uid()
          OR (
            is_supervisor_or_above()
            AND (pl.from_prison_id = get_my_org_id() OR pl.to_org_id = get_my_org_id())
          )
        )
    )
  );

COMMIT;
