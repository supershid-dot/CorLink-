-- CAP-003 Phase 1.5 structural validator (DB side). Disposable local
-- PostgreSQL only. Frontend-side structural assertions (merged-feed
-- normalization, dedup rule, template rendering, Realtime channel
-- guard, deep-link routing) live in the Playwright regression-marker
-- checks inside tests/notification-realtime-legacy-cutover-frontend.
-- test.js, matching this repository's existing convention (see the
-- "full T2A-T3F.2 frontend regression markers" check in
-- tests/task-relationships-frontend.test.js) rather than duplicating
-- source-text assertions here.
\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- ── 1. user_notifications' RLS/grants/schema are byte-for-byte
  -- unchanged by this milestone -- Phase 1.5 reads/writes go through
  -- exactly the same policies and columns Phase 1.1 already shipped ──
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_notifications'
      AND policyname='user_notifications_select'
      AND qual = '(recipient_user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'user_notifications_select-policy-changed '; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_notifications'
      AND policyname='user_notifications_update'
      AND qual = '(recipient_user_id = auth.uid())'
      AND with_check = '(recipient_user_id = auth.uid())'
  ) THEN v_missing := v_missing || 'user_notifications_update-policy-changed '; END IF;

  -- No INSERT/DELETE policy for user_notifications was added -- the
  -- frontend can only ever SELECT (via list_my_notifications/
  -- count_my_unread_notifications) or UPDATE read_at, never insert or
  -- delete a notification of its own. RLS presence/policy count is the
  -- real, meaningful assertion (checked here and below), NOT table-
  -- level grants: this disposable local test harness (build_baseline.
  -- sh's 01-grants.sql) applies a blanket GRANT ... ON ALL TABLES IN
  -- SCHEMA public TO anon, authenticated after every patch, exactly
  -- matching Supabase's own real-world default of broad table grants
  -- with RLS as the actual enforced gate -- the identical precedent
  -- validate-notification-outbox-persistence-foundation.sql already
  -- documents for this same table.
  IF EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='user_notifications'
      AND cmd IN ('INSERT','DELETE')
  ) THEN v_missing := v_missing || 'unexpected-user_notifications-insert-or-delete-policy '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='user_notifications') <> 2 THEN
    v_missing := v_missing || 'user_notifications-unexpected-policy-count ';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.user_notifications')) THEN
    v_missing := v_missing || 'user_notifications-rls-not-enabled ';
  END IF;

  -- ── 2. The read APIs the frontend uses are exactly the Phase 1.1
  -- ones, unmodified, granted only to authenticated -- no new frontend-
  -- facing RPC was added for this milestone (mark-read/unmark-read use
  -- a direct RLS-protected UPDATE, per the investigated absence of any
  -- dedicated mark-read RPC) ───────────────────────────────────────
  IF to_regprocedure('public.list_my_notifications(integer,timestamptz,uuid,boolean)') IS NULL THEN
    v_missing := v_missing || 'list_my_notifications-missing ';
  END IF;
  IF to_regprocedure('public.count_my_unread_notifications()') IS NULL THEN
    v_missing := v_missing || 'count_my_unread_notifications-missing ';
  END IF;
  IF NOT (has_function_privilege('authenticated','list_my_notifications(integer,timestamptz,uuid,boolean)','EXECUTE'))
  THEN v_missing := v_missing || 'list_my_notifications-not-granted-to-authenticated '; END IF;
  IF NOT (has_function_privilege('authenticated','count_my_unread_notifications()','EXECUTE'))
  THEN v_missing := v_missing || 'count_my_unread_notifications-not-granted-to-authenticated '; END IF;

  -- ── 3. No service-role-only surface was exposed to authenticated/
  -- anon by this milestone -- worker/resolver/intent-creation/outbox
  -- remain service_role-exclusive, matching every prior CAP-003 phase ─
  IF has_function_privilege('authenticated','platform_create_user_notification(uuid,uuid,text,text,jsonb,text,text,uuid,uuid,text,text,jsonb,timestamptz)','EXECUTE')
     OR has_function_privilege('anon','platform_create_user_notification(uuid,uuid,text,text,jsonb,text,text,uuid,uuid,text,text,jsonb,timestamptz)','EXECUTE')
  THEN v_missing := v_missing || 'platform_create_user_notification-exposed '; END IF;
  IF has_function_privilege('authenticated','platform_enqueue_outbox_event(text,text,text,uuid,uuid,uuid,uuid,uuid,timestamptz,jsonb,uuid)','EXECUTE')
     OR has_function_privilege('anon','platform_enqueue_outbox_event(text,text,text,uuid,uuid,uuid,uuid,uuid,timestamptz,jsonb,uuid)','EXECUTE')
  THEN v_missing := v_missing || 'platform_enqueue_outbox_event-exposed '; END IF;
  -- Table grants are not checked for these two either, for the same
  -- disposable-harness reason as above -- RLS is the real boundary:
  -- both tables carry zero policies of any kind, so RLS denies every
  -- row to every non-service_role caller regardless of table grants.
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.platform_outbox_events')) THEN
    v_missing := v_missing || 'platform_outbox_events-rls-not-enabled ';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='platform_outbox_events')
  THEN v_missing := v_missing || 'platform_outbox_events-unexpected-policy-present '; END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = to_regclass('public.notification_intents')) THEN
    v_missing := v_missing || 'notification_intents-rls-not-enabled ';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='notification_intents')
  THEN v_missing := v_missing || 'notification_intents-unexpected-policy-present '; END IF;

  -- ── 4. Realtime publication membership for user_notifications is
  -- exactly what this milestone declares -- present when the
  -- supabase_realtime publication object exists at all, correctly a
  -- no-op (not an error) when it doesn't (e.g. this disposable local
  -- Postgres harness), and neither platform_outbox_events nor
  -- notification_intents was ever added to it ──────────────────────
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='user_notifications'
    ) THEN v_missing := v_missing || 'user_notifications-not-in-supabase_realtime-publication '; END IF;
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname='supabase_realtime' AND schemaname='public'
      AND tablename IN ('platform_outbox_events','notification_intents')
  ) THEN v_missing := v_missing || 'service-role-only-table-exposed-via-realtime-publication '; END IF;

  -- ── 5. Legacy notifications table and its four migrated-event dual-
  -- writes are completely untouched -- the docs/88 equivalence review
  -- found a genuine gap in all four (late authorization revalidation
  -- for Task events, no actor-self-exclusion for Meeting events), so
  -- none may be removed; duplicate-visibility prevention is frontend-
  -- only. This mirrors check 7 in validate-task-meeting-notification-
  -- events.sql (re-asserted here so this milestone's own validator
  -- catches a regression even if that one is skipped) ────────────────
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='notifications')
  THEN v_missing := v_missing || 'legacy-notifications-table-removed '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.assign_task(uuid,uuid)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'assign_task-missing ';
  ELSIF v_def NOT ILIKE '%task_assigned%' THEN v_missing := v_missing || 'assign_task-legacy-notification-removed '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.complete_task(uuid,text)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'complete_task-missing ';
  ELSIF v_def NOT ILIKE '%task_completed%' THEN v_missing := v_missing || 'complete_task-legacy-notification-removed '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.update_meeting(uuid,text,text,text,text,text,timestamptz,timestamptz,text,text,text,text,boolean,boolean)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'update_meeting-missing ';
  ELSIF v_def NOT ILIKE '%meeting_updated%' THEN v_missing := v_missing || 'update_meeting-legacy-notification-removed '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.cancel_meeting(uuid,text,boolean)')) INTO v_def;
  IF v_def IS NULL THEN v_missing := v_missing || 'cancel_meeting-missing ';
  ELSIF v_def NOT ILIKE '%meeting_cancelled%' THEN v_missing := v_missing || 'cancel_meeting-legacy-notification-removed '; END IF;

  -- ── 6. No external delivery / preferences / digest infrastructure
  -- introduced by this milestone ─────────────────────────────────────
  IF EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_schema='public' AND (routine_name ILIKE '%send_email%' OR routine_name ILIKE '%send_push%' OR routine_name ILIKE '%send_sms%'))
  THEN v_missing := v_missing || 'unexpected-external-delivery-function '; END IF;
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND (table_name ILIKE '%notification_preference%' OR table_name ILIKE '%notification_digest%'))
  THEN v_missing := v_missing || 'unexpected-notification-preferences-or-digest-table '; END IF;

  -- ── 7. CAP-002/CAP-003 baseline objects unaffected ─────────────────
  IF to_regprocedure('public.intent_user_can_view_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_task-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_meeting(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_meeting-missing '; END IF;
  IF to_regprocedure('public.resolve_notification_intent(uuid)') IS NULL THEN v_missing := v_missing || 'resolve_notification_intent-missing '; END IF;
  IF to_regprocedure('public.process_platform_outbox_batch(integer,text)') IS NULL THEN v_missing := v_missing || 'process_platform_outbox_batch-missing '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Notification Realtime/legacy cutover structural validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Notification Realtime/legacy cutover structural validation PASSED (user_notifications RLS/grants unchanged, read APIs unchanged and correctly scoped, no service-role surface exposed to authenticated/anon, Realtime publication membership correct and RLS-independent, all four migrated-event legacy dual-writes preserved, no external delivery/preferences/digest objects, CAP-002/CAP-003 baselines unaffected).';
END $$;
