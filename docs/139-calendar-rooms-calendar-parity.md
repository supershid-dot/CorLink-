# 139 — Calendar Tab: Parity with Rooms' Calendar

## 1. UAT

Screenshot of the Calendar tab, cluttered with cancelled (strikethrough, red) meeting chips, plus:

> "this view should only show scheduled meetings by default, and when i click a meeting it should show the same window when i click a meeting in rooms calrndat, and should be able to create new meeting same as in rooms calendar"

("rooms calendar" = Rooms' own Schedule tab, which the user has referred to this way throughout this session.)

## 2. Default: scheduled meetings only

`_state.filters.status` now defaults to `'scheduled'` instead of `''` (all). The status filter — both the dropdown's option list and `_applyFilters`'s check — is scoped to `e.type === 'meeting'` only: a room booking's status vocabulary (`confirmed`/`pending`/`hold`/…) and a block's (`active`/`inactive`) are entirely different from a meeting's (`scheduled`/`cancelled`/`draft`), so the filter never touches them. In practice this hides cancelled and draft meetings out of the box — exactly the clutter in the screenshot — while room bookings/blocks stay exactly as visible as before. The dropdown itself was relabelled "All meeting statuses" to make that scope explicit; picking it still shows everything, same as before.

## 3. Clicking a meeting opens the same in-place window as Rooms

Previously, `_routeEventClick('meeting', id)` did `Router.navigate('meetings', { meetingId: id })` — a full navigation away to the Meetings tab. Rooms' own Schedule tab has never done this: `_openBookingOrMeetingDetailModal()` there calls `MeetingsView._openMeetingDetailModal(meeting)` directly, opening the real meeting detail modal in place, without leaving the Rooms page.

Calendar now does the same: it fetches the meeting (`MeetingsAPI.fetchMeeting(id)`) and calls `MeetingsView._openMeetingDetailModal(meeting)` directly, gated behind a new `this._meetingsEnabled` flag (`AppShell.isModuleEnabled(user, 'meetings') && typeof MeetingsView !== 'undefined'`, set once in `render()`, mirroring the exact guard Rooms already uses before routing to `MeetingsView`). Falls back to the old `Router.navigate` only if the Meetings module/view genuinely isn't available.

`MeetingsView._openMeetingDetailModal()` already calls `_ensureUserContext()` internally (added for exactly this "entry point from outside Meetings' own render()" case, since Rooms already relies on it) and renders into the shared `#modal-root`, so no changes were needed on the Meetings side for the open path to work.

The **close** path did need one change: `MeetingsView._refreshCurrentViews()` — called after a terminal action like Cancel Meeting or Delete Draft — only knew to refresh `#meetings-tab-content` and (since docs/133) `#rooms-tab-content`. It now also refreshes `#calendar-content` (`CalendarView._loadAndRender()`) when mounted, so Calendar's own week grid doesn't go stale after acting on a meeting opened from its own in-place modal — the same class of bug docs/133 already fixed for Rooms.

The staff-schedule preview modal (docs/137, for a meeting sourced from another staff member's schedule) is unaffected — it's deliberately a different, narrower window for exactly the reason its own comment already states (calendar visibility and full-detail access are separate permissions there).

## 4. "+ New Meeting" button

Calendar's page header gains a "+ New Meeting" button, shown only when `this._meetingsEnabled`, calling `MeetingsView._openScheduleMeetingModal({ onSuccess: async () => { await this._loadAndRender(); } })` — the same combined Schedule Meeting form Rooms' own "+ Book" button opens, minus a room prefill (Calendar isn't scoped to one room the way Rooms' Schedule tab is scoped to whichever room is selected there).

## 5. Files

- `js/views/calendar.js` — `_meetingsEnabled` (set in `render()`), the "+ New Meeting" button + handler, `_routeEventClick()` now async and opens the in-place detail modal, default `status: 'scheduled'`, status filter scoped to meeting-type events in both `_renderFilters()` and `_applyFilters()`.
- `js/views/meetings.js` — `_refreshCurrentViews()` also refreshes `CalendarView` when its `#calendar-content` root is mounted.
- `tests/rooms-calendar-week-grid-integration-frontend.test.js` — `newCalendarPage()` gained a `meetingsEnabled` option (and a `viewport` sub-key, replacing the old bare-object viewport param) plus a `window.MeetingsView` mock; new/updated tests for the in-place detail modal, its Meetings-unavailable fallback, the New Meeting button (present/absent), and the default scheduled-only filter (including that room bookings are unaffected).
- `tests/meeting-detail-modal-frontend.test.js` — new test mirroring the existing RoomsView one, for `_refreshCurrentViews()` also refreshing a mounted `CalendarView`.

## 6. Deployment

Frontend-only — cache-busters bumped (`calendar.js`, `meetings.js`). Full regression sweep: same pre-existing, unrelated failures only.
