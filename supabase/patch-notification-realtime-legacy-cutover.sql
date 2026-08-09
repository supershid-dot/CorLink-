-- ============================================================
-- CAP-003 Phase 1.5 -- Realtime UI Integration + Legacy
-- Notification Cutover.
--
-- ─── Scope ──────────────────────────────────────────────────────
-- Connects the application notification UI to user_notifications
-- (docs/78, docs/81) and formalizes Realtime as the signal-only
-- refresh mechanism docs/78 §16 already specified. The frontend side
-- of this milestone (js/data/notifications-api.js, js/views/shell.js)
-- is the majority of the actual work; this SQL patch is deliberately
-- small, because the per-event equivalence review below found no safe
-- removal of any legacy dual-write.
--
-- ─── Why no legacy dual-write is removed here ──────────────────────
-- Phase 1.5's own governing instruction requires proving recipient,
-- timing, and authorization equivalence between each of the four
-- currently-migrated events (task.assigned.v1, task.completed.v1,
-- meetings.rescheduled.v1, meetings.cancelled.v1) and its legacy
-- counterpart before any legacy INSERT may be removed. That review
-- (reproduced in full in docs/88) found a genuine, provable semantic
-- gap in all four:
--   * task.assigned.v1 / task.completed.v1 -- CAP-003's worker
--     performs LATE authorization revalidation (intent_user_can_view_
--     task(), patch-notification-target-expansion.sql) at processing
--     time, not at enqueue time. Legacy fires synchronously,
--     unconditionally, in the same transaction as the mutation, with
--     no such revalidation. A candidate whose access is revoked in the
--     enqueue-to-processing gap gets nothing from CAP-003 but would
--     have gotten the legacy notification -- a real, evidenced race
--     window (see Phase 1.4B's own behavioral scenario 17).
--   * meetings.rescheduled.v1 / meetings.cancelled.v1 -- legacy's
--     meeting_participant_recipient_ids(meeting_id, v_actor) excludes
--     the acting user; CAP-003's meeting_participants target
--     resolution (Phase 1.4A, unmodified here) does not exclude the
--     actor (already documented as a known limitation in docs/87).
-- Per the task's own repeated instruction ("if any gap exists: retain
-- legacy dual-write and dedupe visually"), every one of the four
-- legacy INSERT INTO notifications statements in assign_task(),
-- complete_task(), update_meeting(), and cancel_meeting() is left
-- completely untouched. Duplicate-visibility prevention for these four
-- events is instead handled entirely client-side (NotificationsAPI.
-- dedupeLegacyAgainstCap003() in js/data/notifications-api.js) --
-- structural-identity plus a time-window heuristic, documented in
-- docs/88, never a message-text comparison. No table is dropped, no
-- historical row is migrated or deleted, and NotificationsAPI.notify()
-- (the legacy write path) is untouched and still called by every
-- existing site, migrated or not.
--
-- ─── The one change this patch does make ───────────────────────────
-- Exposes user_notifications to Supabase Realtime the same way the
-- legacy `notifications` table already is. Repository-wide search
-- (grep -rn "ALTER PUBLICATION\|supabase_realtime" supabase/*.sql,
-- excluding test-/validate-/rollback- files) found zero explicit
-- publication statements anywhere in this migration history -- not
-- even for `notifications`, whose Realtime channel already works
-- today per docs/78 §2.6/§16 and js/views/shell.js's existing
-- _subscribeRealtime(). That means legacy Realtime exposure is a
-- Supabase-project-level default (a `supabase_realtime` publication
-- that already includes every table, or was toggled on for
-- `notifications` outside of any file this repository tracks) rather
-- than something this migration chain ever declared. Rather than
-- perpetuate that implicit, undocumented state for a second table,
-- this patch adds ONE explicit, idempotent statement so
-- user_notifications' Realtime membership is reviewable in source
-- control going forward -- the guard below makes it a no-op (not an
-- error) on any environment where the `supabase_realtime` publication
-- object doesn't exist at all (e.g. the disposable local Postgres
-- regression harness this repository's test suites run against,
-- which has no Supabase Realtime extension installed), and a no-op if
-- the table is already a member (re-running this patch, or a project
-- where a dashboard toggle already added it, is always safe).
--
-- This does not change what any client can see. postgres_changes
-- always re-evaluates RLS for the connecting user regardless of
-- publication membership (a table being in the publication is
-- necessary, not sufficient, for a client to observe a row's
-- changes) -- user_notifications_select's `recipient_user_id =
-- auth.uid()` clause (patch-notification-outbox-persistence-
-- foundation.sql) still governs exactly which rows any given client
-- can be notified about, identically to how it already governs
-- ordinary SELECTs. No publication statement is added for
-- platform_outbox_events or notification_intents -- neither is ever
-- read by any authenticated client, and both remain service_role-only
-- (unchanged by this patch).
-- ============================================================
\set ON_ERROR_STOP on
BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'user_notifications'
    ) THEN
      EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.user_notifications';
    END IF;
  END IF;
  -- No ELSE branch: an environment with no supabase_realtime
  -- publication object (e.g. this repo's disposable local Postgres
  -- regression harness) has nothing to add this table to, and that is
  -- not an error condition for this patch -- it mirrors exactly how
  -- the legacy `notifications` table already has no publication
  -- statement anywhere in this migration history either.
END $$;

COMMIT;
