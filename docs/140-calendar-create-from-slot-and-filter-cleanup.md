# 140 — Calendar: Create From Empty Slot, Filter Cleanup, Today Highlight

## 1. UAT

Screenshot of the Calendar tab with its now-simplified filter row, plus:

> "should be able to book or create meeting by clicking + sign like in rooms, all organization filter is not needed, it should be default to the users organization, creators and meeting type filter is not needed here, in calendar header today must be highlighted by default both in this calendar and rooms calendar"

## 2. Create a meeting by clicking an empty slot

Rooms' Schedule tab has always let you click an empty week-grid slot (the hover "+") to open the combined Schedule Meeting form prefilled with that day/time (`_openBookOrScheduleModal`). Calendar's own empty-slot click was removed in docs/138 (when its old Day-view drill-down went away) with no replacement. It now gets the same behavior directly: `WeekGrid.bind(...)`'s `onSlotClick` opens `MeetingsView._openScheduleMeetingModal({ prefillDate, prefillTime, onSuccess })`, gated behind the same `this._meetingsEnabled` flag already used for the "+ New Meeting" button and the in-place detail modal (docs/139) — a no-op when Meetings isn't available, same as before.

## 3. Filter cleanup

Removed entirely:
- **"All organizations"** — Calendar is now unconditionally scoped to the viewer's own organization. This isn't just dropping the dropdown: `can_view_meeting()`'s RLS grants a super admin every organization's meetings, so the old filter existed specifically to let a super admin narrow that back down. Without it, Calendar would show every org mixed together with no way to unfilter — so `_applyFilters` now enforces `e.orgId === this._orgId` unconditionally instead. The one deliberate exception: this scoping is suspended while viewing a specific staff member's schedule (docs/137's Staff selector), since that picker already independently governs who's viewable and, for a super admin, is allowed to span organizations by design — forcing it back to the caller's own org there would silently break that already-shipped case.
- **"All creators"** and **"All meeting types"** — removed outright, along with the `creators`/`types` Map-building and their `_applyFilters` checks.

Remaining filter row: Room, meeting Status (defaults to `scheduled`, docs/139), the Staff selector (docs/137), and "Show room blocks".

`this._isSuperAdmin`/`this._orgNames`/the `AdminAPI.listOrganizations()` call were all removed too — nothing else in this file used them once the org filter was gone.

## 4. "Today" highlight

`WeekGrid`'s own `.week-grid-day-header--today`/`.week-grid-day-picker--today` classes were already applied correctly (confirmed by an existing regression test, `tests/week-grid-frontend.test.js`, for the exact local-vs-UTC date bug this could otherwise reintroduce) — the problem was purely visual: a same-color text tint alone reads as almost no highlight at all next to the already-bold header text. Both now get the same filled-circle-around-the-date treatment the old Calendar month-grid used for its own "today" cell (a clear, unambiguous marker), plus a light background tint on the header cell itself. Shared CSS, so both Rooms' Schedule tab and Calendar pick it up automatically.

## 5. Files

- `js/views/calendar.js` — `onSlotClick` wired to `MeetingsView._openScheduleMeetingModal`; `_isSuperAdmin`/`_orgNames`/org-listing fetch removed; `_renderFilters()`/`_applyFilters()` lose the org/creator/type controls and checks, gain the unconditional (staff-schedule-aware) org scope.
- `css/style.css` — `.week-grid-day-header--today`/`.week-grid-day-picker--today` restyled with a background tint + filled date badge.
- `tests/rooms-calendar-week-grid-integration-frontend.test.js` — new/updated tests: empty-slot click opens the Schedule Meeting form (and its Meetings-unavailable no-op fallback), the three removed filters are gone, org scoping hides another org's meeting by default, and org scoping is suspended for an explicitly-selected staff member's schedule.

## 6. Deployment

Frontend-only — cache-busters bumped (`calendar.js`, `style.css`). Full regression sweep: same pre-existing, unrelated failures only.
