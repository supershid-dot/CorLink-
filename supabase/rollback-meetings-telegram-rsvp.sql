-- ============================================================
-- CorLink — Rollback: Telegram RSVP (Accept/Decline inline buttons)
-- (undoes supabase/patch-meetings-telegram-rsvp.sql)
--
-- Restores update_org_telegram_bot_token() to its pre-RSVP body
-- (supabase/patch-meetings-telegram-org-config.sql — no webhook_secret
-- generation), drops respond_to_invitation_via_telegram(), and drops
-- the webhook_secret column. Refuses if any org still has a
-- webhook_secret set (an admin would need to re-save their bot token
-- afterward to restore RSVP button delivery, so this is surfaced as a
-- deliberate choice, not silently discarded) — same "refuse if real
-- work exists" precedent used elsewhere in this codebase.
-- ============================================================

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM organization_telegram_config WHERE webhook_secret IS NOT NULL) THEN
    RAISE EXCEPTION 'Refusing to roll back: at least one organization has a Telegram webhook registered -- rolling back would silently break its RSVP buttons. Clear its bot token first via the Admin screen if you are certain, or keep this patch applied.';
  END IF;
END $$;

DROP FUNCTION IF EXISTS respond_to_invitation_via_telegram(UUID, TEXT, TEXT);

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

  INSERT INTO organization_telegram_config (organization_id, bot_token, updated_by, updated_at)
  VALUES (p_org_id, btrim(p_bot_token), auth.uid(), NOW())
  ON CONFLICT (organization_id) DO UPDATE SET
    bot_token = EXCLUDED.bot_token, updated_by = EXCLUDED.updated_by, updated_at = NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION update_org_telegram_bot_token(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION update_org_telegram_bot_token(UUID, TEXT) TO authenticated;

ALTER TABLE organization_telegram_config DROP COLUMN IF EXISTS webhook_secret;

COMMIT;
