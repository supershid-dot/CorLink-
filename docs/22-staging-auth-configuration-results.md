# 22 — Staging Auth Configuration: Assessment and Verification Results

**Status:** Assessment and read-only verification only. **No Auth setting was changed. No user was created. No Edge Function was invoked. No frontend was deployed. Production (`infjjroktzzhaxjvfknr`) and MeetFlow (`xvwileiyquqxxtzqxghm`) were not contacted.**
**Date:** 2026-07-22
**Target verified:** staging (`vjobntuyzymhcuanyeak`, "CorLink Staging") — confirmed via `list_projects` immediately before any read, and re-confirmed distinct from `infjjroktzzhaxjvfknr` ("corlink-production") and `xvwileiyquqxxtzqxghm` ("meeting-room-booking").

---

## 1. Important limitation — what this step could and could not verify

Supabase's Auth *dashboard* settings (Site URL, Redirect URLs, enabled providers, email template contents, JWT expiry, refresh-token rotation/reuse interval) are **not** stored in any Postgres table reachable by SQL, and are **not** exposed by any Supabase MCP tool available in this session (`list_projects`, `get_project`, `get_project_url`, `get_publishable_keys`, `get_advisors`, `execute_sql`, `list_edge_functions`, `list_tables`, `list_extensions`, `list_migrations`, `list_branches`, `get_logs`, `list_organizations`, `get_organization`, `get_cost`, `confirm_cost`, `create_project`, `create_branch`, `deploy_edge_function`, `generate_typescript_types`, `pause_project`, `restore_project`, `merge_branch`, `rebase_branch`, `reset_branch`, `delete_branch`, `search_docs`). None of these read or return GoTrue configuration.

A read-only query against `information_schema.tables` for schema `auth` was run to check for a possible `auth.config` table (as exists in some self-hosted GoTrue versions). **No such table exists** on this hosted project — confirming these settings are managed entirely through Supabase's platform Auth Settings page / Management API, neither of which this session has credentials or tool access to.

**Consequence:** Site URL, Redirect URLs, enabled-provider toggle states, email template contents, JWT expiry value, and refresh-token rotation/reuse-interval settings **cannot be authoritatively confirmed from this session**. Everything in §2 below distinguishes what was actually verified live (via read-only SQL against `auth.*` tables) from what is stated only as the documented requirement (from `docs/20` §8 and `supabase/auth-setup.md` §3), pending manual confirmation via the Supabase Dashboard by someone with console access.

---

## 2. Current Auth state

### 2a. Verified live (read-only SQL against staging, 2026-07-22)

| Check | Result |
|---|---|
| `auth.users` row count | **0** |
| `auth.identities` row count | **0** |
| `auth.sso_providers` row count | **0** |
| `auth.saml_providers` row count | **0** |
| `auth.oauth_clients` row count | **0** |
| `auth.mfa_factors` row count | **0** |

