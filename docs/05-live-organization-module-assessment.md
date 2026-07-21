# Live Organization Module Assessment

**Type:** Strictly read-only live-database usage assessment (Step 6 of the MeetFlow → CorLink migration process)
**Companion documents:** `docs/04-platform-module-foundation.md` (Phase 1 architecture/seed design), `docs/02-live-supabase-inventory.md` (earlier structural inventory)
**Date:** 2026-07-21
**Project queried:** CorLink production, `infjjroktzzhaxjvfknr` (confirmed via `list_projects` — distinct from MeetFlow's `xvwileiyquqxxtzqxghm`, which was **not** accessed in this step).
**Method:** Supabase MCP `execute_sql`, read-only `SELECT`-only aggregate queries against `organizations`, `users`, `user_assignments`, `sections`, `commands`, `divisions`, `entry_sections`, `requests`, `responses`, `external_correspondence`, `external_correspondence_replies`, `prisoner_letters`, `prisoner_replies`, `internal_requests`, `audit_logs`, and `information_schema.tables`. No `INSERT`/`UPDATE`/`DELETE`/DDL was executed. No RLS policy, role, assignment, or user was changed. No personal, prisoner, or correspondence content was read — every query returned only counts and organization-level structural fields (id, name, type, code, role names, boolean flags).

---

## 1. Organization Inventory

Exactly **2 organizations** exist on the live project — no inactive/legacy organizations, no ambiguous/ungrouped ones. Classification used the structured `organizations.type` column (`'mcs'` / `'authority'`), not name matching, per instructions. CorLink's schema has no parent-organization concept (organizations are flat top-level entities; the command/department/division/section hierarchy sits *below* an organization, not between organizations) — "parent organization" is not applicable to either row.

| Organization | ID (sanitized) | Type | Code | Active | Classification | Active users | Active assignments | Roles present (active) | Active sections | Active commands | Active divisions | Entry sections configured |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Maldives Correctional Service | `...0001` | `mcs` | MCS | Yes | **MCS primary/internal** | 7 | 11 | `assigned_receiver`, `staff`, `supervisor` | 5 | 3 | 0 | **1** |
| Human Rights Commission of the Maldives | `...0002` | `authority` | HRCM | Yes | **External authority** | 3 | 4 | `authority_admin`, `staff`, `supervisor` | 1 | 0 | 1 | 0 |

No organization required "unclear/manual review" classification — both have unambiguous `type` values and active structural data.

**Supplementary role/config findings** (structural evidence, not transactional — see §2–§4 for why):
- MCS: 1 `is_super_admin` user, 0 users, plus 6 non-super-admin users. `mcs_admin` role exists in the schema but has **0 active assignments** (1 assignment row exists with `is_active = false`) — today, MCS's platform/administration access in practice runs through the super admin account, not a dedicated org-admin role.
- HRCM: **2 active `authority_admin` assignments** (org-scoped, `scope_type = 'organization'`) — this is real, currently-exercised organization administration, not a dormant role.
- `is_prisoner_letters_staff = true`: **2 users at MCS**, **1 user at HRCM** — both organizations have staff individually designated for Prisoner Correspondence today.
- `entry_sections` (which section(s) may log Entry correspondence): **configured for MCS only** (1 section designated). HRCM has never configured this — per `is_entry_staff()`'s fallback (`ELSE get_my_org_id() = p_org_id`), this means *any* HRCM member currently passes the Entry-staff check for HRCM's own rows, not that HRCM is blocked.

---

## 2. Requests Usage

**Every count is 0 for both organizations** — `requests` (0 total system-wide), `responses` (0 total system-wide).

| Organization | Created | Received | Actually sent (post-draft) | Responded | Active | Historical |
|---|---|---|---|---|---|---|
| MCS | 0 | 0 | 0 | 0 | 0 | 0 |
| HRCM | 0 | 0 | 0 | 0 | 0 | 0 |

This is not a data gap in this query — `docs/02-live-supabase-inventory.md` (§2, gathered 2026-07-21 earlier the same day) already documented that an earlier, unrelated, explicitly-authorized task wiped transactional tables on this project to 0 rows. Re-confirmed here directly rather than assumed. **Requests usage cannot be judged from live counts for either organization** — the determination below relies on structural/architectural evidence instead (§7).

## 3. Entry Usage

**Every count is 0 for both organizations** — `external_correspondence` and `external_correspondence_replies` are both empty system-wide. Same wiped-data caveat as §2 applies.

| Organization | Created | Routed | Assigned | Active | Historical |
|---|---|---|---|---|---|
| MCS | 0 | 0 | 0 | 0 | 0 |
| HRCM | 0 | 0 | 0 | 0 | 0 |

**Frontend/RLS inspection (not sidebar-only), per instructions:**
- `is_entry_staff(p_org_id)` (`supabase/rls.sql`) is **not** gated by `organizations.type` anywhere — it only checks `entry_sections` configuration for that org, falling back to "any member of that org" when unconfigured. Nothing in RLS restricts Entry to MCS-type organizations.
- `js/views/entry.js`'s `_canLogEntries()` mirrors this exactly (`this._entrySectionIds` from `AdminAPI.listEntrySections`, same org-member fallback) — confirmed by direct read of the current file, not inferred from the sidebar.
- `js/router.js`'s `moduleGuardPasses()`/`MODULE_ROUTES` (Phase 1's own route guard) gates the `entry`/`entry-detail` routes on the `entry` module key only — no additional Layer 2 restriction is layered on top for Entry, matching Requests' treatment.
- **Conclusion: external users (HRCM) can currently reach Entry today** — both by nav visibility (pre-Phase-1: unconditional; post-Phase-1: gated only by the module-enablement flag itself) and by RLS (no type check). Whether Entry is *operationally* MCS-only is a live-configuration fact, not a code restriction: MCS has explicitly configured which section handles Entry (`entry_sections` has 1 row); HRCM has never done so. That is a real signal of *operational engagement*, not of *access being blocked* — HRCM's fallback path (`ELSE get_my_org_id() = p_org_id`) still grants access to HRCM's own members for HRCM's own entries, it's simply undifferentiated within HRCM rather than routed to a specific section.

