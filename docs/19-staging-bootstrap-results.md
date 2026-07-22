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

## 10. Confirmation

- No SQL was applied (all queries executed were read-only `SELECT`s against `information_schema`, `pg_catalog`, and `storage.buckets`).
- No storage buckets were created.
- No extensions were installed.
- No Auth settings were changed.
- No Edge Functions were deployed.
- No frontend was deployed.
- Production (`infjjroktzzhaxjvfknr`) was not queried, read, or modified at any point in this step.
- Staging (`vjobntuyzymhcuanyeak`) was read-only for this step — no writes of any kind were issued against it.
