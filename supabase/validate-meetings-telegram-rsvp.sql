-- ─── Validator: Telegram RSVP (Accept/Decline inline buttons) ───────
-- Run manually against a project AFTER
-- patch-meetings-telegram-rsvp.sql has been applied there.

DO $$
DECLARE
  v_missing TEXT := '';
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'organization_telegram_config' AND column_name = 'webhook_secret'
  ) THEN
    v_missing := v_missing || 'organization_telegram_config.webhook_secret-missing ';
  END IF;
  IF to_regprocedure('public.respond_to_invitation_via_telegram(uuid,text,text)') IS NULL THEN
    v_missing := v_missing || 'respond_to_invitation_via_telegram-missing ';
  END IF;
  IF has_function_privilege('anon', 'respond_to_invitation_via_telegram(uuid,text,text)', 'EXECUTE') THEN
    v_missing := v_missing || 'respond_to_invitation_via_telegram-exposed-to-anon ';
  END IF;
  IF has_function_privilege('authenticated', 'respond_to_invitation_via_telegram(uuid,text,text)', 'EXECUTE') THEN
    v_missing := v_missing || 'respond_to_invitation_via_telegram-exposed-to-authenticated ';
  END IF;
  IF NOT has_function_privilege('service_role', 'respond_to_invitation_via_telegram(uuid,text,text)', 'EXECUTE') THEN
    v_missing := v_missing || 'respond_to_invitation_via_telegram-not-granted-to-service_role ';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION 'STRUCTURAL VALIDATION FAILED: %', v_missing;
  END IF;
  RAISE NOTICE 'PASS: structural checks all present';
END $$;

-- Behavioral: fixture UUID prefix '7e000000-...'.
BEGIN;

INSERT INTO organizations (id, name, type, code) VALUES
  ('7e000000-0000-0000-0000-000000000001', 'RSVP Test Org', 'mcs', 'RSVPT');
INSERT INTO auth.users (id, email) VALUES
  ('7e000000-0004-0000-0000-000000000001', 're-organizer@t.local'),
  ('7e000000-0004-0000-0000-000000000002', 're-invitee@t.local');
INSERT INTO users (id, org_id, service_number, full_name, email, is_active, telegram_chat_id) VALUES
  ('7e000000-0004-0000-0000-000000000001', '7e000000-0000-0000-0000-000000000001', 'RE-1', 'Organizer', 're-organizer@t.local', TRUE, NULL),
  ('7e000000-0004-0000-0000-000000000002', '7e000000-0000-0000-0000-000000000001', 'RE-2', 'Invitee', 're-invitee@t.local', TRUE, '99999999');
INSERT INTO user_assignments (user_id, scope_type, scope_id, role, is_primary, is_active) VALUES
  ('7e000000-0004-0000-0000-000000000001', 'organization', '7e000000-0000-0000-0000-000000000001', 'mcs_admin', TRUE, TRUE);

-- No SET ROLE authenticated here: respond_to_invitation_via_telegram()
-- is SECURITY DEFINER and does its own explicit authorization (the
-- telegram_chat_id match), not an auth.uid()-based RLS check, so this
-- validator runs the fixture inserts and the RPC calls both under the
-- connection's own (privileged) role.
DO $$
DECLARE
  v_meeting_id UUID;
  v_participant_id UUID;
  v_status TEXT;
BEGIN
  -- Direct table insert rather than create_meeting() -- this validator
  -- only needs a real meetings/meeting_participants row to exercise
  -- respond_to_invitation_via_telegram() against, not the full RPC's
  -- own (unrelated, larger) validation/notification surface.
  INSERT INTO meetings (organization_id, created_by, title, meeting_type, status, start_at, end_at)
  VALUES ('7e000000-0000-0000-0000-000000000001', '7e000000-0004-0000-0000-000000000001',
    'RSVP webhook test meeting', 'general', 'scheduled', NOW() + INTERVAL '1 day', NOW() + INTERVAL '1 day' + INTERVAL '1 hour')
  RETURNING id INTO v_meeting_id;
  INSERT INTO meeting_participants (meeting_id, user_id, participant_role, invited_by)
  VALUES (v_meeting_id, '7e000000-0004-0000-0000-000000000002', 'attendee', '7e000000-0004-0000-0000-000000000001')
  RETURNING id INTO v_participant_id;

  -- Wrong chat id must be rejected.
  BEGIN
    PERFORM respond_to_invitation_via_telegram(v_participant_id, 'accepted', '00000000');
    RAISE EXCEPTION 'FAIL: a mismatched telegram_chat_id must be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%not linked%' THEN
      RAISE EXCEPTION 'FAIL: expected a chat-id-mismatch rejection, got: %', SQLERRM;
    END IF;
  END;

  -- Correct chat id succeeds.
  PERFORM respond_to_invitation_via_telegram(v_participant_id, 'accepted', '99999999');
  SELECT invitation_status INTO v_status FROM meeting_participants WHERE id = v_participant_id;
  IF v_status <> 'accepted' THEN
    RAISE EXCEPTION 'FAIL: expected invitation_status=accepted, got %', v_status;
  END IF;

  -- Invalid response value rejected.
  BEGIN
    PERFORM respond_to_invitation_via_telegram(v_participant_id, 'maybe', '99999999');
    RAISE EXCEPTION 'FAIL: an invalid response value must be rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%Invalid response%' THEN
      RAISE EXCEPTION 'FAIL: expected an invalid-response rejection, got: %', SQLERRM;
    END IF;
  END;

  RAISE NOTICE 'PASS: all Telegram RSVP behavioral scenarios behaved as designed';
END $$;

ROLLBACK;
