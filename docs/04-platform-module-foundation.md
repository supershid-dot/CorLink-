# Platform Module Foundation

**Status:** Phase 1 of the MeetFlow → CorLink migration (see `docs/03-migration-architecture.md` §6/§8 Phase 1). Local migration and code changes only — **not yet applied to any Supabase project.**
**Scope:** Introduces a general, two-layer module-access model as a CorLink platform capability. Creates no Meetings/Rooms/Calendar/Tasks/document-signing tables. Migrates no MeetFlow data. Does not use MeetFlow's `rls_auto_enable()` or any MeetFlow RLS pattern.

---

## Architecture

A user may access a module only when **both** layers allow it:

- **Layer 1 — organization module enablement** (new, this patch). Whether a module is turned on for the user's organization at all. Table: `organization_modules`.
- **Layer 2 — existing CorLink role/scope/permission checks** (unchanged). `is_admin()`, `is_supervisor_or_above()`, `has_role()`, `user_assignments`, `is_prisoner_letters_staff`, etc. — exactly the checks already enforced today.

Neither layer is sufficient alone. Layer 1 is new; Layer 2 is not touched by this patch — every existing permission check keeps working exactly as it did before.

## Tables

### `platform_modules`
The module catalogue — one row per known module, whether or not it has shipped. Columns: `id`, `module_key` (unique), `name`, `description`, `category`, `route` (nullable — **NULL means no working route exists yet**, which is what keeps unshipped modules out of navigation and unreachable by URL with zero further logic needed), `icon`, `is_active` (platform-wide kill switch, independent of any org), `display_order`, `created_at`, `updated_at`.

Required keys (all seeded): `requests`, `prisoner_correspondence`, `entry`, `prison_registry`, `meetings`, `rooms`, `tasks`, `calendar`, `reports`, `document_signing`, `administration`. Only `requests`, `prisoner_correspondence`, `entry`, and `administration` currently carry a real `route` — the other seven are seeded with `route = NULL` and are consequently unreachable regardless of any org's enablement.

### `organization_modules`
Per-organization Layer 1 enablement. Columns: `id`, `organization_id` (→ `organizations`), `module_id` (→ `platform_modules`), `is_enabled`, `enabled_at`, `enabled_by` (→ `users`), `disabled_at`, `disabled_by` (→ `users`), `configuration` (`JSONB`, default `{}`), `created_at`, `updated_at`. Unique on `(organization_id, module_id)`.

No `platform_module_dependencies` table was created — nothing in this phase or the next architecturally-planned phases (`docs/03` §8 Phases 3–4) requires one module to depend on another yet. Add it later only if a genuine dependency emerges.

## Helper functions

All `SQL`, `STABLE`, `SECURITY DEFINER`, no `search_path` override — matching every existing helper function in `supabase/rls.sql` exactly (this codebase does not currently pin `search_path` anywhere; this patch does not introduce a new convention).

- `module_enabled_for_org(p_org_id, p_module_key)` — true if that org has that module enabled and the module is platform-active.
- `current_user_module_enabled(p_module_key)` — true for the current authenticated user's own org (or any org, for a super admin).
- `is_module_active(p_module_key)` — true if the module is active platform-wide, independent of any org's enablement.

## RLS rules

Deny by default, no unconditional `authenticated USING(true)`, no anonymous access — same posture as the rest of CorLink, deliberately the opposite of MeetFlow's default-disabled/blanket-policy design (`docs/02-live-supabase-inventory.md` §3, §5).

