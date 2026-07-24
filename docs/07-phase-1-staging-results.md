# Phase 1 Staging Validation Results

**Type:** Local Postgres validation of `supabase/patch-platform-module-foundation.sql` (Step 8 of the MeetFlow → CorLink migration process), performed as the explicitly-chosen fallback after no hosted Supabase staging environment could be created.
**Companion documents:** `docs/04-platform-module-foundation.md`, `docs/05-live-organization-module-assessment.md`, `docs/06-staging-environment-requirements.md`
**Date:** 2026-07-21
**Filename note:** the requesting instruction asked for `docs/06-phase-1-staging-results.md`; that number was already used by `docs/06-staging-environment-requirements.md` from the previous step, so this document is `docs/07` instead — same content the instruction asked for, adjusted numbering only.

---

## 1. Staging project identification

**No hosted Supabase project was used.** `docs/06-staging-environment-requirements.md` found no isolated staging environment available: no existing CorLink staging/dev project, no database branch (the organization is on the free plan, which doesn't include branching), and no separate disposable project. A follow-up attempt to create a new dedicated project (`corlink-staging`, same region as production, `ap-northeast-1`) was explicitly authorized and attempted via `mcp__Supabase__create_project`, but failed cleanly with:

> "The following organization members have reached their maximum limits for the number of active free projects within organizations where they are an administrator or owner: supershid-dot (2 project limit)."

Confirmed via `list_projects` immediately after that nothing was created — the account still has exactly the same 2 projects (`corlink-production`, `meeting-room-booking`) it had before. Every way to free a slot (delete/pause an existing project, or upgrade the plan) conflicted with explicit constraints from that step, so none was attempted.

Given that, you explicitly chose **local Postgres testing** as the fallback (`docs/06`'s Option 3) for this step. What follows is real, executed verification against a genuine local PostgreSQL 16 instance — not a description of what *would* happen, and not a substitute claim of having tested against Supabase. Section 6 below states plainly what this fallback cannot cover.

**Local test database:** `corlink_staging_local`, a fresh PostgreSQL 16.13 database created and dropped entirely within this session's local Postgres cluster (`/var/lib/postgresql/16/main`) — never connected to, or reachable from, either `infjjroktzzhaxjvfknr` (CorLink production) or `xvwileiyquqxxtzqxghm` (MeetFlow). Built using this repo's own established convention: a stub `auth` schema (`auth.users`, `auth.uid()` reading `request.jwt.claim.sub`), `authenticated`/`anon` roles, then the real `schema.sql` and `rls.sql` loaded verbatim, followed by fixture data.

---

## 2. Baseline (captured before applying Phase 1)

| Metric | Value | Matches live CorLink production (`docs/02`)? |
|---|---|---|
| Tables in `public` | 30 | Yes — exact match |
| RLS policies in `public` | 95 | Yes — exact match |
| `platform_modules`/`organization_modules` present | No (neither exists) | Yes — matches production's actual current state |
| Organizations (fixture) | 2 (`Test MCS`, type `mcs`; `Test Authority`, type `authority`) | Structurally mirrors production's 2 real organizations |
| Users (fixture) | 5 (ordinary MCS staff, MCS admin, authority admin, super admin, authority staff) | Covers every role this step's RLS tests require |
| User assignments (fixture) | 4 | — |

The exact table/policy counts matching `docs/02`'s live production inventory (30/95) confirms `schema.sql`/`rls.sql` are a faithful, current baseline — not a stale or drifted copy — before Phase 1's migration was applied on top.

---

## 3. Migration execution

- **Start:** 2026-07-21T14:50:06Z
- **Completion:** 2026-07-21T14:50:07Z (≈1 second)
- **Status:** Clean success, `COMMIT` reached, no errors.
- **Warnings:** Two expected `NOTICE`s (`trigger "set_updated_at" ... does not exist, skipping`) from the migration's own `DROP TRIGGER IF EXISTS` idempotency guards on a first-ever apply — not errors, and exactly the behavior those guards exist to produce.
- **Only** `supabase/patch-platform-module-foundation.sql` was applied. No other patch file, and no MeetFlow file, was run against this database.
- **Database objects created:** tables `platform_modules`, `organization_modules`; indexes `idx_organization_modules_org`, `idx_organization_modules_module`; functions `module_enabled_for_org`, `current_user_module_enabled`, `is_module_active`; RLS enabled + 4 policies (`platform_modules_select`, `platform_modules_write`, `organization_modules_select`, `organization_modules_write`); 2 `updated_at` triggers.
- **Rows seeded:** 11 (`platform_modules` catalogue — all 11 required keys), 8 (`organization_modules` enabled rows — 2 organizations × 4 already-shipped modules), 14 (`organization_modules` disabled rows — 2 organizations × 7 unshipped modules). Total 22 = 2 organizations × 11 modules, with no organization missing any row.
- **Reapply/idempotency:** the migration was applied a second time later in this session (§5, to restore the migrated state after the rollback test) — clean, no errors, ended at the identical row counts (11 / 22).

---

## 4. Seeded module results

### Module catalogue
- Exactly 11 required module keys exist, each exactly once (`validate-platform-module-foundation.sql` check 1, plus `all_required_keys_present = true`).
- No duplicate module keys.
- All 7 future/unshipped modules (`prison_registry`, `meetings`, `rooms`, `tasks`, `calendar`, `reports`, `document_signing`) remain `is_enabled = FALSE` for every organization, with no exceptions found.
- The 4 currently-shipped modules (`requests`, `entry`, `prisoner_correspondence`, `administration`) are `is_enabled = TRUE` for **both** fixture organizations — matching the approved preserve-all seed strategy confirmed in `docs/05`.

### Organization assignments
- Every organization has exactly 11 rows (one per module) — verified directly, no organization has a missing or extra row.
- No duplicate `(organization_id, module_id)` rows (`validate` check 2).
- No orphaned foreign keys (`validate` check 3).
- `configuration` is `{}` (empty JSON object) for every single row, with no exceptions — the column's `NOT NULL DEFAULT '{}'::JSONB` behaves as designed.
- Timestamp logic: all 14 disabled rows have neither `enabled_at` nor `disabled_at` set (never touched by the seed, correct); all 8 enabled rows have `enabled_at` set and `disabled_at` NULL (correct — never disabled). No row was found with an invalid combination (e.g., `disabled_at` set while `is_enabled = TRUE`).

---

## 5. RLS test results

All 13 tests below were run as documented transactions (`BEGIN; SET LOCAL ROLE ...; SET LOCAL request.jwt.claim.sub ...; <query>; ROLLBACK;`) — nothing was permanently written by any test.

| # | Test | Role / user | Result | Pass? |
|---|---|---|---|---|
| 1 | Anonymous cannot read `organization_modules` | `anon` | 0 rows visible | ✅ |
| 2 | Anonymous cannot write `organization_modules` | `anon` | `UPDATE 0` | ✅ |
| 3 | Ordinary MCS staff sees only their own org | MCS staff (no admin role) | 11 rows, `Test MCS` only | ✅ |
| 4 | Ordinary staff cannot toggle a module | MCS staff | `UPDATE 0` | ✅ |
| 5 | MCS admin (org-scoped) sees only their own org | `mcs_admin` | 11 rows, `Test MCS` only | ✅ |
| 6 | MCS admin cannot write module settings (org admin ≠ platform write access) | `mcs_admin` | `UPDATE 0` | ✅ |
| 7 | Authority admin (org-scoped) sees only their own org | `authority_admin` | 11 rows, `Test Authority` only | ✅ |
| 8 | Authority admin cannot write module settings | `authority_admin` | `UPDATE 0` | ✅ |
| 9 | Authority staff cannot read the other (MCS) org's rows | Authority staff | 0 rows visible for MCS org | ✅ |
| 10 | Super admin sees all organizations' rows | `is_super_admin` | 22 rows (both orgs, all modules) | ✅ |
| 11 | Only super admin can actually enable/disable a module | `is_super_admin` | `UPDATE 1` (succeeded) | ✅ |
| 12 | Helper functions fail closed for a user with no valid org assignment | Nonexistent user ID | `get_my_org_id()` → NULL; `current_user_module_enabled('requests')` → **false** | ✅ |
| 13 | Helper function spot checks for a known real user | MCS staff | `module_enabled_for_org(org,'requests')`→true, `module_enabled_for_org(org,'meetings')`→false, `current_user_module_enabled('requests')`→true, `is_module_active('requests')`→true, `is_module_active('nonexistent_key')`→false | ✅ |

**Every requirement from the requesting step's §5 is directly satisfied**, with test numbers: anonymous read/write blocked (1, 2); ordinary users can't change settings (4); org admins can read their own org's assignments (5, 7); org admins can't gain platform-wide write access (6, 8); only super admin can enable/disable (6, 8 denied vs. 11 succeeding); users can't read unrelated organizations' assignments (3, 5, 7, 9); helper functions fail closed without a valid org assignment (12).

**Note on test 12's `module_enabled_for_org` result:** it returned `true`, not `false` — this is correct, not a fail-closed violation. `module_enabled_for_org(p_org_id, p_module_key)` is a direct org+module lookup (it answers "is this specific org's module enabled," independent of who's asking), not a caller-identity check — it is by design not the function this fail-closed requirement targets. `current_user_module_enabled()`, which *is* keyed to the caller's own identity via `get_my_org_id()`, correctly returned `false` for the unknown user, which is the actual fail-closed behavior this requirement is about.

---

## 6. Frontend test results

**Not performed, and not possible via this fallback.** Local Postgres provides a real PostgreSQL engine with real RLS enforcement (which is why the tests in §5 are genuine, not simulated), but it does not provide Supabase Auth (session issuance, JWT signing, password flows), Supabase Storage, PostgREST, or Edge Functions — the full stack the CorLink frontend actually talks to. None of the following could be tested this session, and none should be reported as verified:

- Login, dashboard, Requests, Entry, Prisoner Correspondence, Administration, Modules admin tab, sidebar, top navigation, mobile bottom navigation
- Direct URL route protection (the frontend route guard itself was reviewed as code during Phase 1's own development — see `docs/04` — but not exercised against a live backend here)
- Loading behavior, module-fetch failure behavior
- Super-admin module toggle and authority-admin read-only view, as actual UI interactions
- Confirming Meetings/Rooms/Tasks/Calendar/Prison Registry/Reports/Document Signing stay hidden in the rendered UI (their absence from the seed and from `route`-bearing catalogue rows was confirmed at the database level in §4, but not observed in a running browser)

This gap is exactly what `docs/06`'s Option 3 caveat anticipated. Real frontend-against-backend validation requires either the paid-plan branching path or a dedicated hosted staging project — both blocked this session per `docs/06` and §1 above.

---

## 7. Rollback test result

Performed in the local test database only, after the RLS tests, before the final reapply:

1. Ran the exact SQL documented in `docs/rollback/001-platform-module-foundation.md` §3 (`DROP POLICY`/`DROP TABLE`/`DROP FUNCTION`, in FK-safe order, wrapped in `BEGIN`/`COMMIT`).
2. **Confirmed removal:** `platform_modules`, `organization_modules`, and all 3 helper functions (`current_user_module_enabled`, `module_enabled_for_org`, `is_module_active`) were completely gone afterward.
3. **Confirmed no collateral damage:** every pre-existing count matched the original baseline (§2) exactly — 30 tables, 95 policies, 2 organizations, 5 users, 4 assignments. Nothing outside this phase's own footprint was touched.
4. **Reapplied the migration** (`supabase/patch-platform-module-foundation.sql`) immediately after, restoring the database to the migrated state: 11 catalogue rows, 22 organization-module rows — identical to the first application, confirming the migration is safely re-runnable after a full rollback, not just after a no-op rerun.

**Result: pass.** The rollback is exactly as safe and non-destructive as `docs/rollback/001` claims.

---

## 8. Issues discovered

One issue surfaced during RLS testing (§5, tests 1–11 initially failed with `permission denied for table organization_modules` before the fix below):

- **Test-harness gap, not a migration defect:** the blanket `GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated, anon` issued while setting up this local database ran *before* Phase 1's migration created `platform_modules`/`organization_modules`, so those two new tables never received it (a one-time `GRANT ... ON ALL TABLES` only covers tables that exist at the moment it runs). On a real Supabase project, this class of grant is applied automatically and continuously by the platform itself for every table, including new ones — it isn't something CorLink's own SQL files set (confirmed: no `GRANT` statement for `authenticated`/`anon` appears anywhere in `supabase/*.sql`). **Fix:** issued a second, explicit `GRANT ... ON platform_modules, organization_modules TO authenticated, anon` in the local harness only. This is the identical class of gap already documented from Phase 1's own earlier local verification (`docs/04`'s development history) — expected to recur in any from-scratch local Postgres setup, and not something that needs a code or migration change.

No other issue — no SQL error, no RLS gap, no unexpected row, no idempotency failure — was found anywhere in this step's testing.

---

## 9. Fixes made

**None to `supabase/patch-platform-module-foundation.sql`, or to any application code.** The one fix made (§8) was to this session's disposable local test harness only, not to anything committed to the repository. `supabase/patch-platform-module-foundation.sql` is byte-for-byte unchanged from commit `737c29e`.

Because no code or migration change was needed, this step's results are recorded as a **separate documentation commit** (`docs: record Phase 1 staging validation`), not an amendment to the Phase 1 commit — per this step's own instructions ("If no code changes are needed, create a separate documentation commit").

---

## 10. Production-readiness recommendation

**Database layer: ready.** Every database-level check this step could perform — clean migration application (twice, including after a full rollback), correct seeding, correct RLS behavior across all 5 representative roles plus anonymous access, and a verified non-destructive rollback path — passed without exception.

**Full production readiness: not yet fully confirmed**, specifically because §6's frontend-against-a-real-backend validation could not be performed this session. Before this migration is applied to CorLink production, at minimum one of the following should happen first:
- Set up a real hosted Supabase staging environment (either path from `docs/06`) and run this step's §6 frontend checklist against it, **or**
- Accept applying directly to production with a verified rollback path in hand (this step confirmed the rollback works cleanly) and close monitoring immediately after, understanding that frontend-specific issues (script load order, CSP, session-cache timing) were not exercised end-to-end before that point.

The former is recommended given a clean rollback path alone doesn't catch frontend-only defects (a broken script tag, a CSP violation, a caching bug) that never touch the database at all.

---

## 11. Final Report

- **Staging project used:** No hosted Supabase project — local PostgreSQL 16 (`corlink_staging_local`), created fresh for this step and never connected to any Supabase project.
- **Confirmation it was isolated from production:** Yes — a physically separate local database engine, never networked to `infjjroktzzhaxjvfknr` or `xvwileiyquqxxtzqxghm`. Attempting to create a real isolated hosted project (`corlink-staging`) was tried first and failed cleanly (free-tier 2-project cap) with nothing created — confirmed via `list_projects` before falling back to local Postgres.
- **Migration status:** Applied cleanly twice (initial + post-rollback reapply), ~1 second each, zero errors, only expected first-run `NOTICE`s.
- **Validation status:** All automated `validate-platform-module-foundation.sql` checks pass; all manual catalogue/assignment/config/timestamp checks pass.
- **RLS results:** All 13 tests pass — anonymous blocked, ordinary users blocked from writes, org admins (both types) correctly scoped to their own organization and blocked from writes, only super admin can write, cross-org reads blocked, helper functions fail closed for an unrecognized user.
- **Frontend results:** Not performed — not possible via local Postgres (no real Auth/Storage/PostgREST). See §6 for the explicit list of what remains unverified.
- **Rollback test result:** Pass — clean removal, zero collateral impact on the other 30 tables/95 policies/2 orgs/5 users/4 assignments, clean reapply afterward.
- **Files changed:** `docs/07-phase-1-staging-results.md` (new, this file). No SQL or application code changed.
- **Final commit ID:** recorded immediately after this document (see the following commit — a new, separate documentation commit, per §9).
- **Unresolved issues:** Frontend-against-real-backend validation (§6) remains undone; requires a real Supabase environment. No database-level issue remains open.
- **Whether Phase 1 is ready for production approval:** Database layer — yes. Full readiness — pending either a real staging environment for frontend validation, or an explicit decision to accept that gap and rely on the verified rollback path instead.
- **Confirmation that production and MeetFlow were not modified:** Confirmed — every write in this step targeted only the disposable local database. The one real Supabase call made (`create_project`, attempting `corlink-staging`) failed before creating anything and touched neither `infjjroktzzhaxjvfknr` nor `xvwileiyquqxxtzqxghm`.

**Stop after this step**, per the requesting instruction.
