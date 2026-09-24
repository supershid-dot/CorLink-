# 160 — Rooms Schedule Grid: Add Back Time Range (Match Calendar's Format)

## 1. UAT

> "here also should show the same as section + time range + duration"

(referring to the Meeting Rooms Schedule grid, right after docs/159 gave the Calendar grid the fuller "section, time range, duration" format.)

## 2. Fix

docs/158 had dropped the time range from the Rooms Schedule grid's event chips (section + duration only). This request asks for parity with Calendar's own format (docs/159): section + time range + duration. `bookingEvents`' `meta` now reads `{time range} · {duration}` again — same `_timeRange()`/`_durationLabel()` helpers already in `rooms.js`, unchanged.

## 3. Files

- `js/views/rooms.js` — `bookingEvents`' `meta` field.
- `tests/rooms-calendar-week-grid-integration-frontend.test.js` — updated assertion to expect the time range again.

## 4. Deployment

Full `rooms-calendar-week-grid-integration` suite re-run (30/30 pass). Verified visually: the event now reads "Offender Records" / "08:00 AM – 09:00 AM · 1h".
