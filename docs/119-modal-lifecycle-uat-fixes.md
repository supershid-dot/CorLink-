# 119 — Modal Lifecycle UAT Fixes: No Auto-Close on Action, No Click-Outside-to-Dismiss

## 1. Requirement

UAT screenshot of the Admin "Manage User" panel, with two complaints:

> "when i close[click] any button this automatically closes, this should not happen, also when i click outside of the screen other than this form, the form closes automatically, this happens to all the forms"

Two distinct bugs, confirmed against the code:

1. **Admin's Manage User panel** (`_openManageUserModal`) bundles several independent actions in one modal — Save Profile, Deactivate/Activate, Grant/Revoke Admin Access, Grant/Revoke Prisoner Letters Access, Add/Remove/Set-Primary Section Assignment — and every single one of them called `this._closeModal()` on success. Doing two of these in a row (e.g. grant admin access, then also add a section assignment) required reopening the panel from the Users list after each click.
2. **Every modal in the app** closes when the dark backdrop behind it is clicked (`js/views/*.js`'s `_openModal` helpers all wire `document.getElementById('modal-overlay').addEventListener('click', e => { if (e.target.id === 'modal-overlay') this._closeModal(); })`). Confirmed via AskUserQuestion this should be removed everywhere, not just Admin — an accidental backdrop click (e.g. scrolling a long form near its edge) shouldn't silently discard unsaved input in any of this app's forms.

## 2. Fix 1 — Admin Manage User panel stays open

`_openManageUserModal` (`js/views/admin.js`) gained a local `refreshManageUserModal()` helper: instead of `this._closeModal(); await this._renderTab();`, every action handler now calls this helper, which refreshes the underlying Users table in the background (`this._renderTab()` — confirmed to only touch `#admin-tab-content`, never `#modal-root`, so it's safe to call while a modal is open) and then re-fetches this user's own record (`AdminAPI.listUsersByOrg`) and re-invokes `_openManageUserModal` with the fresh data, re-rendering the same modal in place. Two previously-uncaught handlers (`toggle-user-active`, `toggle-prisoner-letters-staff`) also gained the same try/catch-and-show-inline-error pattern every other handler here already used, since a failed toggle should surface an error in the still-open panel rather than throw silently.

Only the explicit **Close** button, and the temp-password screen's own **Done** button (a genuinely one-shot result screen reached via Reset Password), still dismiss the modal.

## 3. Fix 2 — click-outside-to-close removed app-wide

The `if (e.target.id === 'modal-overlay') this._closeModal()` listener was deleted from every view's `_openModal` helper: `admin.js`, `requests.js`, `request-detail.js`, `prisoner-letters.js`, `prisoner-letter-detail.js`, `entry.js`, `entry-detail.js`, `rooms.js`, `meetings.js`, `calendar.js`, `task-create-modal.js`. `task-detail.js`'s modal helper had the same listener plus a separate Escape-key/focus-trap `keydown` handler; only the click listener was removed — Escape-to-close and Tab focus-trapping are unrelated, standard accessibility behavior the user didn't ask to change, so they're untouched. Every modal now only closes via its own explicit `[data-close-modal]` button(s).

## 4. Tests

New `tests/admin-manage-user-modal-frontend.test.js` (7 checks): Deactivate/Grant-Admin/Grant-Prisoner-Letters/Add-Assignment/Remove-Assignment each keep the modal open and show refreshed data; the explicit Close button still closes it; clicking the backdrop directly no longer does. The backdrop-click removal itself is a one-line mechanical deletion repeated identically across 12 files' `_openModal` helpers — spot-checked via this one test rather than duplicated per view.

Also fixed an unrelated pre-existing flaky test found during the regression sweep: `tests/week-grid-frontend.test.js`'s "mobile: empty half-hour slots render a bookable row" hardcoded `todayStr: '2026-09-16'` without freezing the page's `Date`, so once the real calendar date moved past 2026-09-16 the grid's own past-slot lockout (docs/113) correctly closed every slot on that now-past day, leaving nothing to click. Switched it to the file's own existing frozen-`Date` harness (`newPageAt`, already used by later tests in the same file) pinned to `2026-09-16T00:00:00`.

Full regression sweep across all 21 test files run clean (the same 4 pre-existing files that need `PLAYWRIGHT_CORE_PATH`/`EDGE_PATH` env vars this sandbox doesn't set still fail to start, unrelated to this change, same as every prior session).

## 5. Deployment

Cache-busters bumped for every touched view (`admin.js`, `requests.js`, `request-detail.js`, `prisoner-letters.js`, `prisoner-letter-detail.js`, `entry.js`, `entry-detail.js`, `rooms.js`, `meetings.js`, `calendar.js`, `task-create-modal.js`, `task-detail.js` → `?v=20260917`). Committed and pushed to `claude/phase-2-continuation-mc4hr1`, then fast-forwarded onto `feature/corlink-platform-migration` (staging, `https://corlink.pages.dev`).
