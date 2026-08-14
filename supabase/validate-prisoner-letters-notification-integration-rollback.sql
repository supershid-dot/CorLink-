-- CAP-003 Phase 1.9B rollback validator. Confirms rollback-prisoner-
-- letters-notification-integration.sql restored the exact pre-1.9B
-- state, and that Phase 1.0-1.9A/1.8B baselines are preserved.
\set ON_ERROR_STOP on
DO $$
DECLARE
  v_missing TEXT := '';
  v_def TEXT;
BEGIN
  -- ── 1. The 4 registry rows are gone. ─────────────────────────────
  IF EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type LIKE 'prisoner_letter.%') THEN
    v_missing := v_missing || 'prisoner-letters-registry-rows-still-present ';
  END IF;

  -- ── 2. The adapter is gone. ───────────────────────────────────────
  IF to_regprocedure('public.intent_user_can_view_prisoner_letter(uuid,uuid)') IS NOT NULL THEN
    v_missing := v_missing || 'intent_user_can_view_prisoner_letter-still-present ';
  END IF;

  -- ── 3. source_record_type CHECK restored to exact Phase 1.8B set. ──
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'notification_intents_source_record_type_check'
      AND pg_get_constraintdef(oid) = 'CHECK ((source_record_type = ANY (ARRAY[''workflow_instance''::text, ''platform''::text, ''task''::text, ''meeting''::text, ''request''::text, ''external_correspondence''::text, ''internal_request''::text])))'
  ) THEN v_missing := v_missing || 'notification_intents_source_record_type_check-not-restored '; END IF;

  -- ── 4. create_notification_intent()/resolve_notification_intent()
  -- no longer reference prisoner_letter anywhere. ────────────────────
  SELECT pg_get_functiondef(to_regprocedure('public.create_notification_intent(uuid,text,text,jsonb,text,text,uuid[],uuid,uuid,uuid,uuid,uuid,uuid)')) INTO v_def;
  IF v_def ILIKE '%prisoner_letter%' THEN v_missing := v_missing || 'create_notification_intent-still-references-prisoner-letter '; END IF;

  SELECT pg_get_functiondef(to_regprocedure('public.resolve_notification_intent(uuid)')) INTO v_def;
  IF v_def ILIKE '%intent_user_can_view_prisoner_letter%' THEN v_missing := v_missing || 'resolve_notification_intent-still-references-prisoner-letter-adapter '; END IF;
  -- The internal_request dispatch branch (Phase 1.8B) must still be
  -- present and correct -- this rollback only removes what 1.9B added.
  IF v_def NOT ILIKE '%intent_user_can_view_internal_request%' THEN
    v_missing := v_missing || 'resolve_notification_intent-lost-phase-1.8b-internal-request-branch '; END IF;

  -- ── 5. The 3 modified RPCs no longer enqueue anything. ──────────────
  SELECT pg_get_functiondef(to_regprocedure('public.create_prisoner_letter(uuid,uuid,uuid,text)')) INTO v_def;
  IF v_def ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'create_prisoner_letter-still-enqueues '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.route_prisoner_letter(uuid,uuid,uuid)')) INTO v_def;
  IF v_def ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'route_prisoner_letter-still-enqueues '; END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.create_prisoner_letter_reply(uuid,text)')) INTO v_def;
  IF v_def ILIKE '%platform_enqueue_outbox_event%' THEN v_missing := v_missing || 'create_prisoner_letter_reply-still-enqueues '; END IF;

  -- ── 6. Phase 1.9A mutation foundation fully intact: all 6 RPCs still
  -- present, direct-write closure preserved. ────────────────────────
  IF to_regprocedure('public.create_prisoner_letter(uuid,uuid,uuid,text)') IS NULL THEN v_missing := v_missing || 'create_prisoner_letter-missing '; END IF;
  IF to_regprocedure('public.mark_prisoner_letter_received(uuid)') IS NULL THEN v_missing := v_missing || 'mark_prisoner_letter_received-missing '; END IF;
  IF to_regprocedure('public.route_prisoner_letter(uuid,uuid,uuid)') IS NULL THEN v_missing := v_missing || 'route_prisoner_letter-missing '; END IF;
  IF to_regprocedure('public.mark_prisoner_letter_slip_generated(uuid)') IS NULL THEN v_missing := v_missing || 'mark_prisoner_letter_slip_generated-missing '; END IF;
  IF to_regprocedure('public.create_prisoner_letter_reply(uuid,text)') IS NULL THEN v_missing := v_missing || 'create_prisoner_letter_reply-missing '; END IF;
  IF to_regprocedure('public.mark_prisoner_letter_delivered(uuid)') IS NULL THEN v_missing := v_missing || 'mark_prisoner_letter_delivered-missing '; END IF;
  IF has_table_privilege('authenticated', 'public.prisoner_letters', 'INSERT') THEN v_missing := v_missing || 'prisoner_letters-insert-unexpectedly-open '; END IF;
  IF has_table_privilege('authenticated', 'public.prisoner_replies', 'INSERT') THEN v_missing := v_missing || 'prisoner_replies-insert-unexpectedly-open '; END IF;
  IF (SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename='prisoner_letters') <> 3 THEN
    v_missing := v_missing || 'prisoner_letters-policy-count-drift '; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='attachments' AND policyname='attachments_insert'
      AND with_check ILIKE '%pl.status <> ''delivered''%'
  ) THEN v_missing := v_missing || 'attachments-finalization-lock-disturbed '; END IF;

  -- ── 7. Prior CAP-003 baselines preserved: Internal Collaboration/
  -- Entry/Requests adapters and their own registry rows still present
  -- and unaffected. ────────────────────────────────────────────────
  IF to_regprocedure('public.intent_user_can_view_internal_request(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_internal_request-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_entry(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_entry-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_request(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_request-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_task(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_task-missing '; END IF;
  IF to_regprocedure('public.intent_user_can_view_meeting(uuid,uuid)') IS NULL THEN v_missing := v_missing || 'intent_user_can_view_meeting-missing '; END IF;
  IF NOT EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type = 'entry.routed.v1') THEN v_missing := v_missing || 'entry.routed.v1-missing '; END IF;
  IF NOT EXISTS (SELECT 1 FROM platform_event_type_registry WHERE event_type = 'requests.sent.v1') THEN v_missing := v_missing || 'requests.sent.v1-missing '; END IF;
  IF (SELECT count(*) FROM platform_event_type_registry WHERE owning_module = 'internal_collaboration') <> 5 THEN
    v_missing := v_missing || 'internal-collaboration-event-registry-drift '; END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'Prisoner Letters notification integration ROLLBACK validation FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'Prisoner Letters notification integration ROLLBACK validation PASSED (4 registry rows removed, adapter dropped, source_record_type CHECK restored to exact Phase 1.8B set, create_notification_intent/resolve_notification_intent no longer reference prisoner_letter (Phase 1.8B internal_request branch intact), all 3 modified RPCs no longer enqueue, Phase 1.9A mutation foundation/direct-write closure/attachment lock fully intact, prior CAP-003 baselines -- Internal Collaboration/Entry/Requests/Task/Meeting adapters and registry rows -- untouched).';
END $$;
