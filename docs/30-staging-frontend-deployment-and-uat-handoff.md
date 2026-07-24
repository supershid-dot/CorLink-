# 30 — Staging Frontend Deployment and UAT Handoff

Operator-ready package for deploying the current `main` frontend (Rooms, Meetings,
Draft Meetings, Recurring Meetings Phase 1 + Phase 2) to CorLink's existing Cloudflare
Pages staging project, and handing the result off for browser UAT.

This document was prepared without any connection to Cloudflare or Supabase (staging
or production). No deployment was performed, no Cloudflare configuration was changed
remotely, no SQL was applied, and production was not touched. All commands below are
for an authorized operator with real Cloudflare and Supabase staging credentials to
execute.

---

## 1. Purpose

Get the frontend currently on `main` (commit `539b3ecc9e9ddaaf1208e682f2fd4547433a92e1`
at the time this document was written) in front of the existing Cloudflare Pages
staging project, pointed at the staging Supabase project, so a human tester can perform
browser-based UAT against it — without reconfiguring the Pages project's tracked
branch and without touching production.

---

## 2. Prerequisites

- [ ] Cloudflare account access with permission to view/trigger builds on the existing
      staging Pages project
- [ ] Authorization to push to `feature/corlink-platform-migration` on this repository
- [ ] Staging Supabase project's public `URL` and `anon`/publishable key (project ref
      `vjobntuyzymhcuanyeak` per `docs/19`/`docs/21`/`docs/24` — the operator retrieves
      the actual URL/key from the Supabase dashboard or wherever they were previously
      recorded; this document does not reproduce them)
- [ ] A verified, current staging database state (per `docs/29`'s staging rehearsal
      evidence — RSVP through Recurring Phase 2 audit-visibility applied and validated)
- [ ] A way to view the Cloudflare Pages deployment's build log (dashboard or `wrangler`)

---

## 3. Branch strategy

**Recommendation: fast-forward `feature/corlink-platform-migration` to `main`. Do not
repoint the Cloudflare Pages project to `main`.**

