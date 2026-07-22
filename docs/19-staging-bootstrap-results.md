# 19 — Staging Bootstrap Results: Pre-Deployment Inventory

**Status:** Pre-deployment inventory only. No SQL applied, no buckets created, no extensions installed, no Auth configured, no Edge Functions deployed, no frontend deployed. Staging and production were both read-only for this step.

## 0. Target Verification

Before any inventory call, the write target was independently verified via `mcp__Supabase__list_projects` (not taken on trust from the conversation) against the full project list returned by the Supabase account:

| | Reference | Name | Region |
|---|---|---|---|
| **Staging (target)** | `vjobntuyzymhcuanyeak` | CorLink Staging | ap-northeast-1 |
| **Production (excluded)** | `infjjroktzzhaxjvfknr` | corlink-production | ap-northeast-1 |
| (unrelated third project) | `xvwileiyquqxxtzqxghm` | meeting-room-booking | ap-northeast-2 |

Confirmed:
- The target reference (`vjobntuyzymhcuanyeak`) is **not** the production reference (`infjjroktzzhaxjvfknr`).
- The target's project name ("CorLink Staging") matches what was verified in the prior staging-verification step.
- All inventory calls below were scoped to `project_id: vjobntuyzymhcuanyeak` only. No call in this step targeted `infjjroktzzhaxjvfknr` or `xvwileiyquqxxtzqxghm`.

No abort condition was triggered.

## 1. Project Identity

| Field | Value |
|---|---|
| Name | CorLink Staging |
| Reference | `vjobntuyzymhcuanyeak` |
| URL | `https://vjobntuyzymhcuanyeak.supabase.co` |
| Region | ap-northeast-1 (matches production) |
| Status | ACTIVE_HEALTHY |
| Postgres version | 17.6.1.147 (engine 17, release channel `ga`) |
| Created at | 2026-07-22T06:49:31Z |
| Organization | `ojdttkcggwfqeorzwybk` (same org as production and meeting-room-booking) |

For comparison, production (`infjjroktzzhaxjvfknr`) runs Postgres `17.6.1.127` — a slightly older patch build within the same major/engine version. Not a blocker; noted for completeness.

## 2. Public Schema Object Counts

Queried via read-only `SELECT` against `information_schema` / `pg_catalog` (no writes):

| Object type | Count |
|---|---|
| Tables (`public`) | 0 |
| Views (`public`) | 0 |
| Functions (`public`) | 0 |
| Triggers (non-internal, all schemas) | 5 |
| RLS policies (`public`) | 0 |
| Tables with `public.relrowsecurity` enabled | 0 |
| Sequences (`public`) | 0 |

The 5 non-internal triggers belong to Supabase-managed schemas (e.g. `auth`, `storage`), not to any application schema — consistent with zero application tables existing yet. This confirms the database is genuinely empty of application objects, matching the prior staging-verification step's finding.

`mcp__Supabase__list_tables` (schema: `public`) independently returned an empty table list, corroborating the same conclusion via a second method.

## 3. Installed Extensions

Full extension catalog was retrieved via `mcp__Supabase__list_extensions`. Of the ~75 extensions Postgres makes available on this instance, only the following are actually **installed** (`installed_version` non-null):

| Extension | Version | Schema |
|---|---|---|
| `plpgsql` | 1.0 | `pg_catalog` (default, always present) |
| `uuid-ossp` | 1.1 | `extensions` |
| `pgcrypto` | 1.3 | `extensions` |
| `pg_stat_statements` | 1.11 | `extensions` |
| `supabase_vault` | 0.3.1 | `vault` (Supabase-managed default) |

