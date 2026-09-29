# 162 — Nav Drawer: Fix Missing Opaque Background

## 1. UAT

> "This not good, make something like in Claude menu"

(with a screenshot of the new mobile nav drawer from docs/161 rendering see-through — nav item labels overlapping the dashboard's own "Good afternoon, Ibrahim" heading, stat cards, and buttons behind it — and a reference screenshot of Claude's own mobile app nav drawer: a solid, opaque panel.)

## 2. Fix

The mobile-only `.sidebar` drawer rule added in docs/161 set `position: fixed`, sizing, and the slide-in `transform`, but never set a `background` (or the outer `padding` the persistent desktop sidebar has) — that styling only existed in the separate `@media (min-width: 900px)` rule, which doesn't apply at phone widths. The drawer was rendering fully transparent, so the dashboard behind it showed straight through.

Added `background: var(--color-surface)` and `padding: 20px 14px` (plus `flex-direction: column; gap: 2px`, matching the desktop sidebar's own layout) to the mobile drawer rule.

## 3. Files

- `css/style.css` — the `@media (max-width: 640px) .sidebar` rule.
- `tests/mobile-nav-drawer-frontend.test.js` — new test asserting the open drawer has a non-transparent `background-color` and that `elementFromPoint()` inside the drawer's bounds actually hits the drawer (not whatever was behind it) — the same class of bug docs/161's own tests didn't catch, since none of them checked background/opacity.

## 4. Deployment

Full `mobile-nav-drawer` suite re-run (8/8 pass, including the new background test). Verified visually in a headless browser: the drawer now renders as a solid panel (CorLink branding, all 9 nav items, "Need Help? Contact Support" footer) with the dimmed page correctly visible only outside its bounds.
