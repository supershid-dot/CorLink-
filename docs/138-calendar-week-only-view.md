# 138 — Calendar Tab: Week View Only

## 1. UAT

Screenshot of the Calendar tab in Month view, plus:

> "Change the calendar view same as in rooms, only weekly view is needed like in rooms"

## 2. Change

The Calendar tab's Day/Week/Month/Agenda mode switcher is gone — it now always shows the shared WeekGrid component (`js/views/week-grid.js`), exactly like Rooms' own Schedule tab, which never offered anything but a week grid either. Prev/Today/Next navigation and the existing filter row (org/room/creator/status/type/staff/show-blocks) are unchanged.

Removed along with the switcher: the Month grid, the Day list, and the Agenda list renderers (`_renderMonth`/`_renderDay`/`_renderAgenda`), their shared `_groupByDay` grouping helper, and the chip/row markup builders (`_eventChip`/`_eventRow`) and empty-state helper (`_emptyBlock`) those views alone used — none of it has a caller left. The now-dead `.calendar-view-switch`/`.calendar-month-*`/`.calendar-event-chip`/`.calendar-event-row*`/`.calendar-day-list`/`.calendar-agenda-*`/`.calendar-more-link` CSS rules were removed with them; the per-item-type color classes (`.calendar-event--meeting`/`--draft`/`--cancelled`/`--booking`/`--block`) stay, since WeekGrid's own event elements still use them.

Week view's own `onSlotClick` (previously: clicking empty space switched to Day view for that date) is also gone — there's no drill-down view left to switch into, and Calendar has never had a create action of its own (it's a pure read-only aggregation of Meetings/Rooms data, per this file's own long-standing header comment). Clicking an empty slot is now a no-op, same as it already was for the room/status/etc. filters not applying anything new — nothing regressed, since Day view's own reason for existing (a different date-scoped rendering of the same events) is gone with it.

`_bindEventClicks()` was also removed — it queried a `data-event-type` attribute that only the now-deleted Month/Day/Agenda markup ever carried; the shared WeekGrid component's own click handling (`WeekGrid.bind(...).onEventClick`) was always the actual click path for week view and remains unchanged.

## 3. Files

- `js/views/calendar.js` — mode switcher, `_renderMonth`/`_renderDay`/`_renderAgenda`/`_groupByDay`/`_eventChip`/`_eventRow`/`_emptyBlock`/`_bindEventClicks` removed; `_rangeForMode()` renamed to `_currentWeekRange()` and simplified to always return the anchor's own week; `_rangeLabel()` simplified (no more day-specific format).
- `css/style.css` — dead month/day/agenda-specific rules removed.
- `tests/rooms-calendar-week-grid-integration-frontend.test.js` — updated for the removed mode switcher/Day-view drill-down; fixed two assertions that had been silently matching the wrong (dead) selector.

## 4. Deployment

Frontend-only — cache-busters bumped (`calendar.js`, `style.css`). Full regression sweep: same pre-existing, unrelated failures only.
