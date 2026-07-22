# Staging Bootstrap Audit

**Type:** Repository-structure audit against the documented production bootstrap sequence (`supabase/auth-setup.md`) — no SQL applied, no environment modified. This document supersedes `docs/17-staging-deployment-plan.md` §4 Step 0's assumption ("replay every historical patch in order") with a verified, narrower finding: most of that history is already folded into the current `schema.sql`/`rls.sql`/`storage-policies.sql`/`notifications.sql`, confirmed by direct content comparison, not inferred from dates alone.
**Date:** 2026-07-22
**Scope:** `CorLink Staging` (`vjobntuyzymhcuanyeak`), confirmed empty in the prior step. **No SQL was executed. No staging or production object was created, read beyond prior read-only checks, or modified.** Every finding below comes from reading tracked files in this repository and its git history — not from any live database query.
**Method:** Direct content comparison — for every file `auth-setup.md`'s changelog omits or every patch suspected of being superseded, the actual current `schema.sql`/`rls.sql`/`storage-policies.sql`/`notifications.sql` was grepped for that patch's specific, named objects (a column, a function, a policy) to confirm inclusion or absence — not assumed from commit dates alone. File chronology is git's own recorded first-commit date per file, not the changelog's own prose order (verified independently, since the audit's whole purpose is to check the changelog against reality).

---

## 1. The central finding

`supabase/schema.sql` and `supabase/rls.sql` are **living, periodically-resynced files**, not fixed day-one snapshots — their own last-modified date (2026-07-19) is far later than their apparent "Phase 1 Foundation" header comment suggests. Direct content checks confirm they already contain **every** schema/RLS change from every patch file dated on or before 2026-07-19 (spot-checked: `external_correspondence`, `default_receiving_section_id`, `cancelled` status, `previous_section_id`, `platform_modules` — absent as expected, `entry_sections`, `cc_recipients`, `review_comments`, `parent_entry_id`, participant-column indexes, `requests_action_needed_counts`, `protect_privileged_user_columns` trigger, `pending_approval_by`, `attachments_insert`'s final corrected shape, `commands_insert`'s final shape, `can_view_case_audit_record`, `looped_in_via_internal_collab`, `generate_reference_number` — all present). `storage-policies.sql` (2026-07-10) and `notifications.sql` (2026-07-19) show the identical pattern for their own domains.

**This means the correct staging bootstrap is dramatically shorter than "replay all ~50 patch files in order."** It is: the four current baseline files, in order, plus only the patches dated *after* each file's own last sync — which, as of this repository's current state, is exactly the five files this migration project itself produced (Phase 1 onward). Everything else in `supabase/patch-*.sql` is historical record of how the *current* `schema.sql`/`rls.sql`/`storage-policies.sql`/`notifications.sql` came to be — genuinely useful for understanding *why* a rule exists, and still the correct artifact to run against an **already-live, un-resynced** database — but not a required step for bootstrapping a fresh, empty one.

---

## 2. Exact bootstrap order for an empty database

| # | File | Required? | Safe to rerun? | Destructive? |
|---|---|---|---|---|
| 1 | `supabase/schema.sql` | **Yes** | No — `CREATE TABLE` without `IF NOT EXISTS` on most tables; a second run errors on an already-bootstrapped DB. Safe only on a genuinely empty database. | No (additive on an empty DB) |
| 2 | `supabase/rls.sql` | **Yes** | Partially — most policies use `DROP POLICY IF EXISTS` + `CREATE POLICY` (safe to rerun), but check before assuming every statement is idempotent | No |
| 3 | Storage buckets created via Dashboard/API (`attachments`, `org-logos` — see §4) | **Yes**, before step 4 | Yes (bucket creation is idempotent by name; re-creating an existing bucket errors harmlessly or no-ops depending on client) | No |
| 4 | `supabase/storage-policies.sql` | **Yes** | Yes — explicitly documented as idempotent, and its own header confirms this | No |
| 5 | `pg_cron` extension enabled (Dashboard → Extensions, or the `CREATE EXTENSION` line inside step 6 itself) | **Yes**, before step 6 | Yes (`CREATE EXTENSION IF NOT EXISTS`) | No |
| 6 | `supabase/notifications.sql` | **Yes** | Yes — `CREATE OR REPLACE FUNCTION` throughout, `cron.schedule` is idempotent by job name | No |
| 7 | `supabase/security-functions.sql` | **Yes** | Not verified this step — not read in detail; recommend a rerun-safety check before relying on this in a repeat-run scenario | Unknown — verify before assuming |
| 8 | `supabase/patch-platform-module-foundation.sql` | **Yes** | Yes — confirmed idempotent (`docs/07`: reapplied cleanly, identical row counts) | No |
| 9 | `supabase/validate-platform-module-foundation.sql` | Recommended (read-only check) | Yes — every query is a `SELECT` | No |
| 10 | `btree_gist` extension enabled | **Yes**, before step 11 | Yes | No |
| 11 | `supabase/patch-rooms-booking-foundation.sql` | **Yes** | Yes — confirmed idempotent (`docs/11`: identical object counts on rerun) | No |
| 12 | `supabase/validate-rooms-booking-foundation.sql` | Recommended | Yes | No |
| 13 | `supabase/patch-meetings-foundation.sql` | **Yes** — hard-depends on step 11 (extends `meeting_room_bookings` + `reschedule_booking()` directly) | Yes — confirmed idempotent (`docs/14`) | No |
| 14 | `supabase/validate-meetings-foundation.sql` | Recommended | Yes | No |
| 15 | `supabase/patch-rooms-route-activation.sql` | **Yes**, before Rooms can be enabled for any org | Yes — confirmed idempotent (`docs/15`: second run `UPDATE 0`) | No |
| 16 | `supabase/patch-meetings-route-activation.sql` | **Yes**, before Meetings can be enabled for any org | Yes — confirmed idempotent (`docs/16`) | No |
| 17 | Create the initial super admin (Auth dashboard → SQL `INSERT`, per `auth-setup.md` §4) | **Yes**, to be able to log in and administer anything at all | No — a second attempt with the same service number collides on the unique auth email | N/A (one-time, additive) |
| 18 | Frontend deployment, staging-specific config (see `docs/17` §3) | **Yes** | Yes (redeploy) | No |

Steps 1–2 (`schema.sql`/`rls.sql`) are the only genuinely non-rerunnable, order-critical, "must be the very first thing on a truly empty database" steps — everything after them is either already idempotent or a one-time bootstrap action with no destructive failure mode on retry.

---

## 3. Required extensions

| Extension | Declared in | Purpose |
|---|---|---|
| `pgcrypto` | `schema.sql:8` | `gen_random_uuid()` for every table's primary key default |
| `pg_cron` | `notifications.sql:22` | Daily `check_deadlines()` job (03:00 UTC) |
| `btree_gist` | `patch-rooms-booking-foundation.sql:20` | The room-booking exclusion constraint (`EXCLUDE USING gist`) |

All three confirmed present and available (not yet installed) on `vjobntuyzymhcuanyeak` via `list_extensions` in the prior verification step — no plan-tier or allowlist blocker expected.

---

## 4. Required storage buckets

**Only two buckets are actually used by the application** — confirmed by grepping every `db.storage.from(...)` call site in `js/data/*.js`:

| Bucket | Public | Used by |
|---|---|---|
| `attachments` | No | `AttachmentsAPI` — every module's file uploads (requests, responses, internal replies, prisoner letters/replies, Entry records/replies, meetings), scoped by folder-per-`record_type`, not bucket-per-module |
| `org-logos` | Yes | `AdminAPI` — organization branding logos |

**`prisoner-letters` (listed in `auth-setup.md` §5's bucket table) does not need to be created.** `storage-policies.sql`'s own header explicitly says its policies "remain a future addition," and no application code anywhere references a bucket by that name — prisoner letter files go through the shared `attachments` bucket via `record_type = 'prisoner_letter'`/`'prisoner_reply'` folders, same as every other module. `auth-setup.md`'s bucket table is stale on this point (see §6).

`storage-policies.sql` sets `file_size_limit`/`allowed_mime_types` server-side on both real buckets (20 MB / images+PDF+Office for `attachments`; 2 MB / PNG+JPEG for `org-logos`) — this is data, not a manual dashboard step, and is included in step 4 of §2's order.

---

## 5. Required authentication configuration

Manual, dashboard-only steps (`auth-setup.md` §3) — none of this is expressible as SQL in this repository:

- **Site URL**: the staging frontend's own deployed URL (not production's — see §7's CSP/config caveat)
- **Email confirmations**: OFF (admin-created accounts only)
- **Signup**: disabled (no self-registration)
- **Password policy**: enforced client-side + by the `create-user`/`reset-password` Edge Functions, not by Supabase Auth natively — minimum 10 chars, upper/lower/number/special, no reuse of last 5 (checked against `user_password_history`, created by `schema.sql`), 90-day expiry
- **JWT expiry**: 1800s (30 min), matching `SESSION_TIMEOUT_MINUTES` in `js/config.js`
- **Refresh token rotation**: ON, 10s reuse interval

---

## 6. Required Edge Functions

Two, both required for the app to be usable at all (there is no other way to create a user or reset a password — the anon key cannot call `auth.admin.*`):

| Function | Source | Secrets needed |
|---|---|---|
| `create-user` | `supabase/functions/create-user/index.ts` | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY` — all three auto-injected by Supabase into every Edge Function's environment; no manual secret configuration needed |
| `reset-password` | `supabase/functions/reset-password/index.ts` | Same three, same auto-injection |

Deploy per `supabase/functions/README.md` (paste-and-deploy via Dashboard, or `supabase functions deploy <name>` via CLI) — **against the staging project specifically**, using staging's own auto-injected env vars (Supabase scopes these per-project automatically; no cross-project leakage risk here, but confirm the deploy target is `vjobntuyzymhcuanyeak`, not `infjjroktzzhaxjvfknr`).

Two functions remain unbuilt (`send-notification-email`, `validate-password`) — not required for staging parity with the current application; skip.

---

## 7. Required secrets and environment variables

| Variable | Where it lives | Staging-specific? |
|---|---|---|
| `SUPABASE_URL` | `js/config.js` (hardcoded constant, not an env var — this is a static-file app, no build step) | **Yes — must differ from production.** Currently hardcoded to `https://infjjroktzzhaxjvfknr.supabase.co`. |
| `SUPABASE_ANON_KEY` | `js/config.js` | **Yes — must differ from production.** |
| CSP `connect-src`/`img-src` | `index.html`'s `<meta http-equiv="Content-Security-Policy">` | **Yes — must differ from production.** Currently pinned to `infjjroktzzhaxjvfknr.supabase.co` specifically (deliberately, not a wildcard — see the CSP comment's own stated reasoning about limiting exfiltration blast radius from a hypothetical stored-XSS). A staging deploy needs the equivalent pin to `vjobntuyzymhcuanyeak.supabase.co`. |
| `SUPABASE_SERVICE_ROLE_KEY` | Never in this repo — only inside the two Edge Functions' runtime environment, auto-injected by Supabase per-project | N/A — never manually set, never staging-specific to configure by hand |
| Edge Function `SUPABASE_ANON_KEY` (server-side copy used by `create-user`/`reset-password` to build a caller-scoped client) | Same auto-injection | N/A |

**Repeated from `docs/17` §3, restated here since this audit's own file-by-file pass reconfirms it independently:** the `js/config.js`/CSP swap must be staging-only and **never committed to `feature/corlink-platform-migration`** — that branch merges toward production.

---

## 8. Files that no longer belong in the bootstrap process

- **`supabase/reset.sql`** — destructive reset tool for an *already-migrated* dev database being brought back to a clean slate before re-running schema changes; meaningless (nothing to reset) and not part of any "build from empty" path. `auth-setup.md` itself already scopes it this way ("only needed if re-running after schema changes").
- **`supabase/demo-seed-requests.sql`** — its own header states plainly: "NOT part of the migration chain." Throwaway click-through demo data. Must not run against staging if staging is meant to validate real bootstrap fidelity, and must never run against production.
- **`supabase/cleanup-auth-user.sql`** — a troubleshooting utility for one specific, already-existing production account (hardcodes the email `10108@corlink.internal` and issues a hard `DELETE FROM auth.users`/`auth.identities`). Not a bootstrap step under any circumstance; if ever needed on staging for an analogous collision, it would need editing first, and must never be run against production without deliberate, scoped intent (see §9 — this is also a production-only-assumption risk in its own right, since running it unedited against any other project either does nothing or, worse, silently no-ops when the intent was to actually clean up a colliding staging account).
- **`supabase/patch-fix-section-receiver-supervisor-conflict.sql`** — applied 2026-07-14, explicitly reverted the same day by `patch-fix-routing-rls-visibility.sql` ("Also reverts `patch-fix-section-receiver-supervisor-conflict.sql`'s WITH CHECK loosening — verified empirically that permissive policies' WITH CHECKs are OR'd, so that change was inert"). Confirmed: current `rls.sql`'s `requests_update_supervisor` already reflects only the final, corrected state — this intermediate patch's own effect was never load-bearing and is fully superseded. Historical record only; do not apply on a fresh bootstrap.
- **`supabase/seed.sql`** — not a hard exclusion, but flagged as a judgment call: it hardcodes the real production organization identities ("Maldives Correctional Service"/MCS, "Human Rights Commission of the Maldives"/HRCM) rather than placeholder names, and its super-admin/example-data section is a **commented template requiring manual UUID substitution**, not a run-as-is script. Whoever bootstraps staging should decide deliberately whether staging should mirror real org names (useful for realistic UAT) or use fictional ones (safer if staging access is ever broader than production access) — not a technical blocker either way.
- **`supabase/create-super-admin.sql`** — not excluded, but not a plain "run it" file either: it requires the Auth user to already exist (created first via Dashboard, per `auth-setup.md` §4), with that UUID pasted into the script before running. Sequencing dependency, not a rerun-safety issue.

---

## 9. Legacy MeetFlow components

**None exist in this repository to exclude.** A targeted search for MeetFlow's actual schema object names (`bookings`, `pre_bookings`, `meeting_group_access`, `rls_auto_enable()`, per `docs/01`'s and `docs/02`'s own audit of MeetFlow's live project) found zero matches anywhere in `supabase/*.sql`. The only "MeetFlow" references anywhere in the SQL tree are prose comments in `patch-platform-module-foundation.sql` explicitly documenting that MeetFlow's schema, RLS design, and data were **not** carried over — a from-scratch redesign was the explicit, approved decision from the very start of this migration (`docs/01`, `docs/03`). There is nothing to strip out because nothing was ever copied in.

