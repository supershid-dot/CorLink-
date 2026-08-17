# 105 — CorLink Staging Frontend Bootstrap Hang: Diagnosis and Fix

**Type:** Focused defect fix. Not a redesign, not a new feature, no CAP-003
Phase 2, no Production change, no Supabase migration.
**Baseline:** branch `claude/phase-2-continuation-mc4hr1`, HEAD `7771c3f` ("docs(deploy):
synchronize CorLink staging branch") — the same SHA the task reported as the deployed
Cloudflare Pages build.
**Date:** 2026-08-17.

---

## 1. Reproduction

Cloudflare Pages deployment status was reported as SUCCESS, serving `7771c3f` with
`CORLINK_SUPABASE_URL`/`CORLINK_SUPABASE_ANON_KEY` correctly set to CorLink Staging
(`vjobntuyzymhcuanyeak`). The page renders `index.html`'s inline splash
(`CorLink` / `Loading…`) and never advances — unauthenticated visitors cannot reach
login.

No live Cloudflare Pages URL is recorded anywhere in the repository (a pre-existing gap,
already identified in `docs/102`), so this session could not browser-test the actual
live deployment directly. Instead, the deployed build was reproduced exactly:
`scripts/build-cloudflare-staging.sh` was run locally with
`CORLINK_SUPABASE_URL=https://vjobntuyzymhcuanyeak.supabase.co` and the real staging
anon key (fetched via the Supabase MCP connector), producing a byte-for-byte equivalent
`dist/` to what Cloudflare's build step would produce, served locally and loaded in
headless Chromium (Playwright, the `/opt/pw-browsers/chromium` binary already present in
this environment) with a completely fresh browser context (no `localStorage`, no
cookies).

**The hang reproduced immediately, with zero network dependency on Supabase.**

## 2. Startup path traced

`index.html` → 30+ `<script defer>` tags (classic scripts, no `type="module"`, so every
top-level `const`/`let`/`function` in every one of them shares **one global lexical
scope**) → `js/app.js`'s `init()`, called on `DOMContentLoaded`:

```js
async function init() {
  Router.register('login', LoginView);
  ...
  Router.register('meetings', MeetingsView);   // ← throws here
  ...
  try {
    const session = await Auth.getSession();
    ...
  } catch (err) {
    console.warn('CorLink: session check failed:', ...);
  }
  Router.start();   // registers the 'hashchange' listener and renders the first route
}
```

`Router.start()` is the **only** thing that ever replaces `index.html`'s inline
`#app` splash content — either directly (its own first `handleHashChange()` call) or via
the `hashchange` listener it registers. If `init()` throws anywhere in the
`Router.register(...)` block, execution never reaches `Router.start()`, and the splash
is permanently stuck — this is not caught by the `try/catch` a few lines down, which
only wraps the session-resume logic, not route registration.

## 3. Root cause #1 — `MeetingsView is not defined` (the primary defect)

`js/views/meetings.js` declared:

```js
const SUPPORTING_TASKS_PAGE_SIZE = 5;
```

at the top level. `js/views/request-detail.js` — loaded **earlier** in `index.html`'s
script order — already declares a top-level `const SUPPORTING_TASKS_PAGE_SIZE = 5;` of
its own. Because both files execute as classic scripts sharing one global scope,
re-declaring the same `const` identifier is a **`SyntaxError` at parse time**
(`Identifier 'SUPPORTING_TASKS_PAGE_SIZE' has already been declared`), which aborts
`meetings.js` in its entirety — `MeetingsView` is never assigned to the global scope.

`js/app.js`'s `init()` then throws a `ReferenceError: MeetingsView is not defined` on
`Router.register('meetings', MeetingsView)`, uncaught, before `Router.start()` is ever
reached. The splash never clears, for **every** visitor — authenticated or not.

The two other view files with an identically-shaped "Supporting Tasks page size"
constant already avoid this exact collision by prefixing the identifier:
`js/views/entry-detail.js` uses `ENTRY_SUPPORTING_TASKS_PAGE_SIZE`,
`js/views/prisoner-letter-detail.js` uses `PRISONER_LETTER_SUPPORTING_TASKS_PAGE_SIZE`.
`meetings.js`'s own comment ("same value and reasoning as request-detail.js's
`SUPPORTING_TASKS_PAGE_SIZE`") shows the author was aware of the existing constant, but
did not follow the established prefixing convention when adding the meetings
equivalent — a naming oversight, not a design decision.

A repository-wide static scan (every top-level `const`/`let`/`function` identifier
across every file `index.html` loads via `<script src>`) found this to be the **only**
such collision.

## 4. Root cause #2 — authenticated fast-path skips `Router.start()` entirely

A second, independent defect was found in the same function while verifying the fix,
using a fake-but-realistic Supabase client (no live network dependency) with a valid
cached session seeded into `localStorage` — reproducing what a **returning, already
logged-in** visitor's browser looks like on reload:

```js
if (session) {
  await Auth.resumeSession();
  const hash = window.location.hash.slice(1).split('?')[0];
  if (!hash || hash === 'login') {
    Router.navigate('dashboard');
    return;          // ← bug: skips Router.start() entirely
  }
}
```

`Router.navigate('dashboard')` only sets `window.location.hash = 'dashboard'` — it does
not render anything itself. Rendering happens either via `Router.start()`'s own initial
call, or via the `'hashchange'` listener `Router.start()` registers. The `return`
immediately after `Router.navigate(...)` skips `Router.start()` unconditionally, so
**no listener is ever attached**, the hash changes with nothing observing it, and the
splash is left in place forever — for any visitor who already has a valid session
cached from a previous visit.

This directly contradicts the function's own comment two lines above it
(`// Try to resume an existing session — always fall through to Router.start()`),
confirming this was an oversight, not intended behavior.

## 5. Fix

Both fixes are the smallest correct change to the exact lines at fault — no redesign,
no unrelated file touched.

**`js/views/meetings.js`** — renamed the colliding constant to
`MEETING_SUPPORTING_TASKS_PAGE_SIZE`, matching the prefixing convention already used by
`entry-detail.js` and `prisoner-letter-detail.js` (1 declaration + 2 usages updated).

**`js/app.js`** — removed the `return` that skipped `Router.start()` on the
authenticated fast-path. `init()` now unconditionally reaches `Router.start()`, matching
its own existing comment.

```diff
       if (!hash || hash === 'login') {
         Router.navigate('dashboard');
-        return;
       }
```

No other file was changed. `git diff --stat`:

```
 js/app.js            |  1 -
 js/views/meetings.js | 11 ++++++++---
 2 files changed, 8 insertions(+), 4 deletions(-)
```

## 6. Whether this was frontend / Cloudflare / Supabase

**Purely frontend.** Both defects are JavaScript logic errors in `js/app.js` and
`js/views/meetings.js`, present in the committed source at `7771c3f` regardless of which
Supabase project or Cloudflare configuration serves it. Cloudflare's build/deploy
mechanism (`scripts/build-cloudflare-staging.sh`,
`scripts/set-frontend-environment.sh`) was independently re-verified as correct in this
session (§8) and required no change. No Supabase schema, RLS, or RPC was touched or
needed — `docs/101`'s prior full verification of the staging database stands unchanged.

## 7. Tests added

`tests/frontend-bootstrap-integrity-frontend.test.js` (new). Two layers:

1. **Static regression guards** (no browser): (a) a repository-wide scan asserting no
   two files loaded by `index.html`'s `<script>` tags redeclare the same top-level
   `const`/`let`/`function` identifier — guards the defect *class* from root cause #1,
   not just this one instance; (b) `meetings.js` no longer declares the bare
   `SUPPORTING_TASKS_PAGE_SIZE`; (c) `app.js`'s authenticated fast-path is not
   immediately followed by a `return` that would skip `Router.start()`.
2. **Browser bootstrap checks** (headless Chromium via the `playwright` package against
   this environment's pre-installed `/opt/pw-browsers/chromium` — this repository has no
   `package.json`/bundled `node_modules`, consistent with the pre-existing
   `PLAYWRIGHT_CORE_PATH`/`EDGE_PATH` environment gap already noted in `docs/98`, so this
   suite resolves `playwright` from `NODE_PATH` and degrades gracefully with a clear
   message — not a false pass — if neither is available):
   - No session, Supabase library fails to load entirely (simulated CDN failure) → still
     reaches the login screen, zero uncaught page errors.
   - No session, Supabase library loads normally, server returns no session → reaches
     login.
   - A valid cached profile + a live (stubbed) session, seeded directly into
     `localStorage` → the dashboard actually renders (not stuck on Loading) — this is
     the direct regression test for root cause #2.
   - A stale/garbage cached profile (missing expected keys) → does not hang startup.

All four scenarios above were failing on `stillLoading === true` before the two fixes in
§5 and pass afterward; this was verified by running the suite against the pre-fix
source first (reproducing exactly the reported symptom), then again after each fix.

Existing `tests/test-frontend-config.sh` (staging/production build-config mechanism) was
re-run unmodified and still passes 11/11 on this (Linux) environment — no regression,
and none of the CRLF-related flakiness `docs/102`/`docs/103` noted on Windows applies
here.

## 8. Test results

```
$ bash tests/test-frontend-config.sh
── Summary: 11 passed, 0 failed ──

$ node tests/frontend-bootstrap-integrity-frontend.test.js
PASS: no duplicate top-level identifiers across index.html script tags
PASS: meetings.js no longer declares bare SUPPORTING_TASKS_PAGE_SIZE
PASS: app.js init() always falls through to Router.start() (no early return before it)
PASS: no session, Supabase library fails to load entirely → still reaches login (not stuck on Loading)
PASS: no session, Supabase library loads fine → reaches login (not stuck on Loading)
PASS: valid cached session + live session → startup does not hang on Loading
PASS: stale/garbage cached profile does not hang startup
FRONTEND BOOTSTRAP: 7 PASSED, 0 FAILED
```

## 9. Staging build-config verification

Independently re-confirmed in this session (not merely re-read from `docs/102`/`103`):
`scripts/build-cloudflare-staging.sh` was run against a disposable scratch copy of this
checkout with `CORLINK_SUPABASE_URL=https://vjobntuyzymhcuanyeak.supabase.co` and the
real staging anon key (via Supabase MCP `get_publishable_keys`). Resulting `dist/`:

- `dist/js/config.js` and `dist/index.html`'s CSP (`img-src`/`connect-src`, both
  `https://` and `wss://` forms) contain only `vjobntuyzymhcuanyeak.supabase.co` —
  zero occurrences of the production host `infjjroktzzhaxjvfknr.supabase.co` anywhere
  in `dist/`.
