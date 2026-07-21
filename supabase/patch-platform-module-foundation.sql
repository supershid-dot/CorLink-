-- ─── Patch: Platform Module Foundation ────────────────────────
-- Phase 1 of the MeetFlow → CorLink migration (see docs/03-migration-
-- architecture.md §6/§8 Phase 1). Introduces a general, two-layer
-- module-access model as a CorLink platform capability — independent
-- of any Meetings/Rooms/Calendar work, which comes later:
--
--   Layer 1 (this patch): organization_modules — whether a module is
--   enabled for an organization at all.
--   Layer 2 (already exists): user_assignments / is_admin() /
--   is_supervisor_or_above() / has_role() etc. — whether THIS user may
--   act within an enabled module.
--
-- A user may access a module only when BOTH layers allow it. Neither
-- layer alone is sufficient — this patch only adds Layer 1; it does
-- not change any existing Layer 2 check.
--
-- Creates no Meetings/Rooms/Calendar/Tasks/signing tables, migrates no
-- MeetFlow data, and does not use MeetFlow's rls_auto_enable() or any
-- MeetFlow RLS design (see docs/02-live-supabase-inventory.md for why:
-- MeetFlow's RLS is either fully disabled or a single blanket
-- USING(true) policy — the opposite of the deny-by-default model used
-- throughout the rest of this file and the rest of CorLink).
--
-- Idempotent — safe to run more than once.

BEGIN;

