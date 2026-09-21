# 135 — Rooms Schedule Tab: Section Never Showed for Meeting-Linked Bookings

## 1. Symptom

User report: the Rooms Schedule tab's week-grid event chips (organizer name + time/duration) never showed a section name, even though the code already had support for it (`meta: ... b.section?.name ...`, docs/UAT: "in rooms it should show the section name, who booked, and duration").

## 2. Root cause

`meeting_room_bookings` has its own `section_id` column, separate from `meetings.section_id`. A booking made through the combined Schedule Meeting form (the normal path — task #10/#11) creates a linked `meetings` row with its own section, but never writes anything into the booking row's own `section_id` — that column stays `NULL`. `RoomsAPI.fetchBookings()`'s query correctly embedded `section:sections!meeting_room_bookings_section_id_fkey(...)`, so it wasn't broken, it was just always fetching a column that's essentially never populated for the common case (a meeting-linked booking). A genuinely standalone room-only booking (no linked meeting) would have shown its section correctly — this bug only affected the meeting-linked case, which is now the normal way rooms get booked.

## 3. Fix

`BOOKING_SELECT` now also embeds the linked meeting's own section via the existing `meeting_room_bookings.meeting_id -> meetings.id` foreign key: `linked_meeting:meetings!meeting_room_bookings_meeting_id_fkey(section:sections!meetings_section_id_fkey(id, name))`. The Rooms Schedule tab's event-chip builder now prefers `b.linked_meeting?.section?.name`, falling back to the booking's own `b.section?.name` only for a genuinely standalone booking (no linked meeting).

No backend/RPC change — pure query + display fix.

## 4. Files

- `js/data/rooms-api.js` — `BOOKING_SELECT` gains the `linked_meeting` embed.
- `js/views/rooms.js` — `_renderScheduleTab()`'s event-chip `meta` string prefers `linked_meeting.section`, falls back to the booking's own.
- `tests/rooms-calendar-week-grid-integration-frontend.test.js` — updated the existing section-display test to reflect the real shape (`section: null`, `linked_meeting.section` populated); added a new test for the standalone-booking fallback case.

## 5. Deployment

Frontend-only — cache-busters bumped (`rooms-api.js`, `rooms.js`), full regression sweep clean (same pre-existing, unrelated failures).