- No unresolved `REPLACE_WITH_*` placeholder in any shipped file.
- `dist/` contains exactly `index.html`, `css/`, `assets/`, `fonts/`, `js/` — 45 files,
  matching the allow-list; no `docs/`, `supabase/`, `config/`, `scripts/`, `tests/`,
  or `.git`.

## 10. Commit SHA

See the accompanying final report in this session for the exact commit SHA created for
this fix.

## 11. Development push result / staging-branch sync

See the accompanying final report for push confirmation to
`claude/phase-2-continuation-mc4hr1`, and — once verified as a clean fast-forward — to
`feature/corlink-platform-migration` (the branch Cloudflare Pages' staging project is
documented to build from), matching the same fast-forward mechanism `docs/103` already
established.

## 12. Live Cloudflare redeployment status

**Not independently observable from this session** — this session's Cloudflare MCP
access covers Workers/D1/KV/R2/Hyperdrive only, with no Pages API (the same gap
`docs/102` §3 already identified; unchanged this session). Pushing to
`feature/corlink-platform-migration` is expected to trigger a new Cloudflare Pages
build automatically per the project's documented branch-tracking configuration, but the
resulting build's success/failure and the live splash-clears-to-login behavior require
either Cloudflare Pages dashboard access or an operator confirming directly against the
real deployed URL.

## 13. Production untouched confirmation

No Supabase tool was invoked against `infjjroktzzhaxjvfknr` (Production) at any point in
this session. No file under `config/environments/production.env` or any production-only
path was read for editing (only referenced read-only, to confirm it stays byte-identical
— see `git diff` in §9, which shows zero changes to it). `main` was not checked out,
merged into, or pushed. Only `js/app.js` and `js/views/meetings.js` were modified, both
frontend logic files with no environment-specific content — the same fix ships
identically to whichever Supabase project a given build targets.

## 14. Remaining blocker

Identical to `docs/102`/`docs/103`'s previously identified gap: **no Cloudflare Pages
dashboard/API access from this session**, so the live redeploy triggered by this fix's
push cannot be independently confirmed to succeed, nor can the real
`*.pages.dev`/custom-domain URL be produced. An operator with Cloudflare Pages dashboard
access should confirm: the new build (from the commit in §10) completed successfully,
the live splash now clears to the login screen for a fresh/incognito visit, and Tasks
remains visible for an authenticated user (per `docs/102` §12's static confirmation,
unaffected by this fix).