- `platform_modules_select` — any authenticated user may read the full catalogue (nothing on this table is sensitive; needed for nav rendering).
- `platform_modules_write` — `is_super_admin()` only.
- `organization_modules_select` — a user may read rows for their own organization (`organization_id = get_my_org_id()`), or any organization if `is_super_admin()`.
- `organization_modules_write` — `is_super_admin()` only, both `USING` and `WITH CHECK`. This is the same authority level as `organizations` itself (its own `UPDATE` policy is already super-admin-only — see `js/data/admin-api.js`'s comment on `updateOrgWorkflowSettings`); `mcs_admin`/`authority_admin` cannot enable or disable modules for their own organization today, and external organization admins gain no platform-wide control.

## Seed behavior

The catalogue seed (`INSERT ... ON CONFLICT (module_key) DO UPDATE`) keeps `name`/`description`/`category`/`route`/`icon`/`display_order` in sync on a rerun without ever creating a duplicate row, and deliberately never overwrites `is_active` — a super admin's manual platform-wide kill switch survives a rerun.

**Organization enablement — the actual decision made, and why:**

The instructions for this phase specified two things that turned out to be in tension for existing organizations:
1. External/authority organizations should default to Requests-only (plus Prisoner Correspondence only where "current verified behavior already grants it"), with Entry and Administration excluded by default.
2. Existing users must not lose access to current CorLink modules because of this migration.

Inspection of the live code (`js/views/shell.js`, `supabase/rls.sql`) found that **today, `requests`, `entry`, `prisoner_correspondence`, and `administration` are all already reachable by every organization regardless of `type`** — none of these four are gated by `organizations.type` anywhere in the nav, router, or RLS layer (org-type checks that do exist, e.g. in `prisoner-letters.js`/`admin.js`, only gate a specific *action within* an already-visible module, such as "only MCS may compose a new prisoner letter" — never the module's visibility itself).

Given rule 2 is phrased as an unconditional "must not" and rule 1 is phrased as a default preference ("do not automatically enable" — narrower than a hard prohibition), **this migration's seed enables all four already-shipped modules for every organization, regardless of type**, preserving exactly the access that exists today. Every unshipped module (`route IS NULL`) is left disabled for every organization regardless of type, per rule 1's unambiguous instruction and simple current necessity (there's no route to serve either way).

**This was flagged, then reviewed against live data, and confirmed — not silently decided.** `docs/05-live-organization-module-assessment.md` performed a strictly read-only usage assessment of the live CorLink project and found direct, per-organization evidence supporting the current seed as-is: the one external (authority-type) organization that exists today, HRCM, has 2 real active `authority_admin` users and 1 real active prisoner-letters-staff user — narrowing Administration or Prisoner Correspondence for that organization would remove access those specific, currently-assigned users have today, not a hypothetical future user. The only module with no positive live signal either way is Entry at HRCM (never configured, no historical usage) — `docs/05` recommends a separate policy conversation about it, but confirms the seed should not disable it now, since doing so would newly restrict something that was unconditionally reachable before this migration existed. See `docs/05` for the full per-organization evidence and reasoning.

## Frontend integration

- `js/data/modules-api.js` (new) — `listActiveCatalogue()`, `listEnabledModuleKeys(orgId)`, `listOrgModuleStatus(orgId)`, `setModuleEnabled(orgId, moduleId, enabled)`.
- `js/auth.js` — `enabledModules` (an array of module keys) is fetched alongside `organization` at sign-in and on `refreshProfile()`, and cached onto the same `localStorage` profile object CorLink already uses for `organization` name/logo. A `resumeSession()` backfill (mirroring the existing `organization` backfill) refreshes any profile cached before this feature existed. A failed fetch caches `null`, not `[]` — see "Known limitations" below for why that distinction matters.
- `js/views/shell.js` — new `AppShell.isModuleEnabled(user, moduleKey)`. Composes with the existing Layer 2 checks (`isAdmin`, `canAccessPrisonerLetters`) in `sidebarHtml`/`topbarHtml`/`bottomNavHtml`; `requests`/`entry` (no additional Layer 2 gate today) are shown only when their module key is enabled.
- `js/router.js` — a `MODULE_ROUTES` map plus `moduleGuardPasses()`/`renderModuleUnavailable()` deny direct URL entry to a module-gated route that fails either layer, rendering a denial screen (with a link back to `#dashboard`) instead of the real view. This is the actual security-relevant check; nav hiding in `shell.js` is UX only, matching this codebase's existing "RLS/route guard is the real gate" convention.

### Nav-loading fallback behavior (no flicker, fail-safe)

`enabledModules` is one of three shapes on the cached profile:
- **A real array** — the authoritative Layer 1 answer for that org.
- **`null`** — Layer 1 data couldn't be loaded (network failure, or — critically, during the rollout window before this migration is applied to a given Supabase project — the `organization_modules`/`platform_modules` tables simply don't exist there yet). `AppShell.isModuleEnabled()` treats `null` as "no Layer 1 opinion available" and **passes the check through unchanged**, so the four already-shipped modules keep working exactly as they did before this feature existed, on any project this migration hasn't been applied to yet.
- This does **not** apply to any unshipped module, because those never get a nav item in the template at all, regardless of this check's answer — they're structurally unreachable, not merely hidden by a check that could fail open.

This is what satisfies "fail closed for new modules without unnecessarily breaking existing modules" for both halves at once: new modules are unreachable by construction; existing modules degrade gracefully to pre-migration behavior if Layer 1 data isn't available, and become properly gated the moment it is.

## Administration behavior

A new **Modules** tab in the existing Admin Portal (`js/views/admin.js`), visible to anyone who can already reach the Admin Portal at all (i.e., already `is_super_admin` or an org admin — nothing new is exposed to ordinary users).

- Lists every catalogued module for the selected organization: name, category, availability (`Available` vs. `Not available yet`, driven by whether `route` is set), and enabled/disabled status.
- **Only super admins see toggle controls** — matching `organization_modules_write` RLS exactly, so the UI never offers an action that would fail server-side. Org admins (`mcs_admin`/`authority_admin`) see the same table read-only, with an explanatory banner.
- A module with no route (`route IS NULL`) has **no toggle control at all**, even for super admins — it cannot be enabled by accident through this UI, regardless of platform authority, satisfying "future unfinished modules may be visible... as 'Not available yet,' but must not be enabled accidentally."
- Disabling an already-enabled module requires an explicit confirmation modal naming the organization and the module and stating that current users will immediately lose access — satisfying "prevent disabling a module when doing so would immediately break critical current access, unless a warning and explicit confirmation exist." Enabling requires no confirmation (non-destructive).

## Validation steps

See `supabase/validate-platform-module-foundation.sql` for the full, runnable set of checks (module-key uniqueness/completeness, no duplicate org-module rows, no orphaned FKs, MCS access preserved, no organization holding an unshipped module enabled, RLS-as-non-admin/anon spot checks, helper-function spot checks, seed-rerun idempotency). All of it is read-only SELECT statements plus documented manual RLS-impersonation steps — nothing in that file writes data either.

Also manually verify (per this phase's instructions), once the migration is applied to a real (non-production) project: existing user login, Dashboard, Requests, Prisoner Correspondence, Entry, existing Administration routes, direct URL access to each (both allowed and denied cases), organization switching (super admin's org selector), mobile sidebar/bottom nav, browser console (no errors), no broken script imports, no CSP violations (no new external origins were introduced — `js/data/modules-api.js` only calls the existing Supabase client).

## Known limitations

- The organization-enablement seed intentionally preserves *broader* access for authority-type organizations than `docs/03-migration-architecture.md` §6's eventual target model describes — see "Seed behavior" above. This has now been reviewed against live organization data (`docs/05-live-organization-module-assessment.md`) and confirmed as the correct choice for the organizations that actually exist today; one narrow, non-blocking follow-up remains (HRCM's Entry module — a policy question, not a data gap).
- `enabledModules` is cached at sign-in/refresh, not pushed live — a module enabled or disabled by an admin takes effect for an already-logged-in affected user at their next login or profile refresh, not instantly. This mirrors how `organization` (name/logo) already behaves in this codebase and was judged acceptable for the same reason.
- `search_path` remains unpinned on the new helper functions, matching every existing function in `supabase/rls.sql` — a pre-existing, unaddressed advisor finding (`function_search_path_mutable`, see `docs/02-live-supabase-inventory.md` §2), not something newly introduced here.
- No `platform_module_dependencies` table exists yet — deferred until a real dependency emerges.
- This migration has not been applied to any Supabase project. `supabase/patch-platform-module-foundation.sql` and `supabase/validate-platform-module-foundation.sql` are ready for review but require a separate, explicit approval step before being run — see `docs/03-migration-architecture.md` §8 Phase 1's own approval gate.
