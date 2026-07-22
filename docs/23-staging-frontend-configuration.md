# 23 — Staging Frontend Configuration: Preparation and Local Validation

**Status:** Repository changes and local validation only. **No frontend was deployed anywhere. No Auth setting was changed. No user was created. No Edge Function was invoked. Staging (`vjobntuyzymhcuanyeak`), production (`infjjroktzzhaxjvfknr`), and MeetFlow (`xvwileiyquqxxtzqxghm`) were not contacted by any tool call in this step.**
**Date:** 2026-07-22
**Scope:** Introduces the smallest maintainable mechanism for this static, no-build-step frontend to target production, staging, or local Supabase projects without ever hand-editing `js/config.js` or `index.html`, and without committing any staging-specific value to this branch.

---

## 1. Inventory of hardcoded, production-specific values (before this step)

A full-repository search (`js/**/*.js`, `index.html`, and a check for any hosting/deployment config file such as `netlify.toml`, `vercel.json`, or a `.github/workflows/*` file — none exist) found exactly these hardcoded, environment-specific values:

| Value | Location | Notes |
|---|---|---|
| `SUPABASE_URL` | `js/config.js:4` (was line 4, now shifted by an added comment) | `https://infjjroktzzhaxjvfknr.supabase.co` — CorLink production's project URL. |
| `SUPABASE_ANON_KEY` | `js/config.js:5` | Production's anon/publishable key (a legacy JWT-format anon key). Public by design — safe to ship in a client bundle, protected by RLS, not a secret. |
| CSP `img-src` Supabase origin | `index.html` `<meta http-equiv="Content-Security-Policy">` | `https://infjjroktzzhaxjvfknr.supabase.co` |
| CSP `connect-src` Supabase origin(s) | Same meta tag | `https://infjjroktzzhaxjvfknr.supabase.co` and `wss://infjjroktzzhaxjvfknr.supabase.co` |

**Checked and found absent / not applicable:**
- **Edge Function base URL** — no separate hardcoded value exists. `js/data/admin-api.js`'s two `db.functions.invoke('create-user'|'reset-password', …)` calls go through the same Supabase client `supabase-client.js` builds from `SUPABASE_URL`, so there is nothing extra to parameterize here.
- **Redirect URLs** — none are referenced in frontend code at all. This app never uses Supabase's magic-link/OAuth redirect flow (service-number + password login only, per `js/auth.js`), so there is no `redirectTo`/callback URL hardcoded anywhere to extract. (Auth-dashboard-side Site URL/Redirect URL settings are a separate, already-documented concern — see `docs/22` §2b — not a frontend source-code value.)
- **Asset/API origins other than Supabase** — Google Fonts (`fonts.googleapis.com`/`fonts.gstatic.com`) and jsDelivr (`cdn.jsdelivr.net`, for Supabase JS + Tabler Icons) are the same across every environment by design; nothing to parameterize.
- **Production organization IDs or email addresses** — none found as functional config. The only email-shaped strings in the JS tree (`info@corrections.gov.mv` in `js/views/entry.js` and `js/data/entry-api.js`) are illustrative prose inside code comments describing what the Entry module is for, not a live, used value anywhere in executable code.
- **`AUTH_DOMAIN` (`corlink.internal`)** — not environment-specific; this is a fixed, synthetic login-identity convention used identically in every environment by design (already noted in `docs/21` §3), not a value that should vary between staging/production.

---

## 2. Configuration approach implemented

A static, no-build-step SPA can't select an environment at request time via a bundler or server-side template, and a `<meta http-equiv="Content-Security-Policy">` tag cannot be widened by client-side JS after the page has started loading (CSP directives can only ever be narrowed post-parse, never loosened) — so environment selection has to happen as a **deploy-time file transform**, not a runtime branch. This mirrors a convention `index.html` already uses for its own cache-buster (`sed -i 's/?v=[0-9]\{8\}/?v=YYYYMMDD/g' index.html`, documented in its own comment) — this step extends that same idea rather than introducing a new one.