-- ─── 1. platform_modules — the module catalogue ────────────────
-- One row per known module, whether or not it has shipped yet.
-- is_active is a platform-wide kill switch (independent of any single
-- organization's enablement) for emergency use — not exposed in the
-- admin UI added by this patch; toggled directly by a super admin if
-- ever needed.

CREATE TABLE IF NOT EXISTS platform_modules (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  module_key    TEXT        NOT NULL UNIQUE,
  name          TEXT        NOT NULL,
  description   TEXT,
  category      TEXT,
  -- Hash route this module resolves to once its views/router entry
  -- ship (e.g. 'requests'). NULL means "no working route yet" — the
  -- frontend (shell.js/router.js) treats a NULL route as "not
  -- production-ready" and never shows or serves it, regardless of
  -- organization_modules.is_enabled. This is what keeps future
  -- modules (Meetings, Rooms, Tasks, Calendar, Reports, Document
  -- Signing) hidden with zero further app-side logic.
  route         TEXT,
  icon          TEXT,
  is_active     BOOLEAN     NOT NULL DEFAULT TRUE,
  display_order INTEGER     NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TRIGGER IF EXISTS set_updated_at ON platform_modules;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON platform_modules
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- ─── 2. organization_modules — per-org Layer 1 enablement ──────

CREATE TABLE IF NOT EXISTS organization_modules (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID        NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  module_id       UUID        NOT NULL REFERENCES platform_modules(id) ON DELETE CASCADE,
  is_enabled      BOOLEAN     NOT NULL DEFAULT FALSE,
  enabled_at      TIMESTAMPTZ,
  enabled_by      UUID        REFERENCES users(id),
  disabled_at     TIMESTAMPTZ,
  disabled_by     UUID        REFERENCES users(id),
  -- Free-form per-module, per-org settings (e.g. future module-specific
  -- config) — empty object by default so callers never need a NULL
  -- check before reading a key out of it.
  configuration   JSONB       NOT NULL DEFAULT '{}'::JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (organization_id, module_id)
);

CREATE INDEX IF NOT EXISTS idx_organization_modules_org ON organization_modules(organization_id);
CREATE INDEX IF NOT EXISTS idx_organization_modules_module ON organization_modules(module_id);

DROP TRIGGER IF EXISTS set_updated_at ON organization_modules;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON organization_modules
  FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

-- No platform_module_dependencies table: nothing in this patch's scope
-- (or the next architecturally-planned phase, per docs/03-migration-
-- architecture.md §8 Phases 3-4) requires one module to be enabled as
-- a prerequisite for another. Add it later, only if a genuine
-- dependency emerges (e.g. "calendar" requiring "meetings").

-- ─── 3. Helper functions (Layer 1 checks) ──────────────────────
-- Same conventions as the rest of rls.sql: SQL, STABLE, SECURITY
-- DEFINER, no search_path override (matches every existing helper in
-- this codebase — see get_my_org_id()/is_admin()/etc. in rls.sql).

-- True if p_org_id currently has p_module_key enabled AND the module
-- itself is platform-active. Used both inside RLS policies elsewhere
-- (once Meetings/Rooms/etc. land) and as an RPC the frontend can call
-- directly for a specific org (e.g. an admin viewing another org).
CREATE OR REPLACE FUNCTION module_enabled_for_org(p_org_id UUID, p_module_key TEXT)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1
    FROM organization_modules om
    JOIN platform_modules pm ON pm.id = om.module_id
    WHERE om.organization_id = p_org_id
      AND pm.module_key = p_module_key
      AND om.is_enabled = TRUE
      AND pm.is_active = TRUE
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- True if the CURRENT authenticated user's own organization has
-- p_module_key enabled. This is the one the frontend calls for "does
-- my own org have this on" checks — composes get_my_org_id() (already
-- the standard way every other helper in rls.sql resolves "my org")
-- with module_enabled_for_org() above.
CREATE OR REPLACE FUNCTION current_user_module_enabled(p_module_key TEXT)
RETURNS BOOLEAN AS $$
  SELECT is_super_admin() OR module_enabled_for_org(get_my_org_id(), p_module_key);
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- True if the module itself is active platform-wide, regardless of
-- any organization's enablement — used by the admin Modules tab to
-- distinguish "org has it off" from "the module is globally disabled".
CREATE OR REPLACE FUNCTION is_module_active(p_module_key TEXT)
RETURNS BOOLEAN AS $$
  SELECT COALESCE((SELECT is_active FROM platform_modules WHERE module_key = p_module_key), FALSE);
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ─── 4. RLS ──────────────────────────────────────────────────
-- Deny by default, same as every other table in this schema. No
-- unconditional USING(true) for the authenticated role anywhere below
-- — see docs/03-migration-architecture.md §7 for why that pattern
-- (MeetFlow's) is explicitly excluded from CorLink's design.

ALTER TABLE platform_modules ENABLE ROW LEVEL SECURITY;
ALTER TABLE organization_modules ENABLE ROW LEVEL SECURITY;

-- platform_modules: any authenticated user may read the catalogue
-- (needed for navigation — a user must be able to see a module's
-- name/route/icon to render nav for it), but only super admins may
-- write it. No anonymous access (RLS policies below only ever match
-- the "authenticated" role implicitly via auth.uid()-based helpers;
-- there is no policy granting anything to "anon").
DROP POLICY IF EXISTS "platform_modules_select" ON platform_modules;
CREATE POLICY "platform_modules_select" ON platform_modules
  FOR SELECT USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "platform_modules_write" ON platform_modules;
CREATE POLICY "platform_modules_write" ON platform_modules
  FOR ALL USING (is_super_admin()) WITH CHECK (is_super_admin());

-- organization_modules:
--   SELECT — a user may read assignments for their OWN organization
--   (needed for nav-building and the admin Modules tab when an org
--   admin views their own org), or any organization if they are a
--   super admin (needed for the admin Modules tab's org selector,
--   which already lets super admins pick any organization elsewhere
--   in Admin > Organizations).
--   WRITE — restricted to is_super_admin() only. organizations itself
--   is already super-admin-only to UPDATE (see admin-api.js's comment
--   on orgs_update) — module enablement is provisioning-level
--   authority in the same category, not something mcs_admin/
--   authority_admin (org-scoped roles) hold today. This also
--   satisfies "no ability for organization users to enable modules"
--   and "external organization administrators must not gain
--   platform-wide module-control rights" — no role other than
--   is_super_admin() can write this table at all.
DROP POLICY IF EXISTS "organization_modules_select" ON organization_modules;
CREATE POLICY "organization_modules_select" ON organization_modules
  FOR SELECT USING (
    is_super_admin() OR organization_id = get_my_org_id()
  );

DROP POLICY IF EXISTS "organization_modules_write" ON organization_modules;
CREATE POLICY "organization_modules_write" ON organization_modules
  FOR ALL USING (is_super_admin()) WITH CHECK (is_super_admin());

-- ─── 5. Seed: module catalogue ──────────────────────────────────
-- ON CONFLICT (module_key) DO UPDATE keeps name/description/category/
-- route/icon/display_order in sync on a re-run (e.g. a copy fix)
-- without ever inserting a duplicate row, and deliberately does NOT
-- touch is_active — so a super admin's manual platform-wide kill
-- switch survives a re-run of this seed.

INSERT INTO platform_modules (module_key, name, description, category, route, icon, display_order) VALUES
  ('requests',               'Requests',               'Inter-organization correspondence: request, response, approval workflow.', 'correspondence', 'requests',        'ti-inbox',      10),
  ('prisoner_correspondence', 'Prisoner Correspondence', 'One-directional prisoner letter correspondence tied to the prisoner registry.', 'correspondence', 'prisoner-letters', 'ti-mail',       20),
  ('entry',                  'Entry',                  'Correspondence logged on arrival from outside the CorLink network.', 'correspondence', 'entry',           'ti-mailbox',    30),
  ('prison_registry',        'Prison Registry',        'Standalone prisoner registry management.', 'correspondence', NULL, 'ti-id-badge',   40),
  ('meetings',               'Meetings',               'Meeting scheduling, participants, minutes, and decisions.', 'scheduling', NULL, 'ti-calendar-event', 50),
  ('rooms',                  'Meeting Rooms',          'Bookable room management and availability.', 'scheduling', NULL, 'ti-door',       60),
  ('tasks',                  'Tasks',                  'Task assignment and tracking.', 'productivity', NULL, 'ti-checklist',  70),
  ('calendar',               'Calendar',               'Unified calendar view across scheduling modules.', 'scheduling', NULL, 'ti-calendar',   80),
  ('reports',                'Reports',                'Cross-module reporting and analytics.', 'administration', NULL, 'ti-report',     90),
  ('document_signing',       'Document Signing',       'Digital document signing workflow.', 'administration', NULL, 'ti-signature', 100),
  ('administration',         'Administration',         'Organization structure, user, and audit management.', 'administration', 'admin', 'ti-settings',   110)
ON CONFLICT (module_key) DO UPDATE SET
  name          = EXCLUDED.name,
  description   = EXCLUDED.description,
  category      = EXCLUDED.category,
  route         = EXCLUDED.route,
  icon          = EXCLUDED.icon,
  display_order = EXCLUDED.display_order,
  updated_at    = NOW();

-- ─── 6. Seed: initial organization enablement ───────────────────
-- Preserves CURRENT live access exactly as it exists in the app today
-- (see docs/04-platform-module-foundation.md "Seed behavior" for the
-- full reasoning): requests, entry, prisoner_correspondence, and
-- administration are, right now, all reachable by every organization
-- regardless of type (org.type is checked nowhere in the nav/route
-- layer for any of the four — only within specific in-module actions,
-- e.g. "only MCS may compose a new prisoner letter", which is an
-- existing Layer 2/data-layer check this patch does not touch).
-- Every future/unshipped module (route IS NULL) is left disabled for
-- every organization, since platform_modules.route already hides them
-- from the frontend regardless — this seed just keeps the enablement
-- table's own contents honest and un-surprising if inspected directly.
--
-- ON CONFLICT DO NOTHING — never creates a duplicate
-- (organization_id, module_id) row, and never re-enables/re-disables a
-- module an admin has since changed by hand.
INSERT INTO organization_modules (organization_id, module_id, is_enabled, enabled_at)
SELECT o.id, pm.id, TRUE, NOW()
FROM organizations o
CROSS JOIN platform_modules pm
WHERE pm.module_key IN ('requests', 'entry', 'prisoner_correspondence', 'administration')
ON CONFLICT (organization_id, module_id) DO NOTHING;

-- Every organization also gets an explicit, disabled row for every
-- other catalogued module (rather than simply having no row at all).
-- An explicit is_enabled = FALSE row is unambiguous when the admin
-- Modules tab or module_enabled_for_org() is inspected directly; a
-- missing row would read the same as "not enabled" today but would
-- silently stop doing so if this table's semantics were ever extended
-- later (e.g. a hypothetical future default-on module).
INSERT INTO organization_modules (organization_id, module_id, is_enabled)
SELECT o.id, pm.id, FALSE
FROM organizations o
CROSS JOIN platform_modules pm
WHERE pm.module_key NOT IN ('requests', 'entry', 'prisoner_correspondence', 'administration')
ON CONFLICT (organization_id, module_id) DO NOTHING;

COMMIT;
