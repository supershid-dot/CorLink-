-- CAP-003 Phase 1.0A legacy notification INSERT-RLS correction
-- rollback validator (hard fail)
\set ON_ERROR_STOP on
DO $$
DECLARE v_missing TEXT := '';
BEGIN
  -- The new RPC must be gone.
  IF to_regprocedure('public.create_legacy_notification(uuid[],text,text,uuid,text)') IS NOT NULL THEN
    v_missing := v_missing || 'create_legacy_notification-still-present ';
  END IF;

  -- The original insecure policy must be back, byte-identical to its
  -- pre-correction definition (this is the expected, verified-correct
  -- pre-correction state -- not an endorsement of it).
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications'
      AND policyname = 'notif_insert' AND cmd = 'INSERT'
      AND with_check = '(auth.uid() IS NOT NULL)'
  ) THEN v_missing := v_missing || 'notif_insert-policy-not-restored '; END IF;

  -- notif_select/notif_update must be exactly as they always were --
  -- this rollback never touched them, so they should be unaffected
  -- either way, but verified directly.
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications'
      AND policyname = 'notif_select' AND cmd = 'SELECT' AND qual = '(user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'notif_select-drift '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications'
      AND policyname = 'notif_update' AND cmd = 'UPDATE' AND qual = '(user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'notif_update-drift '; END IF;

  -- Exactly 3 policies total on notifications (select, insert, update)
  -- -- back to the original pre-correction count.
  IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'notifications') <> 3 THEN
    v_missing := v_missing || 'unexpected-policy-count-after-rollback ';
  END IF;

  -- Phase 1-5.4 CAP-002 baseline and the notifications table itself
  -- remain completely untouched by this rollback either way.
  IF to_regclass('public.notifications') IS NULL
     OR to_regclass('public.workflow_events') IS NULL
     OR to_regprocedure('public.process_workflow_sla_due_batch(integer)') IS NULL
  THEN v_missing := v_missing || 'baseline-drift-after-rollback '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Legacy notification INSERT-RLS correction rollback validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Legacy notification INSERT-RLS correction rollback validation PASSED (create_legacy_notification absent, notif_insert restored byte-identical to its pre-correction definition, notif_select/notif_update/CAP-002 baseline all unaffected, policy count back to 3).';
END $$;