This confirms: no user or identity of any kind exists yet (matches `docs/19`/`docs/20`'s "zero users" baseline, re-verified live this step, not merely restated), and no SSO/SAML/custom-OAuth provider or MFA factor has ever been used on this project — consistent with, though not itself conclusive proof of, "only Email/Password is enabled" (a provider can be toggled on with zero rows if unused).

`get_advisors` (security) was also run against staging: 181 lints returned, none of which are Supabase's Auth-*config* lint names (e.g. `auth_otp_long_expiry`, `auth_leaked_password_protection`, `auth_insufficient_mfa_options`) — only schema-level lints (`rls_enabled_no_policy`, `function_search_path_mutable`, `*_security_definer_function_executable`, etc.), which are out of scope for this Auth-configuration step and not reported further here.

### 2b. Documented requirement, not independently confirmable this step (from `docs/20` §8 / `auth-setup.md` §3)

| Setting | Required value | Live status |
|---|---|---|
| Site URL | Staging frontend's deployed URL | **Cannot be set — URL doesn't exist yet.** Blocked on frontend deployment (out of scope). Current live value unknown (still whatever the project's default was on creation — unverifiable this step). |
| Redirect URLs | Same staging URL(s) | Same blocker as Site URL. |
| Enabled providers | Email/password only, no OAuth/SSO | No OAuth/SSO/SAML provider has ever had a row created on this project (§2a), consistent with the requirement, but the dashboard toggle state itself is unverified. |
| Email confirmations | OFF | Unverified — dashboard-only setting. |
| Disable signup | ON | Unverified — dashboard-only setting. |
| Email templates | Likely no changes needed (app never relies on Supabase's own auth-email flows) | Unverified — dashboard-only setting; not yet inspected even at the template-content level, per `docs/20` §8's own note. |
| Password policy (Supabase-native) | N/A — CorLink enforces its own policy client-side + via Edge Function, not through Supabase Auth's native policy field | N/A to dashboard config; already correctly implemented in `create-user`/`reset-password` (verified by reading their source in the prior step) and requires no Auth-dashboard action. |
| JWT expiry | 1800s (30 min), matching `SESSION_TIMEOUT_MINUTES` in `js/config.js` | Unverified — dashboard-only setting; still presumed at Supabase's project default per `docs/20` §8, not re-confirmed live this step. |
| Refresh token rotation | ON, 10s reuse interval | Unverified — dashboard-only setting; same caveat as JWT expiry. |

---

## 3. Comparison against `docs/20` requirements

| Requirement source | Status |
|---|---|
| `docs/20` §8 Site URL / Redirect URLs | **Blocked** — frontend not deployed, so the correct value isn't yet knowable, let alone settable. |
| `docs/20` §8 Email templates | **Deferred, likely no-op** — app has no self-registration/email-confirmation flow, so low priority; still not inspected at the template-content level. |
| `docs/20` §8 Enabled providers | **Likely already correct by default** (Supabase projects default to email/password enabled, no OAuth configured) — but the toggle state itself needs a live Dashboard check to move from "likely" to "confirmed." |
| `docs/20` §8 JWT expiry (1800s) | **Not yet set** — requires an explicit Dashboard change from Supabase's default (typically 3600s) to 1800s. |
| `docs/20` §8 Refresh token rotation (ON, 10s) | **Not yet set** — requires an explicit Dashboard change. |
| `docs/20` §8 Password policy | **N/A to Auth dashboard** — already correctly handled in application code (Edge Functions + client-side), confirmed by source reading in the prior deployment step. |
| `docs/20` §9 item 2 — super admin bootstrap | **Blocked**, dependency: needs Edge Functions (done) → this Auth assessment (this step) → actual Dashboard settings applied → then the one-time manual `create-super-admin.sql` escape hatch. |

---

## 4. Settings already correct / missing / blocked / should stay default

**Already correct (by design, needs no change):**
- Password policy enforcement — lives entirely in `create-user`/`reset-password` and client-side, not Supabase Auth's native (weaker) policy field. No Auth-dashboard action needed or wanted here.
- Zero users/identities/SSO/OAuth/SAML/MFA rows — matches the intended pre-bootstrap staging state exactly; nothing to clean up.

**Missing (requires an explicit, future, separately-authorized Dashboard/Management-API step):**
- JWT expiry → 1800s.
- Refresh token rotation → ON, 10s reuse interval.
- Email confirmations → OFF (should be verified even though it's Supabase's typical default, not assumed).
- Disable signup → ON (same — verify, don't assume).

**Blocked (cannot be correctly set yet, dependency not met):**
- Site URL — no staging frontend URL exists yet.
- Redirect URLs — same blocker.

**Should remain at defaults / no action planned:**
- Enabled providers beyond email/password — no OAuth/SSO/SAML is used anywhere in this codebase; nothing to enable.
- Email template contents — likely no changes needed given no self-registration/confirmation flow is ever triggered by this app; flagged for a future low-priority look, not a required change.

---

## 5. Recommended configuration order (planning only — not executed this step)

1. Deploy the staging frontend (out of scope for this document) to obtain a real Site URL.
2. Set Site URL + Redirect URLs to that value.
3. Explicitly verify (not assume) Email confirmations = OFF and Disable signup = ON in the Dashboard.
4. Set JWT expiry to 1800s.
5. Set refresh token rotation ON with a 10s reuse interval.
6. Only after 1–5: proceed with the super-admin bootstrap escape hatch (`docs/18` §8/§11, `docs/20` §4 last row) — creating the first Auth user via Dashboard, then hand-running `create-super-admin.sql`.
7. Only after 6: proceed with `docs/20`'s remaining 6 test accounts via the now-deployed `create-user` function.

This order is unchanged from `docs/20` §9's dependency chain — this step did not alter that sequencing, only re-confirmed where staging currently sits within it.

---

## 6. Risks

| Risk | Severity | Note |
|---|---|---|
| Proceeding to create the super admin before Site URL/redirect URLs are set | Medium | Login/password-reset redirect flows could point at an unconfigured or wrong URL once a frontend exists. Not an immediate risk today since no frontend is deployed and no user exists yet. |
| Assuming Supabase's default JWT expiry/refresh-token settings without confirming them live | Low–Medium | If the project default differs from what's assumed, sessions could last longer (or rotate differently) than `SESSION_TIMEOUT_MINUTES` intends, until explicitly set. No user exists yet, so no live exposure today. |
| This assessment step could not read live Dashboard values | Low (process risk, not security risk) | Means step 3 above ("explicitly verify") in §5 is not optional — the next execution step must actually open the Dashboard/Management API, not rely on this document's "likely correct" language. |
| No new security risk introduced by this step | — | This step made no write of any kind; only read-only SQL and read-only MCP calls were executed. |

---

## 7. Prerequisites before any user creation

1. Frontend deployed to staging (provides the real Site URL/Redirect URL value) — **not yet done, out of scope for this document.**
2. Site URL / Redirect URLs set in the Supabase Dashboard to match.
3. JWT expiry and refresh-token rotation settings explicitly confirmed or set to match `docs/20` §8.
4. Only then: the one-time super-admin bootstrap escape hatch (Dashboard-created Auth user + hand-run `create-super-admin.sql`), which is itself a separate, explicitly-authorized step, not performed here.
5. Only then: the remaining 6 test accounts via `create-user` (already deployed and confirmed ACTIVE on staging, per `docs/21`'s deployment-results section).

**None of steps 1–4 were performed in this document.** This is a read-only assessment and live-verification step only.

---

## 8. Confirmation of constraints honored

- No Auth setting was changed — no write of any kind was made to staging's Auth configuration (none was even possible from this session, per §1).
- No user was created — confirmed live via `auth.users` count = 0, both before and after this step (this step performed no insert).
- No Edge Function was invoked — `create-user`/`reset-password` were not called.
- No frontend was deployed.
- Production (`infjjroktzzhaxjvfknr`) was not contacted, read, or modified.
- MeetFlow's project (`xvwileiyquqxxtzqxghm`) was not contacted, read, or modified.
- No push occurred; no Git signing configuration was changed.

---

## 9. Files changed

- `docs/22-staging-auth-configuration-results.md` (new, this file)

No other file was created or modified in this step.