Rationale:
- The existing Cloudflare Pages staging project is configured with **Production branch:
  `feature/corlink-platform-migration`** (documented in `scripts/build-cloudflare-staging.sh`'s
  own header and `docs/23-staging-frontend-configuration.md` §10's settings table). This
  is an existing, working, already-verified pipeline — changing which branch a live
  Cloudflare Pages project tracks is a Cloudflare configuration change with its own
  risk (webhook re-registration, potential build-cache invalidation, another team
  member's mental model of "staging = that branch" breaking silently), and is
  unnecessary when a fast-forward achieves the same result more simply.
- **Verified in this repository:** `feature/corlink-platform-migration` (local and
  `origin`, both at `6c1906ee2c6d26dfb1773306807768e1a043d177`) is a strict ancestor of
  `main` — `git merge-base --is-ancestor feature/corlink-platform-migration main`
  returns true, and `git log --oneline main..feature/corlink-platform-migration` is
  empty (zero commits exist on the feature branch that aren't already on `main`). A
  fast-forward is therefore mechanical and lossless: no merge, no conflict resolution,
  no rebase.
- The 5 commits `feature/corlink-platform-migration` is behind `main` are:
  `44be62c` (PR #103 merge), `f924a9d` (platform migration merge commit),
  `eec4e3b`, `2d3f7cb`, `539b3ec` (three documentation-only commits — the production
  SQL deployment runbook and its dependency-documentation correction). None of these
  touch `js/`, `css/`, `index.html`, `config/`, or `scripts/` — the frontend build
  output is identical whether built from the old or new tip; only tracked
  documentation differs.
- Reconfiguring the Pages project to build from `main` directly is explicitly **not
  recommended**: `scripts/build-cloudflare-staging.sh`'s own branch guard *refuses to
  build* when `CF_PAGES_BRANCH` is `main` (by design, to prevent staging configuration
  ever silently applying to a production-tracked branch). Pointing the existing staging
  project at `main` would require also removing or rewriting that guard — a code change
  to the deployment safety mechanism itself, not just a Cloudflare setting — and is out
  of scope unless the fast-forward path is later found to be impossible.

---

## 4. Exact operator commands

Run from a clone with push access to `origin` (this repository).

```bash
# 1. Fetch latest refs
git fetch origin main feature/corlink-platform-migration

# 2. Verify clean state and expected starting points
git status --short
# Expect: no output (clean working tree)

git rev-parse origin/main
# Expect: 539b3ecc9e9ddaaf1208e682f2fd4547433a92e1 (or later, if main has since advanced —
# if later, re-verify §3's ancestor check below before continuing)

git rev-parse origin/feature/corlink-platform-migration
# Expect: 6c1906ee2c6d26dfb1773306807768e1a043d177 (if different, someone else has
# already moved this branch — stop and re-assess before proceeding)

# 3. Re-confirm the fast-forward is still conflict-free (cheap, always re-check
#    immediately before acting — refs may have moved since this document was written)
git merge-base --is-ancestor origin/feature/corlink-platform-migration origin/main && \
  echo "OK: fast-forward is safe" || echo "STOP: do not fast-forward, branches have diverged"

# 4. Fast-forward the local branch to origin/main
git checkout feature/corlink-platform-migration
git merge --ff-only origin/main
# --ff-only guarantees this fails loudly instead of creating a merge commit if
# anything unexpected has changed since step 3's check.

# 5. Push the fast-forwarded branch
git push origin feature/corlink-platform-migration

# 6. Verify the pushed commit
git rev-parse origin/feature/corlink-platform-migration
# Expect: 539b3ecc9e9ddaaf1208e682f2fd4547433a92e1 (or main's current tip, if it advanced)
git log --oneline -1 origin/feature/corlink-platform-migration
```

This push alone will trigger a new Cloudflare Pages build automatically (Cloudflare
Pages builds on every push to the tracked production branch) — no separate "deploy"
action is required beyond the push itself, unless the operator wants a manual retrigger
from the Cloudflare dashboard instead.

---

## 5. Environment-variable setup (placeholders only)

Required Cloudflare Pages **project environment variables** (Settings → Environment
variables, on the **Production** environment tab, since this project's "Production
branch" is `feature/corlink-platform-migration` itself — see §3):

| Variable | Value | Notes |
|---|---|---|
| `CORLINK_SUPABASE_URL` | `<STAGING_SUPABASE_URL>` | e.g. `https://vjobntuyzymhcuanyeak.supabase.co` — the operator fills in the real value directly in the Cloudflare dashboard, never in a file |
| `CORLINK_SUPABASE_ANON_KEY` | `<STAGING_SUPABASE_ANON_KEY>` | Staging's public anon/publishable key only — **never** a service-role key |

No other build variables are required — `scripts/build-cloudflare-staging.sh` reads
only these two (via `scripts/set-frontend-environment.sh staging`'s CI-variable
precedence) and needs nothing else to produce `dist/`.

**These must never be committed to Git, in any form:**
- Do **not** create `config/environments/staging.env` with real values and commit it —
  it is gitignored specifically so this can never happen (`.gitignore` excludes
  `config/environments/staging.env` and `config/environments/*.local.env`).
- Set both variables **only** in the Cloudflare Pages dashboard (Settings →
  Environment variables) or via `wrangler pages secret`/project-settings tooling —
  never in a shell history file, script, or commit that gets pushed anywhere.
- If a local dry run is needed before relying on Cloudflare's own build, export both
  as shell environment variables for that single command only
  (`CORLINK_SUPABASE_URL=... CORLINK_SUPABASE_ANON_KEY=... scripts/build-cloudflare-staging.sh`),
  never written to a file inside the repository.

---

## 6. Cloudflare Pages build settings

These should already be configured on the existing staging project (verify, don't
recreate, unless the project genuinely doesn't exist yet):

| Setting | Value |
|---|---|
| Production branch | `feature/corlink-platform-migration` |
| Root directory | `/` |
| Build command | `scripts/build-cloudflare-staging.sh` |
| Build output directory | `dist` |
| Environment variables | `CORLINK_SUPABASE_URL`, `CORLINK_SUPABASE_ANON_KEY` (§5) |
| SPA rewrite | None needed — hash-based routing (`#meetings`, `#rooms`, etc.) means every request is simply "serve `index.html`" |
| HTTPS | Automatic (Cloudflare-provided) |

Source: `docs/23-staging-frontend-configuration.md` §10, `scripts/build-cloudflare-staging.sh`'s
own header comment — both independently state the same settings.

---

## 7. Deployment procedure

1. Complete §4 (fast-forward and push `feature/corlink-platform-migration`).
2. Confirm §5's two environment variables are set on the Cloudflare Pages project
   (verify existing values, or set them if this is the first real staging deploy).
3. The push in §4 step 5 triggers a new build automatically. If a manual trigger is
   preferred instead, use the Cloudflare Pages dashboard's "Retry deployment" /
   "Create deployment" action against the newly-pushed commit.
4. Watch the build log for:
   - The branch guard's own output — expect **no** `ERROR: refusing to build staging
     configuration for branch 'main'` line (that would indicate `CF_PAGES_BRANCH` is
     somehow `main`, which should never happen on this project's own tracked branch).
   - `Applying 'staging' environment from: CI environment variables (CORLINK_SUPABASE_URL / CORLINK_SUPABASE_ANON_KEY)`
   - The masked anon-key line (`SUPABASE_ANON_KEY=<first6>...<last4> (redacted, N chars)`)
     — confirm it is **not** the full key, and confirm the `SUPABASE_URL` line shown
     matches staging's project, **not** `infjjroktzzhaxjvfknr` (production).
   - `dist/ assembled with: index.html css assets fonts js`
   - `Cloudflare Pages build complete.`
5. Once the build succeeds, Cloudflare assigns a deployment URL (either the project's
   standard `*.pages.dev` staging alias, or a per-deployment preview URL — record
   whichever one Cloudflare actually generates in §11's deployment record).

---

## 8. Verification checklist

Perform every check below against the actual deployed URL from §7 step 5.

- [ ] **Deployed commit hash** — Cloudflare Pages' deployment detail view shows the
      commit SHA it built from; confirm it matches the SHA pushed in §4 step 5/6
- [ ] **Branch** — confirm the deployment is attributed to `feature/corlink-platform-migration`
      in the Cloudflare dashboard, not any other branch
- [ ] **Staging Supabase project confirmation** — open browser DevTools → Network tab,
      reload the page, confirm outbound requests target the staging Supabase host
      (`vjobntuyzymhcuanyeak.supabase.co`, or whatever the operator's real
      `CORLINK_SUPABASE_URL` resolves to) and **not** `infjjroktzzhaxjvfknr.supabase.co`
      (production)
- [ ] **Application load** — the page loads without a blank screen or CSP-violation
      console error
- [ ] **Login** — log in with a real staging account (per `docs/24`, currently only the
      staging super admin, service number `10108`, exists — the six other staging
      personas are documented as not-yet-created); confirm the session establishes and
      the dashboard renders
- [ ] **Rooms route** — navigate to `#rooms`, confirm the Rooms list view renders and
      an API call to `meeting_rooms`/`meeting_room_bookings` succeeds (200, not 4xx/5xx)
- [ ] **Meetings route** — navigate to `#meetings`, confirm the Meetings list view
      renders and an API call to `meetings` succeeds
- [ ] **Browser console** — confirm zero uncaught JS errors and zero CSP-violation
      reports throughout the checks above
- [ ] **Failed network calls** — confirm zero unexpected non-2xx responses in the
      Network tab (expected 401/403 responses from an intentional negative-permission
      test are not "failures" — distinguish those from genuine errors)

---

## 9. Rollback instructions

If the deployed build is broken, misconfigured, or otherwise needs to be reverted:

1. **Restore the prior staging branch commit.** Before §4, record
   `origin/feature/corlink-platform-migration`'s prior tip
   (`6c1906ee2c6d26dfb1773306807768e1a043d177`, per this document — reconfirm it is
   still accurate immediately before rolling back, in case another deploy happened in
   between). Reset the branch back to it:
   ```bash
   git fetch origin main feature/corlink-platform-migration
   git checkout feature/corlink-platform-migration
   git reset --hard 6c1906ee2c6d26dfb1773306807768e1a043d177
   git push --force-with-lease origin feature/corlink-platform-migration
   ```
   `--force-with-lease` (not a bare `--force`) is required here since this is a
   history-rewriting push on a shared branch — it fails safely if someone else has
   pushed to this branch since the fetch, rather than silently discarding their work.
2. **Trigger redeployment.** The force-push in step 1 triggers a new Cloudflare Pages
   build automatically, same as any other push to the tracked branch. If a manual
   retrigger is needed instead, use the dashboard's deployment list to redeploy the
   specific prior successful deployment (Cloudflare Pages keeps deployment history and
   supports "Rollback to this deployment" directly, without even needing the git
   revert above, if that direct-rollback path is faster than the git-level one).
3. **Verify rollback.** Repeat §8's checklist against the post-rollback deployment URL
   — specifically re-confirm the deployed commit hash now matches the restored prior
   commit, and that the application still loads and logs in correctly at the older
   commit.

---

## 10. UAT handoff checklist

Before handing the deployed staging URL to a human tester for full browser UAT:

- [ ] §7's deployment procedure completed with a successful build
- [ ] §8's verification checklist passed in full
- [ ] The tester has been given: the deployment URL, the one known working staging
      login (service number `10108` + its password, communicated to the tester through
      a secure channel — **never** written into this document or any commit), and a
      clear statement that only one real persona currently exists on staging (per
      `docs/24` — the other six documented personas remain uncreated, which limits
      multi-persona testing until that gap is closed separately)
- [ ] The tester has been pointed at the full workflow list this staging environment is
      expected to support (Platform/Rooms/Meetings/RSVP/Attendance/Minutes/
      Lock/Personal Notes/Meeting Groups/Draft Meetings/Recurring Meetings Phase 1+2,
      Notifications, Calendar if enabled) — see `docs/29` §2/§20 for the exact list
      already validated in the prior staging SQL rehearsal, so the tester knows what's
      expected to already work versus what's genuinely being tested for the first time
      at the UI layer
- [ ] The tester has been told explicitly **not** to assume the earlier database-level
      validation (`docs/29`) guarantees UI correctness — this deployment is the first
      time these workflows are being exercised through the actual browser UI against
      staging
- [ ] A clear escalation path is given for any defect found (where to report it, and
      that no production system is at risk regardless of what's found on staging)

---

## 11. Deployment record template

| Field | Value |
|---|---|
| Date/time | `<DATE_TIME>` |
| Operator | `<OPERATOR_NAME>` |
| Fast-forward performed: from → to | `6c1906ee2c6d26dfb1773306807768e1a043d177` → `<NEW_TIP_SHA>` |
| Pushed branch | `feature/corlink-platform-migration` |
| Cloudflare deployment ID | `<DEPLOYMENT_ID>` |
| Deployed commit hash (per Cloudflare) | `<SHA>` |
| Deployment/preview URL | `<URL>` |
| `CORLINK_SUPABASE_URL` confirmed pointed at staging (not production) | yes / no |
| Build log clean (no branch-guard error, no missing-config error) | yes / no |
| §8 verification checklist result | pass / fail (attach details if fail) |
| Rollback performed | yes / no (if yes, reference §9 and record the restored commit) |
| Handed off for UAT | yes / no, to whom: `<TESTER_NAME>`, date: `<DATE>` |

---

## 12. Confirmation of constraints honored

No SQL was applied. No production Supabase project was contacted. No Cloudflare
configuration was changed remotely — no deployment, project setting, or environment
variable was created or modified by preparing this document; every action above is
written for an operator to execute. No real credentials, connection strings, or keys
appear anywhere in this document — only named placeholders and, where a real
non-secret identifier already exists in this repository's own prior documentation
(the staging project ref `vjobntuyzymhcuanyeak`, itself not a secret), a reference to
that existing documentation rather than a restated value. This document does not claim
any deployment has occurred.
