# 117 — Linked-Meeting Detail Routing + Edit/Schedule Form Unification

## 1. Requirement

"When I click a booked meeting I should see this window like in MeetFlow. And when I click edit it should see the meeting edit window same like new meeting."

## 2. Booking Click → Full Meeting Detail (not the room-only Booking Details modal)

Every booking made through the combined Schedule Meeting form (docs/115) is linked to a real meeting (`meeting_room_bookings.meeting_id`), but clicking it anywhere in Rooms (the schedule grid, My Bookings, Pending Approvals, or a deep link) still opened the bare room-only "Booking Details" modal (Room/Status/When/Requested By/Section) with, at best, a "Linked to a meeting — View" badge to navigate away and see the real content. MeetFlow shows the rich meeting view directly.

`rooms.js` gains `_openBookingOrMeetingDetailModal(booking)`: when a booking carries a `meeting_id` and the Meetings module is enabled, it fetches the full meeting (`MeetingsAPI.fetchMeeting`) and opens `MeetingsView._openMeetingDetailModal()` — the same rich detail view (participants, RSVP, My Notes, minutes, documents, notify, lock/edit/cancel) already used from the Meetings tab, in CorLink's own theme (matching this session's established rule throughout docs/115-117: MeetFlow's *layout concept* — full context on click, not a bare stub — never its colors/branding). A booking with no `meeting_id` (the room-only fallback path, or Meetings disabled for the org) still falls back to the original Booking Details modal, unchanged. All four places a booking was clickable now go through this one helper.

Since `_openMeetingDetailModal` (and its many permission helpers — `_canOverrideLock`, `_canManageRoom`, etc.) reads `this._isAdmin`/`this._isSupervisor`/`this._orgId`/`this._roomsEnabled`, which `MeetingsView.render()` normally sets but a caller reaching it straight from Rooms (without ever rendering the Meetings tab this session) wouldn't have — added `_ensureUserContext()`, a small idempotent helper that fills in whatever `render()` hasn't already set, called at the top of both `_openMeetingDetailModal()` and `_openScheduleMeetingModal()`.

## 3. Edit Meeting Rebuilt to Match Schedule Meeting

`_openEditMeetingModal()` was still the original, narrower form (Title/Description/Meeting Type/Visibility/Status/Starts+Ends-as-two-datetime-pickers/Timezone/Location) — visually and structurally unrelated to the combined Schedule Meeting form built in docs/115-116. Rebuilt to the same field set and two-column layout:

- **Format** (not "Location"), same wording as Create — In person/Room, In person/External, Online/Virtual link — with the same hybrid checkbox revealing an optional virtual link alongside a room or external meeting.
- **Section** (already added in docs/116), **Date/Start Time/Duration** in place of two separate datetime-local pickers, **Privacy** (renamed from "Visibility", same Public/Private wording), bilingual **Agenda/Notes** (already added in docs/116).
- **No Timezone** (always Indian/Maldives, matching Create) and **no Meeting Type** field (fixed at creation, matching Create — `update_meeting`'s `p_meeting_type` simply isn't sent, so `COALESCE` leaves the existing value untouched server-side; nothing is silently reset).

Two things are deliberately **not** carried over from Create:
- **Recurrence** — editing a single occurrence never turns it into a series.
- **The inline Participants panel** — the meeting already exists; its detail view's own Add/Remove Participant flows already manage this without duplicating that logic (and state) inside the edit form.

A room-based meeting's room renders as **read-only text** (name + a pointer to "Assign/Change Room from the meeting detail"), not an editable select — reassigning a room already goes through a distinct, working, already-tested flow (`assign_room_booking`/`_openChangeRoomModal`) that manages the linked booking record itself; re-deriving that inline here would either duplicate it or risk silently diverging from it. Availability-based duration capping (docs/116) was also deliberately left out of Edit: naively reusing that logic would flag the room as conflicting with the meeting's *own* existing booking.

## 4. Tests

7 new checks in `tests/schedule-meeting-combined-form-frontend.test.js` (Edit renders the same field set with no Timezone/Meeting Type/recurrence/participants panel; prefills date/start/duration from `start_at`/`end_at`; submits `updateMeeting` with correctly recomputed start/end and the section; a room-based meeting shows read-only room text) and 2 in `tests/rooms-calendar-week-grid-integration-frontend.test.js` (a linked booking opens the meeting detail via `fetchMeeting`, never the room-only modal; an unlinked booking still opens the room-only modal). Full regression sweep run clean.

## 5. Deployment

Committed and pushed to `claude/phase-2-continuation-mc4hr1`, then fast-forwarded onto `feature/corlink-platform-migration` (staging, `https://corlink.pages.dev`).