**Not yet installed** (required by `docs/18`'s bootstrap plan, to be installed at the appropriate bootstrap step — not this one):
- `pg_cron` (available, `default_version` 1.6.4, `installed_version` null)
- `btree_gist` (available, `default_version` 1.7, `installed_version` null)

This matches expectations: a freshly created Supabase project ships `pgcrypto` and `uuid-ossp` by default, but `pg_cron` and `btree_gist` are always opt-in per-project.

## 4. Storage Buckets

Queried via read-only `SELECT id, name, public, file_size_limit, allowed_mime_types, created_at FROM storage.buckets`:

**Result: 0 buckets.** No `attachments`, no `org-logos`, no legacy `prisoner-letters`, no MeetFlow buckets. Confirms the prior staging-verification finding that the project is fully empty, including Storage.

## 5. Migration History

`mcp__Supabase__list_migrations` returned an empty list — no migrations have been applied to this project via the Supabase migration-tracking mechanism. Consistent with zero application tables existing.

## 6. Deployed Edge Functions

`mcp__Supabase__list_edge_functions` returned an empty list — no Edge Functions (`create-user`, `reset-password`, or otherwise) are deployed to this project yet.

## 7. Auth Configuration (readable subset)

The Supabase MCP tool surface available in this session does not expose a dedicated Auth-configuration read endpoint (no provider list, redirect-URL list, or JWT-expiry setting is queryable through the tools called in this step). What could be read:

| Item | Value |
|---|---|
| Legacy anon API key | present, active, `disabled: false` |
| New-format publishable API key | present, active, `disabled: false` (id `a0b4c27e-e42f-4518-8c4a-a2e0198efed8`) |

Both key types resolving successfully confirms the project's Auth/API layer is provisioned and reachable. Provider settings, redirect URLs, email templates, and JWT expiry were **not** verified this step — per `docs/18` §5, these require manual Supabase Dashboard configuration and were explicitly out of scope for this read-only inventory.

## 8. Security Advisors

`mcp__Supabase__get_advisors` (type: `security`) returned zero lints — expected for a database with no application tables/policies yet; there is nothing yet for the advisor to flag.

## 9. Summary

| Category | Status |
|---|---|
| Target verified as staging, not production | ✅ Confirmed independently |
| Public application tables | 0 (empty, confirmed two ways) |
| Storage buckets | 0 (empty) |
| Migrations applied | 0 |
| Edge Functions deployed | 0 |
| Required extensions already present | `pgcrypto`, `uuid-ossp` (defaults) |
| Required extensions still needed | `pg_cron`, `btree_gist` — not yet installed |
| Auth configuration | API keys active; provider/URL/JWT settings unverified (dashboard-only, out of scope this step) |
| Security advisories | None (nothing to flag on an empty database) |

This confirms the staging project is in the exact same clean, empty state as the prior staging-verification step reported, with no drift in the interim. The project is ready for the canonical baseline application (`schema.sql` → `rls.sql` → `storage-policies.sql` → `notifications.sql`) and the 5-file migration stack described in `docs/18-staging-bootstrap-plan.md`, but that application step was explicitly out of scope for this turn and was not performed.

## 10. Infrastructure prerequisites

**Status:** Extensions installed and Storage buckets created. `schema.sql`/`rls.sql`/`storage-policies.sql`/`notifications.sql` were **not** applied — this step covers only the two non-SQL-expressible prerequisites `docs/18` §11 identified as required before the canonical baseline can be applied (bucket creation, plus the two extensions the baseline SQL itself declares as dependencies).

### 0. Target verification (this step)

Two separate write actions were taken this step (extension install, bucket creation); the target was independently re-verified via `mcp__Supabase__list_projects` immediately before each:

| | Reference | Name |
|---|---|---|
| Staging (target, both writes) | `vjobntuyzymhcuanyeak` | CorLink Staging |
| Production (excluded, both checks) | `infjjroktzzhaxjvfknr` | corlink-production |

Both checks confirmed target ≠ production. No abort condition was triggered at either point.

### 1. Extensions installed

Confirmed required per `docs/18` §3 by reading `schema.sql:8`, `notifications.sql:22`, and `patch-rooms-booking-foundation.sql:20` directly this step:

| Extension | Version | Schema | Purpose | Action taken |
|---|---|---|---|---|
| `pgcrypto` | 1.3 | `extensions` | `gen_random_uuid()` for every table's PK default (`schema.sql:8`) | **Not reinstalled** — already present from project creation |
| `btree_gist` | 1.7 | `public` | Room-booking exclusion constraint, `EXCLUDE USING gist` (`patch-rooms-booking-foundation.sql:20`) | Installed via `CREATE EXTENSION IF NOT EXISTS btree_gist;` |
| `pg_cron` | 1.6.4 | `pg_catalog` | Daily `check_deadlines()` job, confirmed required by reading `notifications.sql:22`'s own `CREATE EXTENSION IF NOT EXISTS pg_cron;` line and its `cron.schedule(...)` call at the bottom of that file | Installed via `CREATE EXTENSION IF NOT EXISTS pg_cron;` |

Post-install state independently re-confirmed via `mcp__Supabase__list_extensions` (not assumed from the install call's lack of error): all three show non-null `installed_version` matching the table above.

### 2. Storage buckets created

Exactly two buckets, matching `docs/18` §4's finding that only these two are ever referenced by application code (`js/data/*.js`'s `db.storage.from(...)` call sites):

| Bucket | Public | File size limit | Allowed MIME types | Source of these values |
|---|---|---|---|---|
| `attachments` | No (private) | 20971520 bytes (20 MB) | `application/pdf`, `application/vnd.openxmlformats-officedocument.wordprocessingml.document`, `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`, `image/jpeg`, `image/png` | `storage-policies.sql:86-95` (its `UPDATE storage.buckets` block) — not invented |
| `org-logos` | Yes (public) | 2097152 bytes (2 MB) | `image/png`, `image/jpeg` | `storage-policies.sql:100-103` — not invented |

**Not created** (explicitly excluded per the task): `prisoner-letters`, `meetings`, `rooms`, or any MeetFlow-related bucket. `prisoner-letters` is confirmed dead in `docs/18` §4 — no application code references it, and `storage-policies.sql`'s own header calls its policies "a future addition." Meetings and Rooms both reuse the shared `attachments` bucket via `record_type` folder scoping; neither module has ever had its own bucket in this codebase.

**Method note:** no Supabase MCP tool in this session's tool list provides bucket management (`list_projects`, `execute_sql`, `list_extensions`, etc. were available; no `create_bucket`/`list_buckets` equivalent was). Buckets were created via a direct `INSERT INTO storage.buckets (...) ... ON CONFLICT (id) DO NOTHING` using only the columns `storage.buckets` actually has (confirmed via `information_schema.columns` before writing) and only the values `storage-policies.sql` itself already defines. This is a one-time bucket-creation action, distinct from applying `storage-policies.sql` itself (which sets bucket policies, not bucket existence, and was **not** run this step).

Post-creation state independently re-confirmed via a fresh `SELECT ... FROM storage.buckets` — both rows match the table above exactly, including `created_at`.

### 3. Validation results

| Check | Result |
|---|---|
| `btree_gist` installed | ✅ 1.7, schema `public` |
| `pg_cron` installed | ✅ 1.6.4, schema `pg_catalog` |
| `pgcrypto` untouched (not reinstalled) | ✅ still 1.3, schema `extensions`, same as pre-existing state |
| Exactly two buckets exist | ✅ `attachments`, `org-logos` — no others |
| No excluded bucket created | ✅ confirmed by the same `SELECT` — no `prisoner-letters`/`meetings`/`rooms`/MeetFlow rows |
| Public tables still 0 | ✅ `mcp__Supabase__list_tables` — empty |
| Migrations still 0 | ✅ `mcp__Supabase__list_migrations` — empty |
| Edge Functions still 0 | ✅ `mcp__Supabase__list_edge_functions` — empty |

### 4. Deferred (not performed this step, by instruction)

- `schema.sql` / `rls.sql` / `storage-policies.sql` / `notifications.sql` application (the canonical baseline)
- The 5-file Rooms/Meetings/route-activation migration stack
- SQL validation scripts (`validate-*.sql`)
- Auth configuration (Site URL, email/signup settings, password policy, JWT expiry)
- Edge Function deployment (`create-user`, `reset-password`)
- Frontend deployment / `js/config.js` and CSP staging swap
- Initial super admin account creation

All of the above remain correctly sequenced *after* this step, per `docs/18` §2's bootstrap order (buckets and these two extensions were steps 3, 5, and 10 — all now complete; step 1, `schema.sql`, is next).

## 11. Canonical baseline application

**Status:** All four canonical baseline files applied to staging, in exact order, one at a time, with target re-verification before each write. No unexpected errors — every file applied cleanly on the first attempt; no silent patching was needed at any step. Migration patch stack (Rooms/Meetings/route-activation), Auth configuration, Edge Function deployment, and frontend deployment remain out of scope for this step and were not touched.

### 0. Target verification (this step)

Four separate write actions were taken (one per baseline file); the target was independently re-verified via `mcp__Supabase__list_projects` immediately before each:

| | Reference | Name |
|---|---|---|
| Staging (target, all four writes) | `vjobntuyzymhcuanyeak` | CorLink Staging |
| Production (excluded, all four checks) | `infjjroktzzhaxjvfknr` | corlink-production |

All four checks confirmed target ≠ production. No abort condition was triggered at any point.

### 1. Execution order and per-file results

| # | File | Result | Applied via |
|---|---|---|---|
| 1 | `supabase/schema.sql` | ✅ Success, no errors | `mcp__Supabase__apply_migration` (migration `01_schema`) |
| 2 | `supabase/rls.sql` | ✅ Success, no errors | `mcp__Supabase__apply_migration` (migration `02_rls`) |
| 3 | `supabase/storage-policies.sql` | ✅ Success, no errors | `mcp__Supabase__apply_migration` (migration `03_storage_policies`) |
| 4 | `supabase/notifications.sql` | ✅ Success, no errors | `mcp__Supabase__apply_migration` (migration `04_notifications`) |

Each file's exact content was read in full from the repository immediately before being applied (not reconstructed from memory or an earlier partial read) and applied verbatim — no lines skipped, no statements reordered.

### 2. Object counts after each file

| Checkpoint | Public tables | Public functions | RLS policies | Triggers | Views | Tables w/ RLS enabled |
|---|---|---|---|---|---|---|
| Before this step (post-inventory) | 0 | 0 | 0 | 0 | 0 | 0 |
| After `schema.sql` | 30 | 202 | 0 | 17 | 0 | 0 |
| After `rls.sql` | 30 | 231 | 95 | 18 | 0 | 30 |
| After `storage-policies.sql` | 30 | 231 | 95 (public schema; +7 on `storage.objects`, a different schema not counted here) | 18 | 0 | 30 |
| After `notifications.sql` | 30 | 234 | 95 | 18 | 0 | 30 |

The table count (30) matches an exact manual count of every `CREATE TABLE` in `schema.sql`, confirming no table was missed or duplicated. The trigger count (17 → 18) matches `schema.sql`'s 17 defined triggers plus `rls.sql`'s one added trigger (`protect_privileged_user_columns`). The policy count (95) matches `rls.sql`'s `CREATE POLICY` statements on `public`-schema tables. `storage-policies.sql` added 7 policies on `storage.objects` (a separate schema, not reflected in the `public`-schema policy count above) — confirmed directly (see §4).

### 3. Dependency verification

- **`rls.sql` depended on `schema.sql`:** every table/column `rls.sql`'s policies and helper functions reference (e.g. `organizations.default_receiving_section_id`, `internal_requests.parent_entry_id`) existed before `rls.sql` ran. Applied cleanly, confirming the dependency was satisfied.
- **`storage-policies.sql` depended on the `attachments` table (for its `attachments_storage_select` policy's `EXISTS` subquery) and on the `attachments`/`org-logos` buckets already existing** (created in the prior infrastructure-prerequisites step). Both were present; applied cleanly.
- **`notifications.sql` depended on `rls.sql`'s `scope_section_ids()` helper** (used by its own `section_user_ids()`) **and on the `pg_cron` extension** (installed in the prior infrastructure-prerequisites step, confirmed still present). Applied cleanly.

### 4. Post-`storage-policies.sql` verification

7 policies confirmed on `storage.objects`, matching all 7 `CREATE POLICY` statements in the file exactly: `org_logos_public_read`, `org_logos_admin_insert`, `org_logos_admin_update`, `org_logos_admin_delete`, `attachments_storage_select`, `attachments_storage_insert`, `attachments_storage_delete`. Bucket settings (`file_size_limit`/`allowed_mime_types` on `attachments` and `org-logos`) re-confirmed unchanged from the infrastructure-prerequisites step — the file's `UPDATE storage.buckets` statements were idempotent no-ops against already-correct values.

### 5. Post-`notifications.sql` verification

- **pg_cron job:** exactly one job exists — `check-deadlines-daily`, schedule `0 3 * * *`, command `SELECT check_deadlines();`, `active: true`. Matches the file's `cron.schedule(...)` call exactly.
- **Notification-related objects:** all three functions the file defines are present — `check_deadlines`, `org_supervisor_user_ids`, `section_user_ids`.
- **No MeetFlow objects:** directly queried `information_schema.tables` for MeetFlow's actual table names (`bookings`, `pre_bookings`, `meeting_group_access`) plus the Rooms/Meetings module's own table names (`meeting_rooms`, `meeting_room_bookings`, `meeting_room_blocks`, `meetings`, `meeting_participants`) — zero rows returned. Correct and expected: none of these come from the 4 canonical baseline files; the Rooms/Meetings tables are created by the separate migration-patch stack, which is explicitly out of scope for this step and was not applied.

### 6. Warnings

- **`btree_gist` remains installed in the `public` schema** rather than `extensions` (a pre-existing condition from the infrastructure-prerequisites step, re-confirmed still present after `schema.sql`; not caused by or corrected during this step — noted, not silently patched).
- **Security advisor findings after `schema.sql` and `rls.sql`** (`mcp__Supabase__get_advisors`, type `security`): zero ERROR-level findings at any point. All WARN-level findings (`function_search_path_mutable` on every custom function; `anon_security_definer_function_executable`/`authenticated_security_definer_function_executable` on the three reference-number-generator RPCs) are pre-existing characteristics of the source files exactly as written — not introduced by, or unique to, this staging application. Two INFO/WARN items are explicitly by-design per the source file's own comments: `letter_reference_sequences` has RLS enabled with zero policies (write-only via its SECURITY DEFINER generator function, same convention as `reference_sequences`/`entry_reference_sequences`), and `login_attempts_insert`'s `WITH CHECK (true)` is documented in `rls.sql` itself as intentional (Edge-Function-managed logging).
- No blanket `USING (true)` policies exist anywhere in the public schema except the one documented case above.

### 7. Deferred (not performed this step, by instruction)

- The 5-file migration-patch stack (`patch-platform-module-foundation.sql`, `patch-rooms-booking-foundation.sql`, `patch-meetings-foundation.sql`, `patch-rooms-route-activation.sql`, `patch-meetings-route-activation.sql`)
- SQL validation scripts (`validate-*.sql`)
- Exhaustive schema/security verification beyond the advisor scan and object-count checks above (a fuller RLS/route/anonymous-access audit is called for once the migration stack lands)
- Auth configuration
- Edge Function deployment
- Staging test account creation
- Frontend deployment / `js/config.js` and CSP staging swap

All of the above remain correctly sequenced *after* this step, per `docs/18` §2's bootstrap order (steps 1–6 — schema, RLS, buckets, storage policies, pg_cron, notifications — are now complete; step 7, `security-functions.sql`, and step 8, `patch-platform-module-foundation.sql`, are next).

## 12. Confirmation

- No SQL was applied (all queries executed were read-only `SELECT`s against `information_schema`, `pg_catalog`, and `storage.buckets`).
- No storage buckets were created.
- No extensions were installed.
- No Auth settings were changed.
- No Edge Functions were deployed.
- No frontend was deployed.
- Production (`infjjroktzzhaxjvfknr`) was not queried, read, or modified at any point in this step.
- Staging (`vjobntuyzymhcuanyeak`) was read-only for this step — no writes of any kind were issued against it.
