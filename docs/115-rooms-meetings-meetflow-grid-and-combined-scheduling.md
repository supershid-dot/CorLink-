# 115 — Rooms/Calendar Week-Grid + Combined Schedule Meeting Form

## 1. Summary

Two related deliverables against docs/22's MeetFlow-parity roadmap, both matching MeetFlow's UI/workflow *concepts* only (layout, navigation, single-window flow) — never its colors, branding, or its collapsed data model:

1. **A shared week-grid component** (`js/views/week-grid.js`) replacing Rooms' old day-list Schedule tab and Calendar's old list-style Week mode with a single positioned day-columns × half-hour-rows grid on desktop and a day-picker-strip + single-day agenda on mobile, in CorLink's own `--color-*`/`--radius-*` theme.
2. **A combined "Schedule Meeting" form** (`MeetingsView._openScheduleMeetingModal()` in `js/views/meetings.js`) that books the room and schedules the meeting in one window/one submit, replacing the previous create-meeting → assign-room → add-participants sequence across three separate modals.

## 2. Week-Grid Component

`WeekGrid.html({weekStart, events, todayStr, selectedDay, bookableUntilMinutes})` / `WeekGrid.bind(container, {onSlotClick, onEventClick, onDayPick})` is the one implementation used by both Rooms' Schedule tab and Calendar's Week mode — connected-component clustering + first-fit column packing for overlapping events, a sticky header sharing one scroll container with the body (avoids the scrollbar-width column-drift bug an earlier iteration hit), and a `_isPastSlot()`/`bookableUntilMinutes` combination that makes past dates/times and a room's own `bookable_until` policy both non-clickable without ever hiding a real booking that runs later than either cutoff.

Every "calendar day" computation across `week-grid.js`/`rooms.js`/`calendar.js` uses local-date-component construction (`_dayStr()`), not `toISOString().slice(0,10)` — the latter returns the UTC date and silently shifts the computed "today" by a day once the viewer's UTC offset crosses a midnight boundary.

Tests: `tests/week-grid-frontend.test.js` (24 checks — desktop/mobile rendering, event layout/packing, range auto-expansion, bookable-until enforcement, timezone-correct today-highlight, past-slot lockout, hover "+" affordance), `tests/rooms-calendar-week-grid-integration-frontend.test.js` (12 checks — both views wired end to end).

## 3. Combined Schedule Meeting Form

### 3.1 Problem

Clicking an empty slot in Rooms' grid opened a room-only "New Booking" modal (room/time/timezone/section — no meeting details at all). Creating a meeting from the Meetings tab was a separate, multi-step flow: `create_meeting` (bare title/time), then a separate "Assign Room" modal calling `assign_room_booking`, then a separate "Add Participant" modal per person/group. MeetFlow has no such split — its entire model is `meetings.room_id`; there is no independent "room booking" concept. UAT asked for the same single-window result: pick a room, set the time, add whoever needs to attend, and submit once.

### 3.2 What already existed (no backend changes needed)

Investigation before writing any code found every piece already built and independently tested:
- `meeting_participants` already carries `external_name`/`external_email`/`external_phone`/`external_organization_name` alongside a nullable `user_id` — external ("guest") participants were already a first-class, working feature via `add_participant`, just never exposed at meeting-creation time.
- `assign_room_booking(meeting_id, room_id)` already internally dispatches to `create_room_booking` (room manager → auto-confirmed) or `submit_booking_request` (non-manager → pending approval) — identical semantics to the standalone Rooms booking flow, so routing a booking through a meeting changes nothing about who needs to approve it.
- `create_recurring_meeting` already accepts `p_room_id` and `p_group_id` directly, applying both atomically across every generated occurrence.
- `apply_group_to_meeting` already exists for the non-recurring path.

No migration, RPC, or RLS change was needed — only client-side sequencing of RPCs that already had their own coverage.

### 3.3 What changed

- **`MeetingsView._openScheduleMeetingModal({prefillRoomId, prefillDate, prefillTime, onSuccess})`** (`js/views/meetings.js`) — one form: title, meeting type, format (room/external/virtual — room option hidden when the Rooms module is disabled for the org), meeting room + Check Availability, date/start time/duration, timezone, recurrence quick-picks (None/Weekly/Every 2 weeks/Monthly, revealing a Series End Date field), agenda notes, privacy (visibility), and a Participants panel (organizer chip + queued staff/group/guest chips, each removable, added via a Staff-search/Group/Guest tab set reusing the same add-participant UI pattern already used elsewhere in this file).
  - Non-recurring submit: `createMeeting` → `assignRoomBooking` (if a room was picked) → `applyGroupToMeeting` (if a group was queued) → `addParticipant` per queued staff/guest.
  - Recurring submit: `createRecurringMeeting` (room and the single queued group passed directly, atomic across the series) → `addParticipant` per queued staff/guest against every created occurrence.
  - Each post-creation step is caught individually; a partial failure (e.g. a room conflict) does not roll back the meeting/series already created — it's surfaced via `alert()` after close, the same `alert(failures.join('\n'))` pattern already used elsewhere in this codebase for partial multi-step failures (entry.js/request-detail.js attachment uploads).
- **`MeetingsView._openMeetingFormModal`** was edit-only to begin with in spirit (its `isEdit` branch was the only one still reachable once creation moved to the new modal) — renamed to **`_openEditMeetingModal(meeting)`** and simplified to drop the now-dead create branch entirely, rather than leaving unreachable code behind.
- **Rooms' booking flow** (`js/views/rooms.js`): the toolbar "Book" button and the grid's `onSlotClick` now call a new **`_openBookOrScheduleModal({date, time})`**, which opens `MeetingsView._openScheduleMeetingModal()` prefilled with the selected room/day/time when the Meetings module is enabled for the org, or falls back to the original room-only `_openBookingFormModal()` when it isn't (there is no meeting flow to route to in that case). `onSuccess` refreshes Rooms' own grid in place rather than navigating away.
- **Meetings' own "New Meeting" button** now opens the same combined modal (no separate "bare meeting" creation path left in the UI); the dedicated "Recurring Series" button/modal is unchanged and still available for the fuller series-focused form.
- Deliberately **out of scope**: MeetFlow's "On behalf of Section" field has no equivalent column anywhere in `meetings` and would require new schema — omitted rather than adding a UI field with nothing behind it.

### 3.4 Tests

- `tests/schedule-meeting-combined-form-frontend.test.js` (new, 7 checks) — field rendering, prefill wiring, Rooms-module-disabled hides the room option, non-recurring submit sequences `createMeeting`→`assignRoomBooking` correctly, queued staff/group/guest each hit the right API, recurrence submit calls `createRecurringMeeting` (not `createMeeting`) with room+group passed atomically, and a validation rejection when Format=Room has no room selected.
- `tests/rooms-calendar-week-grid-integration-frontend.test.js` — one new check confirming Rooms' slot-click routes to `MeetingsView._openScheduleMeetingModal` (not the room-only fallback) with the correct room/date/time prefill when Meetings is enabled.
- Full regression sweep (all `tests/*.test.js`) run clean; the one pre-existing failure (`internal-collaboration-notification-integration-frontend.test.js`, CAP003_ROUTES `prisoner_letter` key) predates and is unrelated to this work.

## 4. Deployment

Committed and pushed to `claude/phase-2-continuation-mc4hr1`, then fast-forwarded onto `feature/corlink-platform-migration` (staging, `https://corlink.pages.dev`) after verifying zero unique staging commits.
