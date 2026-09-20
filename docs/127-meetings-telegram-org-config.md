# 127 — Per-Organization Telegram Bot Token (Admin UI, MeetFlow parity)

## 1. Requirement

After docs/126 shipped (Telegram bot token as a manually-configured Edge Function secret, `TELEGRAM_BOT_TOKEN`), the user sent a screenshot of MeetFlow's actual Admin portal — a "Telegram Notifications" panel: an info box reading "Create a bot via **@BotFather**, paste the token below. Add each staff member's Chat ID in their profile (they can get it from **@userinfobot**).", a masked "BOT TOKEN" input, and a "Save Token" button — with the instruction: "Add this to admin portal."

This changes the storage model: instead of an operator running `supabase secrets set TELEGRAM_BOT_TOKEN=...`, an org admin pastes the token directly into CorLink's own Admin screen, exactly like MeetFlow's own UX.

## 2. Design decisions

- **Per-organization, not platform-wide.** MeetFlow is single-tenant — one bot token for the whole app. CorLink is multi-tenant; every other admin-configurable setting (e.g. `update_org_workflow_settings()`'s `default_receiving_section_id`/`reference_number_format`) is scoped to one `organization_id`. The bot token follows the same convention: a new `organization_telegram_config` table, keyed on `organization_id`, one row per org.
- **Not a column on `organizations`.** That table is broadly `SELECT`-able by ordinary staff (org name/logo display). Storing a secret there would leak it to every user in the org. Instead a brand-new, narrowly-locked-down table.
- **RLS: SELECT restricted to admins of that org (or super admin); no direct write policy at all.** Writes go exclusively through a new `SECURITY DEFINER` RPC, `update_org_telegram_bot_token(p_org_id, p_bot_token)` — the exact pattern (and the exact rationale) `rls.sql` already documents on `update_org_workflow_settings()`: "writes go exclusively through [the RPC]".
- **Blank input clears the token**, deleting the row rather than saving an empty string — matches MeetFlow's own "leave blank to disable" affordance and avoids the Edge Function treating `''` as a present-but-useless token.
- **The token never reaches the browser after being saved.** The Admin panel's own read (`getOrgTelegramBotToken`) does show the existing value back to the admin who's allowed to see it (same as MeetFlow's own behavior, and consistent with the RLS SELECT policy scoping this to that org's own admins) — but the Edge Function's system-wide send step reads it via the service-role client, never via a client-facing query across all orgs.

## 3. Implementation

### 3.1 Schema — `supabase/patch-meetings-telegram-org-config.sql`

```sql
CREATE TABLE organization_telegram_config (
  organization_id UUID PRIMARY KEY REFERENCES organizations(id) ON DELETE CASCADE,
  bot_token       TEXT NOT NULL,
  updated_by      UUID REFERENCES users(id),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

RLS: `SELECT` allowed to `is_super_admin() OR (organization_id = get_my_org_id() AND is_admin())`. No `INSERT`/`UPDATE`/`DELETE` policy.

`update_org_telegram_bot_token(p_org_id UUID, p_bot_token TEXT)` — `SECURITY DEFINER`, authorizes the same way (`is_super_admin() OR (is_admin() AND p_org_id = get_my_org_id())`, else raises), deletes the row on a blank/NULL token, otherwise upserts (`ON CONFLICT (organization_id) DO UPDATE`). `REVOKE ALL ... FROM PUBLIC, anon; GRANT EXECUTE ... TO authenticated;` — same explicit-revoke convention this codebase settled on after the docs/126 anon-grant bug.

### 3.2 Edge Function — `supabase/functions/process-meeting-notifications/index.ts`

The module-level `TELEGRAM_BOT_TOKEN` env var is gone. The Telegram-flush step now looks up each pending notification's organization, batches a single `organization_telegram_config` query per unique org in the batch (not per notification), and skips any recipient whose organization hasn't configured a bot — same "skip, don't fail" posture already used for a recipient with no linked `telegram_chat_id`.

### 3.3 Frontend

- `js/data/admin-api.js`: `getOrgTelegramBotToken(orgId)` (direct `SELECT ... maybeSingle()`, relies on the RLS policy above) and `updateOrgTelegramBotToken(orgId, botToken)` (calls the RPC, audit-logs the change via the existing `logAudit()` helper).
- `js/views/admin.js`: a new "Telegram Notifications" panel (`_telegramConfigPanelHtml`/`_bindTelegramConfigPanel`) on the Admin → Structure tab, immediately below the existing Org Settings panel, for both org-type branches (`mcs` and flat/authority). Same instructional copy as MeetFlow's screenshot (@BotFather / @userinfobot), a password-masked token field prefilled with the existing token (if any), and a "Save Token" button that re-renders the tab on success — no toast (this codebase doesn't use toasts anywhere; every other Admin panel here just re-renders on save).

## 4. Files

- `supabase/patch-meetings-telegram-org-config.sql` / `validate-meetings-telegram-org-config.sql` / `rollback-meetings-telegram-org-config.sql` — new table, RLS, RPC; rollback refuses if any org has a token configured (real data that would otherwise be destroyed).
- `supabase/functions/process-meeting-notifications/index.ts` — rewritten Telegram-flush step (per-org token lookup instead of a single env var).
- `js/data/admin-api.js`, `js/views/admin.js` — Admin UI.
- `tests/admin-telegram-config-frontend.test.js` — new: panel renders with the BotFather/userinfobot copy and an empty field when unset; prefills and masks an existing token; saving calls the RPC wrapper with the entered value; a blank submit calls it with an empty value (clears the token).

## 5. Tests

Full regression sweep across all 23 test files: clean, including the 4 new Telegram config tests and the pre-existing `admin-manage-user-modal-frontend.test.js` suite (unaffected — this milestone didn't touch the Manage User modal). Same 5 pre-existing files needing `PLAYWRIGHT_CORE_PATH`/`EDGE_PATH` this sandbox doesn't set, unrelated to this change.

Backend RPC/RLS correctness (org admin can set/read/clear their own org's token; a plain staff member of the same org cannot read it; an admin of a *different* org can neither read nor write it) is verified via `validate-meetings-telegram-org-config.sql`'s behavioral half, run against CorLink Staging.

## 6. Deployment

Cache-busters bumped: `js/data/admin-api.js?v=20260920a`, `js/views/admin.js?v=20260920a`. Migration applied to CorLink Staging (`vjobntuyzymhcuanyeak`); both halves of the validator passed. `process-meeting-notifications` Edge Function redeployed with the per-org lookup. This supersedes the `TELEGRAM_BOT_TOKEN` Edge Function secret from docs/126 — no operator secret-setting is needed anymore; any org admin can enable Telegram delivery for their own organization directly from the Admin → Structure screen.
