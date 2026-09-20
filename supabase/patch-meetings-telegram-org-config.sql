-- ============================================================
-- CorLink — Patch: per-organization Telegram bot token, admin-managed
--
-- Follow-up to patch-meetings-notification-completion.sql: that patch
-- stored the Telegram bot token as an Edge Function secret
-- (TELEGRAM_BOT_TOKEN), requiring a human with Supabase project access
-- to set it via `supabase secrets set`. The user asked for MeetFlow's
-- own UI instead — an admin pastes the bot token directly into the
-- Admin screen (see MeetFlow's "Telegram Notifications" panel) — which
-- also naturally makes the bot per-organization rather than a single
-- platform-wide bot, matching how every other admin-configurable
-- setting in this codebase (default_receiving_section_id,
-- reference_number_format, etc.) is already scoped to one org.
--
-- Deliberately NOT a new column on `organizations` itself: that table
-- is broadly readable (org name/type/logo are used all over the UI by
-- ordinary staff, not just admins), so a bot token living there would
-- leak the secret to every authenticated member of the org. A
-- dedicated table with admin-only SELECT keeps the token's read
-- surface as narrow as the write surface already is.
--
-- Writes go exclusively through update_org_telegram_bot_token() below
-- (SECURITY DEFINER; no direct write RLS policy on the table at all),
-- mirroring the exact rls.sql comment on update_org_workflow_settings():
-- "writes go exclusively through [the RPC]". Reads are RLS-gated to
-- admins of that org (or a super admin) — an ordinary staff member can
-- never see it, even indirectly via a generic `select *`.
--
-- Idempotent — CREATE TABLE IF NOT EXISTS / CREATE OR REPLACE / DROP
-- POLICY IF EXISTS throughout.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS organization_telegram_config (
  organization_id UUID PRIMARY KEY REFERENCES organizations(id) ON DELETE CASCADE,
  bot_token       TEXT NOT NULL,
  updated_by      UUID REFERENCES users(id),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE organization_telegram_config ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS organization_telegram_config_select ON organization_telegram_config;
CREATE POLICY organization_telegram_config_select ON organization_telegram_config
  FOR SELECT USING (is_super_admin() OR (organization_id = get_my_org_id() AND is_admin()));

-- No INSERT/UPDATE/DELETE policy — every write goes through the
-- SECURITY DEFINER RPC below, which bypasses RLS for its own
-- statements after doing its own explicit authorization check. This
-- is the same shape update_org_workflow_settings()/organizations
-- already uses (see rls.sql's own comment on that function).

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
    bot_token = EXCLUDED.bot_token,
    updated_by = EXCLUDED.updated_by,
    updated_at = NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION update_org_telegram_bot_token(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION update_org_telegram_bot_token(UUID, TEXT) TO authenticated;

COMMIT;
