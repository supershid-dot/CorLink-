# 161 — Mobile Nav: Vertical Drawer Instead of the Crowded Bottom Tab Bar

## 1. UAT

> "The bottom menus looks crowded. Change it to another method. Maybe vertical menu"

(with a screenshot of the fixed bottom tab bar squeezed to fit 8 visible items — Home, Tasks, Requests, Entry, Rooms, Calendar, Meetings, Letters, with Admin cut off — labels overlapping/truncated.)

## 2. Fix

The fixed bottom tab bar (designed for 7 items, grown to 9 as the app added Calendar/Meetings/Admin over time) is gone. In its place: a hamburger button in the mobile topbar opens `#sidebar` — the exact same vertical nav markup the persistent desktop sidebar already uses — as an off-canvas drawer that slides in from the left, with a semi-transparent backdrop behind it. This reuses one nav-item list instead of introducing a third hand-duplicated copy (the app already had two: `topbarHtml()`'s inline links and `sidebarHtml()`'s vertical list — the removed `bottomNavHtml()` was the third).

The drawer closes on: tapping the backdrop, tapping its own close button, or picking any nav link (so a normal tap-to-navigate never leaves it open in the background). Only the ≤640px tier changes — the 641–899px tier already showed the topbar's inline nav links without crowding and is untouched.

## 3. Files

- `js/views/shell.js` — removed `bottomNavHtml()` entirely; `sidebarHtml()` gained a close button (`#sidebar-close-btn`, hidden on desktop); `topbarHtml()` gained the hamburger trigger (`#topbar-menu-btn`) and a backdrop element (`#sidebar-backdrop`); `bindTopbar()` wires open/close.
- 14 view files (`admin.js`, `calendar.js`, `dashboard.js`, `entry.js`, `entry-detail.js`, `meetings.js`, `prisoner-letter-detail.js`, `prisoner-letters.js`, `request-detail.js`, `requests.js`, `rooms.js`, `task-dashboard.js`, `task-detail.js`, `tasks.js`) — removed their now-dead `${AppShell.bottomNavHtml(...)}` call (17 call sites; `topbarHtml()`'s own output already includes the sidebar/drawer, so no other change was needed per view).
- `css/style.css` — removed `.bottom-nav`/`.bottom-nav-item*`/`.bottom-nav-icon-wrap`/`.nav-action-badge--corner` (all dead); new `.topbar-menu-btn`/`.sidebar-close-btn`/`.sidebar-backdrop` rules; the ≤640px block turns `#sidebar` into a `position: fixed`, off-canvas (`transform: translateX(-100%)`, `.sidebar--open` slides it in) drawer instead of showing the old tab bar; `.main-content`'s mobile padding no longer reserves space for a fixed bottom bar that doesn't exist any more; `.topbar-appname`'s max-width recalculated for the new hamburger button's footprint.
- `tests/mobile-nav-drawer-frontend.test.js` (new) — open/close interactions (hamburger, backdrop, close button, nav-link), confirms `bottomNavHtml` is genuinely removed (not just hidden), confirms the drawer lists every module-gated item correctly, confirms the hamburger is hidden at desktop width.

## 4. Deployment

Full regression sweep (all 26 test files) run — only the same pre-existing, unrelated failures already documented in docs/144 (`meeting-detail-modal`, `schedule-meeting-combined-form` date-drift) plus a handful of test files that fail to even load in this sandbox for missing environment variables unrelated to this change (documented previously as a known sandbox limitation). Zero new regressions. Verified interactively in a headless browser at phone width (390×844): the drawer opens/closes correctly, lists all 9 nav items, and the hamburger/close button are correctly hidden at desktop width — confirmed via computed styles and `elementFromPoint()` hit-testing (this sandbox can't render the Tabler icon font, so screenshots alone were misleading here; DOM-level verification was used instead).
