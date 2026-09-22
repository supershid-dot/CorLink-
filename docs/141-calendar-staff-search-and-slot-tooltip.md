# 141 — Calendar: Searchable Staff Filter + Slot-Hover Time Tooltip

## 1. UAT

Screenshot of the Staff filter's dropdown open, showing a flat list of staff names, plus:

> "list should be searchable" / "and when i move mouse to + sign it should show the timing"

## 2. Searchable Staff filter

The Staff filter (docs/137) was a plain `<select>` — no search of its own once the org has more than a handful of staff. Replaced with a small combobox: a text input (`#cal-filter-staff-input`) that, on focus, shows a floating options panel (`#cal-filter-staff-list`) below it; typing filters that panel live by substring match against each option's label. Selecting an option (mousedown, not click, so it registers before the input's own blur would otherwise close the panel first) sets `filters.staffId` exactly as the old `<select>`'s change handler did, and re-fetches via `_loadAndRender()` for a real staff id. Blurring without picking anything reverts the input's text back to the current selection, discarding any unconfirmed typed query.

New CSS (`.combobox`/`.combobox-list`/`.combobox-option`/`.combobox-empty`) mirrors this app's existing absolute-panel dropdowns (`.user-menu-dropdown`, `.row-actions-menu`) rather than inventing a new visual language.

No other filter changed shape — Room and Status stay plain `<select>`s (short, fixed option counts that don't need search).

## 3. "+" slot hover shows its time

The desktop week-grid's empty-slot hover affordance (the "+") carried no visible time indication — the mobile row equivalent already shows its time range as text, but hovering has no meaning on touch, so that gap was desktop-only. Each open slot's `title` attribute now reads e.g. `"09:00 – 09:30"` (the native browser tooltip), computed from the slot's own start/`SLOT_MINUTES`. `WeekGrid` is shared by both Rooms' Schedule tab and Calendar, so this applies to both automatically — closed (non-bookable) slots already had their own `title` ("Not bookable at this time") and are unaffected.

## 4. Files

- `js/views/calendar.js` — `_staffOptions()`, `_bindStaffCombobox()`; the `<select id="cal-filter-staff">` is now the `#cal-filter-staff-box` combobox markup in `_renderFilters()`.
- `js/views/week-grid.js` — `_desktopHtml()`'s open-slot template gains a computed `title` (time range).
- `css/style.css` — new `.combobox`/`.combobox-list`/`.combobox-option`/`.combobox-empty` rules.
- `tests/rooms-calendar-week-grid-integration-frontend.test.js` — `selectCalendarStaff()` helper replacing the old `select.value = …; dispatchEvent('change')` pattern everywhere the Staff filter is exercised; new assertions for live filtering, the "No matches" empty state, and reverting on blur.
- `tests/week-grid-frontend.test.js` — updated the existing hover-affordance test's regex for the new attribute, added a `title` assertion.

## 5. Deployment

Frontend-only — cache-busters bumped (`calendar.js`, `week-grid.js`, `style.css`). Full regression sweep: same pre-existing, unrelated failures only.
