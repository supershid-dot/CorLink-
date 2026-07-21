# Rollback — 001: Platform Module Foundation

Companion to `docs/04-platform-module-foundation.md`. This document explains how to undo Phase 1 of the MeetFlow → CorLink migration (`supabase/patch-platform-module-foundation.sql` + the accompanying frontend changes) **if it needs to be reversed after being applied**. As of this document's creation, the migration has **not** been applied to any Supabase project — nothing here has been executed.

This rollback is scoped narrowly to what this phase actually created. It does not touch `organizations`, `users`, `user_assignments`, or any other pre-existing CorLink table or data — those are never written to by this phase's migration.

---

## 1. Restore previous navigation behavior

If the frontend changes have been deployed but you want to immediately restore pre-Phase-1 navigation without waiting for a code revert:

- Set every affected `platform_modules.route`-bearing module's `is_active = FALSE` for a global, instant kill switch (still leaves the tables/data intact — see §3 for full removal):
  ```sql
  UPDATE platform_modules SET is_active = FALSE
  WHERE module_key IN ('requests', 'entry', 'prisoner_correspondence', 'administration');
  ```
  **Caution:** this makes `module_enabled_for_org()` return `false` for these modules for every organization, which — because the frontend fallback only passes through on `null` (fetch failure), not on a real `false` answer — **would actually hide these already-working modules from every user**, the opposite of "restore previous behavior." Do not use this as a rollback step; it's listed here only so its effect is understood if it's ever reached for by mistake. The correct restoration is the code revert in §2, or simply leaving `organization_modules` rows enabled as seeded (§3's `DROP TABLE` naturally restores pre-Phase-1 behavior via the `null`-fallback path described in `docs/04`).

- The reliable way to restore previous navigation behavior without a code revert: leave the seeded `organization_modules` rows exactly as the migration created them (every org has `requests`/`entry`/`prisoner_correspondence`/`administration` enabled) — this reproduces today's actual access exactly. Only §3 (full removal) or a manual admin action would change that.

## 2. Remove the new frontend integration

Revert or remove, in this order:

1. `index.html` — remove the `js/data/modules-api.js` script tag; revert the version-string bumps on `js/auth.js`, `js/router.js`, `js/views/shell.js`, `js/views/admin.js` if desired (not required — the bumps are harmless cache-busters, reverting them isn't necessary for correctness).
2. `js/views/admin.js` — remove the `data-tab="modules"` button, the `else if (this._state.tab === 'modules')` branch, `_renderModules`, `_setModuleEnabled`, `_openDisableModuleConfirm`, and the `this._isOrgAdmin = isOrgAdmin;` line (only needed by the Modules tab).
3. `js/router.js` — remove `MODULE_ROUTES`, `layer2Allows`, `moduleGuardPasses`, `renderModuleUnavailable`, and the block in `handleHashChange` that calls them. Routing reverts to auth-only guarding, exactly as it was before this phase.
4. `js/views/shell.js` — remove `AppShell.isModuleEnabled`, and revert `sidebarHtml`/`topbarHtml`/`bottomNavHtml` to their unconditional (`requests`/`entry`) / Layer-2-only (`admin`/`prisoner-letters`) rendering.
5. `js/auth.js` — remove `fetchEnabledModules`, the `enabledModules` field from the `signIn()`/`refreshProfile()` profile objects, and the `enabledModules` clause in the `resumeSession()` backfill condition.
6. Delete `js/data/modules-api.js`.

Each of these files can be reverted independently via `git revert`/`git checkout` against the commit before this phase, since none of them share a change with unrelated work in the same commit.

## 3. Remove the new database objects safely

Run as a superuser/service-role connection, in this exact order (respects FK dependencies — `organization_modules` references `platform_modules`, so it must be dropped first):

```sql
BEGIN;

DROP POLICY IF EXISTS "organization_modules_write"  ON organization_modules;
DROP POLICY IF EXISTS "organization_modules_select" ON organization_modules;
DROP TABLE IF EXISTS organization_modules;

DROP POLICY IF EXISTS "platform_modules_write"  ON platform_modules;
DROP POLICY IF EXISTS "platform_modules_select" ON platform_modules;
DROP TABLE IF EXISTS platform_modules;

DROP FUNCTION IF EXISTS current_user_module_enabled(TEXT);
DROP FUNCTION IF EXISTS module_enabled_for_org(UUID, TEXT);
DROP FUNCTION IF EXISTS is_module_active(TEXT);

COMMIT;
```

**This is safe and non-destructive to the rest of CorLink**: both tables are exclusively new, exclusively created by this phase, and referenced by nothing outside this phase's own frontend code (no other table has a foreign key pointing *into* `platform_modules` or `organization_modules`, and no trigger on any pre-existing table reads from either). Dropping them cannot cascade into `organizations`, `users`, or any correspondence/request/entry/letter data.

**Do not** run any broader statement (`DROP SCHEMA`, `TRUNCATE` on any pre-existing table, or anything wildcard-based) to accomplish this rollback — the explicit `DROP TABLE`/`DROP FUNCTION` list above is the entire footprint of this phase, and rollback should touch exactly that footprint and nothing else.

## 4. Confirm existing CorLink functionality remains intact

After either a partial rollback (§1) or a full rollback (§2 + §3), verify:

- Existing users can log in and land on the Dashboard.
- Requests, Entry, Prisoner Correspondence (for staff with `is_prisoner_letters_staff`), and Administration (for admins) are all reachable exactly as before this phase — both via nav links and by typing the URL hash directly.
- `SELECT COUNT(*) FROM organizations;`, `SELECT COUNT(*) FROM users;`, and equivalent counts on `requests`/`external_correspondence`/`prisoner_letters` match their pre-rollback values exactly (this phase's migration and rollback never touch these tables, so an unexpected change here would indicate an unrelated issue, not a side effect of this rollback).
- `supabase/validate-platform-module-foundation.sql`'s queries against `platform_modules`/`organization_modules` return "relation does not exist" errors after a full (§3) rollback — confirming clean removal — or their normal pre-rollback results if only §1/§2 were performed.