## 4. Prisoner Correspondence Usage

**Every count is 0 for both organizations** — `prisoner_letters` and `prisoner_replies` are both empty system-wide. Same wiped-data caveat applies.

| Organization | Created (as MCS sender) | Sent to org (as authority recipient) | Replies submitted | Total visible |
|---|---|---|---|---|
| MCS | 0 | 0 | 0 | 0 |
| HRCM | 0 | 0 | 0 | 0 |

Per-organization access-type determination (from `prisoner_letters_insert`/`prisoner_letters_select` RLS, confirmed by direct read):
- **MCS: create access** — `prisoner_letters_insert` requires `is_prisoner_letters_staff()` AND `from_prison_id = get_my_org_id()` AND the sending org's `type = 'mcs'`. MCS has 2 users flagged `is_prisoner_letters_staff = true`, i.e. real, currently-designated staff for this exact create path.
- **HRCM: receive/view + reply access, no create access** — the same policy's second `EXISTS` clause requires the *destination* org's `type = 'authority'`, matching HRCM. HRCM has 1 user flagged `is_prisoner_letters_staff = true` — real, currently-designated staff for the view/reply path. RLS itself (not just intent) already prevents HRCM from creating new prisoner correspondence (`from_prison_id` must resolve to an `mcs`-type org) — the "external organizations must not create new prisoner correspondence" rule is already enforced independent of the Layer 1 module-enablement work in this migration.
- No organization needs "no access" — both have live, individually-designated staff for their respective (different) sides of this module today.

## 5. Administration Usage

