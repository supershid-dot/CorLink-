-- Validates supabase/patch-meetings-prebook-slots.sql. Read-only checks
-- plus one small smoke-test batch (created as the currently-authenticated
-- caller — run this via the Supabase SQL editor logged in as an org
-- admin, or via `SET request.jwt.claims` for a service-role session, same
-- convention as this repo's other validate-*.sql smoke tests).

DO $$
DECLARE
  v_missing TEXT := '';
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'create_prebooked_meeting_slots'
  ) THEN
    v_missing := v_missing || 'function:create_prebooked_meeting_slots ';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.role_routine_grants
    WHERE routine_name = 'create_prebooked_meeting_slots' AND grantee = 'authenticated' AND privilege_type = 'EXECUTE'
  ) THEN
    v_missing := v_missing || 'grant:create_prebooked_meeting_slots-authenticated ';
  END IF;

  IF NOT (
    SELECT pg_get_constraintdef(oid) LIKE '%''meeting_prebook_slots_created''%'
    FROM pg_constraint WHERE conname = 'audit_logs_action_check'
  ) THEN
    v_missing := v_missing || 'constraint:audit_logs_action_check-missing-meeting_prebook_slots_created ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'validate-meetings-prebook-slots FAILED: %', v_missing;
  END IF;

  RAISE NOTICE 'validate-meetings-prebook-slots: static checks passed';
END $$;

-- ── Smoke test (manual — uncomment and run as an authenticated org
-- admin session to exercise the actual RPC end-to-end) ──────────────
--
-- DO $$
-- DECLARE
--   v_section_id UUID;
--   v_count INTEGER;
--   v_id UUID;
-- BEGIN
--   SELECT id INTO v_section_id FROM sections WHERE org_id = get_my_org_id() AND is_active = TRUE LIMIT 1;
--   IF v_section_id IS NULL THEN
--     RAISE NOTICE 'skipped: no active section found for the caller''s org';
--     RETURN;
--   END IF;
--
--   SELECT count(*) INTO v_count FROM create_prebooked_meeting_slots(
--     p_title := 'Validate Smoke Test Slot',
--     p_section_id := v_section_id,
--     p_from_date := CURRENT_DATE + 7,
--     p_to_date := CURRENT_DATE + 11,
--     p_days_of_week := ARRAY[1,2,3,4,5],
--     p_start_time := '09:00',
--     p_end_time := '09:30'
--   );
--   IF v_count = 0 THEN
--     RAISE EXCEPTION 'validate-meetings-prebook-slots FAILED: smoke test created 0 slots';
--   END IF;
--
--   IF EXISTS (
--     SELECT 1 FROM meetings WHERE title = 'Validate Smoke Test Slot'
--       AND (status <> 'draft' OR section_id <> v_section_id)
--   ) THEN
--     RAISE EXCEPTION 'validate-meetings-prebook-slots FAILED: a created slot is not a section-tagged draft';
--   END IF;
--
--   IF EXISTS (
--     SELECT 1 FROM meetings m WHERE m.title = 'Validate Smoke Test Slot'
--       AND EXISTS (SELECT 1 FROM meeting_participants mp WHERE mp.meeting_id = m.id AND mp.removed_at IS NULL)
--   ) THEN
--     RAISE EXCEPTION 'validate-meetings-prebook-slots FAILED: a created slot unexpectedly has participants';
--   END IF;
--
--   RAISE NOTICE 'validate-meetings-prebook-slots: smoke test passed (% slots created)', v_count;
--
--   -- Cleanup — through the same delete_draft_meeting() RPC the
--   -- frontend uses, not a raw DELETE (meetings carries zero write
--   -- policy for any role; every mutation goes through an RPC).
--   FOR v_id IN SELECT id FROM meetings WHERE title = 'Validate Smoke Test Slot' LOOP
--     PERFORM delete_draft_meeting(v_id);
--   END LOOP;
-- END $$;