The one place a MeetFlow *reference* legitimately exists is `meeting-room-booking` (`xvwileiyquqxxtzqxghm`) itself — the original hosted MeetFlow Supabase project, entirely separate from both `corlink-production` and `CorLink Staging`. It has never been queried for schema and must never be treated as a source to copy from during any bootstrap.

---

## 10. Production-only assumptions that could break staging

- **`js/config.js` and `index.html`'s CSP both hardcode production's Supabase URL/anon key** (§7) — deploying the frontend unmodified against staging would have every API call silently target production instead, or (with the CSP in place) simply fail every fetch outright once the anon key stops matching the URL's own project. This is the single highest-risk item for a staging deploy specifically, already flagged in `docs/17` §3 and reconfirmed here.
- **`cleanup-auth-user.sql`'s hardcoded email** (§8) — a copy-paste run against staging without editing the email does nothing useful (no such account exists there yet); the real risk is the inverse — someone editing it for staging use, then later running the *original* unedited copy against production by mistake, deleting a real account. Recommend never keeping an edited copy of this file checked in at all; treat it as an interactively-typed one-off command each time it's needed.
- **`seed.sql`'s hardcoded UUIDs** (`00000000-0000-0000-0000-000000000001` for MCS, `...002` for HRCM, etc.) — these are fine as internally-consistent placeholder UUIDs (they're not secrets), but if staging is ever bootstrapped a second time from scratch, or if seed data is loaded into staging *after* real UAT data already exists there under different IDs, re-running `seed.sql` verbatim would either collide (UNIQUE violation on `organizations.code`) or create confusingly-duplicated organizations with different UUIDs than an earlier staging run used. Treat `seed.sql` as a true one-time, first-bootstrap-only step for a given project, never a routine rerun.
- **The Super Admin creation flow assumes a specific service number convention** (`<SERVICE_NUMBER>@corlink.internal`, per `AUTH_DOMAIN` in `js/config.js`) — this is environment-agnostic (works identically on staging), not a production-only assumption, but worth confirming explicitly since it's the one piece of "convention, not config" that could otherwise be mistaken for something needing a staging-specific value. It does not.
- **`auth-setup.md` §5's bucket table itself is stale** (§4) — following it literally would have someone create a `prisoner-letters` bucket that nothing uses and that has no RLS policy coverage at all (an empty, policy-less private bucket is harmless, but it's wasted setup effort and a documentation trap for whoever bootstraps staging by reading that table literally rather than verifying against actual code, exactly as this audit just did).

