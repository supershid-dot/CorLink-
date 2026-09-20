-- ─── Validator: Meetings notification completion ───────────────────
-- Run manually against a project AFTER
-- patch-meetings-notification-completion.sql has been applied there.
-- Part 1 is structural (columns/registry/function-literal checks, no
-- side effects). Part 2 is behavioral: creates disposable fixture rows
-- (a distinct '7c000000-...' test-UUID prefix, distinguishing this
-- validator's fixtures from validate-meetings-section-scope.sql's own
-- '7a000000-...' ones) inside ONE transaction and ROLLS BACK at the
-- very end — nothing here persists, safe to run against a live/
-- populated project.

\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- ── 1. New columns exist ──────────────────────────────────────
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='meetings' AND column_name='reminder_at')
    THEN v_missing := v_missing || 'meetings.reminder_at-missing '; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='meetings' AND column_name='reminder_dispatched_at')
    THEN v_missing := v_missing || 'meetings.reminder_dispatched_at-missing '; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='users' AND column_name='telegram_chat_id')
    THEN v_missing := v_missing || 'users.telegram_chat_id-missing '; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='user_notifications' AND column_name='telegram_sent_at')
    THEN v_missing := v_missing || 'user_notifications.telegram_sent_at-missing '; END IF;

  -- ── 2. The three new event types are registered ────────────────
  IF NOT EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type = 'meetings.scheduled.v1' AND owning_module = 'meetings' AND uses_generic_notification_envelope = TRUE)
    THEN v_missing := v_missing || 'meetings.scheduled.v1-registry-row-missing '; END IF;
  IF NOT EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type = 'meetings.updated.v1' AND owning_module = 'meetings' AND uses_generic_notification_envelope = TRUE)
    THEN v_missing := v_missing || 'meetings.updated.v1-registry-row-missing '; END IF;
  IF NOT EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type = 'meetings.reminder.v1' AND owning_module = 'meetings' AND uses_generic_notification_envelope = TRUE)
    THEN v_missing := v_missing || 'meetings.reminder.v1-registry-row-missing '; END IF;

  -- ── 3. create_meeting() gained p_suppress_notification and still
  -- enqueues meetings.scheduled.v1; create_recurring_meeting() passes
  -- TRUE for it (no per-occurrence spam) ──────────────────────────
  IF to_regprocedure('public.create_meeting(text,timestamptz,timestamptz,text,text,text,text,text,text,text,text,uuid,boolean)') IS NULL THEN
    v_missing := v_missing || 'create_meeting-new-signature-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.create_meeting(text,timestamptz,timestamptz,text,text,text,text,text,text,text,text,uuid,boolean)')) INTO v_def;
    IF v_def NOT ILIKE '%platform_enqueue_outbox_event%' OR v_def NOT ILIKE '%meetings.scheduled.v1%' THEN
      v_missing := v_missing || 'create_meeting-missing-scheduled-enqueue ';
    END IF;
    IF v_def NOT ILIKE '%reminder_at%' THEN v_missing := v_missing || 'create_meeting-missing-reminder_at ';  END IF;
  END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.create_recurring_meeting(text,date,date,time,time,text,text,text,text,text,text,text,text,uuid,uuid,integer,uuid)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'create_recurring_meeting-missing ';
  ELSIF v_def NOT ILIKE '%p_suppress_notification := TRUE%' THEN
    v_missing := v_missing || 'create_recurring_meeting-does-not-suppress-per-occurrence-scheduled-event ';
  END IF;

  -- ── 4. update_meeting() enqueues both new events + maintains
  -- reminder_at, still enqueues the pre-existing rescheduled event ──
  SELECT pg_get_functiondef(to_regprocedure('public.update_meeting(uuid,text,text,text,text,text,timestamptz,timestamptz,text,text,text,text,boolean,boolean,uuid,boolean)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'update_meeting-missing ';
  ELSE
    IF v_def NOT ILIKE '%meetings.scheduled.v1%' THEN v_missing := v_missing || 'update_meeting-missing-scheduled-enqueue '; END IF;
    IF v_def NOT ILIKE '%meetings.updated.v1%' THEN v_missing := v_missing || 'update_meeting-missing-updated-enqueue '; END IF;
    IF v_def NOT ILIKE '%meetings.rescheduled.v1%' THEN v_missing := v_missing || 'update_meeting-lost-existing-rescheduled-enqueue '; END IF;
    IF v_def NOT ILIKE '%reminder_at%' THEN v_missing := v_missing || 'update_meeting-missing-reminder_at-maintenance '; END IF;
  END IF;

  -- ── 5. cancel_meeting() is byte-for-byte unchanged (this patch
  -- deliberately makes no edit to it -- see the patch's own header) ──
  SELECT pg_get_functiondef(to_regprocedure('public.cancel_meeting(uuid,text,boolean)')) INTO v_def;
  IF v_def IS NULL THEN
    v_missing := v_missing || 'cancel_meeting-missing ';
  ELSIF v_def NOT ILIKE '%meetings.cancelled.v1%' THEN
    v_missing := v_missing || 'cancel_meeting-lost-existing-cancelled-enqueue ';
  END IF;

  -- ── 6. dispatch_due_meeting_reminders() exists, requires auth,
  -- granted to authenticated ───────────────────────────────────────
  IF to_regprocedure('public.dispatch_due_meeting_reminders()') IS NULL THEN
    v_missing := v_missing || 'dispatch_due_meeting_reminders-missing ';
  ELSE
    SELECT pg_get_functiondef(to_regprocedure('public.dispatch_due_meeting_reminders()')) INTO v_def;
    IF v_def NOT ILIKE '%auth.uid() IS NULL%' THEN v_missing := v_missing || 'dispatch_due_meeting_reminders-missing-auth-check '; END IF;
    IF v_def NOT ILIKE '%meetings.reminder.v1%' THEN v_missing := v_missing || 'dispatch_due_meeting_reminders-missing-enqueue '; END IF;
  END IF;
  IF NOT has_function_privilege('authenticated', 'dispatch_due_meeting_reminders()', 'EXECUTE') THEN
    v_missing := v_missing || 'dispatch_due_meeting_reminders-not-granted-to-authenticated ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'STRUCTURAL VALIDATION FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'PASS: structural checks (columns, registry, function signatures/literals) all present';
END $$;

-- ─── Part 2: behavioral smoke test ──────────────────────────────────
BEGIN;

INSERT INTO organizations (id, name, type, code) VALUES
  ('7c000000-0000-0000-0000-000000000001', 'MNC Test Org', 'mcs', 'MNCT');
INSERT INTO auth.users (id, email) VALUES
  ('7c000000-0004-0000-0000-000000000001', 'mnc-organizer@t.local'),
  ('7c000000-0004-0000-0000-000000000002', 'mnc-attendee@t.local');
INSERT INTO users (id, org_id, service_number, full_name, email, is_active) VALUES
  ('7c000000-0004-0000-0000-000000000001', '7c000000-0000-0000-0000-000000000001', 'MNC-1', 'Organizer', 'mnc-organizer@t.local', TRUE),
  ('7c000000-0004-0000-0000-000000000002', '7c000000-0000-0000-0000-000000000001', 'MNC-2', 'Attendee', 'mnc-attendee@t.local', TRUE);
INSERT INTO organization_modules (organization_id, module_id, is_enabled)
  SELECT '7c000000-0000-0000-0000-000000000001', pm.id, TRUE FROM platform_modules pm WHERE pm.module_key = 'meetings';

-- Deliberately NOT `SET ROLE authenticated` here (unlike validate-
-- meetings-section-scope.sql's own fixture) — every RPC below is
-- SECURITY DEFINER, so it runs with its owner's privileges regardless
-- of the calling role, and auth.uid() is driven purely by the
-- request.jwt.claims setting below, not by the literal Postgres role.
-- Staying in the connection's own (privileged) role instead lets this
-- script's own direct SELECTs against platform_outbox_events succeed —
-- that table has no SELECT grant for `authenticated` (correctly: it's
-- an internal system table, never meant to be queried directly by an
-- ordinary user; user_notifications/list_my_notifications() is the
-- sanctioned read path for real callers).

DO $$
DECLARE
  v_meeting_id UUID;
  v_reminder_at TIMESTAMPTZ;
  v_dispatched_at TIMESTAMPTZ;
  v_scheduled_count INTEGER;
  v_updated_count INTEGER;
  v_rescheduled_count INTEGER;
  v_reminder_count INTEGER;
  v_due_ids UUID[];
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"7c000000-0004-0000-0000-000000000001"}', true);

  -- Create a meeting starting 1 hour from now -> reminder_at should be
  -- 30 minutes from now, and meetings.scheduled.v1 should be enqueued.
  v_meeting_id := create_meeting(
    p_title := 'Smoke Test Meeting', p_start_at := NOW() + INTERVAL '1 hour',
    p_end_at := NOW() + INTERVAL '2 hour', p_status := 'scheduled'
  );

  SELECT reminder_at, reminder_dispatched_at INTO v_reminder_at, v_dispatched_at FROM meetings WHERE id = v_meeting_id;
  IF v_reminder_at IS NULL OR abs(extract(epoch FROM (v_reminder_at - (NOW() + INTERVAL '30 minutes')))) > 5 THEN
    RAISE EXCEPTION 'FAIL: reminder_at not set to ~30 minutes before start on create (got %)', v_reminder_at;
  END IF;
  IF v_dispatched_at IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: reminder_dispatched_at should start NULL';
  END IF;

  SELECT count(*) INTO v_scheduled_count FROM platform_outbox_events
    WHERE event_type = 'meetings.scheduled.v1' AND source_record_id = v_meeting_id;
  IF v_scheduled_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected exactly 1 meetings.scheduled.v1 event for the create, got %', v_scheduled_count;
  END IF;

  -- A title-only edit (no time change) -> meetings.updated.v1, not rescheduled.
  PERFORM update_meeting(v_meeting_id, p_title := 'Smoke Test Meeting (renamed)');
  SELECT count(*) INTO v_updated_count FROM platform_outbox_events WHERE event_type = 'meetings.updated.v1' AND source_record_id = v_meeting_id;
  SELECT count(*) INTO v_rescheduled_count FROM platform_outbox_events WHERE event_type = 'meetings.rescheduled.v1' AND source_record_id = v_meeting_id;
  IF v_updated_count <> 1 THEN RAISE EXCEPTION 'FAIL: expected exactly 1 meetings.updated.v1 event after a title-only edit, got %', v_updated_count; END IF;
  IF v_rescheduled_count <> 0 THEN RAISE EXCEPTION 'FAIL: a title-only edit must never fire meetings.rescheduled.v1, got %', v_rescheduled_count; END IF;

  -- A time change -> meetings.rescheduled.v1 (not a second "updated"),
  -- and reminder_at/reminder_dispatched_at move with it.
  PERFORM update_meeting(v_meeting_id, p_start_at := NOW() + INTERVAL '3 hour', p_end_at := NOW() + INTERVAL '4 hour');
  SELECT count(*) INTO v_rescheduled_count FROM platform_outbox_events WHERE event_type = 'meetings.rescheduled.v1' AND source_record_id = v_meeting_id;
  SELECT count(*) INTO v_updated_count FROM platform_outbox_events WHERE event_type = 'meetings.updated.v1' AND source_record_id = v_meeting_id;
  IF v_rescheduled_count <> 1 THEN RAISE EXCEPTION 'FAIL: expected exactly 1 meetings.rescheduled.v1 event after a time change, got %', v_rescheduled_count; END IF;
  IF v_updated_count <> 1 THEN RAISE EXCEPTION 'FAIL: a reschedule must not ALSO fire a second meetings.updated.v1 (still expected 1 from the earlier title edit), got %', v_updated_count; END IF;

  -- Force the reminder due right now and dispatch it.
  UPDATE meetings SET reminder_at = NOW() - INTERVAL '1 minute' WHERE id = v_meeting_id;
  SELECT array_agg(x) INTO v_due_ids FROM dispatch_due_meeting_reminders() AS x;
  IF v_due_ids IS NULL OR NOT (v_meeting_id = ANY(v_due_ids)) THEN
    RAISE EXCEPTION 'FAIL: dispatch_due_meeting_reminders() did not report this meeting as due';
  END IF;
  SELECT count(*) INTO v_reminder_count FROM platform_outbox_events WHERE event_type = 'meetings.reminder.v1' AND source_record_id = v_meeting_id;
  IF v_reminder_count <> 1 THEN RAISE EXCEPTION 'FAIL: expected exactly 1 meetings.reminder.v1 event, got %', v_reminder_count; END IF;

  -- Calling it again must be a true no-op (reminder_dispatched_at
  -- already set) -- no second enqueue attempt, no idempotency error.
  SELECT array_agg(x) INTO v_due_ids FROM dispatch_due_meeting_reminders() AS x;
  IF v_due_ids IS NOT NULL AND v_meeting_id = ANY(v_due_ids) THEN
    RAISE EXCEPTION 'FAIL: dispatch_due_meeting_reminders() re-dispatched an already-dispatched reminder';
  END IF;
  SELECT count(*) INTO v_reminder_count FROM platform_outbox_events WHERE event_type = 'meetings.reminder.v1' AND source_record_id = v_meeting_id;
  IF v_reminder_count <> 1 THEN RAISE EXCEPTION 'FAIL: a second poll must not create a second meetings.reminder.v1 event, got %', v_reminder_count; END IF;

  -- Cancel it -> no further reminder should ever be dispatchable
  -- (status filter in dispatch_due_meeting_reminders() excludes it).
  PERFORM cancel_meeting(v_meeting_id, p_cancellation_reason := 'smoke test cleanup');
  UPDATE meetings SET reminder_at = NOW() - INTERVAL '1 minute', reminder_dispatched_at = NULL WHERE id = v_meeting_id;
  SELECT array_agg(x) INTO v_due_ids FROM dispatch_due_meeting_reminders() AS x;
  IF v_due_ids IS NOT NULL AND v_meeting_id = ANY(v_due_ids) THEN
    RAISE EXCEPTION 'FAIL: a cancelled meeting must never have its reminder dispatched';
  END IF;

  RAISE NOTICE 'PASS: all meetings-notification-completion behavioral scenarios behaved as designed';
END $$;

ROLLBACK;
