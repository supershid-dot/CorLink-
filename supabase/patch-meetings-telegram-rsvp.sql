-- ============================================================
-- CorLink — Patch: Telegram RSVP (Accept/Decline inline buttons)
--
-- docs/131: per the user's explicit request, matching MeetFlow's own
-- inline ✅/❌ RSVP buttons on the "New meeting" Telegram message.
-- Tapping a button fires a Telegram "callback_query" webhook — an
-- unauthenticated external HTTP call, since there is no CorLink
-- session behind a Telegram tap. Two new pieces:
--
-- 1. organization_telegram_config.webhook_secret — a per-org random
--    value, regenerated every time update_org_telegram_bot_token()
--    saves a real token, passed to Telegram's setWebhook as
--    secret_token. The new telegram-webhook Edge Function validates
--    every inbound call's X-Telegram-Bot-Api-Secret-Token header
--    against this column (looked up via the tapped participant's own
--    meeting -> organization, since the webhook payload carries no
--    bot/org identity of its own) — this is the entire authenticity
--    boundary for an endpoint Telegram calls with no Supabase JWT.
--
-- 2. respond_to_invitation_via_telegram(p_participant_id, p_response,
--    p_telegram_chat_id) — a Telegram-safe sibling of the existing
--    respond_to_invitation() RPC (supabase/patch-meetings-rsvp.sql),
--    reproducing the same validation/update logic but substituting
--    auth.uid() = meeting_participants.user_id (impossible to check —
--    no session exists) with users.telegram_chat_id = the chat that
--    tapped the button. This is a NEW function, not a replacement of
--    respond_to_invitation() itself — that RPC is untouched by this
--    patch. service_role-only (called exclusively by the
--    telegram-webhook Edge Function, never a client).
--
-- Idempotent — ADD COLUMN IF NOT EXISTS / CREATE OR REPLACE.
-- ============================================================

BEGIN;

ALTER TABLE organization_telegram_config ADD COLUMN IF NOT EXISTS webhook_secret TEXT;

-- Reproduces update_org_telegram_bot_token()'s existing body
-- (supabase/patch-meetings-telegram-org-config.sql) verbatim, plus:
-- generates a fresh webhook_secret whenever a real (non-blank) token
-- is saved, so a token change and its webhook_secret are always
-- registered together in the very next register-telegram-webhook
-- call (js/data/admin-api.js) — never left mismatched.
CREATE OR REPLACE FUNCTION update_org_telegram_bot_token(p_org_id UUID, p_bot_token TEXT)
RETURNS VOID AS $$
BEGIN
  IF NOT (is_super_admin() OR (is_admin() AND p_org_id = get_my_org_id())) THEN
    RAISE EXCEPTION 'Not authorized to update this organization';
  END IF;

  IF p_bot_token IS NULL OR btrim(p_bot_token) = '' THEN
    DELETE FROM organization_telegram_config WHERE organization_id = p_org_id;
    RETURN;
  END IF;

  INSERT INTO organization_telegram_config (organization_id, bot_token, webhook_secret, updated_by, updated_at)
  VALUES (p_org_id, btrim(p_bot_token), encode(extensions.gen_random_bytes(24), 'hex'), auth.uid(), NOW())
  ON CONFLICT (organization_id) DO UPDATE SET
    bot_token = EXCLUDED.bot_token,
    webhook_secret = EXCLUDED.webhook_secret,
    updated_by = EXCLUDED.updated_by,
    updated_at = NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION update_org_telegram_bot_token(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION update_org_telegram_bot_token(UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION respond_to_invitation_via_telegram(
  p_participant_id UUID,
  p_response TEXT,
  p_telegram_chat_id TEXT
) RETURNS VOID AS $$
DECLARE
  v_participant meeting_participants;
  v_meeting meetings;
  v_actor UUID;
BEGIN
  IF p_response NOT IN ('accepted', 'declined') THEN
    RAISE EXCEPTION 'Invalid response: % (expected accepted or declined)', p_response;
  END IF;

  SELECT * INTO v_participant FROM meeting_participants WHERE id = p_participant_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Participant not found';
  END IF;
  IF v_participant.removed_at IS NOT NULL THEN
    RAISE EXCEPTION 'This participant record has been removed';
  END IF;
  IF v_participant.user_id IS NULL THEN
    RAISE EXCEPTION 'External participants cannot respond via Telegram';
  END IF;

  v_actor := v_participant.user_id;

  -- The entire authorization boundary for this RPC: the Telegram chat
  -- that tapped the button must be the same chat linked to this
  -- participant's own CorLink profile. No CorLink session exists for
  -- a Telegram callback, so this is the Telegram-side equivalent of
  -- respond_to_invitation()'s own "auth.uid() = user_id" check.
  IF NOT EXISTS (
    SELECT 1 FROM users WHERE id = v_actor AND telegram_chat_id = p_telegram_chat_id
  ) THEN
    RAISE EXCEPTION 'This Telegram chat is not linked to the invited participant''s account';
  END IF;

  SELECT * INTO v_meeting FROM meetings WHERE id = v_participant.meeting_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Meeting not found';
  END IF;
  IF v_meeting.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot respond to a cancelled meeting';
  END IF;
  IF NOT meetings_module_active_for(v_meeting.organization_id) THEN
    RAISE EXCEPTION 'The Meetings module is not enabled for this organization';
  END IF;

  UPDATE meeting_participants SET
    invitation_status = p_response
    WHERE id = p_participant_id;

  INSERT INTO audit_logs (user_id, action, record_type, record_id, notes)
  VALUES (v_actor, 'invitation_responded', 'meeting', v_meeting.id, 'via Telegram');

  IF v_meeting.created_by <> v_actor THEN
    INSERT INTO notifications (user_id, type, record_type, record_id, message)
    VALUES (v_meeting.created_by, 'participant_responded', 'meeting', v_meeting.id,
      'A participant has responded to your meeting invitation: ' || v_meeting.title);
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION respond_to_invitation_via_telegram(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION respond_to_invitation_via_telegram(UUID, TEXT, TEXT) TO service_role;

COMMIT;