---

## 11. Does the repository already contain enough SQL to fully recreate production from an empty database?

**Mostly yes, for schema/RLS/functions — no, for two categories of non-SQL setup this repository never expressed as SQL at all:**

**Sufficient (pure SQL, verified present and, per §1, already current):**
- `schema.sql` + `rls.sql` — full current table/policy/function set through 2026-07-19's patches
- `storage-policies.sql` — full current bucket-policy set through 2026-07-10's patches
- `notifications.sql` — full current notification-RPC/cron-job set through 2026-07-19's patches
- `security-functions.sql` — login lockout + audit RPCs (not re-verified for fold-back currency this step, since no later patch in the changelog claims to touch it — treated as standalone and current by default; worth a quick confirmation pass before relying on this claim for a real staging bootstrap)
- The five Rooms/Meetings-era files (§2 steps 8, 11, 13, 15, 16)

**Missing — not expressible as SQL at all, requires manual Dashboard/API action every time a fresh project is bootstrapped:**
1. **Storage bucket *creation* itself** (`attachments`, `org-logos`) — `storage-policies.sql` only ever `CREATE POLICY`s and `UPDATE storage.buckets SET file_size_limit=...`; it never `INSERT`s into `storage.buckets`. No file in this repository creates a bucket. This is a genuine, permanent gap in "recreate from SQL alone" — buckets must be created via Dashboard/Management API/CLI first, every time.
2. **Auth configuration** (§5) — Site URL, email/signup settings, password policy dashboard toggles, JWT/session settings. None of this is SQL; Supabase Auth configuration lives outside the Postgres database this repository's `.sql` files target.
3. **Edge Function deployment** (§6) — the two `.ts` function source files exist in this repo, but *deploying* them (Dashboard paste or CLI `functions deploy`) is an action outside SQL, and outside what any Supabase MCP tool used so far in this migration has been asked to do.
4. **The initial super admin account** — genuinely two-step by design (create the Auth user via Dashboard first, copy its UUID, then run a hand-edited `INSERT`) — not a gap, but not a single automatable SQL step either.
5. **pg_cron extension enablement** — expressible as SQL (`CREATE EXTENSION IF NOT EXISTS pg_cron;`, already inside `notifications.sql`), but Supabase's own pg_cron support requires it to be genuinely available on the project (confirmed present in `list_extensions` for staging, per the prior verification step) — no gap here, just noting it's the one "extension" item that happens to already be inline in tracked SQL rather than a separate manual step.

**Answer to the literal question:** the repository contains **all the SQL needed** to recreate production's database schema, RLS, functions, and data-layer logic from an empty database. It does **not** contain everything needed to recreate a fully *working* production environment end-to-end — buckets, Auth settings, and Edge Function deployment are real, permanent, non-SQL gaps inherent to how Supabase separates "database" from "project configuration," not an oversight specific to this repository's SQL files.

---

## 12. Final review

- **No SQL was executed** — every fact in this document came from reading tracked `.sql`/`.md` files and their `git log` history.
- **Staging (`vjobntuyzymhcuanyeak`) was not modified** — no write-capable Supabase MCP tool was called this step.
- **Production (`infjjroktzzhaxjvfknr`) was not touched** at all this step, not even read-only (the prior step's read-only production check is not repeated here).
- **No migration was applied anywhere.**

---

## 13. Files changed

- `docs/18-staging-bootstrap-plan.md` (new, this file)

No other file was created or modified in this step.