### New files

| File | Tracked? | Purpose |
|---|---|---|
| `config/environments/production.env` | **Yes** | The exact values already committed in `js/config.js` today (no new exposure — this is a copy, not a new secret). Exists purely so the swap script has a single source of truth. |
| `config/environments/staging.env.example` | **Yes** (template) | Placeholder-only. Copy to `config/environments/staging.env` (gitignored) and fill in staging's real public URL/key to enable a staging deploy. |
| `.env.local.example` | **Yes** (template) | Same idea, for personal local development. Copy to `.env.local` (already gitignored before this step — see `.gitignore`). |
| `scripts/set-frontend-environment.sh` | **Yes** | The swap script itself (bash + sed only, no new dependency — matches this repo's existing zero-tooling frontend). |

### Files never committed with real staging/local values

- `config/environments/staging.env` and `.env.local` are both gitignored (the latter already was; `.gitignore` now also excludes `config/environments/staging.env` and any `config/environments/*.local.env`). This directly implements the warning already recorded in `docs/17` §3 item 2: a real staging URL must never land in a commit on a branch that's also destined for production, because that branch reaching production would otherwise risk shipping the wrong backend. `config/environments/production.env`, by contrast, is safe to track: its values are already public and already committed (today, in `js/config.js`), so tracking a second copy of the same already-public values changes nothing about production's exposure.

### How the swap works

`scripts/set-frontend-environment.sh <production|staging|local>`:
1. Resolves the right source file (`config/environments/production.env`, `config/environments/staging.env`, or `.env.local`).
2. Fails loudly (see §4) if that file is missing, missing a required key, or still holds a `REPLACE_WITH_…` placeholder.
3. Replaces `js/config.js`'s `SUPABASE_URL`/`SUPABASE_ANON_KEY` const lines and `index.html`'s CSP Supabase origin (wherever it currently points) with the target environment's values, via `sed -i`, then removes the `.bak` files it creates.
4. Prints an explicit reminder not to commit the result to a shared branch.

This is meant to run against a disposable build/deploy checkout for one environment at a time — never against `feature/corlink-platform-migration` itself as a permanent edit. Running it with `production` as the argument is a no-op in practice today, since the committed defaults already match.

### Why CSP still pins to a single origin (not both production and staging at once)

`index.html`'s own existing design comment already explains why `connect-src`/`img-src` are pinned to one specific project subdomain instead of the broader `https://*.supabase.co` wildcard: limiting a hypothetical stored-XSS payload's exfiltration blast radius to one project. Permanently listing **both** production's and staging's origins in the same shipped CSP — so one file could serve either backend without a swap — would double that blast radius for every deployment, including production, which is a real weakening of an already-deliberate protection, not a neutral convenience. The swap script instead keeps single-origin pinning intact and simply changes *which* origin is pinned depending on deploy target, satisfying "the staging origin can be used" without touching (or duplicating into) any other directive — `script-src`, `style-src`, `font-src`, `object-src`, `base-uri`, and `frame-ancestors` are all untouched by the script, by design (it only ever rewrites the Supabase-origin string(s)).

### Requirements checklist

| Requirement | How it's met |
|---|---|
| Support local, staging, production | Three named environments, resolved by the same script. |
| No service-role keys or secrets committed | Only `SUPABASE_URL`/`SUPABASE_ANON_KEY` ever appear in any of these files — checked explicitly (§5). |
| Only public URL/anon key in frontend config | Same — the env-file format has exactly these two fields, nothing else. |
| Preserve production behavior by default | `js/config.js`/`index.html`'s committed, at-rest values are completely unchanged from before this step; a checkout deployed with zero extra steps behaves identically to today. |
| Staging deployable without editing source files | The swap script edits `js/config.js`/`index.html` programmatically; a deployer only fills in a gitignored `.env`-style file and runs one command. |
| Fail clearly when required config is missing | Both the script (missing file / missing key / placeholder value → non-zero exit with a specific message) and the runtime (`js/supabase-client.js`'s `getSupabase()`, extended — see below) refuse to proceed silently. |
| Compatible with the current non-framework architecture | Bash + `sed` only; no bundler, no `package.json`, no build step introduced. |

### Runtime guard extended (`js/supabase-client.js`)

`getSupabase()`'s existing check only validated `SUPABASE_URL` against the single literal `'YOUR_SUPABASE_URL'`. Extended to also validate `SUPABASE_ANON_KEY`, and to recognize any `REPLACE_WITH_…`-prefixed placeholder (the convention every template file above uses) as "not configured," with a clearer error message pointing at the new script and this document. Production's real values pass both checks unchanged.

---

## 3. CSP changes

Only the **explanatory comment** above the CSP meta tag was changed, to describe the new deploy-time swap mechanism instead of implying manual editing ("If you deploy to a different Supabase project, update the ref here to match" → now points at `scripts/set-frontend-environment.sh` and this document). **The CSP directive values themselves are byte-for-byte unchanged** — `default-src`, `script-src`, `style-src`, `font-src`, `object-src`, `base-uri`, `frame-ancestors` are untouched, and `img-src`/`connect-src` still pin to exactly one Supabase origin (today, still production's, since no swap has been run against this checkout).

---

## 4. Local validation performed

All checks below were run against this repository checkout; where a test required non-production values, it ran against a **disposable scratch copy** (under this session's scratchpad directory), never against the tracked working tree, so the committed state stays exactly at production defaults throughout.

1. **Syntax checks** — `node --check js/config.js` and `node --check js/supabase-client.js`: both pass, no syntax errors.
2. **Existing frontend tests** — none exist in this repository (`package.json`, `*.test.js`, `*.spec.js` all absent, confirmed by search) — nothing to run; noted rather than silently skipped.
3. **Production default still resolves correctly** — confirmed `js/config.js`'s committed `SUPABASE_URL`/`SUPABASE_ANON_KEY` and `index.html`'s CSP origin still read the real, original `infjjroktzzhaxjvfknr.supabase.co` values, unchanged by this step.
4. **Staging configuration selectable with test values** — in a scratch copy: created a `config/environments/staging.env` with fabricated test values (`https://test-staging-project.supabase.co` / a dummy anon-key-shaped string), ran `scripts/set-frontend-environment.sh staging`, and confirmed both `js/config.js` and the CSP origin in the scratch copy's `index.html` were rewritten to the test values, with every other CSP directive byte-identical to before.
5. **Missing configuration fails safely** — in the same scratch copy: (a) ran the script with no `config/environments/staging.env` present at all → non-zero exit, clear "not found" message, no file modified; (b) ran it with `staging.env` still containing the shipped `REPLACE_WITH_STAGING_SUPABASE_URL` placeholder → non-zero exit, clear "still contains placeholder values" message, no file modified; (c) ran it with an unrecognized environment name → usage message, non-zero exit.
6. **No service-role key or secret added** — `grep -ri "service_role\|SERVICE_ROLE_KEY" config/environments/ .env.local.example scripts/set-frontend-environment.sh` returned no matches; every new file's diff was manually reviewed and contains only `SUPABASE_URL`/`SUPABASE_ANON_KEY` fields or prose.

None of these checks modified the tracked working tree's effective configuration — `git status`/`git diff` after validation shows only the intended new/changed files listed in §6, with production's own values still exactly as committed before this step.

---

## 5. Which values are public/safe vs. must never enter frontend code

**Safe to expose in frontend config (public by Supabase's own design):**
- Supabase project URL (`SUPABASE_URL`)
- Supabase anon/publishable key (`SUPABASE_ANON_KEY`) — protected by RLS, meant to ship in every client

**Must never enter frontend code, any committed file, or this configuration mechanism:**
- `SUPABASE_SERVICE_ROLE_KEY` (or any service-role key) — server-side only, used exclusively by `create-user`/`reset-password` Edge Functions via `Deno.env.get(...)`, auto-injected by the Supabase Edge Runtime, never referenced by any frontend file
- Any database connection string, JWT signing secret, or third-party API key (none currently exist in this app's scope)

---

## 6. Usage

### Production
No action needed. `js/config.js`/`index.html` already ship with production's values; `scripts/set-frontend-environment.sh production` is a no-op confirmation, not a required step.

### Staging
```
cp config/environments/staging.env.example config/environments/staging.env
# edit config/environments/staging.env, filling in staging's real public
# SUPABASE_URL / SUPABASE_ANON_KEY (already known from docs/19 §2 /
# docs/21's deployment-results section — vjobntuyzymhcuanyeak.supabase.co
# and its anon key, fetched during that step but deliberately not
# committed to this branch — see §1's rationale above)
scripts/set-frontend-environment.sh staging
```
Deploy the resulting working copy to staging's own hosting target; do not commit the result back to `feature/corlink-platform-migration`.

### Local development
```
cp .env.local.example .env.local
# edit .env.local with your own local/personal Supabase project's values
scripts/set-frontend-environment.sh local
```

### Hosting/deployment requirements
- Static file hosting only (no server-side rendering, no build step) — matches the existing GitHub Pages target.
- Whoever deploys staging still needs, separately from this step: a real hosting location for the staging frontend (its own URL — deliberately **not invented here**, per instruction; still blocked, per `docs/20` §8 and `docs/22` §2b/§4), and the staging Auth Site URL/Redirect URL settings to be pointed at that URL once it exists.

---

## 7. Remaining deployment inputs still needed (not resolved by this step)

- A real, deployed staging frontend hosting URL — does not exist yet; this step deliberately does not invent one (task instruction 6). Once it exists, it becomes both the Site URL Auth setting (`docs/22` §5 step 2) and (if this app ever gains a redirect-based flow) a redirect URL.
- Someone with access must actually fill in `config/environments/staging.env` with staging's real public values before `scripts/set-frontend-environment.sh staging` can be used for a real deploy — deliberately left as a placeholder-only template on this branch (§1's rationale).
- The staging Auth Dashboard settings identified as still missing in `docs/22` (JWT expiry, refresh-token rotation, explicit confirmation of email-confirmation/signup toggles) remain outstanding and unrelated to this step's frontend-only scope.

---

## 8. Confirmation of constraints honored

- The frontend was not deployed anywhere.
- No Auth setting was changed; no user was created.
- No Edge Function was invoked.
- Staging (`vjobntuyzymhcuanyeak`), production (`infjjroktzzhaxjvfknr`), and MeetFlow (`xvwileiyquqxxtzqxghm`) were not contacted by any tool call in this step — every action in this step was a local file read/write/test.
- No service-role key or other secret was added to any file.
- No staging-specific real value was committed to this branch — `config/environments/staging.env` and `.env.local` remain gitignored and were never created with real content in the tracked working tree.

---

## 9. Files changed

- `js/config.js` — comment update only; `SUPABASE_URL`/`SUPABASE_ANON_KEY` values unchanged.
- `js/supabase-client.js` — extended the "not configured" guard to also check `SUPABASE_ANON_KEY` and recognize `REPLACE_WITH_…` placeholders.
- `index.html` — CSP explanatory comment updated to describe the new script; CSP directive values unchanged.
- `.gitignore` — added `config/environments/staging.env` and `config/environments/*.local.env`.
- `config/environments/production.env` (new) — tracked, real values (copy of what's already public in `js/config.js`).
- `config/environments/staging.env.example` (new) — tracked template, placeholders only.
- `.env.local.example` (new) — tracked template, placeholders only.
- `scripts/set-frontend-environment.sh` (new) — the deploy-time swap script.
- `docs/23-staging-frontend-configuration.md` (new, this file).

No other file was created or modified in this step.
