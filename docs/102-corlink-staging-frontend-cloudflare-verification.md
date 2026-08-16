# 102 — CorLink Staging Frontend / Cloudflare Pages Verification

**Type:** Verification and targeted-correction checkpoint. Not a redesign, not a new
architecture milestone, no CAP-003 Phase 2, no Digital Signatures, no Production
deployment or migration.
**Baseline:** branch `claude/phase-2-continuation-mc4hr1`, HEAD
`dec558dd11a6e5581c8295cac93e37bd814d6dfc` ("docs(deploy): verify CorLink Supabase
staging deployment").
**Date:** 2026-08-16.

---

## 1. Baseline / workspace integrity

- Repository root: `D:/CorLink`. This checkout's `main` branch was 308 commits behind
  `origin/main` and not on the task's target branch at all.
- The task's target branch, `claude/phase-2-continuation-mc4hr1`, was already checked
  out in a separate git worktree on this machine
  (`C:/Users/10108/.codex/worktrees/cc3b/CorLink`), at local HEAD `1d0913d` — 40
  commits behind `origin/claude/phase-2-continuation-mc4hr1`. All verification and any
  corrective work for this checkpoint was performed in that worktree, not in
  `D:/CorLink`, since git refuses to check out the same branch into two worktrees at
  once.
- That worktree's working tree held only pre-existing untracked scratch SQL files
  (`supabase/patch-workflow-definition-validation-activation.sql` and nine similar
  files) — no modified tracked files, no active merge/rebase.
- `git fetch origin` confirmed `origin/claude/phase-2-continuation-mc4hr1` at
  `dec558d`, containing the required checkpoint. Synchronized with
  `git merge --ff-only origin/claude/phase-2-continuation-mc4hr1` (fast-forward only,
  no reset, no rebase, no force). Local HEAD now `dec558d`, exactly matching remote
  (0 ahead / 0 behind). `git merge-base --is-ancestor dec558d HEAD` confirmed true.

## 2. Governing documentation read

`docs/98` (release gate — NOT READY at the time, two P0s since closed by `docs/100`),
`docs/99` (UAT checklist), `docs/100` (P0 corrections — READY FOR UAT, database-side),
`docs/101` (Supabase staging verification — staging DB fully verified; frontend
deployment visibility named as the sole remaining blocker), `supabase/deploy/README.md`,
`supabase/deploy/canonical-migration-order.txt`, `docs/23` (staging frontend
configuration mechanism), `docs/30` (staging frontend deployment/UAT handoff package,
committed on `feature/corlink-platform-migration`'s tip).

A repository-wide search for the required terms (staging/production project refs,
`SUPABASE_URL`/`SUPABASE_ANON_KEY`, `VITE_SUPABASE`, Cloudflare/Pages/wrangler,
`window.__ENV`, etc.) found no build-tool config (no `vite`, `next`, `netlify.toml`,
`vercel.json`, `.github/workflows/*` — none exist). This is a static, no-build-step
SPA; environment selection happens as a **deploy-time file transform**, not a runtime
JS branch. See §9.

## 3. Cloudflare access check

**Confirmed working, but scoped to Workers/D1/KV/R2/Hyperdrive only — no Pages API.**
`workers_list` returned `{"workers":[],"count":0}`. `d1_databases_list` and
`kv_namespaces_list` both returned empty. `r2_buckets_list` returned
`403 — "Please enable R2 through the Cloudflare Dashboard."` No tool in this session's
Cloudflare MCP connector can list, inspect, or manage a Cloudflare **Pages** project —
confirmed by searching the full tool catalog (`select:*cloudflare*`); only
`workers_*`, `d1_*`, `kv_*`, `r2_*`, `hyperdrive_*`, `search_cloudflare_documentation`,
and `migrate_pages_to_workers_guide` exist. This is the identical gap `docs/101` §17
already identified in an earlier session — re-confirmed independently here, not
assumed.

Because this account shows **zero** Workers, D1, KV, or R2 resources, it cannot even
be independently confirmed that this is the same Cloudflare account that hosts
CorLink's staging Pages project — there is nothing observable in it either way.

## 4. Identify the actual staging frontend

**No live Cloudflare Pages project, deployment, or URL could be identified or
inventoried from this session** (§3). Falling back to repository evidence:

- `scripts/build-cloudflare-staging.sh`'s own header comment and `docs/23` §10 both
  independently document the intended settings: **Production branch:
  `feature/corlink-platform-migration`**, root `/`, build command
  `scripts/build-cloudflare-staging.sh`, output dir `dist`, required env vars
  `CORLINK_SUPABASE_URL` / `CORLINK_SUPABASE_ANON_KEY`.
- `docs/30` (committed on `feature/corlink-platform-migration`'s own tip) is an
  **operator runbook that was prepared but explicitly states no deployment action was
  taken** — it does not confirm a live deployment exists, only that the branch/env-var
  mechanism was designed and locally validated.
- A full-repository search for `pages.dev`, `Deployment ID`, or any filled-in
  deployment-record value (`docs/30` §11's own template) found **no completed record
  anywhere in the repository** — every occurrence of `docs/30` §11's table is still the
  blank template.
- No custom staging domain is referenced anywhere in the repository.

**Conclusion: no canonical staging UAT URL can be produced from this session.** Per
task §19, this is a STOP condition ("the Cloudflare project cannot be confidently
identified"), not a gap to improvise around. No URL is guessed or fabricated here.

## 5. Verify deployed source version — SEPARATE, INDEPENDENTLY-DISCOVERED DEFECT

Even setting aside §3/§4's access gap, a second, self-contained problem was found by
git ancestry analysis alone (no Cloudflare access needed):

- The documented staging Pages project builds from **`feature/corlink-platform-migration`**.
- `origin/feature/corlink-platform-migration` and `origin/main` are currently
  **identical** (`9afb7c4`, "docs: add staging frontend deployment and UAT handoff
  package").
- `git merge-base --is-ancestor origin/feature/corlink-platform-migration dec558d`
  → **true**. `git rev-list --left-right --count origin/feature/corlink-platform-migration...dec558d`
  → **0 ahead / 72 behind**.
- Of those 72 commits only on `claude/phase-2-continuation-mc4hr1`, **31 touch
  frontend paths** (`js/`, `index.html`, `css/`, `assets/`, `fonts/`) — including the
  **entire Tasks frontend** (`edc9a9d` implement task list, `71734c6` task detail
  foundation, `e513a0d` comments/timeline, `031e235` assignee/watcher management,
  `9583bc0`/`5479661`/`32ef339` dashboard, `73faa75` editing/lifecycle, `d14574f`
  attachments, `541955a`/`275d216`/`37efb13` relationships/dependencies) and the
  **entire CAP-003 notification-realtime frontend integration**
  (`bf7e642`/`f757219`/`a89cef4`/`2bea548`/`97a54a3`/`31a9dfd`/`fd48c61`/`4d32dc5`/
  `93863a0`/`6a5012e`) plus per-module notification integration for
  Requests/Entry/Internal Collaboration/Prisoner Letters.

**If `feature/corlink-platform-migration` is what Cloudflare Pages is actually
building today, that deployment predates the existence of the Tasks frontend and the
CAP-003 notification frontend entirely** — not a permission/role rule hiding Tasks,
but the code implementing it never having been on that branch. This is independently
consistent with, and a plausible root cause of, the user's original report of not
seeing Tasks (§12).

`docs/30` (§3) itself already anticipated a version gap and explicitly recommended,
at the time it was written, fast-forwarding `feature/corlink-platform-migration` to
`main`'s then-tip (`539b3ec`) — which happened (the branch is now at `9afb7c4`,
`main`'s current tip). But `main` itself was never advanced past that point with any
of the later Tasks/CAP-003/Workflow work that only ever landed on
`claude/phase-2-continuation-mc4hr1`. The fast-forward mechanism `docs/30` designed
was applied once, correctly, and has simply not been repeated since — it is not
broken, just stale.

## 6. Verify Supabase environment mapping

**Mechanism, not live state, is what could be verified this session** (§3 blocks live
confirmation). The mechanism is sound:

- `js/config.js`'s **committed default** is `https://infjjroktzzhaxjvfknr.supabase.co`
  (production) — by design (`docs/23` §2), preserving zero-setup production behavior
  for any checkout that doesn't run the swap script.
- `scripts/set-frontend-environment.sh` resolves `SUPABASE_URL`/`SUPABASE_ANON_KEY` by
  explicit precedence: (a) CI env vars `CORLINK_SUPABASE_URL`/`CORLINK_SUPABASE_ANON_KEY`
  — what a Cloudflare Pages project's own environment-variable settings supply — then
  (b) a local `config/environments/<env>.env` file, then (c) production's committed
  defaults **only when `production` is explicitly requested**. Staging **never**
  silently falls back to production's values if its own source is missing — that is a
  loud, non-zero-exit failure instead (verified directly in the script source, lines
  107–133).
- `scripts/build-cloudflare-staging.sh` calls this script during the Cloudflare Pages
  **build step**, before `dist/` is assembled — meaning the substitution happens in the
  built artifact Cloudflare serves, not at runtime in the browser. This directly
  answers task §8's caution against assuming "a Cloudflare variable changes browser
  JavaScript behavior" without tracing it: it does, because the build command itself
  performs a `sed`-based rewrite of `js/config.js`/`index.html` before any file is
  served, not a runtime read of an env var from the browser.

**Independent re-verification performed this session** (not merely re-read from
`docs/23`): ran `tests/test-frontend-config.sh` directly against this checkout.
**10 of 11 cases passed.** The one failure (case 7, "running `production` leaves
`js/config.js`/`index.html` byte-identical to committed defaults") was manually
re-diffed and traced to a **Windows Git-Bash/`sed` CRLF→LF line-ending side effect of
this local test environment** — every line of both files was flagged as changed by
`diff`, but manual inspection confirmed the actual text content (including the
`SUPABASE_URL`/`SUPABASE_ANON_KEY` values themselves) is byte-for-byte identical
prose, only the invisible line-ending character differs. `git status`/`git diff`
confirmed the tracked working tree itself was never touched by the test run (it
operates on `mktemp` scratch copies only). This is a local Windows-toolchain artifact,
not a defect in the deploy mechanism — Cloudflare Pages' Linux build environment does
not exhibit this quirk. Reported honestly as 10/11 rather than rounding to a clean
11/11.

**Cannot be verified this session:** whether the actual, live Cloudflare Pages
project (if it exists) has `CORLINK_SUPABASE_URL`/`CORLINK_SUPABASE_ANON_KEY` actually
set, and to which values. This requires either Cloudflare Pages dashboard/API access
this session does not have, or an operator confirming directly.

## 7. Production/staging isolation

No action in this session touched Production (`infjjroktzzhaxjvfknr`) in any way — no
Supabase tool was invoked against it, no Cloudflare resource was modified, and no
git push occurred to `main` or `feature/corlink-platform-migration` (§5's finding is
reported, not corrected — see §9). `scripts/build-cloudflare-staging.sh`'s own branch
guard independently refuses to build staging configuration if `CF_PAGES_BRANCH` is
`main`/`master`/`production`, an existing safeguard this session did not need to touch
or rely on.

## 8. Build/deployment configuration mechanism

Documented (and, for the local half, independently re-tested — §6) as: branch-based
(not preview-based), single dedicated Cloudflare Pages project, allow-list `dist/`
assembly (`index.html`, `css/`, `js/`, `assets/`, `fonts/` only — `.git`, `docs/`,
`supabase/`, `config/`, `scripts/`, `references/`, `tests/` excluded by construction,
confirmed by test cases 9–10). No SPA rewrite needed (hash-based routing). This
mechanism itself is not in question — §5's finding is that the **branch** it is
configured to build from is stale, not that the build mechanism is broken.

## 9. Correction made

**None.** Two independent conditions each individually satisfy a task §19 STOP
condition, so no repository or Cloudflare correction was attempted:

1. **Cloudflare Pages project cannot be confidently identified** (§3/§4) — no tool
   access, no recorded URL anywhere in the repository.
2. **The only available corrective action for §5's staleness — fast-forwarding
   `feature/corlink-platform-migration` (≡ `main`) forward by 72 commits — is outside
   this task's authorized git-push scope** (task §18 names only
   `origin/claude/phase-2-continuation-mc4hr1` as a push target) **and touches the
   branch `scripts/build-cloudflare-staging.sh`'s own guard treats as
   production-adjacent** (its hard refusal on `CF_PAGES_BRANCH=main`). Pushing 72
   commits into a shared branch neither named nor scoped by this task, on the
   strength of an assumption about what else might consume it, is exactly the kind of
   unilateral repair the task's own §1 and general safety instructions direct against
   ("If there is a genuine divergence... STOP. Report the exact mismatch. Do not
   repair it unilaterally" — applied here by analogy, since this is the same class of
   risk one level up, at the deployment-branch layer instead of the local-worktree
   layer).

No frontend code, Cloudflare configuration, or SQL was changed in this checkpoint.

## 10. Live staging site verification

**Not performed — no URL exists to verify against** (§4). Per task instruction,
stating this plainly rather than fabricating a check: no browser navigation, network
inspection, or login attempt was made against any CorLink staging deployment this
session, because no reachable URL for one is known. This is a limitation, explicitly
not being reported as a completed check.

## 11. Existing login — not touched

No Supabase Auth call, user creation, password reset, or `auth.users`/`public.users`
write occurred in this session — consistent with `docs/101`'s prior confirmation that
staging's 7 existing accounts remain intact. Nothing in this checkpoint had reason to
touch Auth, and nothing did.

## 12. Tasks visibility check — frontend source verified current, deployment unverifiable

Static inspection of `js/views/shell.js` (all three nav renderers — sidebar, topbar,
bottom nav) at `dec558d`: the Tasks nav item
(`item('task-dashboard', 'Tasks', 'ti-checklist')`) is rendered **unconditionally for
every authenticated user** — unlike Requests/Entry/Rooms/Meetings/Calendar/Prisoner
Letters/Administration, which are each gated behind
`isModuleEnabled(user, '<module>')` and/or a role check. There is no module-enablement
row, role gate, or org-scoping condition hiding Tasks in the current source. Route
registration confirmed in `js/app.js` (`task-dashboard`, `tasks`, `task-detail`, all
registered). Backing views (`js/views/task-dashboard.js`, `tasks.js`,
`task-detail.js`) and data layer (`js/data/tasks-api.js`) all exist and are current.

**Conclusion: at the current repository checkpoint, any authenticated staging user
should see Tasks — there is no legitimate permission rule that would hide it.** Per
§5, if the live deployment is still built from `feature/corlink-platform-migration`
(72 commits behind), Tasks is absent from the deployed frontend not because of any
permission logic but because that code doesn't exist yet on the branch actually
deployed. This is the most direct, evidence-backed explanation available this session
for the user's original "I don't see Tasks" report — but it remains a hypothesis
pending either live Cloudflare confirmation or an operator check, since this session
cannot observe the live deployment at all (§3/§10).

## 13. Core UAT navigation smoke (static source check only)

At `dec558d`, confirmed present in source for every current module named in task §13
(routes registered in `js/app.js`, nav items in `js/views/shell.js`, backing view +
data-layer files exist):

| Module | Route(s) | Nav gating | Status |
|---|---|---|---|
| Dashboard | `dashboard` | none (always shown) | present |
| Tasks | `task-dashboard`, `tasks`, `task-detail` | none (always shown) | present |
| Requests | `requests`, `request-detail` | `isModuleEnabled('requests')` | present |
| Meetings | `meetings` | `isModuleEnabled('meetings')` | present |
| Entry / External Correspondence | `entry`, `entry-detail` | `isModuleEnabled('entry')` | present |
| Internal Collaboration | reached from within Requests/Entry detail pages (polymorphic thread on a parent record), not a standalone top-level route — consistent with `docs/101` §10's description of the module's own design | n/a | present |
| Prisoner Letters | `prisoner-letters`, `prisoner-letter-detail` | `canAccessPrisonerLetters(user) && isModuleEnabled('prisoner_correspondence')` | present |
| Administration | `admin` | `isAdmin(user) && isModuleEnabled('administration')` | present |

No route exists for a module outside this current list (no Inventory, Procurement,
Finance, etc., confirmed by the same `js/app.js` read). This is source-level
confirmation only — it says the deployed-if-current frontend *would* expose these
correctly; it says nothing about what a stale (§5) deployment actually serves today.

## 14. Notification frontend smoke (static source check only)

`js/data/notifications-api.js` at `dec558d` confirmed: `listNotifications()`/
`getUnreadCount()` call the durable `list_my_notifications()`/
`count_my_unread_notifications()` RPCs (not a Realtime payload treated as
authoritative — matching `docs/101` §14's "Realtime as refresh signal only" finding),
a legacy/CAP-003 merge path (`listUnreadLegacy`), and a `CAP003_ROUTES` deep-link
resolver covering `task → task-detail`, `meeting → meetings`, `request →
request-detail`, `external_correspondence → entry-detail`, `prisoner_letter →
prisoner-letter-detail`; Internal Collaboration/`internal_request` deep links resolve
via an async polymorphic-parent lookup (same pattern the pre-existing
`meeting_series` branch already uses), per the file's own comments. All of this is
current in source. Live behavior unverifiable this session (§3/§10).

## 15. Security / secrets check

`grep -rni "service_role|service-role"` across every frontend-shipped path
(`js/`, `index.html`, `css/`, `assets/`, `fonts/`) at `dec558d`: **zero matches.** No
service-role key, database password, Cloudflare API token, or worker secret appears
anywhere in frontend-shipped code. `scripts/set-frontend-environment.sh` additionally
hard-refuses to run at all if `SUPABASE_SERVICE_ROLE_KEY`/
`CORLINK_SUPABASE_SERVICE_ROLE_KEY` is set in its environment (verified directly in
script source) — a service-role key cannot be silently carried into a deploy through
this mechanism even by operator mistake. Only the public `SUPABASE_URL`/
`SUPABASE_ANON_KEY` pair is ever written to `js/config.js`, matching Supabase's own
public/anon-key design.

## 16. Canonical UAT URL

**None can be provided.** Per §4/§19, no live Cloudflare Pages deployment could be
identified, inventoried, or confirmed from this session, and no URL for one is
recorded anywhere in the repository. Providing a guessed or fabricated URL would be
actively harmful here (the task's own §16 explicitly prohibits handing over an
ambiguous guess), so none is given. See §22 for what is required to unblock this.

## 17. Documentation

This file (`docs/102-corlink-staging-frontend-cloudflare-verification.md`).

## 18. Corrections made

None (§9).

## 19. Live-site / browser verification performed

None — explicitly not performed, not claimed (§10).

## 20. Final UAT readiness decision

# CORLINK STAGING FRONTEND NOT READY FOR UAT

Two independent, individually-sufficient blockers, neither correctable within this
session's tool access or this task's authorized scope:

1. **No Cloudflare Pages project, deployment, or URL is observable or recorded** —
   this session's Cloudflare access covers Workers/D1/KV/R2/Hyperdrive only, no Pages
   API; no deployment URL exists anywhere in the repository (§3, §4, §16).
2. **Even if Cloudflare Pages access existed, the documented staging branch
   (`feature/corlink-platform-migration`, ≡ `main`) is 72 commits behind the verified
   staging baseline, missing the entire Tasks frontend and CAP-003 notification
   frontend integration** — the correction (fast-forwarding that branch) requires a
   push outside this task's authorized scope and outside a branch this checkpoint was
   asked to touch (§5, §9).

The Supabase staging database side remains fully verified and ready per `docs/101`.
This checkpoint's own scope — frontend deployment visibility — remains blocked by
exactly the gap `docs/101` §17–§18 already named, now confirmed independently and with
one additional concrete defect (branch staleness) identified.

## 21. Remaining blockers / exact next action for an operator with the needed access

1. **Cloudflare Pages dashboard/API access** — needed to confirm whether a staging
   Pages project exists at all, its current build branch, its last build status and
   commit SHA, its assigned `*.pages.dev` or custom domain, and its
   `CORLINK_SUPABASE_URL`/`CORLINK_SUPABASE_ANON_KEY` environment variable values.
2. **If the project exists and is confirmed building from `feature/corlink-platform-migration`:**
   fast-forward that branch (and, if it is meant to track `main` in lockstep per
   `docs/30`'s original strategy, `main` as well) to include the 72 commits currently
   only on `claude/phase-2-continuation-mc4hr1`, specifically to restore the Tasks and
   CAP-003 notification frontend code. This is a mechanical fast-forward per the same
   ancestry check performed in §5 (`git merge-base --is-ancestor
   origin/feature/corlink-platform-migration dec558d` → true), not a merge or rebase —
   but it is an operator action on branches this task was not authorized to push to.
3. Once (1) and (2) are done, re-run this checkpoint's §10/§13/§14 live-browser checks
   against the real resulting URL — they were designed and ready to run this session,
   only blocked by the access gap above.
