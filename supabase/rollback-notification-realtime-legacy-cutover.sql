-- CAP-003 Phase 1.5 rollback. Reverses patch-notification-realtime-
-- legacy-cutover.sql exactly.
--
-- Non-destructive by design: this milestone's SQL-side change is
-- exactly one thing -- user_notifications' membership in the
-- supabase_realtime publication (conditionally added when that
-- publication object exists at all). Removing that membership is the
-- complete DB-side rollback; no table was created, no column was
-- added, no row was written, and none of the four legacy dual-writes
-- were ever touched by the patch, so there is nothing to restore on
-- that front -- they were never modified.
--
-- The frontend-side rollback (js/data/notifications-api.js,
-- js/views/shell.js) is a plain file revert, not a SQL migration --
-- see docs/88 "Rollback" for the exact git-level steps (this repo has
-- no frontend migration/versioning system; reverting to the pre-1.5
-- commit for those two files is the complete frontend rollback, and
-- is independent of whether this SQL rollback is also applied).
\set ON_ERROR_STOP on
BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    IF EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'user_notifications'
    ) THEN
      EXECUTE 'ALTER PUBLICATION supabase_realtime DROP TABLE public.user_notifications';
    END IF;
  END IF;
END $$;

COMMIT;
