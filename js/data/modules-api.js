// ─── Platform Module Access Data API ──────────────────────────
// Layer 1 of the two-layer module access model (see
// docs/03-migration-architecture.md §6, docs/04-platform-module-
// foundation.md): whether a module is enabled for an organization at
// all. Layer 2 (existing role/assignment checks — isAdmin(),
// canAccessPrisonerLetters(), etc.) lives in js/views/shell.js and is
// unchanged by this file.
//
// RLS (supabase/patch-platform-module-foundation.sql) is the real
// enforcement layer, same as every other data API in this codebase —
// this file only shapes requests/responses for the UI.

const ModulesAPI = (() => {
  return {
    // Full module catalogue, active modules only, ordered for nav
    // rendering. Only the columns navigation actually needs are
    // requested (module_key/name/route/icon/category/display_order) —
    // nothing sensitive lives on this table, but there's no reason to
    // pull description/timestamps into a nav-building call either.
    async listActiveCatalogue() {
      const db = getSupabase();
      const { data, error } = await db.from('platform_modules')
        .select('module_key, name, route, icon, category, display_order')
        .eq('is_active', true)
        .order('display_order');
      if (error) throw error;
      return data || [];
    },

    // The set of module keys enabled for a specific organization —
    // this is what js/auth.js caches onto the signed-in user's profile
    // (see Auth.signIn/refreshProfile) so shell.js can build nav
    // synchronously with no per-render fetch and no visible flicker.
    // Returns keys only for modules that are BOTH org-enabled AND
    // platform-active; a module with no route yet can still appear
    // here (Layer 1 says nothing about whether a route exists — that
    // check happens separately in shell.js/router.js against the
    // catalogue's `route` column) — callers must not assume presence
    // in this list alone means "show a nav link".
    async listEnabledModuleKeys(orgId) {
      if (!orgId) return [];
      const db = getSupabase();
      const { data, error } = await db.from('organization_modules')
        .select('is_enabled, platform_modules!inner(module_key, is_active)')
        .eq('organization_id', orgId)
        .eq('is_enabled', true)
        .eq('platform_modules.is_active', true);
      if (error) throw error;
      return (data || []).map(row => row.platform_modules.module_key);
    },

    // Full catalogue x this org's enablement, for the Admin > Modules
    // tab. Includes modules with no route yet (shown as "Not available
    // yet" by the view) and the org's is_enabled/enabled_at state for
    // every module, not just the enabled ones.
    async listOrgModuleStatus(orgId) {
      const db = getSupabase();
      const { data, error } = await db.from('platform_modules')
        .select('id, module_key, name, description, category, route, icon, is_active, display_order, organization_modules!left(id, organization_id, is_enabled, enabled_at, disabled_at)')
        .order('display_order');
      if (error) throw error;
      return (data || []).map(pm => {
        const om = (pm.organization_modules || []).find(r => r.organization_id === orgId);
        return {
          moduleId: pm.id,
          moduleKey: pm.module_key,
          name: pm.name,
          description: pm.description,
          category: pm.category,
          route: pm.route,
          icon: pm.icon,
          platformActive: pm.is_active,
          isEnabled: !!om?.is_enabled,
          enabledAt: om?.enabled_at || null,
          disabledAt: om?.disabled_at || null,
        };
      });
    },

    // Enable/disable a module for an organization. RLS restricts this
    // write to is_super_admin() — see organization_modules_write in
    // the migration; ordinary org admins cannot call this
    // successfully regardless of what the UI shows them.
    async setModuleEnabled(orgId, moduleId, enabled) {
      const db = getSupabase();
      const session = await Auth.getSession();
      const actorId = session?.user?.id || null;
      const patch = enabled
        ? { is_enabled: true, enabled_at: new Date().toISOString(), enabled_by: actorId }
        : { is_enabled: false, disabled_at: new Date().toISOString(), disabled_by: actorId };

      const { error } = await db.from('organization_modules')
        .upsert(
          { organization_id: orgId, module_id: moduleId, ...patch },
          { onConflict: 'organization_id,module_id' }
        );
      if (error) throw error;

      await db.from('audit_logs').insert({
        user_id: actorId,
        action: enabled ? 'module_enabled' : 'module_disabled',
        record_type: 'organization',
        record_id: orgId,
        notes: enabled ? 'Enabled a platform module' : 'Disabled a platform module',
      });
    },
  };
})();