- **MCS**: 1 active `is_super_admin` user (platform-wide administration, not org-scoped — `is_super_admin` bypasses Layer 1 entirely per `AppShell.isModuleEnabled()`, so this user's access is unaffected by whatever this migration decides for MCS's `administration` module row). 0 active `mcs_admin` assignments (1 exists but `is_active = false`). **Today, ordinary MCS staff cannot reach Administration at all** (`is_admin()` requires `is_super_admin() OR has_role('mcs_admin') OR has_role('authority_admin')`, and no MCS user besides the super admin satisfies any branch) — so for MCS specifically, `administration`'s Layer 1 enablement is presently moot for everyone except the super admin, who ignores Layer 1 anyway.
- **HRCM**: **2 active `authority_admin` assignments**, `scope_type = 'organization'` — real, currently-exercised **organization-scoped** administration (per `js/data/admin-api.js`'s own documented convention, `authority_admin`/`mcs_admin` manage their own org's users/structure/settings; they do **not** gain the platform-wide authority that `organization_modules_write`/`platform_modules_write` RLS reserves for `is_super_admin()` only). This is unambiguously "organization administration," not "platform administration," in this codebase's terms.
- **Distinguishing platform vs. organization administration** (both meanings coexist under the single `administration` module key today): platform administration = `is_super_admin()`-gated actions (managing all organizations, module enablement itself); organization administration = `mcs_admin`/`authority_admin`-gated actions (managing one's own org's users, structure, settings) — the live data shows HRCM's 2 admins operate exclusively at the organization-administration level; nothing in `user_assignments` grants any non-super-admin user platform-level authority.
- **Disabling `administration` for HRCM today would remove real, currently-active access** for HRCM's 2 `authority_admin` users — this is not hypothetical, it is what `is_admin()` returning true for those 2 real users, combined with a disabled Layer 1 flag, would produce.

---

## 6. Module Recommendation Matrix

| Organization | Classification | Requests | Entry | Prisoner Correspondence | Administration | Evidence | Recommended initial enablement | Confidence | Manual review required |
|---|---|---|---|---|---|---|---|---|---|
| Maldives Correctional Service | MCS primary/internal | enable | enable | enable | enable | `entry_sections` actively configured (1); 2 users flagged prisoner-letters staff; `requests`/`administration` are core, unrestricted, currently-reachable modules; 0 transactional history (wiped, not a usage signal) | requests, entry, prisoner_correspondence, administration | High | No |
| Human Rights Commission of the Maldives | External authority | enable | manual review | enable | enable | 2 active `authority_admin` users (real org-administration usage today) and 1 prisoner-letters-staff user are direct, positive evidence for Administration and Prisoner Correspondence; Requests is architecturally bidirectional and unrestricted by type; Entry has **no positive or negative live signal** (`entry_sections` never configured, 0 historical entries) and no code-level type restriction — safe to enable per "must not lose access" (this reflects Entry's current unconditional reachability, not a data-backed need), but recommended for a deliberate policy check-in with the org, since unlike the other three modules there is no direct evidence either way | requests, entry, prisoner_correspondence, administration | High (Requests/Prisoner Correspondence/Administration); Medium (Entry — see manual review) | **Entry** — recommend a policy confirmation with HRCM/the platform owner on whether Entry should remain generally available to HRCM long-term; not a blocker to Phase 1's current seed, since the seed's obligation is to preserve today's already-unconditional access, which it does |

No organization required "disable" or "enable with restricted permissions" for any module — every module currently reachable by an organization has either direct role/config evidence supporting it, or (Entry at HRCM) no evidence against it and an explicit "must not lose access" obligation for what's already reachable today.

---

## 7. Seed Strategy Recommendation

### Evaluation of the four options

- **Option A — Preserve-all seed.** Risk of access loss: none (matches what §1–§5 show is actually in use or reachable today). Risk of overexposure: low — the only module without a positive usage signal (Entry at HRCM) was already unconditionally reachable before this migration existed, so enabling it via the seed changes nothing about actual exposure; it only makes the *existing* exposure explicit and revocable through the new admin UI instead of implicit in unconditional code. Rollback complexity: trivial (`docs/rollback/001` §1 already documents that leaving the seeded rows alone reproduces today's behavior exactly). Maintainability: highest — a single seed shape for all organizations, easy to reason about, matches how the codebase already treats these four modules (no type-based branching exists anywhere in Layer 2 for them). Consistency with the approved architecture: this **is** what `supabase/patch-platform-module-foundation.sql` already implements.
- **Option B — Organization-aware seed.** Would require branching the seed by `organizations.type`, narrowing HRCM to (at most) Requests + Prisoner Correspondence. Risk of access loss: **real and immediate** for HRCM's 2 active `authority_admin` users (Administration) — not hypothetical, directly evidenced in §5. Risk of overexposure: lower than A only for Entry, and only if HRCM genuinely never needs it (unconfirmed). Rollback complexity: same as A once seeded. Maintainability: worse — introduces a `type`-based branch that doesn't exist anywhere else in this migration's design and would need to stay in sync with any future org whose real usage doesn't match its `type`. Consistency: contradicts `docs/03`'s target end-state only in the sense that it would apply that end-state's narrower model *before* the current real usage (HRCM's active admins) is accounted for — i.e., it would satisfy the architecture doc at the cost of violating this step's own "must not remove legitimate access" objective.
- **Option C — Explicit allowlist seed.** With only 2 organizations, this is operationally identical to Option A (both orgs would be allowlisted for all four modules per §6) but adds a hardcoded-ID maintenance burden for zero present benefit — the next organization created would need a manual allowlist entry before it could use modules the rest of the platform already treats as universal. Not recommended for a 2-organization live population where the same outcome is achievable generically.
- **Option D — Compatibility mode.** Would mean `organization_modules` initially governs only new (unshipped) modules while `requests`/`entry`/`prisoner_correspondence`/`administration` keep working through legacy checks alone. This contradicts Phase 1's actual purpose (bringing exactly these four modules under Layer 1 governance so they can be seen and toggled in the new Admin Modules tab) and would mean re-doing this exact seeding step later anyway, with no evidence gathered in the interim that isn't already gathered here.

### Recommendation

**Option A (Preserve-all), now confirmed by live evidence rather than assumed from code-reading alone.** The live data doesn't just fail to contradict the seed already implemented in `supabase/patch-platform-module-foundation.sql` — for 3 of 4 modules (Requests, Prisoner Correspondence, Administration) it supplies direct, positive, per-organization justification (real active `authority_admin` and `is_prisoner_letters_staff` assignments at HRCM; real active role structure and `entry_sections` configuration at MCS) that wasn't available when that seed was first written. The 4th module (Entry at HRCM) has no positive evidence either way, but disabling it now would be a new restriction the seed has no data basis for — the correct action per this migration's own "must not lose access" rule is to leave it enabled and flag it for a separate, deliberate policy conversation, which §6 does.

---

## 8. Migration Update Decision

**The live evidence is clear enough to make a decision — and the decision it supports is that the currently-implemented seed is already correct.** No change to `supabase/patch-platform-module-foundation.sql`'s seed logic was made, because there is nothing to correct: the seed already enables `requests`/`entry`/`prisoner_correspondence`/`administration` for every organization, which §1–§6 now show is the right outcome for both organizations that actually exist, for reasons specific to each of them (not merely "no evidence against it").

What **was** updated, since this closes out a decision that `docs/04` and the validation script had explicitly left open pending exactly this kind of live review:
- `docs/04-platform-module-foundation.md` — "Seed behavior" section and "Known limitations" bullet updated to record that the seed-scope question has been reviewed against live data and confirmed (not merely presumed), citing this document.
- `supabase/validate-platform-module-foundation.sql` — check 5b's comment updated to reference this document instead of describing the review as still-pending.
- No change to table definitions, RLS policies, helper functions, or the seed's `INSERT` statements themselves. `supabase/patch-platform-module-foundation.sql` is byte-for-byte unchanged from the version committed in `0d99e73`.
- Because the SQL itself is unchanged, the local Postgres verification already performed for Phase 1 (clean initial apply, clean idempotent reruns, correct RLS-as-different-roles behavior) remains valid and was not re-run — there is nothing new to verify.

---

## 9. Final Checks

- **CorLink Supabase was accessed read-only:** Yes — every call in this step was `list_projects` (read-only listing) or `execute_sql` with a `SELECT` statement. No `INSERT`/`UPDATE`/`DELETE`/DDL was executed.
- **No Supabase write occurred:** Confirmed — re-verified by re-reading every query issued in this step before writing this report.
- **MeetFlow was not accessed:** Confirmed — every `execute_sql` call in this step used `project_id = infjjroktzzhaxjvfknr` (CorLink) only; MeetFlow's `xvwileiyquqxxtzqxghm` was never referenced.
- **No deployment occurred:** Confirmed — no Edge Function, migration, or branch operation was invoked; only `list_projects` and read-only `execute_sql`.
- **CorLink remains on `feature/corlink-platform-migration`:** Confirmed via `git status` before and during this step.
- **MeetFlow (`references/meetflow`) remains untouched:** Confirmed — no files under that path were read, written, or otherwise accessed during this step.
- **The migration has still not been applied:** Confirmed directly — `information_schema.tables` shows neither `platform_modules` nor `organization_modules` exists yet on the live CorLink project, and every transactional table (`requests`, `responses`, `external_correspondence`, `external_correspondence_replies`, `prisoner_letters`, `prisoner_replies`, `internal_requests`, `audit_logs`) reports 0 rows.

---

## Summary for the Requesting Step

- **Organization classifications:** Maldives Correctional Service = MCS primary/internal (7 active users, 1 super admin, `entry_sections` configured); Human Rights Commission of the Maldives = external authority (3 active users, 2 active `authority_admin`, 1 prisoner-letters-staff user). Both classified from the structured `organizations.type` column, not by name. No inactive/legacy/unclear organizations exist.
- **Important usage findings:** All transactional tables (`requests`, `responses`, `external_correspondence`, `external_correspondence_replies`, `prisoner_letters`, `prisoner_replies`) are empty for both organizations — a prior, unrelated, already-documented data wipe, not a gap in this query. In its absence, the assessment relied on structural/role evidence: HRCM has 2 real, currently-active `authority_admin` users and 1 real prisoner-letters-staff user (direct evidence Administration and Prisoner Correspondence must stay enabled for HRCM); MCS has an actively-configured `entry_sections` row and a full active role structure but 0 active `mcs_admin` assignments (Administration is presently moot for ordinary MCS staff, harmless to enable). Entry at HRCM is the one module with no live signal either way.
- **Recommended seed strategy:** Option A (Preserve-all), now evidence-confirmed rather than assumed — see §7.
- **Whether the migration was updated:** The seed logic in `supabase/patch-platform-module-foundation.sql` was **not** changed (already correct, confirmed by evidence). `docs/04-platform-module-foundation.md` and `supabase/validate-platform-module-foundation.sql` (comment only) were updated to close out the previously-flagged open question.
- **Files changed:** `docs/05-live-organization-module-assessment.md` (new, this file), `docs/04-platform-module-foundation.md` (edited), `supabase/validate-platform-module-foundation.sql` (edited, comment only).
- **Amended commit ID:** see the commit recorded immediately after this document in the same change (Phase 1's original commit, amended per this step's instructions — message unchanged).
- **Organizations needing manual review:** Human Rights Commission of the Maldives — Entry module only (policy confirmation recommended, not a migration blocker; current seed already satisfies "must not lose access").
- **Whether Phase 1 is now ready to apply to staging:** The seed-scope question — the one item `docs/04`'s "Known limitations" flagged as needing a decision before production — is now resolved for both organizations that actually exist, with one narrow, explicitly-flagged, non-blocking follow-up (HRCM's Entry policy). No other blocker was identified in this step. Ready for staging, pending your review of this document and the Entry follow-up.

**Stop after this step**, per the requesting instruction.
